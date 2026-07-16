# WebSocket Endpoint Guide

This project can expose ACP over a WebSocket endpoint through the custom adapter container.

## Endpoint Summary

- URL pattern: `ws://<host>:<ACP_WEBSOCKET_PORT>`
- Default local URL: `ws://127.0.0.1:8080`
- Auth: HTTP Basic auth
- Username: `WEBSOCKET_USER` (default `token`)
- Password: `WEBSOCKET_TOKEN`

## Start Both Containers

Option 1: Docker Compose profile (builds both images):

```bash
docker compose --profile websocket up -d --build
```

Option 2: Start ACP first, then adapter script:

```bash
docker compose up -d --build
./start-websocket-proxy.sh
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
- Adapter exits on startup: set `WEBSOCKET_TOKEN` in `.env`.
- ACP not reachable: ensure ACP server is running and `ACP_PORT`/`ACP_WEBSOCKET_TARGET_HOST` are correct.
- Resume falls back to new session: the server may have evicted or restarted the session.
