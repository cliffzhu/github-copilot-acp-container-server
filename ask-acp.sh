#!/usr/bin/env bash
set -euo pipefail

SERVER_HOST="127.0.0.1"
PORT="3000"
CWD="/workspace"
AGENT="ACP-Chatbot"
QUESTION=""
INTERACTIVE="false"
DENY_PERMISSIONS="false"

usage() {
  cat <<EOF
Usage: ask-acp.sh [options]

Options:
  --host <host>                 ACP server host (default: 127.0.0.1)
  --port <port>                 ACP server port (default: 3000)
  --cwd <path>                  Working directory sent to session/new (default: /workspace)
  --agent <name>                Agent name to set via session/set_config_option
  --question <text>             One-shot prompt text
  --interactive                 Interactive mode (type /exit to quit)
  --deny-permissions            Respond to permission requests with cancelled
  -h, --help                    Show this help message

Examples:
  ./ask-acp.sh --question "hello"
  ./ask-acp.sh --interactive --agent ACP-Chatbot
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      SERVER_HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
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

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run ask-acp.sh" >&2
  exit 1
fi

ACP_SERVER_HOST="$SERVER_HOST" \
ACP_PORT="$PORT" \
ACP_CWD="$CWD" \
ACP_AGENT="$AGENT" \
ACP_QUESTION="$QUESTION" \
ACP_INTERACTIVE="$INTERACTIVE" \
ACP_DENY_PERMISSIONS="$DENY_PERMISSIONS" \
node - <<'NODE'
const net = require('node:net');
const readline = require('node:readline');

const serverHost = process.env.ACP_SERVER_HOST || '127.0.0.1';
const port = Number(process.env.ACP_PORT || '3000');
const cwd = process.env.ACP_CWD || process.cwd();
const agent = process.env.ACP_AGENT || 'ACP-Chatbot';
const question = process.env.ACP_QUESTION || '';
const interactive = (process.env.ACP_INTERACTIVE || 'false') === 'true';
const denyPermissions = (process.env.ACP_DENY_PERMISSIONS || 'false') === 'true';
const requestTimeoutMs = Number(process.env.ACP_REQUEST_TIMEOUT_MS || '20000');

const socket = net.createConnection({ host: serverHost, port });
socket.setEncoding('utf8');

let nextId = 1;
let buffer = '';
const pending = new Map();

function sendJson(payload) {
  socket.write(`${JSON.stringify(payload)}\n`);
}

function respondMethodNotFound(id, method) {
  sendJson({
    jsonrpc: '2.0',
    id,
    error: { code: -32601, message: `Method not found: ${method}` },
  });
}

function handleIncoming(msg) {
  if (msg && Object.prototype.hasOwnProperty.call(msg, 'id') && !msg.method) {
    const slot = pending.get(String(msg.id));
    if (!slot) {
      return;
    }
    pending.delete(String(msg.id));
    clearTimeout(slot.timer);
    if (msg.error) {
      slot.reject(new Error(`ACP error in ${slot.method}: ${JSON.stringify(msg.error)}`));
      return;
    }
    slot.resolve(msg.result);
    return;
  }

  if (msg?.method === 'session/update') {
    const update = msg?.params?.update;
    if (update?.sessionUpdate === 'agent_message_chunk') {
      const text = update?.content?.type === 'text' ? update?.content?.text : undefined;
      if (typeof text === 'string' && text.length > 0) {
        process.stdout.write(text);
      }
    }
    return;
  }

  if (msg?.method === 'session/request_permission') {
    sendJson({
      jsonrpc: '2.0',
      id: msg.id,
      result: {
        outcome: {
          outcome: denyPermissions ? 'cancelled' : 'approved',
        },
      },
    });
    return;
  }

  if (msg && Object.prototype.hasOwnProperty.call(msg, 'id') && msg.method) {
    respondMethodNotFound(msg.id, msg.method);
  }
}

socket.on('data', (chunk) => {
  buffer += chunk;
  const lines = buffer.split('\n');
  buffer = lines.pop() ?? '';

  for (const line of lines) {
    if (!line.trim()) {
      continue;
    }
    try {
      const msg = JSON.parse(line);
      handleIncoming(msg);
    } catch {
      // Ignore malformed line and keep processing.
    }
  }
});

function invoke(method, params) {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`ACP request timed out for method: ${method}`));
    }, requestTimeoutMs);

    pending.set(id, { resolve, reject, timer, method });
    sendJson({
      jsonrpc: '2.0',
      id,
      method,
      params,
    });
  });
}

function ensureAgentOption(setAgentResult, desiredAgent) {
  const options = setAgentResult?.configOptions;
  if (!Array.isArray(options)) {
    throw new Error('session/set_config_option did not return configOptions');
  }

  const opt = options.find((o) => o?.id === 'agent');
  if (!opt || opt.currentValue !== desiredAgent) {
    throw new Error(`Failed to set ACP session agent to '${desiredAgent}'`);
  }
}

async function trySetAgent(sessionId, desiredAgent) {
  if (!desiredAgent) {
    return false;
  }

  try {
    const setAgentResult = await invoke('session/set_config_option', {
      sessionId,
      configId: 'agent',
      value: desiredAgent,
    });
    ensureAgentOption(setAgentResult, desiredAgent);
    return true;
  } catch (err) {
    // Some ACP runtimes don't expose this method and rely on server startup agent.
    process.stderr.write(`Warning: unable to set session agent explicitly (${err.message}). Continuing with server default.\n`);
    return false;
  }
}

async function runPrompt(sessionId, text) {
  const result = await invoke('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text }],
  });
  process.stdout.write('\n');
  process.stdout.write(`stopReason: ${result?.stopReason}\n`);
}

socket.on('connect', async () => {
  try {
    const initResult = await invoke('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
    });

    if (!Object.prototype.hasOwnProperty.call(initResult ?? {}, 'protocolVersion')) {
      throw new Error('initialize did not return protocolVersion');
    }

    const session = await invoke('session/new', {
      cwd,
      mcpServers: [],
    });

    const sessionId = session?.sessionId;
    if (!sessionId) {
      throw new Error('session/new did not return sessionId');
    }

    const agentPinned = await trySetAgent(sessionId, agent);

    if (!interactive && question) {
      await runPrompt(sessionId, question);
      socket.end();
      return;
    }

    process.stdout.write(`Connected to ACP server on ${serverHost}:${port}\n`);
    process.stdout.write(`SessionId: ${sessionId}\n`);
    process.stdout.write(`Agent: ${agentPinned ? agent : `${agent} (server default/fallback)`}\n`);
    process.stdout.write('Type /exit to quit.\n');

    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, prompt: '> ' });
    rl.prompt();

    rl.on('line', async (line) => {
      const q = line.trim();
      if (!q) {
        rl.prompt();
        return;
      }
      if (q === '/exit') {
        rl.close();
        socket.end();
        return;
      }

      try {
        await runPrompt(sessionId, q);
      } catch (err) {
        process.stderr.write(`${err.message}\n`);
      }
      rl.prompt();
    });

    rl.on('close', () => {
      socket.end();
    });
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    socket.end();
    process.exitCode = 1;
  }
});

socket.on('error', (err) => {
  process.stderr.write(`TCP error: ${err.message}\n`);
  process.exitCode = 1;
});

socket.on('close', () => {
  for (const [, slot] of pending) {
    clearTimeout(slot.timer);
    slot.reject(new Error('ACP connection closed before response'));
  }
  pending.clear();
});
NODE