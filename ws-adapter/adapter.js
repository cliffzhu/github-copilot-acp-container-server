const http = require('http');
const net = require('net');
const { WebSocketServer } = require('ws');

const listenPort = Number(process.env.ACP_WEBSOCKET_PORT || '8080');
const targetHost = process.env.ACP_WEBSOCKET_TARGET_HOST || '127.0.0.1';
const targetPort = Number(process.env.ACP_PORT || '3000');
const expectedUser = process.env.WEBSOCKET_USER || 'token';
const expectedToken = process.env.WEBSOCKET_TOKEN || '';

if (!expectedToken) {
  console.error('WEBSOCKET_TOKEN is required.');
  process.exit(1);
}

function parseBasicAuth(header) {
  if (!header || !header.startsWith('Basic ')) return null;
  const encoded = header.slice('Basic '.length).trim();
  try {
    const decoded = Buffer.from(encoded, 'base64').toString('utf8');
    const idx = decoded.indexOf(':');
    if (idx < 0) return null;
    return {
      user: decoded.slice(0, idx),
      token: decoded.slice(idx + 1),
    };
  } catch {
    return null;
  }
}

function unauthorized(socket) {
  socket.write(
    'HTTP/1.1 401 Unauthorized\r\n' +
      'WWW-Authenticate: Basic realm="ACP WebSocket Adapter"\r\n' +
      'Connection: close\r\n' +
      '\r\n'
  );
  socket.destroy();
}

const server = http.createServer((_req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.end('ACP WebSocket adapter is running.\n');
});

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const auth = parseBasicAuth(req.headers.authorization);
  const ok = auth && auth.user === expectedUser && auth.token === expectedToken;
  if (!ok) {
    unauthorized(socket);
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit('connection', ws, req);
  });
});

wss.on('connection', (ws) => {
  const tcp = net.createConnection({ host: targetHost, port: targetPort });

  let closed = false;

  function closeBoth() {
    if (closed) return;
    closed = true;
    try {
      ws.close();
    } catch {}
    try {
      tcp.destroy();
    } catch {}
  }

  tcp.on('connect', () => {
    console.log(`bridge connected to ${targetHost}:${targetPort}`);
  });

  tcp.on('data', (chunk) => {
    if (ws.readyState === ws.OPEN) {
      ws.send(chunk.toString('utf8'));
    }
  });

  tcp.on('error', (err) => {
    console.error(`tcp error: ${err.message}`);
    closeBoth();
  });

  tcp.on('close', () => {
    closeBoth();
  });

  ws.on('message', (data, isBinary) => {
    if (tcp.destroyed) return;
    if (isBinary) {
      tcp.write(data);
    } else {
      tcp.write(Buffer.from(data.toString(), 'utf8'));
    }
  });

  ws.on('close', () => {
    closeBoth();
  });

  ws.on('error', (err) => {
    console.error(`ws error: ${err.message}`);
    closeBoth();
  });
});

server.listen(listenPort, '0.0.0.0', () => {
  console.log(`ACP WebSocket adapter listening on 0.0.0.0:${listenPort}`);
  console.log(`Target ACP TCP endpoint: ${targetHost}:${targetPort}`);
});
