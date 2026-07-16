#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

load_env_defaults() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue

    local key="${line%%=*}"
    local value="${line#*=}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

load_env_defaults "$SCRIPT_DIR/.env"

WS_HOST="127.0.0.1"
WS_PORT="${ACP_WEBSOCKET_PORT:-8080}"
WS_URL=""
WS_USER="${WEBSOCKET_USER:-token}"
WS_TOKEN="${WEBSOCKET_TOKEN:-}"
CWD="/workspace"
AGENT="ACP-Chatbot"
AUTH_METHOD_ID="${ACP_AUTH_METHOD_ID:-}"
QUESTION=""
INTERACTIVE="false"
DENY_PERMISSIONS="false"
ADAPTER_IMAGE="${ACP_WEBSOCKET_ADAPTER_IMAGE:-acp-websocket-adapter:local}"
SESSION_ID="${ACP_SESSION_ID:-}"

usage() {
  cat <<EOF
Usage: ask-acp-websocket.sh [options]

Options:
  --host <host>                 WebSocket adapter host (default: 127.0.0.1)
  --port <port>                 WebSocket adapter port (default: ACP_WEBSOCKET_PORT or 8080)
  --url <url>                   Full websocket URL override (example: ws://127.0.0.1:8080)
  --user <username>             Basic auth user (default: WEBSOCKET_USER or token)
  --token <token>               Basic auth token (default: WEBSOCKET_TOKEN from .env)
  --cwd <path>                  Working directory for session/new (default: /workspace)
  --agent <name>                Agent name to set via session/set_config_option
  --auth-method-id <id>         ACP auth method id for authenticate (optional)
  --session-id <id>             Optional session id to resume (fallback to session/new)
  --question <text>             One-shot prompt text
  --interactive                 Interactive mode (type /exit to quit)
  --deny-permissions            Respond to permission requests with cancelled
  --adapter-image <image>       Adapter image tag (default: ACP_WEBSOCKET_ADAPTER_IMAGE)
  -h, --help                    Show this help

Examples:
  ./ask-acp-websocket.sh --question "hello"
  ./ask-acp-websocket.sh --session-id <id> --question "continue"
  ./ask-acp-websocket.sh --interactive --agent ACP-Chatbot
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      WS_HOST="${2:-}"
      shift 2
      ;;
    --port)
      WS_PORT="${2:-}"
      shift 2
      ;;
    --url)
      WS_URL="${2:-}"
      shift 2
      ;;
    --user)
      WS_USER="${2:-}"
      shift 2
      ;;
    --token)
      WS_TOKEN="${2:-}"
      shift 2
      ;;
    --cwd)
      CWD="${2:-}"
      shift 2
      ;;
    --agent)
      AGENT="${2:-}"
      shift 2
      ;;
    --auth-method-id)
      AUTH_METHOD_ID="${2:-}"
      shift 2
      ;;
    --session-id)
      SESSION_ID="${2:-}"
      shift 2
      ;;
    --question)
      QUESTION="${2:-}"
      shift 2
      ;;
    --interactive)
      INTERACTIVE="true"
      shift
      ;;
    --deny-permissions)
      DENY_PERMISSIONS="true"
      shift
      ;;
    --adapter-image)
      ADAPTER_IMAGE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$INTERACTIVE" != "true" && -z "$QUESTION" ]]; then
  echo "Provide --question for one-shot mode, or use --interactive." >&2
  exit 1
fi

if [[ -z "$WS_TOKEN" ]]; then
  echo "Missing websocket token. Set WEBSOCKET_TOKEN in .env or pass --token." >&2
  exit 1
fi

if [[ -z "$WS_URL" ]]; then
  WS_URL="ws://${WS_HOST}:${WS_PORT}"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found." >&2
  exit 1
fi

USE_SUDO_DOCKER="false"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    USE_SUDO_DOCKER="true"
  else
    echo "Docker daemon is not reachable for current user." >&2
    exit 1
  fi
fi

docker_cmd() {
  if [[ "$USE_SUDO_DOCKER" == "true" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

image_needs_build="false"
if ! docker_cmd image inspect "$ADAPTER_IMAGE" >/dev/null 2>&1; then
  image_needs_build="true"
elif ! docker_cmd run --rm "$ADAPTER_IMAGE" sh -lc 'test -f /app/ask-websocket.js && grep -q "ACP_SESSION_ID" /app/ask-websocket.js && grep -q "effectiveSessionId" /app/ask-websocket.js && grep -q "session/load" /app/ask-websocket.js' >/dev/null 2>&1; then
  image_needs_build="true"
fi

if [[ "$image_needs_build" == "true" ]]; then
  echo "Building adapter image: $ADAPTER_IMAGE"
  docker_cmd build -f "$SCRIPT_DIR/Dockerfile.websocket-adapter" -t "$ADAPTER_IMAGE" "$SCRIPT_DIR" >/dev/null
fi

docker_cmd run --rm -i --network host \
  -e ACP_WS_URL="$WS_URL" \
  -e ACP_WS_USER="$WS_USER" \
  -e ACP_WS_TOKEN="$WS_TOKEN" \
  -e ACP_CWD="$CWD" \
  -e ACP_AGENT="$AGENT" \
  -e ACP_AUTH_METHOD_ID="$AUTH_METHOD_ID" \
  -e ACP_SESSION_ID="$SESSION_ID" \
  -e ACP_QUESTION="$QUESTION" \
  -e ACP_INTERACTIVE="$INTERACTIVE" \
  -e ACP_DENY_PERMISSIONS="$DENY_PERMISSIONS" \
  "$ADAPTER_IMAGE" \
  node /app/ask-websocket.js
