#!/usr/bin/env bash

set -euo pipefail

DEPLOY_DIR="/tmp/slop-mop-website-deploys"
MAX_AGE_SECONDS=3600
PORT_RANGE_START=3850
PORT_RANGE_END=3910

mkdir -p "$DEPLOY_DIR"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy_app.sh
  scripts/deploy_app.sh --status
  scripts/deploy_app.sh --logs
  scripts/deploy_app.sh --stop

Examples:
  scripts/deploy_app.sh
  scripts/deploy_app.sh --status
EOF
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

dir_hash() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}

lockfile_for() {
  printf '%s/%s.json\n' "$DEPLOY_DIR" "$(dir_hash "$1")"
}

logfile_for() {
  printf '%s/%s.log\n' "$DEPLOY_DIR" "$(dir_hash "$1")"
}

screen_session_for() {
  printf 'slop-mop-website-%s\n' "$(dir_hash "$1")"
}

is_pid_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null
}

is_screen_alive() {
  local session="$1"
  [[ -n "$session" ]] && screen -ls 2>/dev/null | grep -q "[.]$session[[:space:]]"
}

jq_field() {
  local json="$1"
  local field="$2"

  echo "$json" | grep -o "\"$field\":[^,}]*" | head -1 | sed "s/\"$field\"://;s/^[[:space:]]*\"//;s/\"[[:space:]]*$//" || true
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup_stale() {
  local now
  now=$(date +%s)

  for lockfile in "$DEPLOY_DIR"/*.json; do
    [[ -f "$lockfile" ]] || continue

    local data
    data=$(cat "$lockfile")

    local pid
    local started_at
    local dir
    local session
    pid=$(jq_field "$data" "pid")
    started_at=$(jq_field "$data" "startedAt")
    dir=$(jq_field "$data" "dir")
    session=$(jq_field "$data" "screenSession")

    if [[ -n "$session" ]] && is_screen_alive "$session"; then
      :
    elif [[ -z "$pid" ]] || ! is_pid_alive "$pid"; then
      echo "  Removing dead deployment: $dir (pid ${pid:-none})"
      rm -f "$lockfile"
      continue
    fi

    if [[ -n "$started_at" ]]; then
      local age=$((now - started_at))
      if (( age > MAX_AGE_SECONDS )); then
        echo "  Killing stale deployment: $dir (${age}s old, pid ${pid:-none})"
        if [[ -n "$session" ]] && is_screen_alive "$session"; then
          screen -S "$session" -X quit 2>/dev/null || true
        elif is_pid_alive "$pid"; then
          kill "$pid" 2>/dev/null || true
          pkill -P "$pid" 2>/dev/null || true
        fi
        rm -f "$lockfile"
      fi
    fi
  done
}

stop_deployment() {
  local root="$1"
  local lockfile
  local fallback_session
  lockfile=$(lockfile_for "$root")
  fallback_session=$(screen_session_for "$root")

  if [[ ! -f "$lockfile" ]]; then
    if is_screen_alive "$fallback_session"; then
      echo "Stopping deployment screen $fallback_session"
      screen -S "$fallback_session" -X quit 2>/dev/null || true
      sleep 1
    fi
    echo "No active deployment for $root"
    return 0
  fi

  local data
  data=$(cat "$lockfile")

  local pid
  local session
  local port
  pid=$(jq_field "$data" "pid")
  session=$(jq_field "$data" "screenSession")
  port=$(jq_field "$data" "wranglerPort")

  if [[ -n "$session" ]] && is_screen_alive "$session"; then
    echo "Stopping deployment on :$port (screen $session)"
    screen -S "$session" -X quit 2>/dev/null || true
  fi

  if [[ -n "$pid" ]] && is_pid_alive "$pid"; then
    echo "Stopping deployment on :$port (pid $pid)"
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
  fi

  if [[ -n "$port" ]]; then
    local port_pids
    port_pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [[ -n "$port_pids" ]]; then
      while IFS= read -r listener_pid; do
        [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null || true
      done <<EOF
$port_pids
EOF
    fi
  fi

  rm -f "$lockfile"
  echo "Stopped."
}

find_free_port() {
  local port="$PORT_RANGE_START"
  local used_ports=""

  for lockfile in "$DEPLOY_DIR"/*.json; do
    [[ -f "$lockfile" ]] || continue
    local data
    data=$(cat "$lockfile")
    used_ports="$used_ports $(jq_field "$data" "wranglerPort")"
  done

  while (( port < PORT_RANGE_END )); do
    if echo "$used_ports" | grep -qw "$port"; then
      port=$((port + 2))
      continue
    fi

    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      port=$((port + 2))
      continue
    fi

    echo "$port"
    return 0
  done

  die "No free ports in range $PORT_RANGE_START-$PORT_RANGE_END"
}

show_status() {
  local now
  now=$(date +%s)
  local found=0

  for lockfile in "$DEPLOY_DIR"/*.json; do
    [[ -f "$lockfile" ]] || continue

    local data
    data=$(cat "$lockfile")

    local pid
    local dir
    local port
    local started_at
    local branch
    local session
    local alive="dead"
    local age="?"

    pid=$(jq_field "$data" "pid")
    dir=$(jq_field "$data" "dir")
    port=$(jq_field "$data" "wranglerPort")
    started_at=$(jq_field "$data" "startedAt")
    branch=$(jq_field "$data" "branch")
    session=$(jq_field "$data" "screenSession")

    if is_pid_alive "$pid" || is_screen_alive "$session"; then
      alive="running"
    fi

    if [[ -n "$started_at" ]]; then
      age="$(((now - started_at) / 60))m"
    fi

    echo "  :$port  $alive  $age  $branch  $dir"
    found=1
  done

  if (( found == 0 )); then
    echo "  No active deployments."
  fi
}

show_logs() {
  local root="$1"
  local lockfile
  lockfile=$(lockfile_for "$root")
  [[ -f "$lockfile" ]] || die "No active deployment for $root"

  local data
  local log_file
  data=$(cat "$lockfile")
  log_file=$(jq_field "$data" "log")

  [[ -n "$log_file" ]] || die "No tracked log file for $root"
  [[ -f "$log_file" ]] || die "Tracked log file does not exist: $log_file"

  tail -f "$log_file"
}

ensure_prerequisites() {
  require_command curl
  require_command git
  require_command lsof
  require_command node
  require_command npm
  require_command screen
  require_command shasum
}

ACTION="deploy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)
      ACTION="stop"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --logs)
      ACTION="logs"
      shift
      ;;
    --help|-h)
      ACTION="help"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

ROOT=$(repo_root)
BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

case "$ACTION" in
  help)
    usage
    exit 0
    ;;
  stop)
    ensure_prerequisites
    stop_deployment "$ROOT"
    exit 0
    ;;
  status)
    ensure_prerequisites
    echo "slop-mop website deployments:"
    cleanup_stale
    show_status
    exit 0
    ;;
  logs)
    ensure_prerequisites
    show_logs "$ROOT"
    exit 0
    ;;
esac

ensure_prerequisites

WRANGLER_BIN="$ROOT/node_modules/.bin/wrangler"
[[ -f "$WRANGLER_BIN" ]] || die "Wrangler is not installed. Run npm install first."

echo "=== slop-mop website deploy ==="
echo "Dir:    $ROOT"
echo "Branch: $BRANCH"
echo ""

echo "Cleaning stale deployments..."
cleanup_stale

stop_deployment "$ROOT"

echo "Building..."
cd "$ROOT"
npm run build

WRANGLER_PORT=$(find_free_port)
WRANGLER_LOG=$(logfile_for "$ROOT")
SCREEN_SESSION=$(screen_session_for "$ROOT")

echo ""
echo "Allocated port: $WRANGLER_PORT"

rm -f "$WRANGLER_LOG"
screen -S "$SCREEN_SESSION" -X quit 2>/dev/null || true
screen -dmS "$SCREEN_SESSION" bash -lc '
  exec > "$2" 2>&1
  cd "$1"
  exec "$4" dev \
    --ip 127.0.0.1 \
    --port "$3" \
    --show-interactive-dev-session=false
' _ "$ROOT" "$WRANGLER_LOG" "$WRANGLER_PORT" "$WRANGLER_BIN"

WRANGLER_PID=$(pgrep -f "SCREEN.*${SCREEN_SESSION}" | head -1 || true)
if [[ -z "$WRANGLER_PID" ]]; then
  WRANGLER_PID=0
fi

echo "Starting wrangler (screen $SCREEN_SESSION, pid $WRANGLER_PID)..."
READY=0
for _ in $(seq 1 30); do
  if curl --silent --show-error --fail --max-time 2 "http://127.0.0.1:$WRANGLER_PORT/" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done

if [[ "$READY" != "1" ]]; then
  echo "ERROR: wrangler did not become ready. Log:" >&2
  sed -n '1,160p' "$WRANGLER_LOG" 2>/dev/null || true
  stop_deployment "$ROOT"
  exit 1
fi

NOW=$(date +%s)
ROOT="$ROOT" BRANCH="$BRANCH" PORT="$WRANGLER_PORT" PID="$WRANGLER_PID" NOW="$NOW" LOG="$WRANGLER_LOG" SCREEN_SESSION="$SCREEN_SESSION" \
  node -e "
    const payload = {
      dir: process.env.ROOT,
      branch: process.env.BRANCH,
      wranglerPort: Number(process.env.PORT),
      pid: Number(process.env.PID),
      startedAt: Number(process.env.NOW),
      log: process.env.LOG,
      screenSession: process.env.SCREEN_SESSION,
    };
    process.stdout.write(JSON.stringify(payload) + '\\n');
  " > "$(lockfile_for "$ROOT")"

echo ""
echo "========================================"
echo "  slop-mop website is live on:"
echo "  http://127.0.0.1:$WRANGLER_PORT/"
echo ""
echo "  Branch: $BRANCH"
echo "  PID:    $WRANGLER_PID"
echo "  Log:    $WRANGLER_LOG"
echo "  Stop:   scripts/deploy_app.sh --stop"
echo "  Status: scripts/deploy_app.sh --status"
echo "  Logs:   scripts/deploy_app.sh --logs"
echo "========================================"