// Local reverse proxy for OpenCode Go, deployed for DSH Desktop's web-search provider.
//
// Why: @deepseek-ai/dsh-web-search-deepseek speaks the Anthropic-compatible Messages API
// and hard-codes its request headers, so it cannot send the `x-opencode-session` header
// that the OpenCode Go gateway requires (a missing one is rejected with 400
// MissingSessionID). This proxy only adds that header (and a self-identifying UA) and
// otherwise passes everything through untouched. The API key stays with the client.
//
// Route:  http://127.0.0.1:8787/v1/*  ->  https://opencode.ai/zen/go/v1/*
// Usage:  node proxy.js
//
// Env overrides:
//   PROXY_PORT             listen port          (default 8787)
//   OPENCODE_SESSION_ID    injected session id  (default dsh-desktop-opencode-go-search)
//   PROXY_USER_AGENT       injected User-Agent
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PROXY_PORT || 8787);
const HOST = '127.0.0.1';
const UPSTREAM_ORIGIN = 'https://opencode.ai';
const UPSTREAM_PREFIX = '/zen/go';
const SESSION_ID = process.env.OPENCODE_SESSION_ID || 'dsh-desktop-opencode-go-search';
const USER_AGENT =
  process.env.PROXY_USER_AGENT || 'DSH-Desktop/2.0.13 (Windows; opencode-go-proxy/1.0)';

const LOG_FILE = path.join(__dirname, 'proxy.log');
// Keep upstream TLS connections warm: Node's default 5s idle timeout forces a fresh
// DNS+TCP+TLS handshake between searches.
const UPSTREAM_AGENT = new https.Agent({
  keepAlive: true,
  keepAliveMsecs: 30000,
  timeout: 600000,
  noDelay: true,
  maxSockets: 64,
  maxFreeSockets: 16,
});
// Hop-by-hop headers must not be forwarded (RFC 7230 §6.1).
const HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
];

function log(line) {
  const ts = new Date().toISOString();
  try {
    fs.appendFileSync(LOG_FILE, `${ts} ${line}\n`);
  } catch {
    // logging must never crash the proxy
  }
}

function filterHeaders(headers) {
  const out = {};
  for (const [k, v] of Object.entries(headers)) {
    if (HOP_BY_HOP.includes(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const started = Date.now();

  // Local health probe, never forwarded.
  if (req.url === '/healthz') {
    sendJson(res, 200, { ok: true, upstream: UPSTREAM_ORIGIN + UPSTREAM_PREFIX });
    return;
  }

  // Map local /v1/foo -> upstream /zen/go/v1/foo. Paths that already carry the
  // upstream prefix pass through unchanged (idempotent).
  let url = req.url;
  if (url.startsWith('/v1/') || url === '/v1') {
    url = UPSTREAM_PREFIX + url;
  } else if (!url.startsWith(UPSTREAM_PREFIX)) {
    sendJson(res, 404, {
      type: 'error',
      message: `opencode-go-proxy: unexpected path ${url}; configure baseURL as http://${HOST}:${PORT}/v1`,
    });
    return;
  }

  const headers = filterHeaders(req.headers);
  headers['user-agent'] = USER_AGENT;
  headers['x-opencode-session'] = SESSION_ID;

  let upstreamResStarted = false;
  const upReq = https.request(
    UPSTREAM_ORIGIN + url,
    { method: req.method, headers, agent: UPSTREAM_AGENT },
    (upRes) => {
      upstreamResStarted = true;
      const resHeaders = filterHeaders(upRes.headers);
      res.writeHead(upRes.statusCode, resHeaders);
      // Pipe untouched so SSE streaming works end to end.
      upRes.pipe(res);
      upRes.on('end', () => {
        log(`${req.method} ${req.url} -> ${upRes.statusCode} ${Date.now() - started}ms`);
      });
    }
  );

  upReq.on('error', (err) => {
    log(`ERROR ${req.method} ${req.url} -> ${err.message}`);
    if (!upstreamResStarted && !res.headersSent) {
      sendJson(res, 502, {
        type: 'error',
        message: `opencode-go-proxy: upstream request failed: ${err.message}`,
      });
    } else {
      res.destroy();
    }
  });

  res.on('close', () => {
    if (!res.writableEnded) upReq.destroy();
  });

  req.pipe(upReq);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    log(`START-FAILED port ${PORT} already in use, exiting (another instance is likely running)`);
    console.error(`port ${PORT} already in use, exiting`);
    process.exit(0);
  }
  log(`SERVER-ERROR ${err.message}`);
  console.error(err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  const msg = `STARTED listening on http://${HOST}:${PORT}/v1 -> ${UPSTREAM_ORIGIN}${UPSTREAM_PREFIX}/v1 session=${SESSION_ID}`;
  log(msg);
  console.log(msg);
});
