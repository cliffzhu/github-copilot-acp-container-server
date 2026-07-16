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

ACP_WEBSOCKET_PORT="${ACP_WEBSOCKET_PORT:-}"
WEBSOCKET_TOKEN="${WEBSOCKET_TOKEN:-}"
WEBSOCKET_USER="${WEBSOCKET_USER:-token}"
ACP_WEBSOCKET_ADAPTER_IMAGE="${ACP_WEBSOCKET_ADAPTER_IMAGE:-acp-websocket-adapter:local}"
ACP_WEBSOCKET_TARGET_HOST="${ACP_WEBSOCKET_TARGET_HOST:-127.0.0.1}"

if [ -z "$ACP_WEBSOCKET_PORT" ]; then
  echo "ACP_WEBSOCKET_PORT is empty. Set it in .env." >&2
  exit 1
fi

if [ -z "$WEBSOCKET_TOKEN" ]; then
  echo "WEBSOCKET_TOKEN is empty. Set it in .env." >&2
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

URL="ws://127.0.0.1:${ACP_WEBSOCKET_PORT}"

echo "Testing WebSocket adapter at ${URL}"

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

if ! docker_cmd image inspect "$ACP_WEBSOCKET_ADAPTER_IMAGE" >/dev/null 2>&1; then
  echo "Adapter image not found: $ACP_WEBSOCKET_ADAPTER_IMAGE" >&2
  echo "Run ./start-websocket-proxy.sh first to build and launch it." >&2
  exit 1
fi

docker_cmd run --rm -i --network host -w /app \
  -e ACP_TEST_WS_URL="$URL" \
  -e ACP_TEST_USER="$WEBSOCKET_USER" \
  -e ACP_TEST_TOKEN="$WEBSOCKET_TOKEN" \
  "$ACP_WEBSOCKET_ADAPTER_IMAGE" \
  node - <<'NODE' >"$tmp_out" 2>&1 || true
const { WebSocket } = require('ws');

const url = process.env.ACP_TEST_WS_URL;
const user = process.env.ACP_TEST_USER;
const token = process.env.ACP_TEST_TOKEN;
const auth = Buffer.from(`${user}:${token}`, 'utf8').toString('base64');

const ws = new WebSocket(url, {
  headers: {
    Authorization: `Basic ${auth}`,
  },
});

let buffer = '';
const timeout = setTimeout(() => {
  console.error('timeout waiting for initialize response');
  process.exit(1);
}, 10000);

ws.on('open', () => {
  const msg = {
    jsonrpc: '2.0',
    id: '1',
    method: 'initialize',
    params: {
      protocolVersion: 1,
      clientCapabilities: {},
    },
  };
  ws.send(JSON.stringify(msg) + '\n');
});

ws.on('message', (chunk) => {
  buffer += chunk.toString();
  const lines = buffer.split('\n');
  buffer = lines.pop() || '';

  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const payload = JSON.parse(line);
      if (payload.id === '1' && payload.result) {
        clearTimeout(timeout);
        console.log('initialize-ok');
        ws.close();
        process.exit(0);
      }
    } catch {
      // Ignore non-JSON or partial chunks.
    }
  }
});

ws.on('error', (err) => {
  clearTimeout(timeout);
  console.error('ws-error:', err.message);
  process.exit(1);
});

ws.on('close', () => {
  clearTimeout(timeout);
});
NODE

if grep -q 'initialize-ok' "$tmp_out"; then
  echo "WebSocket adapter auth + ACP initialize succeeded."
  echo "Backend bridge target: ${ACP_WEBSOCKET_TARGET_HOST}:${ACP_PORT:-3000}"
  exit 0
fi

echo "WebSocket adapter test failed. Output:" >&2
cat "$tmp_out" >&2
exit 1
