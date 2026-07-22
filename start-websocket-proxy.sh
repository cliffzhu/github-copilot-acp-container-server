#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

load_env_defaults() {
  file="$1"
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        continue
        ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
          [A-Za-z_][A-Za-z0-9_]*)
            eval "current=\${$key-}"
            if [ -z "$current" ]; then
              export "$key=$value"
            fi
            ;;
        esac
        ;;
    esac
  done < "$file"
}

load_env_defaults "$SCRIPT_DIR/.env"

ACP_PORT="${ACP_PORT:-3000}"
ACP_WEBSOCKET_PORT="${ACP_WEBSOCKET_PORT:-}"
WEBSOCKET_TOKEN="${WEBSOCKET_TOKEN:-}"
WEBSOCKET_USER="${WEBSOCKET_USER:-token}"
PROXY_CONTAINER_NAME="${ACP_WEBSOCKET_CONTAINER_NAME:-acp-server}"
ACP_WEBSOCKET_TARGET_HOST="${ACP_WEBSOCKET_TARGET_HOST:-127.0.0.1}"
ACP_SERVER_IMAGE="${ACP_SERVER_IMAGE:-github-copilot-acp-container-server:local}"

if [ -z "$ACP_WEBSOCKET_PORT" ]; then
  echo "ACP_WEBSOCKET_PORT is empty. Set it in .env (example: ACP_WEBSOCKET_PORT=8080)." >&2
  exit 1
fi

if [ -z "$WEBSOCKET_TOKEN" ]; then
  echo "WEBSOCKET_TOKEN is empty. Set a long random secret in .env before starting proxy." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found." >&2
  exit 1
fi

USE_SUDO_DOCKER=false
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    USE_SUDO_DOCKER=true
  else
    echo "Docker daemon is not reachable for current user." >&2
    exit 1
  fi
fi

docker_cmd() {
  if [ "$USE_SUDO_DOCKER" = "true" ]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

docker_cmd rm -f "$PROXY_CONTAINER_NAME" >/dev/null 2>&1 || true

if ! docker_cmd image inspect "$ACP_SERVER_IMAGE" >/dev/null 2>&1; then
  echo "Building unified ACP image: $ACP_SERVER_IMAGE"
  docker_cmd build \
    -f "$SCRIPT_DIR/Dockerfile" \
    -t "$ACP_SERVER_IMAGE" \
    "$SCRIPT_DIR" >/dev/null
fi

docker_cmd run -d \
  --name "$PROXY_CONTAINER_NAME" \
  --restart unless-stopped \
  -p "$ACP_PORT:$ACP_PORT" \
  -p "$ACP_WEBSOCKET_PORT:$ACP_WEBSOCKET_PORT" \
  -v "$SCRIPT_DIR/workspace:/workspace" \
  -v "$SCRIPT_DIR/copilot-home:/root/.copilot" \
  --env-file "$SCRIPT_DIR/.env" \
  -e ACP_BIND_ALL_INTERFACES=true \
  -e ACP_WEBSOCKET_SERVER_ENABLED=true \
  -e ACP_WEBSOCKET_PORT="$ACP_WEBSOCKET_PORT" \
  -e ACP_WEBSOCKET_TARGET_HOST="$ACP_WEBSOCKET_TARGET_HOST" \
  -e ACP_PORT="$ACP_PORT" \
  -e WEBSOCKET_USER="$WEBSOCKET_USER" \
  -e WEBSOCKET_TOKEN="$WEBSOCKET_TOKEN" \
  "$ACP_SERVER_IMAGE" >/dev/null

echo "Unified ACP + WebSocket container started."
echo "ACP TCP endpoint: http://<host>:$ACP_PORT"
echo "WebSocket endpoint: ws://<host>:$ACP_WEBSOCKET_PORT -> ${ACP_WEBSOCKET_TARGET_HOST}:$ACP_PORT"
echo "Basic auth user: $WEBSOCKET_USER"
echo "Container: $PROXY_CONTAINER_NAME"
