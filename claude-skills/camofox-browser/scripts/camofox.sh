#!/usr/bin/env bash
#
# camofox.sh -- drive the skill's own Camofox container over its REST API.
#
# The skill owns the container. Every action command starts the container first
# if it does not run, then waits for /health. No MCP server is involved, and no
# other Camofox deployment on the host is touched.
#
# The session id is fixed (CAMOFOX_USER_ID, default `camofox-skill`), so tabs
# and cookies persist for as long as the container lives.
#
# Usage:
#   camofox.sh up                      start the container, wait for health
#   camofox.sh status                  container state plus /health
#   camofox.sh down                    stop and remove the container
#   camofox.sh pull                    download the image (ask the user first)
#   camofox.sh logs [LINES]            container log tail (default 100)
#
#   camofox.sh open <url>              open a tab, print its tabId
#   camofox.sh tabs                    list the session's tabs
#   camofox.sh navigate <tabId> <url>
#   camofox.sh snapshot <tabId> [--offset N] [--json]
#   camofox.sh click <tabId> (<selector> | --ref eN) [--double]
#   camofox.sh type <tabId> (<selector> | --ref eN) <text> [--delay MS] [--clear] [--enter]
#   camofox.sh press <tabId> <key>
#   camofox.sh scroll <tabId> [--up] [--amount PX]
#   camofox.sh extract <tabId> <json-schema>
#   camofox.sh evaluate <tabId> <expression>
#   camofox.sh screenshot <tabId> [outfile.png]
#   camofox.sh close <tabId>
#   camofox.sh rest <METHOD> <path> [json-body]   any other route
#
# Environment:
#   CAMOFOX_HOST_PORT  host port of the skill's container, default 9378
#   CAMOFOX_BASE_URL   full base URL, overrides CAMOFOX_HOST_PORT
#   CAMOFOX_CONTAINER  container name, default camofox-skill
#   CAMOFOX_USER_ID    REST session id, default camofox-skill
#   CAMOFOX_START_TIMEOUT  seconds to wait for /health, default 90

set -euo pipefail

PORT="${CAMOFOX_HOST_PORT:-9378}"
BASE="${CAMOFOX_BASE_URL:-http://127.0.0.1:$PORT}"
CONTAINER="${CAMOFOX_CONTAINER:-camofox-skill}"
USER_ID="${CAMOFOX_USER_ID:-camofox-skill}"
START_TIMEOUT="${CAMOFOX_START_TIMEOUT:-90}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd "$SCRIPT_DIR/../docker" && pwd)

die() { printf 'camofox.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

compose() {
  CAMOFOX_HOST_PORT="$PORT" CAMOFOX_CONTAINER="$CONTAINER" \
    docker compose --project-directory "$COMPOSE_DIR" \
      -f "$COMPOSE_DIR/docker-compose.yml" "$@"
}

# Image references that the Compose file needs and the local daemon does not
# have. Empty output means every image is present.
missing_images() {
  local img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || printf '%s\n' "$img"
  done < <(compose config --images 2>/dev/null)
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || printf 'absent\n'
}

# Host port that the container actually publishes for the server's 9377. Empty
# when the container does not exist or publishes nothing.
container_port() {
  docker inspect \
    -f '{{with index .NetworkSettings.Ports "9377/tcp"}}{{(index . 0).HostPort}}{{end}}' \
    "$CONTAINER" 2>/dev/null || true
}

health_ok() {
  curl -sf --max-time 5 "$BASE/health" >/dev/null 2>&1
}

wait_healthy() {
  local waited=0
  while [ "$waited" -lt "$START_TIMEOUT" ]; do
    health_ok && { printf 'camofox.sh: healthy after %ss\n' "$waited" >&2; return 0; }
    sleep 2
    waited=$((waited + 2))
  done
  die "container '$CONTAINER' did not report healthy within ${START_TIMEOUT}s.
    Inspect it with: $0 logs"
}

# Start the skill's container if it is not already serving, and prove that the
# service on the target port is that container.
#
# A foreign Camofox on the port is an error, never something to reuse. It can
# run a different image, a different geo profile, and other clients' tabs. The
# ownership test is the published host port of our own container: comparing it
# to the port in $BASE is the only local check that cannot be faked by another
# instance answering /health.
#
# An explicit CAMOFOX_BASE_URL is an operator override. It skips both the
# container management and the ownership test.
ensure_up() {
  need curl; need jq

  if [ -n "${CAMOFOX_BASE_URL:-}" ]; then
    health_ok || die "CAMOFOX_BASE_URL=$BASE does not answer /health"
    return 0
  fi

  need docker

  local state port
  state=$(container_state)
  port=$(container_port)

  if [ "$state" = "running" ]; then
    if [ "$port" != "$PORT" ]; then
      die "container '$CONTAINER' publishes port '${port:-none}', not $PORT.
    Whatever answers on $PORT is not this skill's container.
    Recreate it with: $0 down && $0 up"
    fi
    health_ok && return 0
    wait_healthy
    return 0
  fi

  if health_ok; then
    die "$BASE answers /health but container '$CONTAINER' is not running.
    Another Camofox instance owns that port. This skill does not share one.
    Set CAMOFOX_HOST_PORT to a free port, or stop the other instance."
  fi

  # Downloading the image is a multi-gigabyte, multi-minute action, so it is
  # never implicit. `compose up` would pull on its own, which is why the check
  # happens here and `--pull never` backs it up.
  local missing; missing=$(missing_images)
  if [ -n "$missing" ]; then
    die "the container image is not present on this machine:
      $missing
    This script does not download it. Approve the download, then run:
      $0 pull"
  fi

  printf 'camofox.sh: starting container %s on 127.0.0.1:%s\n' "$CONTAINER" "$PORT" >&2
  compose up -d --pull never >&2 || die "docker compose up failed"
  wait_healthy
}

post() {
  local path="$1" body="$2"
  curl -sS --fail-with-body -X POST "$BASE$path" \
    -H 'Content-Type: application/json' -d "$body"
  printf '\n'
}

get() {
  local path="$1"; shift
  curl -sS --fail-with-body --get "$BASE$path" \
    --data-urlencode "userId=$USER_ID" "$@"
}

cmd_up() { ensure_up; cmd_status; }

cmd_status() {
  need docker; need curl
  printf 'container: %s (%s), publishes port %s\n' \
    "$CONTAINER" "$(container_state)" "$(container_port || true)"
  printf 'base url:  %s\n' "$BASE"
  printf 'user id:   %s\n' "$USER_ID"
  if health_ok; then
    printf 'health:    '
    curl -sf --max-time 5 "$BASE/health" | jq -c .
  else
    printf 'health:    unreachable\n'
  fi
}

# The one command that downloads. Run it only after the user approves.
cmd_pull() {
  need docker
  compose pull
}

cmd_down() {
  need docker
  compose down
}

cmd_logs() {
  need docker
  docker logs --tail "${1:-100}" "$CONTAINER"
}

cmd_open() {
  [ $# -eq 1 ] || usage
  ensure_up
  local out
  out=$(curl -sS --fail-with-body -X POST "$BASE/tabs/open" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$USER_ID" --arg url "$1" '{userId: $u, url: $url}')")
  printf '%s\n' "$out" | jq -r '.tabId // .tab.tabId // empty' | grep . || printf '%s\n' "$out"
}

cmd_tabs() {
  [ $# -eq 0 ] || usage
  ensure_up
  get "/tabs"
  printf '\n'
}

cmd_navigate() {
  [ $# -eq 2 ] || usage
  ensure_up
  post "/tabs/$1/navigate" "$(jq -n --arg u "$USER_ID" --arg url "$2" '{userId: $u, url: $url}')"
}

cmd_snapshot() {
  local tab="" offset="" format="text"
  while [ $# -gt 0 ]; do
    case "$1" in
      --offset) offset="${2:-}"; [ -n "$offset" ] || die "--offset needs a value"; shift 2 ;;
      --json)   format="json"; shift ;;
      -h|--help) usage 0 ;;
      --*)      die "unknown option: $1" ;;
      *)        [ -z "$tab" ] || usage; tab="$1"; shift ;;
    esac
  done
  [ -n "$tab" ] || usage
  ensure_up
  local args=(--data-urlencode "format=$format")
  [ -n "$offset" ] && args+=(--data-urlencode "offset=$offset")
  get "/tabs/$tab/snapshot" "${args[@]}"
  printf '\n'
}

cmd_click() {
  local tab="" target_key="selector" target="" double=false
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)    target_key="ref"; target="${2:-}"; [ -n "$target" ] || die "--ref needs a value"; shift 2 ;;
      --double) double=true; shift ;;
      -h|--help) usage 0 ;;
      --*)      die "unknown option: $1" ;;
      *)        positional+=("$1"); shift ;;
    esac
  done
  case "${#positional[@]}" in
    1) tab="${positional[0]}" ;;
    2) tab="${positional[0]}"; target="${positional[1]}" ;;
    *) usage ;;
  esac
  [ -n "$target" ] || die "need a selector or --ref"
  ensure_up
  post "/tabs/$tab/click" "$(jq -n --arg u "$USER_ID" --arg k "$target_key" --arg v "$target" \
    --argjson d "$double" '{userId: $u, doubleClick: $d} + {($k): $v}')"
}

# `mode`, `delay`, and `pressEnter` are absent from the server's OpenAPI schema
# but are implemented by the route handler. `mode=keyboard` focuses the element
# and sends real per-character keydown/keypress/beforeinput/input/keyup events
# with isTrusted true. The schema's documented `clear` flag is the reverse case:
# present in the schema, never destructured by the handler, so it does nothing.
# keyboard mode appends, so replacing a value needs an explicit empty fill().
cmd_type() {
  local tab="" target_key="selector" target="" text="" delay=30 enter=false clear=false
  local positional=()

  [ $# -ge 1 ] || usage

  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)    target_key="ref"; target="${2:-}"; [ -n "$target" ] || die "--ref needs a value"; shift 2 ;;
      --delay)  delay="${2:-}";  [ -n "$delay" ] || die "--delay needs a value"; shift 2 ;;
      --enter)  enter=true;  shift ;;
      --clear)  clear=true;  shift ;;
      -h|--help) usage 0 ;;
      --*)      die "unknown option: $1" ;;
      *)        positional+=("$1"); shift ;;
    esac
  done

  case "${#positional[@]}" in
    2) tab="${positional[0]}"; text="${positional[1]}" ;;
    3) tab="${positional[0]}"; target="${positional[1]}"; text="${positional[2]}" ;;
    *) usage ;;
  esac

  [ -n "$tab" ] || usage
  [ -n "$target" ] || die "need a selector or --ref (keyboard mode must focus the element)"
  case "$delay" in ''|*[!0-9]*) die "--delay must be an integer (milliseconds)" ;; esac

  ensure_up

  if [ "$clear" = true ]; then
    curl -sS -X POST "$BASE/tabs/$tab/type" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg u "$USER_ID" --arg k "$target_key" --arg v "$target" \
              '{userId: $u, text: ""} + {($k): $v} + {mode: "fill"}')" \
      >/dev/null
  fi

  post "/tabs/$tab/type" "$(jq -n --arg u "$USER_ID" --arg k "$target_key" --arg v "$target" \
    --arg t "$text" --argjson d "$delay" --argjson e "$enter" \
    '{userId: $u, text: $t, mode: "keyboard", delay: $d, pressEnter: $e} + {($k): $v}')"
}

cmd_press() {
  [ $# -eq 2 ] || usage
  ensure_up
  post "/tabs/$1/press" "$(jq -n --arg u "$USER_ID" --arg k "$2" '{userId: $u, key: $k}')"
}

cmd_scroll() {
  local tab="" direction="down" amount=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --up)     direction="up"; shift ;;
      --down)   direction="down"; shift ;;
      --amount) amount="${2:-}"; [ -n "$amount" ] || die "--amount needs a value"; shift 2 ;;
      -h|--help) usage 0 ;;
      --*)      die "unknown option: $1" ;;
      *)        [ -z "$tab" ] || usage; tab="$1"; shift ;;
    esac
  done
  [ -n "$tab" ] || usage
  case "${amount:-0}" in ''|*[!0-9]*) die "--amount must be an integer (pixels)" ;; esac
  ensure_up
  local body
  if [ -n "$amount" ]; then
    body=$(jq -n --arg u "$USER_ID" --arg d "$direction" --argjson a "$amount" \
      '{userId: $u, direction: $d, amount: $a}')
  else
    body=$(jq -n --arg u "$USER_ID" --arg d "$direction" '{userId: $u, direction: $d}')
  fi
  post "/tabs/$tab/scroll" "$body"
}

cmd_extract() {
  [ $# -eq 2 ] || usage
  ensure_up
  printf '%s' "$2" | jq -e . >/dev/null 2>&1 || die "the schema argument must be valid JSON"
  post "/tabs/$1/extract" "$(jq -n --arg u "$USER_ID" --argjson s "$2" '{userId: $u, schema: $s}')"
}

cmd_evaluate() {
  [ $# -eq 2 ] || usage
  ensure_up
  post "/tabs/$1/evaluate" "$(jq -n --arg u "$USER_ID" --arg e "$2" '{userId: $u, expression: $e}')"
}

# The route returns raw `image/png` bytes. The server's OpenAPI schema claims
# `application/json` with a base64 `screenshot.data` field, which the handler
# never produces. Write the body straight to a file.
cmd_screenshot() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  ensure_up
  local tab="$1" out="${2:-}"
  [ -n "$out" ] || out="${TMPDIR:-/tmp}/camofox-${tab%%-*}.png"
  curl -sS --fail-with-body -o "$out" --get "$BASE/tabs/$tab/screenshot" \
    --data-urlencode "userId=$USER_ID"
  [ -s "$out" ] || { rm -f "$out"; die "the screenshot response was empty"; }
  printf '%s\n' "$out"
}

cmd_close() {
  [ $# -eq 1 ] || usage
  ensure_up
  curl -sS --fail-with-body -X DELETE \
    "$BASE/tabs/$1?userId=$(jq -rn --arg u "$USER_ID" '$u|@uri')"
  printf '\n'
}

# Escape hatch for the routes with no subcommand: /act, /wait, /viewport,
# /links, /images, /downloads, /back, /forward, /refresh, /stats, /sessions/*.
# userId is injected into the query string for GET and into the body for POST.
cmd_rest() {
  [ $# -ge 2 ] || usage
  local method path body
  method=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  path="$2"; body="${3:-}"
  case "$path" in /*) ;; *) path="/$path" ;; esac
  ensure_up
  case "$method" in
    GET)
      get "$path"; printf '\n' ;;
    POST|PUT|PATCH)
      [ -n "$body" ] || body='{}'
      printf '%s' "$body" | jq -e . >/dev/null 2>&1 || die "the body argument must be valid JSON"
      post "$path" "$(jq -n --arg u "$USER_ID" --argjson b "$body" '{userId: $u} + $b')" ;;
    DELETE)
      curl -sS --fail-with-body -X DELETE \
        "$BASE$path?userId=$(jq -rn --arg u "$USER_ID" '$u|@uri')"
      printf '\n' ;;
    *) die "unsupported method: $method" ;;
  esac
}

case "${1:-}" in
  up)         shift; cmd_up "$@" ;;
  status)     shift; cmd_status "$@" ;;
  pull)       shift; cmd_pull "$@" ;;
  down)       shift; cmd_down "$@" ;;
  logs)       shift; cmd_logs "$@" ;;
  open)       shift; cmd_open "$@" ;;
  tabs)       shift; cmd_tabs "$@" ;;
  navigate)   shift; cmd_navigate "$@" ;;
  snapshot)   shift; cmd_snapshot "$@" ;;
  click)      shift; cmd_click "$@" ;;
  type)       shift; cmd_type "$@" ;;
  press)      shift; cmd_press "$@" ;;
  scroll)     shift; cmd_scroll "$@" ;;
  extract)    shift; cmd_extract "$@" ;;
  evaluate)   shift; cmd_evaluate "$@" ;;
  screenshot) shift; cmd_screenshot "$@" ;;
  close)      shift; cmd_close "$@" ;;
  rest)       shift; cmd_rest "$@" ;;
  -h|--help|'') usage 0 ;;
  *) die "unknown command: $1" ;;
esac
