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
ACP_WEBSOCKET_TARGET_HOST="${ACP_WEBSOCKET_TARGET_HOST:-127.0.0.1}"

if [ -z "$ACP_WEBSOCKET_PORT" ]; then
  echo "ACP_WEBSOCKET_PORT is empty. Set it in .env." >&2
  exit 1
fi

if [ -z "$WEBSOCKET_TOKEN" ]; then
  echo "WEBSOCKET_TOKEN is empty. Set it in .env." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node command not found." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm command not found." >&2
  exit 1
fi

WS_CLIENT_DIR="$SCRIPT_DIR/ws-adapter"
if [ ! -f "$WS_CLIENT_DIR/ask-websocket.js" ]; then
  echo "WebSocket client script not found: $WS_CLIENT_DIR/ask-websocket.js" >&2
  exit 1
fi

if [ ! -d "$WS_CLIENT_DIR/node_modules/ws" ]; then
  echo "Installing websocket client dependencies in $WS_CLIENT_DIR"
  npm --prefix "$WS_CLIENT_DIR" install --omit=dev >/dev/null
fi

URL="ws://127.0.0.1:${ACP_WEBSOCKET_PORT}"

echo "Testing WebSocket adapter at ${URL}"

print_poc_example() {
  cat <<'EOF'

Proof of concept client flow:

const { WebSocket } = require('ws');

const url = process.env.ACP_TEST_WS_URL;
const user = process.env.ACP_TEST_USER || 'token';
const token = process.env.ACP_TEST_TOKEN;
const agent = process.env.ACP_TEST_AGENT || 'ACP-Chatbot';
const auth = Buffer.from(`${user}:${token}`, 'utf8').toString('base64');

const ws = new WebSocket(url, {
  headers: {
    Authorization: `Basic ${auth}`,
  },
});

let nextId = 1;
let buffer = '';
let sessionId = '';

function send(method, params) {
  ws.send(JSON.stringify({ jsonrpc: '2.0', id: String(nextId++), method, params }) + '\n');
}

ws.on('open', () => {
  send('initialize', {
    protocolVersion: 1,
    clientCapabilities: {},
  });
});

ws.on('message', (chunk) => {
  buffer += chunk.toString();
  const lines = buffer.split('\n');
  buffer = lines.pop() || '';

  for (const line of lines) {
    if (!line.trim()) continue;
    const msg = JSON.parse(line);

    if (msg.id === '1' && msg.result) {
      send('session/new', { cwd: '/workspace', mcpServers: [] });
      continue;
    }

    if (msg.id === '2' && msg.result?.sessionId) {
      sessionId = msg.result.sessionId;
      send('session/set_config_option', {
        sessionId,
        configId: 'agent',
        value: agent,
      });
      continue;
    }

    if (msg.id === '3' && msg.result) {
      send('session/prompt', {
        sessionId,
        prompt: [{ type: 'text', text: 'Say hello in one sentence.' }],
      });
      continue;
    }
  }
});
EOF
}

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

(cd "$WS_CLIENT_DIR" && \
  ACP_TEST_WS_URL="$URL" \
  ACP_TEST_USER="$WEBSOCKET_USER" \
  ACP_TEST_TOKEN="$WEBSOCKET_TOKEN" \
  node - <<'NODE') >"$tmp_out" 2>&1 || true
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
  print_poc_example
  exit 0
fi

echo "WebSocket adapter test failed. Output:" >&2
cat "$tmp_out" >&2
exit 1
