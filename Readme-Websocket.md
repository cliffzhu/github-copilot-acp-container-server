# WebSocket Endpoint Guide

This project can expose ACP over a WebSocket endpoint through the built-in adapter in the same ACP container.

## Endpoint Summary

- URL pattern: `ws://<host>:<ACP_WEBSOCKET_PORT>`
- Default local URL: `ws://127.0.0.1:8080`
- Auth: HTTP Basic auth
- Username: `WEBSOCKET_USER` (default `token`)
- Password: `WEBSOCKET_TOKEN`

## Start ACP With WebSocket Enabled

Option 1: Set values in `.env` and start normally:

```bash
docker compose up -d --build
```

Required `.env` values:

- `ACP_WEBSOCKET_SERVER_ENABLED=true`
- `ACP_WEBSOCKET_PORT=8080`
- `WEBSOCKET_TOKEN=<long-random-secret>`

Option 2: One-shot command override:

```bash
ACP_WEBSOCKET_SERVER_ENABLED=true ACP_WEBSOCKET_PORT=8080 WEBSOCKET_TOKEN="<long-random-secret>" docker compose up -d --build
```

## Verify Endpoint

Run the adapter verification test:

```bash
./test-websocket-proxy.sh
```

Run a real ACP prompt over WebSocket:

```bash
./ask-acp-websocket.sh --question "what is the capital of China?"
```

Resume by optional session id:

```bash
./ask-acp-websocket.sh --session-id "<existing-session-id>" --question "continue from previous context"
```

## Protocol Details

The WebSocket stream carries ACP JSON-RPC lines delimited by newline characters.

Client request framing:

- One JSON message per line
- Append `\n` to each JSON-RPC payload

Typical call sequence:

1. `initialize`
2. Optional `authenticate` (when `ACP_AUTH_METHOD_ID` is configured)
3. `session/new`
4. `session/prompt`
5. Optional `logout` (if capability is advertised)

Resume sequence when `session-id` is provided:

1. `initialize`
2. Optional `authenticate`
3. Try `session/load` when `agentCapabilities.loadSession` is advertised
4. Then try `session/resume` (with the input session id) for runtimes that support it
5. If both fail, fallback to `session/new`
6. `session/prompt`

## Minimal JavaScript Connection Example

```javascript
const { WebSocket } = require('ws');

const user = process.env.WEBSOCKET_USER || 'token';
const token = process.env.WEBSOCKET_TOKEN;
const auth = Buffer.from(`${user}:${token}`, 'utf8').toString('base64');

const ws = new WebSocket('ws://127.0.0.1:8080', {
  headers: {
    Authorization: `Basic ${auth}`,
  },
});

ws.on('open', () => {
  ws.send(JSON.stringify({
    jsonrpc: '2.0',
    id: '1',
    method: 'initialize',
    params: { protocolVersion: 1, clientCapabilities: {} },
  }) + '\n');
});

ws.on('message', (msg) => {
  process.stdout.write(msg.toString());
});
```

## Troubleshooting

- `401 Unauthorized`: verify `WEBSOCKET_USER` and `WEBSOCKET_TOKEN`.
- No response to `initialize`: ensure each JSON-RPC payload ends with `\n`.
- Adapter exits on startup: set `ACP_WEBSOCKET_SERVER_ENABLED=true` and `WEBSOCKET_TOKEN` in `.env`.
- ACP not reachable: ensure ACP server is running and `ACP_WEBSOCKET_TARGET_HOST`/`ACP_WEBSOCKET_TARGET_PORT` are correct (recommended same-container values are `127.0.0.1` and `ACP_INTERNAL_PORT`, typically `3001`).
- Startup fails with invalid upstream/self-reference: `ACP_WEBSOCKET_TARGET_HOST` + `ACP_WEBSOCKET_TARGET_PORT` is pointing at the websocket listener itself. Use loopback + ACP internal runtime port instead.
- Resume falls back to new session: the server may have evicted or restarted the session.
