const readline = require('node:readline');
const { WebSocket } = require('ws');

const wsUrl = process.env.ACP_WS_URL || 'ws://127.0.0.1:8080';
const wsUser = process.env.ACP_WS_USER || 'token';
const wsToken = process.env.ACP_WS_TOKEN || '';
const cwd = process.env.ACP_CWD || '/workspace';
const agent = process.env.ACP_AGENT || 'ACP-Chatbot';
const authMethodId = (process.env.ACP_AUTH_METHOD_ID || '').trim();
const question = process.env.ACP_QUESTION || '';
const interactive = (process.env.ACP_INTERACTIVE || 'false') === 'true';
const denyPermissions = (process.env.ACP_DENY_PERMISSIONS || 'false') === 'true';
const requestTimeoutMs = Number(process.env.ACP_REQUEST_TIMEOUT_MS || '20000');
const sessionIdInput = (process.env.ACP_SESSION_ID || '').trim();

if (!interactive && !question) {
  console.error('Provide ACP_QUESTION for one-shot mode, or set ACP_INTERACTIVE=true.');
  process.exit(1);
}

if (!wsToken) {
  console.error('ACP_WS_TOKEN is required.');
  process.exit(1);
}

const auth = Buffer.from(`${wsUser}:${wsToken}`, 'utf8').toString('base64');

let nextId = 1;
let buffer = '';
const pending = new Map();
let initResult = null;
let authenticated = false;
let ws = null;

function sendJson(payload) {
  ws.send(`${JSON.stringify(payload)}\n`);
}

function respondMethodNotFound(id, method) {
  sendJson({
    jsonrpc: '2.0',
    id,
    error: {
      code: -32601,
      message: `Method not found: ${method}`,
    },
  });
}

function supportsLogout() {
  return Boolean(initResult?.agentCapabilities?.auth?.logout);
}

function supportsLoadSession() {
  return Boolean(initResult?.agentCapabilities?.loadSession);
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
    process.stderr.write(`Warning: unable to set session agent explicitly (${err.message}). Continuing with server default.\n`);
    return false;
  }
}

async function tryLogout() {
  if (!authenticated || !supportsLogout()) {
    return;
  }
  await invoke('logout', {});
}

async function authenticateIfRequested() {
  if (!authMethodId) {
    return false;
  }

  const authMethods = Array.isArray(initResult?.authMethods) ? initResult.authMethods : [];
  const found = authMethods.some((m) => m?.id === authMethodId);
  if (!found) {
    throw new Error(`ACP auth method '${authMethodId}' was not advertised by initialize`);
  }

  await invoke('authenticate', { methodId: authMethodId });
  return true;
}

async function runPrompt(sessionId, text) {
  const result = await invoke('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text }],
  });

  process.stdout.write('\n');
  process.stdout.write(`stopReason: ${result?.stopReason}\n`);
}

function isMethodNotFoundError(err, method) {
  const message = String(err?.message || '');
  return message.includes('Method not found') && message.includes(method);
}

async function establishSession() {
  if (!sessionIdInput) {
    const created = await invoke('session/new', {
      cwd,
      mcpServers: [],
    });
    const createdSessionId = created?.sessionId;
    if (!createdSessionId) {
      throw new Error('session/new did not return sessionId');
    }
    return { sessionId: createdSessionId, resumed: false };
  }

  if (supportsLoadSession()) {
    try {
      const loaded = await invoke('session/load', {
        sessionId: sessionIdInput,
        cwd,
        mcpServers: [],
      });
      return { sessionId: loaded?.sessionId || sessionIdInput, resumed: true };
    } catch (err) {
      process.stderr.write(`Warning: failed to load sessionId '${sessionIdInput}' via session/load (${err.message}); trying session/resume.\n`);
    }
  }

  try {
    const resumed = await invoke('session/resume', {
      sessionId: sessionIdInput,
    });
    return { sessionId: resumed?.sessionId || sessionIdInput, resumed: true };
  } catch (err) {
    if (isMethodNotFoundError(err, 'session/resume') && supportsLoadSession()) {
      process.stderr.write('Warning: ACP server does not implement session/resume and session/load already failed; creating a new session.\n');
    } else {
      process.stderr.write(`Warning: failed to resume sessionId '${sessionIdInput}' (${err.message}); creating a new session.\n`);
    }
    const created = await invoke('session/new', {
      cwd,
      mcpServers: [],
    });
    const createdSessionId = created?.sessionId;
    if (!createdSessionId) {
      throw new Error('session/new did not return sessionId');
    }
    return { sessionId: createdSessionId, resumed: false };
  }
}

function closeAndExit(code) {
  try {
    ws.close();
  } catch {
    // Ignore close errors while terminating.
  }
  process.exit(code);
}

ws = new WebSocket(wsUrl, {
  headers: {
    Authorization: `Basic ${auth}`,
  },
});

ws.on('open', async () => {
  try {
    initResult = await invoke('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
    });

    if (!Object.prototype.hasOwnProperty.call(initResult ?? {}, 'protocolVersion')) {
      throw new Error('initialize did not return protocolVersion');
    }

    authenticated = await authenticateIfRequested();

    const { sessionId, resumed } = await establishSession();

    const agentPinned = await trySetAgent(sessionId, agent);

    if (!interactive && question) {
      await runPrompt(sessionId, question);
      process.stdout.write(`effectiveSessionId: ${sessionId}\n`);
      if (sessionIdInput) {
        process.stdout.write(`sessionMode: ${resumed ? 'resumed' : 'new'}\n`);
      }
      await tryLogout();
      closeAndExit(0);
      return;
    }

    process.stdout.write(`Connected to ACP websocket ${wsUrl}\n`);
    process.stdout.write(`SessionId: ${sessionId}\n`);
    if (sessionIdInput) {
      process.stdout.write(`Session mode: ${resumed ? 'resumed' : 'new'} (input sessionId)\n`);
    }
    process.stdout.write(`Agent: ${agentPinned ? agent : `${agent} (server default/fallback)`}\n`);
    process.stdout.write(`Auth: ${authenticated ? `authenticate(${authMethodId})` : 'none'}\n`);
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
        await tryLogout();
        closeAndExit(0);
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
      closeAndExit(0);
    });
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    closeAndExit(1);
  }
});

ws.on('message', (chunk) => {
  buffer += chunk.toString('utf8');
  const lines = buffer.split('\n');
  buffer = lines.pop() || '';

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

ws.on('error', (err) => {
  process.stderr.write(`WebSocket error: ${err.message}\n`);
  process.exit(1);
});

ws.on('close', () => {
  for (const [, slot] of pending) {
    clearTimeout(slot.timer);
    slot.reject(new Error('WebSocket connection closed'));
  }
  pending.clear();
});
