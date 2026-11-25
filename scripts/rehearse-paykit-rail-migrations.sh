#!/usr/bin/env bash
# Rehearse a candidate Paykit image against a schema-only clone of the rail.
# Inputs: PAYKIT_CANDIDATE_DIGEST, PAYKIT_SOURCE_SHA, PAYKIT_SERVER_REPO,
# PAYKIT_RAIL_CONFIG, and RAILWAY_PROJECT_ID, RAILWAY_ENVIRONMENT,
# RAILWAY_DATABASE_SERVICE. PAYKIT_IMAGE_REPOSITORY optionally changes the
# image repository. PAYKIT_MIGRATOR_ROLE, PAYKIT_RUNTIME_ROLE, and
# PAYKIT_PG_CLIENT_BIN set the roles and PostgreSQL client directory.
# PAYKIT_REHEARSAL_POSTGRES_IMAGE, PAYKIT_REHEARSAL_PLATFORM,
# PAYKIT_REHEARSAL_START_TIMEOUT, PAYKIT_REHEARSAL_WINDOW, and
# PAYKIT_REHEARSAL_EVIDENCE_DIR set the clone image, platform, deadlines, and
# optional evidence destination. Roles default to postgres and the migrator
# role. The clone defaults to postgres:<source-major>, the candidate platform
# to linux/amd64, and the start timeout and window to 240 and 20 seconds.
# Exit 0 prints GATE: PROCEED; exit 1 is a hard stop; exit 2 is an input or
# tool error; interruptions exit 130 or 143. Every non-proceed result stops.
# PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE is a local test hook that replaces the
# Railway tunnel with a mode-0600 URL file. It is not an operator path.
umask 077
set -Eeuo pipefail
export LC_ALL=C

scratch=""
tunnel_pid=""
random_id=""
network_name=""
clone_name=""
candidate_name=""
network_created=false
clone_created=false
candidate_created=false
candidate_failure=false
gate_decision=""
gate_reason="incomplete rehearsal"
gate_exit=2
candidate_image=""
source_host=""
source_port=""
source_user=""
source_database=""
source_server_version_num=""
source_server_major=""
expected_stack_id=""
metadata_present=false
stack_identity_present=false
ledger_present=false
relation_count=""
new_migration_files=""
metadata_line=""
liveness_first="not run"
liveness_second="not run"
clone_ledger=""
throwaway_master_key=""
clone_password=""
migrator_password=""
runtime_password=""
migrator_url=""
runtime_url=""
start_timeout=240
observation_window=20

progress() {
  printf 'rehearsal: %s\n' "$*" >&2
}

cleanup() {
  trap - EXIT
  trap '' INT TERM HUP
  if [[ -n "$tunnel_pid" ]]; then
    stop_process_tree "$tunnel_pid"
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=""
  fi
  if [[ "$candidate_created" == true && -n "$candidate_name" ]] && command -v docker >/dev/null 2>&1; then
    docker rm -f "$candidate_name" >/dev/null 2>&1 || true
  fi
  if [[ "$clone_created" == true && -n "$clone_name" ]] && command -v docker >/dev/null 2>&1; then
    docker rm -fv "$clone_name" >/dev/null 2>&1 || true
  fi
  if [[ "$network_created" == true && -n "$network_name" ]] && command -v docker >/dev/null 2>&1; then
    docker network rm "$network_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "$scratch" && -d "$scratch" ]]; then
    rm -rf "$scratch" || true
  fi
  unset PGPASSFILE PGOPTIONS || true
  unset throwaway_master_key clone_password migrator_password runtime_password || true
  unset migrator_url runtime_url || true
}

write_evidence() {
  local decision=$1
  local exit_code=$2
  local evidence_dir=${PAYKIT_REHEARSAL_EVIDENCE_DIR:-}
  local candidate_ledger_summary="not read"
  [[ -n "$evidence_dir" ]] || return 0
  if [[ -n "$scratch" && -f "$scratch/candidate-ledger" ]]; then
    candidate_ledger_summary="$(<"$scratch/candidate-ledger")"
  fi
  mkdir -p "$evidence_dir" || return 0
  if [[ -n "$scratch" && -f "$scratch/candidate.log" ]]; then
    cp "$scratch/candidate.log" "$evidence_dir/candidate.log" || true
  fi
  if [[ -n "$scratch" && -f "$scratch/config-check.log" ]]; then
    cp "$scratch/config-check.log" "$evidence_dir/config-check.log" || true
  fi
  {
    printf 'decision=%s\n' "$decision"
    printf 'reason=%s\n' "$gate_reason"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'candidate_digest=%s\n' "${PAYKIT_CANDIDATE_DIGEST:-}"
    printf 'candidate_source_sha=%s\n' "${PAYKIT_SOURCE_SHA:-}"
    printf 'source_postgresql_version=%s\n' "$source_server_version_num"
    printf 'candidate_migration_ledger=%s\n' "$candidate_ledger_summary"
    printf 'new_migration_files=%s\n' "${new_migration_files:-none}"
    printf 'metadata_line=%s\n' "${metadata_line:-not captured}"
    printf 'first_liveness=%s\n' "$liveness_first"
    printf 'second_liveness=%s\n' "$liveness_second"
    printf 'clone_ledger=%s\n' "${clone_ledger:-not read}"
  } >"$evidence_dir/gate-summary.txt" || true
}

on_exit() {
  local original_exit=$?
  local final_exit
  trap '' INT TERM HUP
  set +e
  if [[ -z "$gate_decision" ]]; then
    gate_decision=STOP
    case "$original_exit" in
      2|130|143)
        gate_exit=$original_exit
        ;;
      *)
        gate_exit=1
        ;;
    esac
  fi
  final_exit=$gate_exit
  if [[ "$candidate_failure" == true && -n "$scratch" && -f "$scratch/candidate.log" ]]; then
    progress "last 40 candidate log lines"
    tail -n 40 "$scratch/candidate.log" >&2 || true
  fi
  write_evidence "$gate_decision" "$final_exit"
  cleanup
  if [[ "$gate_decision" == PROCEED ]]; then
    printf 'GATE: PROCEED (%s)\n' "$gate_reason"
  else
    printf 'GATE: STOP (%s)\n' "$gate_reason" >&2
  fi
  exit "$final_exit"
}

on_signal() {
  local signal_exit=$1
  gate_decision=STOP
  gate_reason="interrupted"
  gate_exit=$signal_exit
  exit "$signal_exit"
}

stop() {
  local reason=$1
  local code=${2:-1}
  gate_decision=STOP
  gate_reason=$reason
  gate_exit=$code
  progress "$reason"
  exit "$code"
}

proceed() {
  gate_decision=PROCEED
  gate_reason=$1
  gate_exit=0
}

require_value() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    stop "$name is required" 2
  fi
}

validate_inputs() {
  require_value PAYKIT_CANDIDATE_DIGEST
  require_value PAYKIT_SOURCE_SHA
  require_value PAYKIT_SERVER_REPO
  require_value PAYKIT_RAIL_CONFIG
  if [[ ! "$PAYKIT_CANDIDATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    stop "PAYKIT_CANDIDATE_DIGEST must be sha256 followed by 64 lowercase hex characters" 2
  fi
  if [[ ! "$PAYKIT_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    stop "PAYKIT_SOURCE_SHA must be 40 lowercase hex characters" 2
  fi
  if [[ ! -d "$PAYKIT_SERVER_REPO" ]]; then
    stop "PAYKIT_SERVER_REPO is not a directory" 2
  fi
  if [[ ! -f "$PAYKIT_RAIL_CONFIG" || ! -r "$PAYKIT_RAIL_CONFIG" ]]; then
    stop "PAYKIT_RAIL_CONFIG is not a readable file" 2
  fi
  if [[ -n "${PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE:-}" ]]; then
    if [[ ! -f "$PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE" || ! -r "$PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE" ]]; then
      stop "PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE is not a readable file" 2
    fi
  else
    require_value RAILWAY_PROJECT_ID
    require_value RAILWAY_ENVIRONMENT
    require_value RAILWAY_DATABASE_SERVICE
  fi
  start_timeout=${PAYKIT_REHEARSAL_START_TIMEOUT:-240}
  observation_window=${PAYKIT_REHEARSAL_WINDOW:-20}
  if [[ ! "$start_timeout" =~ ^[0-9]+$ || "$start_timeout" =~ ^0+$ ]]; then
    stop "PAYKIT_REHEARSAL_START_TIMEOUT must be a positive integer" 2
  fi
  if [[ ! "$observation_window" =~ ^[0-9]+$ ]]; then
    stop "PAYKIT_REHEARSAL_WINDOW must be a non-negative integer" 2
  fi
  start_timeout=$((10#$start_timeout))
  observation_window=$((10#$observation_window))
  if ! command -v python3 >/dev/null 2>&1; then
    stop "required tool is unavailable: python3" 2
  fi
  if ! python3 - "$PAYKIT_RAIL_CONFIG" ${PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE:+"$PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE"} <<'PY'
import os
import stat
import sys
import tomllib
from pathlib import Path

if sys.version_info < (3, 11):
    raise SystemExit(2)
try:
    with Path(sys.argv[1]).open("rb") as source:
        config = tomllib.load(source)
    assert config["bitcoin"]["network"] == "regtest"
    assert config["deployment"]["stack_role"] == "proof"
    if len(sys.argv) == 3:
        mode = stat.S_IMODE(os.stat(sys.argv[2]).st_mode)
        if mode != 0o600:
            raise ValueError("test source URL file mode is not 0600")
except (KeyError, TypeError, ValueError, OSError, tomllib.TOMLDecodeError, AssertionError):
    raise SystemExit(1)
PY
  then
    stop "rail TOML must be valid with bitcoin.network=regtest and deployment.stack_role=proof; a test URL file must be mode 0600" 2
  fi
}

preflight_tools() {
  local tool
  local pg_client_bin
  if [[ -n "${PAYKIT_PG_CLIENT_BIN:-}" ]]; then
    pg_client_bin=$PAYKIT_PG_CLIENT_BIN
    export PATH="$pg_client_bin:$PATH"
  elif [[ -d /opt/homebrew/opt/libpq/bin ]]; then
    export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
  fi
  for tool in docker git python3 openssl pgrep psql pg_dump pg_dumpall pg_restore; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      stop "required tool is unavailable: $tool" 2
    fi
  done
  if [[ -z "${PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE:-}" ]] && ! command -v railway >/dev/null 2>&1; then
    stop "required tool is unavailable: railway" 2
  fi
  if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
    stop "python3 3.11 or newer is required" 2
  fi
  if ! docker info >/dev/null 2>&1; then
    stop "docker daemon is unavailable" 2
  fi
}

make_scratch() {
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/paykit-rail-rehearsal.XXXXXX") || stop "could not create scratch directory" 2
  chmod 0700 "$scratch" || stop "could not protect scratch directory" 2
  if ! python3 -c 'import os, stat, sys; raise SystemExit(stat.S_IMODE(os.stat(sys.argv[1]).st_mode) != 0o700)' "$scratch"; then
    stop "scratch directory mode is not 0700" 2
  fi
  random_id=$(openssl rand -hex 8) || stop "could not generate resource names" 2
  if [[ ! "$random_id" =~ ^[0-9a-f]{16}$ ]]; then
    stop "could not generate valid resource names" 2
  fi
  network_name="paykit-rail-rehearsal-${random_id}-net"
  clone_name="paykit-rail-rehearsal-${random_id}-clone"
  candidate_name="paykit-rail-rehearsal-${random_id}-candidate"
}

pull_candidate() {
  local repository=${PAYKIT_IMAGE_REPOSITORY:-ghcr.io/bitcoinerrorlog/paykit-server}
  local platform=${PAYKIT_REHEARSAL_PLATFORM:-linux/amd64}
  local revision
  candidate_image="${repository}@${PAYKIT_CANDIDATE_DIGEST}"
  progress "pulling candidate image"
  if ! docker pull --platform "$platform" "$candidate_image" >"$scratch/candidate-pull.log" 2>&1; then
    stop "candidate image pull failed" 2
  fi
  revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$candidate_image") || stop "candidate image label could not be read" 2
  if [[ "$revision" != "$PAYKIT_SOURCE_SHA" ]]; then
    stop "candidate image revision does not equal PAYKIT_SOURCE_SHA" 2
  fi
}

list_candidate_migrations() {
  progress "reading candidate migration files"
  if ! python3 - "$PAYKIT_SERVER_REPO" "$PAYKIT_SOURCE_SHA" "$scratch" <<'PY'
import hashlib
import re
import subprocess
import sys
from pathlib import Path

repo, requested_sha, output_dir = sys.argv[1:]
out = Path(output_dir)
def git(*args):
    return subprocess.run(
        ["git", "-C", repo, *args], check=True, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout
try:
    commit = git("rev-parse", "--verify", requested_sha + "^{commit}").decode("ascii").strip()
    if commit != requested_sha:
        raise ValueError("commit mismatch")
    paths = git("ls-tree", "--name-only", commit, "paykit-server/migrations/").decode("utf-8").splitlines()
    rows = []
    versions = set()
    for path in paths:
        name = path.rsplit("/", 1)[-1]
        match = re.fullmatch(r"([0-9]+)_.+\.sql", name)
        if match is None:
            continue
        version = int(match.group(1))
        if version in versions:
            raise ValueError("duplicate migration version")
        versions.add(version)
        blob = git("cat-file", "blob", commit + ":paykit-server/migrations/" + name)
        rows.append((version, name, hashlib.sha384(blob).hexdigest()))
    rows.sort()
    (out / "candidate-files").write_text(
        "".join(f"{version}\t{name}\n" for version, name, _ in rows), encoding="utf-8"
    )
    (out / "candidate-ledger").write_text(
        "".join(f"{version}|t|{checksum}\n" for version, _, checksum in rows), encoding="ascii"
    )
except (subprocess.CalledProcessError, UnicodeError, ValueError, OSError):
    raise SystemExit(1)
PY
  then
    stop "candidate migration files could not be read at PAYKIT_SOURCE_SHA" 2
  fi
}

write_rehearsal_config() {
  progress "writing rehearsal TOML"
  if ! python3 - "$PAYKIT_RAIL_CONFIG" "$scratch/rehearsal.toml" <<'PY'
import json
import math
import re
import sys
import tomllib
from pathlib import Path

source_path, output_path = sys.argv[1:]
with Path(source_path).open("rb") as source:
    config = tomllib.load(source)
if config.get("bitcoin", {}).get("network") != "regtest":
    raise SystemExit(1)
if config.get("deployment", {}).get("stack_role") != "proof":
    raise SystemExit(1)
for table, key, value in (
    ("http", "listen_addr", "0.0.0.0:3001"),
    ("electrum", "endpoint", "tcp://127.0.0.1:9"),
    ("paykit", "auth_relay", "http://127.0.0.1:9/"),
    ("shutdown", "drain_timeout", "5s"),
):
    section = config.setdefault(table, {})
    if not isinstance(section, dict):
        raise SystemExit(1)
    section[key] = value

def key(value):
    if re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return value
    return json.dumps(value, ensure_ascii=False)

def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value):
            return "nan"
        if math.isinf(value):
            return "inf" if value > 0 else "-inf"
        return repr(value)
    if isinstance(value, list):
        if any(isinstance(item, (dict, list)) for item in value):
            raise ValueError("nested arrays and table arrays are unsupported")
        return "[" + ", ".join(scalar(item) for item in value) + "]"
    raise ValueError("unsupported TOML value")

def is_value(value):
    return not isinstance(value, dict)

lines = []
def emit_table(table, path):
    values = [(name, value) for name, value in table.items() if is_value(value)]
    children = [(name, value) for name, value in table.items() if not is_value(value)]
    if path:
        if lines and lines[-1] != "":
            lines.append("")
        lines.append("[" + ".".join(key(part) for part in path) + "]")
    for name, value in values:
        lines.append(key(name) + " = " + scalar(value))
    for name, child in children:
        emit_table(child, path + [name])
try:
    emit_table(config, [])
    text = "\n".join(lines) + "\n"
    Path(output_path).write_text(text, encoding="utf-8")
    Path(output_path).chmod(0o644)
except (OSError, TypeError, ValueError):
    raise SystemExit(1)
PY
  then
    stop "rail TOML contains an unsupported value or invalid rail settings" 2
  fi
}

check_candidate_config() {
  local platform=${PAYKIT_REHEARSAL_PLATFORM:-linux/amd64}
  local check_exit
  progress "checking rail configuration without network access"
  throwaway_master_key=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n') || stop "could not generate throwaway master key" 2
  if [[ ! "$throwaway_master_key" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    stop "throwaway master key has an invalid form" 2
  fi
  if ! PAYKIT_MIGRATOR_DATABASE_URL='postgresql://postgres:placeholder@127.0.0.1:9/postgres' \
    PAYKIT_DATABASE_URL='postgresql://postgres:placeholder@127.0.0.1:9/postgres' \
    PAYKIT_MASTER_KEY="$throwaway_master_key" \
    docker create --platform "$platform" --network none --name "$candidate_name" \
      --label "paykit-rail-rehearsal=$random_id" \
      -e PAYKIT_CONFIG=/home/paykit/rail.toml \
      -e PAYKIT_MIGRATOR_DATABASE_URL -e PAYKIT_DATABASE_URL -e PAYKIT_MASTER_KEY \
      "$candidate_image" --check-config /home/paykit/rail.toml >/dev/null 2>&1; then
    stop "could not create candidate config container" 1
  fi
  candidate_created=true
  if ! docker cp "$PAYKIT_RAIL_CONFIG" "$candidate_name:/home/paykit/rail.toml" >/dev/null 2>&1; then
    stop "could not copy rail config" 1
  fi
  if docker start -a "$candidate_name" >"$scratch/config-check.log" 2>&1; then
    check_exit=0
  else
    check_exit=$?
  fi
  if [[ "$check_exit" -ne 0 ]]; then
    stop "candidate config check exited $check_exit" 1
  fi
  if ! python3 -c 'import sys; from pathlib import Path; raise SystemExit(Path(sys.argv[1]).read_bytes() != b"config ok: network=regtest stack_role=proof\n")' "$scratch/config-check.log"; then
    stop "candidate config check output did not match the rail settings" 1
  fi
  if ! docker rm "$candidate_name" >/dev/null 2>&1; then
    stop "could not remove candidate config container" 1
  fi
  candidate_created=false
}

stop_process_tree() {
  local parent_pid=$1
  local child_pid
  while read -r child_pid; do
    [[ -n "$child_pid" ]] && stop_process_tree "$child_pid"
  done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
  kill "$parent_pid" 2>/dev/null || true
}

stop_tunnel() {
  if [[ -n "$tunnel_pid" ]]; then
    stop_process_tree "$tunnel_pid"
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=""
  fi
}

parse_source_connection() {
  python3 - "$1" "$scratch" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

text = Path(sys.argv[1]).read_text(errors="replace")
output_dir = Path(sys.argv[2])
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
match = re.search(r"postgres(?:ql)?://[^\s]+", text)
if match is None:
    raise SystemExit(1)
url = urlsplit(match.group(0).rstrip(".,;"))
if not all((url.hostname, url.port, url.username, url.path.lstrip("/"))):
    raise SystemExit(1)
parts = {
    "source-host": url.hostname,
    "source-port": str(url.port),
    "source-user": unquote(url.username),
    "source-database": unquote(url.path.lstrip("/")),
}
for name, value in parts.items():
    (output_dir / name).write_text(value)
def pgpass_escape(value):
    return value.replace("\\", "\\\\").replace(":", "\\:")
(output_dir / "source.pgpass").write_text(":".join((
    pgpass_escape(url.hostname),
    str(url.port),
    pgpass_escape(unquote(url.path.lstrip("/"))),
    pgpass_escape(unquote(url.username)),
    pgpass_escape(unquote(url.password or "")),
)) + "\n")
PY
}

open_source_connection() {
  local elapsed=0
  if [[ -n "${PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE:-}" ]]; then
    progress "test source connection in use"
    if ! parse_source_connection "$PAYKIT_REHEARSAL_TEST_SOURCE_URL_FILE" >/dev/null 2>&1; then
      stop "test source URL could not be parsed" 2
    fi
  else
    : >"$scratch/tunnel.log"
    chmod 0600 "$scratch/tunnel.log"
    progress "opening source tunnel"
    railway connect "$RAILWAY_DATABASE_SERVICE" \
      --project "$RAILWAY_PROJECT_ID" \
      --environment "$RAILWAY_ENVIRONMENT" \
      --tunnel-only >"$scratch/tunnel.log" 2>&1 &
    tunnel_pid=$!
    while [[ "$elapsed" -lt 120 ]]; do
      if ! kill -0 "$tunnel_pid" 2>/dev/null; then
        stop "source tunnel exited before becoming ready" 1
      fi
      if parse_source_connection "$scratch/tunnel.log" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
      elapsed=$((elapsed + 1))
    done
    if [[ ! -f "$scratch/source-database" ]]; then
      stop "source tunnel did not expose connection details" 1
    fi
  fi
  source_host="$(<"$scratch/source-host")"
  source_port="$(<"$scratch/source-port")"
  source_user="$(<"$scratch/source-user")"
  source_database="$(<"$scratch/source-database")"
  chmod 0600 "$scratch/source.pgpass"
}

drop_source_credentials() {
  rm -f "$scratch/tunnel.log" "$scratch/source.pgpass"
}

source_psql() {
  PGPASSFILE="$scratch/source.pgpass" PGOPTIONS='-c default_transaction_read_only=on' \
    psql -X -A -t -v ON_ERROR_STOP=1 \
      --host "$source_host" --port "$source_port" --username "$source_user" \
      --dbname "$source_database" "$@"
}

read_source_state() {
  local dump_version
  local dump_client_major
  local other_ledgers
  progress "reading source migration state"
  if ! source_server_version_num=$(source_psql --command "SHOW server_version_num"); then
    stop "could not read source PostgreSQL version" 1
  fi
  if [[ ! "$source_server_version_num" =~ ^[0-9]+$ ]]; then
    stop "source PostgreSQL version is invalid" 1
  fi
  source_server_major=$((source_server_version_num / 10000))
  dump_version=$(pg_dump --version)
  dump_client_major=$(printf '%s\n' "$dump_version" | awk '{split($3, version, "."); print version[1]}')
  if [[ "$dump_client_major" != "$source_server_major" ]]; then
    stop "pg_dump major $dump_client_major does not match source PostgreSQL major $source_server_major" 1
  fi
  if ! ledger_present=$(source_psql --command "SELECT to_regclass('public._sqlx_migrations') IS NOT NULL"); then
    stop "could not check source migration ledger" 1
  fi
  if ! other_ledgers=$(source_psql --command "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '_sqlx_migrations' AND n.nspname <> 'public'"); then
    stop "could not check for a migration ledger outside the public schema" 1
  fi
  if [[ ! "$other_ledgers" =~ ^[0-9]+$ ]]; then
    stop "migration ledger schema check returned an invalid value" 1
  fi
  if [[ "$other_ledgers" -ne 0 ]]; then
    stop "a migration ledger exists outside the public schema" 1
  fi
  if [[ "$ledger_present" == t ]]; then
    if ! source_psql --command "SELECT version || '|' || CASE WHEN success THEN 't' ELSE 'f' END || '|' || encode(checksum, 'hex') FROM public._sqlx_migrations ORDER BY version" >"$scratch/live-ledger"; then
      stop "could not read source migration ledger" 1
    fi
  elif [[ "$ledger_present" == f ]]; then
    : >"$scratch/live-ledger"
    if ! relation_count=$(source_psql --command "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_temp\\_%' AND n.nspname NOT LIKE 'pg_toast_temp\\_%'"); then
      stop "could not check whether the source database is empty" 1
    fi
    if [[ ! "$relation_count" =~ ^[0-9]+$ ]]; then
      stop "source database emptiness check returned an invalid value" 1
    fi
    if [[ "$relation_count" -ne 0 ]]; then
      stop "source database has relations but no migration ledger, so it is not a fresh install" 1
    fi
  else
    stop "source migration ledger check returned an invalid value" 1
  fi
  if ! metadata_present=$(source_psql --command "SELECT to_regclass('public.deployment_metadata') IS NOT NULL"); then
    stop "could not check source deployment metadata" 1
  fi
  if ! stack_identity_present=$(source_psql --command "SELECT to_regclass('public.stack_identity') IS NOT NULL"); then
    stop "could not check source stack identity" 1
  fi
  if [[ "$metadata_present" != t && "$metadata_present" != f ]] ||
    [[ "$stack_identity_present" != t && "$stack_identity_present" != f ]]; then
    stop "source identity table check returned an invalid value" 1
  fi
  expected_stack_id=""
  if [[ "$metadata_present" == t && "$stack_identity_present" == t ]]; then
    if ! expected_stack_id=$(source_psql --command "SELECT d.stack_role || ':' || s.instance_uuid FROM public.deployment_metadata d CROSS JOIN public.stack_identity s WHERE d.id = 1"); then
      stop "could not read source deployment identity" 1
    fi
    if [[ -n "$expected_stack_id" && "$expected_stack_id" != proof:* ]]; then
      stop "source deployment identity is not a proof stack" 1
    fi
  fi
}

decide_migration_plan() {
  local decision
  if [[ "$ledger_present" == f ]]; then
    proceed "fresh install, no rehearsal needed"
    return 0
  fi
  if ! python3 - "$scratch/live-ledger" "$scratch/candidate-ledger" "$scratch/candidate-files" "$scratch" <<'PY'
import re
import sys
from pathlib import Path

live_path, candidate_path, files_path, output_dir = sys.argv[1:]
out = Path(output_dir)
def rows(path):
    result = []
    for line in Path(path).read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9]+)\|([tf])\|([0-9a-f]{96})", line)
        if match is None:
            raise ValueError("invalid ledger row")
        result.append((int(match.group(1)), match.group(2), match.group(3)))
    return result
try:
    live = rows(live_path)
    candidate = rows(candidate_path)
    live_by_version = {version: (success, checksum) for version, success, checksum in live}
    candidate_by_version = {version: checksum for version, _, checksum in candidate}
    if len(live_by_version) != len(live) or len(candidate_by_version) != len(candidate):
        raise ValueError("duplicate ledger version")
    if any(success == "f" for _, success, _ in live):
        decision = "failed ledger row"
    elif any(version not in candidate_by_version for version in live_by_version):
        decision = "candidate is older than the database"
    elif any(live_by_version[version][1] != checksum for version, checksum in candidate_by_version.items() if version in live_by_version):
        decision = "applied migration changed"
    elif len(live) == len(candidate) and all(
        live_by_version[version][1] == checksum for version, checksum in candidate_by_version.items()
    ):
        decision = "unchanged"
    else:
        decision = "rehearse"
    new_versions = sorted(set(candidate_by_version) - set(live_by_version))
    names = []
    for line in Path(files_path).read_text(encoding="utf-8").splitlines():
        version, name = line.split("\t", 1)
        if int(version) in new_versions:
            names.append(name)
    (out / "decision").write_text(decision + "\n", encoding="ascii")
    (out / "new-files").write_text("".join(name + "\n" for name in names), encoding="utf-8")
except (OSError, ValueError):
    raise SystemExit(1)
PY
  then
    stop "source and candidate migration ledgers could not be compared" 1
  fi
  decision="$(<"$scratch/decision")"
  new_migration_files=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    progress "new migration file: $name"
    if [[ -n "$new_migration_files" ]]; then
      new_migration_files="$new_migration_files,$name"
    else
      new_migration_files=$name
    fi
  done <"$scratch/new-files"
  case "$decision" in
    unchanged)
      proceed "migration set unchanged, no rehearsal needed"
      ;;
    rehearse)
      ;;
    *)
      stop "$decision" 1
      ;;
  esac
}

dump_source() {
  local -a table_args
  progress "dumping source roles, schema, and migration identity rows"
  table_args=(--table public._sqlx_migrations)
  if [[ "$metadata_present" == t ]]; then
    table_args+=(--table public.deployment_metadata)
  fi
  if [[ "$stack_identity_present" == t ]]; then
    table_args+=(--table public.stack_identity)
  fi
  if ! PGPASSFILE="$scratch/source.pgpass" PGOPTIONS='-c default_transaction_read_only=on' \
    pg_dumpall --host "$source_host" --port "$source_port" --username "$source_user" \
      --database "$source_database" --roles-only --no-role-passwords >"$scratch/roles.sql"; then
    stop "source roles dump failed" 1
  fi
  if ! PGPASSFILE="$scratch/source.pgpass" PGOPTIONS='-c default_transaction_read_only=on' \
    pg_dump --host "$source_host" --port "$source_port" --username "$source_user" \
      --dbname "$source_database" --format=custom --schema-only --create \
      --file "$scratch/schema.dump"; then
    stop "source schema dump failed" 1
  fi
  if ! PGPASSFILE="$scratch/source.pgpass" PGOPTIONS='-c default_transaction_read_only=on' \
    pg_dump --host "$source_host" --port "$source_port" --username "$source_user" \
      --dbname "$source_database" --format=custom --data-only \
      "${table_args[@]}" --file "$scratch/data.dump"; then
    stop "source migration data dump failed" 1
  fi
  stop_tunnel
  drop_source_credentials
}

check_dump_contents() {
  local schema_listing
  local dumped_data_objects
  local expected_data_objects
  schema_listing="$(pg_restore --list "$scratch/schema.dump")" ||
    stop "could not inspect source schema dump" 1
  if printf '%s\n' "$schema_listing" |
    awk '$4 == "BLOB" ||
         ($4 == "TABLE" && $5 == "DATA") ||
         ($4 == "SEQUENCE" && $5 == "SET") { found = 1 }
         END { exit !found }'
  then
    stop "schema dump unexpectedly contains data" 1
  fi
  dumped_data_objects="$(
    pg_restore --list "$scratch/data.dump" |
      awk '$4 == "TABLE" && $5 == "DATA" { print $6 "." $7 }' | sort
  )" || stop "could not inspect source data dump" 1
  expected_data_objects="public._sqlx_migrations"
  if [[ "$metadata_present" == t ]]; then
    expected_data_objects="$expected_data_objects"$'\n'"public.deployment_metadata"
  fi
  if [[ "$stack_identity_present" == t ]]; then
    expected_data_objects="$expected_data_objects"$'\n'"public.stack_identity"
  fi
  expected_data_objects="$(printf '%s\n' "$expected_data_objects" | sort)"
  if [[ "$dumped_data_objects" != "$expected_data_objects" ]]; then
    stop "data dump contains an object outside the requested migration identity tables" 1
  fi
}

start_clone() {
  local clone_image=${PAYKIT_REHEARSAL_POSTGRES_IMAGE:-postgres:$source_server_major}
  local started_at
  local clone_version_num
  local clone_major
  progress "starting isolated PostgreSQL clone"
  clone_password=$(openssl rand -hex 32) || stop "could not generate clone password" 1
  if ! docker network create --internal --label "paykit-rail-rehearsal=$random_id" "$network_name" >/dev/null 2>&1; then
    stop "could not create internal Docker network" 1
  fi
  network_created=true
  if ! POSTGRES_PASSWORD="$clone_password" docker run -d \
    --network "$network_name" --name "$clone_name" --label "paykit-rail-rehearsal=$random_id" \
    -e POSTGRES_USER=clone_admin -e POSTGRES_PASSWORD \
    "$clone_image" >/dev/null 2>&1; then
    stop "could not start PostgreSQL clone" 1
  fi
  clone_created=true
  unset clone_password
  started_at=$SECONDS
  while ! docker exec "$clone_name" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; do
    if (( SECONDS - started_at >= start_timeout )); then
      stop "PostgreSQL clone did not become ready" 1
    fi
    sleep 1
  done
  clone_version_num=$(docker exec "$clone_name" psql -X -A -t -v ON_ERROR_STOP=1 \
    -U clone_admin -d postgres --command "SHOW server_version_num") || stop "could not read clone PostgreSQL version" 1
  if [[ ! "$clone_version_num" =~ ^[0-9]+$ ]]; then
    stop "clone PostgreSQL version is invalid" 1
  fi
  clone_major=$((clone_version_num / 10000))
  if [[ "$clone_major" != "$source_server_major" ]]; then
    stop "clone PostgreSQL major $clone_major does not match source major $source_server_major" 1
  fi
}

restore_clone() {
  local migrator_role=${PAYKIT_MIGRATOR_ROLE:-postgres}
  local runtime_role=${PAYKIT_RUNTIME_ROLE:-$migrator_role}
  progress "restoring schema and migration identity rows"
  if ! docker exec -i "$clone_name" psql -X -v ON_ERROR_STOP=1 \
    -U clone_admin -d postgres <"$scratch/roles.sql" >"$scratch/roles-restore.log" 2>&1; then
    stop "could not restore roles" 1
  fi
  # The clone image creates the postgres and clone_admin databases; the
  # restore recreates the source database under its own name.
  case "$source_database" in
    template0|template1)
      stop "source database name $source_database cannot be cloned" 1
      ;;
  esac
  if ! SQL_DATABASE="$source_database" python3 -c 'import os; print("DROP DATABASE IF EXISTS \"" + os.environ["SQL_DATABASE"].replace("\"", "\"\"") + "\";")' |
    docker exec -i "$clone_name" psql -X -v ON_ERROR_STOP=1 \
      -U clone_admin -d template1 >"$scratch/database-reset.log" 2>&1; then
    stop "could not prepare clone database" 1
  fi
  if ! pg_restore --create -f - "$scratch/schema.dump" |
    docker exec -i "$clone_name" psql -X -v ON_ERROR_STOP=1 \
      -U clone_admin -d template1 >"$scratch/schema-restore.log" 2>&1; then
    stop "could not restore schema" 1
  fi
  if ! pg_restore --data-only --disable-triggers -f - "$scratch/data.dump" |
    docker exec -i "$clone_name" psql -X -v ON_ERROR_STOP=1 \
      -U clone_admin -d "$source_database" >"$scratch/data-restore.log" 2>&1; then
    stop "could not restore migration identity rows" 1
  fi
  migrator_password=$(openssl rand -hex 32) || stop "could not generate migrator role password" 1
  if [[ "$runtime_role" == "$migrator_role" ]]; then
    runtime_password=$migrator_password
  else
    runtime_password=$(openssl rand -hex 32) || stop "could not generate runtime role password" 1
  fi
  if ! SQL_MIGRATOR_ROLE="$migrator_role" SQL_RUNTIME_ROLE="$runtime_role" \
    SQL_MIGRATOR_PASSWORD="$migrator_password" SQL_RUNTIME_PASSWORD="$runtime_password" \
    python3 - <<'PY' |
import os

def identifier(value):
    return '"' + value.replace('"', '""') + '"'
def literal(value):
    return "'" + value.replace("'", "''") + "'"
roles = (
    (os.environ["SQL_MIGRATOR_ROLE"], os.environ["SQL_MIGRATOR_PASSWORD"]),
    (os.environ["SQL_RUNTIME_ROLE"], os.environ["SQL_RUNTIME_PASSWORD"]),
)
seen = set()
for role, password in roles:
    if role not in seen:
        print("ALTER ROLE " + identifier(role) + " PASSWORD " + literal(password) + ";")
        seen.add(role)
PY
    docker exec -i "$clone_name" psql -X -v ON_ERROR_STOP=1 \
      -U clone_admin -d postgres >"$scratch/passwords-restore.log" 2>&1; then
    stop "could not set fresh clone role passwords" 1
  fi
  if ! URL_ROLE="$migrator_role" URL_PASSWORD="$migrator_password" URL_DATABASE="$source_database" \
    URL_HOST="$clone_name" python3 -c 'import os; from urllib.parse import quote; print("postgresql://" + quote(os.environ["URL_ROLE"], safe="") + ":" + quote(os.environ["URL_PASSWORD"], safe="") + "@" + os.environ["URL_HOST"] + ":5432/" + quote(os.environ["URL_DATABASE"], safe=""))' >"$scratch/migrator-url"; then
    stop "could not construct clone migrator URL" 1
  fi
  if ! URL_ROLE="$runtime_role" URL_PASSWORD="$runtime_password" URL_DATABASE="$source_database" \
    URL_HOST="$clone_name" python3 -c 'import os; from urllib.parse import quote; print("postgresql://" + quote(os.environ["URL_ROLE"], safe="") + ":" + quote(os.environ["URL_PASSWORD"], safe="") + "@" + os.environ["URL_HOST"] + ":5432/" + quote(os.environ["URL_DATABASE"], safe=""))' >"$scratch/runtime-url"; then
    stop "could not construct clone runtime URL" 1
  fi
  chmod 0600 "$scratch/migrator-url" "$scratch/runtime-url"
  migrator_url="$(<"$scratch/migrator-url")"
  runtime_url="$(<"$scratch/runtime-url")"
  rm -f "$scratch/migrator-url" "$scratch/runtime-url"
}

refresh_candidate_log() {
  if [[ "$candidate_created" == true ]]; then
    docker logs "$candidate_name" >"$scratch/candidate.log" 2>&1
  fi
}

capture_metadata_line() {
  python3 - "$scratch/candidate.log" "$PAYKIT_SOURCE_SHA" "$expected_stack_id" "$scratch/metadata.line" <<'PY'
import json
import sys
from pathlib import Path

log_path, source_sha, expected_stack_id, output_path = sys.argv[1:]
for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if not isinstance(event, dict) or event.get("target") != "paykit_server::build_metadata":
        continue
    fields = event.get("fields")
    if not isinstance(fields, dict):
        continue
    stack_id = fields.get("stack_id")
    stack_ok = stack_id == expected_stack_id if expected_stack_id else isinstance(stack_id, str) and stack_id.startswith("proof:")
    if fields.get("source_sha") == source_sha and fields.get("network") == "regtest" and fields.get("role") == "proof" and stack_ok:
        Path(output_path).write_text(line + "\n", encoding="utf-8")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

probe_liveness() {
  local response_file=$1
  if ! docker exec "$clone_name" timeout 5 bash -c \
    "exec 3<>/dev/tcp/$candidate_name/3001; printf 'GET /health/live HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >&3; cat <&3" \
    >"$response_file" 2>/dev/null; then
    return 1
  fi
  python3 - "$response_file" <<'PY'
import re
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
head, separator, body = data.partition(b"\r\n\r\n")
if not separator:
    head, separator, body = data.partition(b"\n\n")
if not separator or not head:
    raise SystemExit(1)
try:
    status = head.splitlines()[0].decode("ascii")
except (IndexError, UnicodeDecodeError):
    raise SystemExit(1)
if re.match(r"^HTTP/1\.[01] 200 ", status) is None:
    raise SystemExit(1)
if body != b'{"status":"live"}':
    raise SystemExit(1)
PY
}

fail_candidate() {
  candidate_failure=true
  refresh_candidate_log >/dev/null 2>&1 || true
  stop "$1" 1
}

run_candidate() {
  local platform=${PAYKIT_REHEARSAL_PLATFORM:-linux/amd64}
  local started_at
  local running
  local state
  progress "starting candidate against the isolated clone"
  if ! PAYKIT_MIGRATOR_DATABASE_URL="$migrator_url" PAYKIT_DATABASE_URL="$runtime_url" \
    PAYKIT_MASTER_KEY="$throwaway_master_key" \
    docker create --platform "$platform" --network "$network_name" --name "$candidate_name" \
      --label "paykit-rail-rehearsal=$random_id" \
      --cap-drop ALL --security-opt no-new-privileges \
      -e PAYKIT_CONFIG=/home/paykit/rehearsal.toml \
      -e PAYKIT_MIGRATOR_DATABASE_URL -e PAYKIT_DATABASE_URL -e PAYKIT_MASTER_KEY \
      "$candidate_image" >/dev/null 2>&1; then
    stop "could not create candidate container" 1
  fi
  candidate_created=true
  unset migrator_url runtime_url
  if ! docker cp "$scratch/rehearsal.toml" "$candidate_name:/home/paykit/rehearsal.toml" >/dev/null 2>&1; then
    fail_candidate "could not copy rehearsal TOML"
  fi
  : >"$scratch/candidate.log"
  if ! docker start "$candidate_name" >/dev/null 2>&1; then
    fail_candidate "candidate container did not start"
  fi
  started_at=$SECONDS
  while true; do
    refresh_candidate_log || true
    if capture_metadata_line >/dev/null 2>&1; then
      metadata_line="$(<"$scratch/metadata.line")"
      break
    fi
    running=$(docker inspect --format '{{.State.Running}}' "$candidate_name" 2>/dev/null) || running=unknown
    if [[ "$running" != true ]]; then
      fail_candidate "candidate exited before startup metadata"
    fi
    if (( SECONDS - started_at >= start_timeout )); then
      fail_candidate "candidate startup metadata timed out"
    fi
    sleep 1
  done
  if probe_liveness "$scratch/liveness-first"; then
    liveness_first=passed
  else
    liveness_first=failed
    fail_candidate "first candidate liveness probe failed"
  fi
  started_at=$SECONDS
  while (( SECONDS - started_at < observation_window )); do
    running=$(docker inspect --format '{{.State.Running}}' "$candidate_name" 2>/dev/null) || running=unknown
    if [[ "$running" != true ]]; then
      fail_candidate "candidate exited during the observation window"
    fi
    sleep 1
  done
  running=$(docker inspect --format '{{.State.Running}}' "$candidate_name" 2>/dev/null) || running=unknown
  if [[ "$running" != true ]]; then
    fail_candidate "candidate is not running after the observation window"
  fi
  if probe_liveness "$scratch/liveness-second"; then
    liveness_second=passed
  else
    liveness_second=failed
    fail_candidate "second candidate liveness probe failed"
  fi
  if ! docker stop -t 30 "$candidate_name" >/dev/null 2>&1; then
    fail_candidate "candidate did not stop cleanly"
  fi
  state=$(docker inspect --format '{{.State.Running}}|{{.State.ExitCode}}|{{.State.OOMKilled}}' "$candidate_name" 2>/dev/null) || state=unknown
  if [[ "$state" != 'false|0|false' ]]; then
    fail_candidate "candidate stop state was $state"
  fi
  if ! refresh_candidate_log; then
    fail_candidate "candidate log could not be read"
  fi
  if ! scan_candidate_log "$scratch/candidate.log"; then
    candidate_failure=true
    stop "candidate log contains a prohibited line" 1
  fi
}

scan_candidate_log() {
  local log_file=$1
  python3 - "$log_file" <<'PY'
import json
import re
import sys
from pathlib import Path

bad_lines = set()
try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
except OSError:
    raise SystemExit(1)
for number, line in enumerate(lines, 1):
    try:
        event = json.loads(line)
        if not isinstance(event, dict):
            raise ValueError("not an object")
    except (json.JSONDecodeError, ValueError):
        bad_lines.add(number)
    if re.search(r'"level"\s*:\s*"ERROR"', line):
        bad_lines.add(number)
    if line.startswith("Error:") or "panicked" in line:
        bad_lines.add(number)
for number in sorted(bad_lines):
    print(f"rehearsal: offending candidate log line {number}", file=sys.stderr)
if bad_lines or not lines:
    raise SystemExit(1)
PY
}

check_clone_ledger() {
  progress "checking clone migration ledger"
  if ! docker exec "$clone_name" psql -X -A -t -v ON_ERROR_STOP=1 \
    -U clone_admin -d "$source_database" \
    --command "SELECT version || '|' || CASE WHEN success THEN 't' ELSE 'f' END || '|' || encode(checksum, 'hex') FROM public._sqlx_migrations ORDER BY version" \
    >"$scratch/clone-ledger" 2>/dev/null; then
    fail_candidate "could not read clone migration ledger"
  fi
  clone_ledger="$(<"$scratch/clone-ledger")"
  if [[ "$clone_ledger" != "$(<"$scratch/candidate-ledger")" ]]; then
    fail_candidate "clone migration ledger does not equal the candidate set"
  fi
}

main() {
  local pg_variable
  for pg_variable in $(compgen -v PG); do
    unset "$pg_variable"
  done
  trap on_exit EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  validate_inputs
  preflight_tools
  make_scratch
  pull_candidate
  list_candidate_migrations
  write_rehearsal_config
  check_candidate_config
  open_source_connection
  read_source_state
  decide_migration_plan
  if [[ "$gate_decision" == PROCEED ]]; then
    stop_tunnel
    drop_source_credentials
    return 0
  fi
  dump_source
  check_dump_contents
  start_clone
  restore_clone
  run_candidate
  check_clone_ledger
  proceed "rehearsal passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
