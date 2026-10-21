// gateway is the shop's public API. It checks the caller's API key, reads
// products from catalog over gRPC, and forwards orders to orders over HTTP,
// giving every request an id that follows it through the other services.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { catalogClient, grpcStatus } from './catalog.js';
import { formatPrice } from './price.js';

const config = {
  port: Number(process.env.PORT ?? 3000),
  apiKey: process.env.API_KEY ?? 'dev-key',
  ordersUrl: process.env.ORDERS_URL ?? 'http://localhost:8080',
  catalogAddr: process.env.CATALOG_ADDR ?? 'localhost:50051',
  protoDir: process.env.PROTO_DIR ??
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../proto'),
};

const catalog = catalogClient(config.catalogAddr, config.protoDir);

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function product(p) {
  return { sku: p.sku, name: p.name, price: formatPrice(p.priceCents), in_stock: p.stock > 0 };
}

function catalogError(res, err) {
  if (err.code === grpcStatus.NOT_FOUND) return send(res, 404, { error: 'product not found' });
  // gateway never cancels a call itself: a cancelled call ran out of time
  // while grpc-js was retrying it.
  if (err.code === grpcStatus.DEADLINE_EXCEEDED || err.code === grpcStatus.CANCELLED) {
    return send(res, 504, { error: 'catalog timed out' });
  }
  console.error('catalog call failed:', err.message);
  return send(res, 503, { error: 'catalog is unavailable' });
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

// forward passes a request on to orders and its answer back unchanged.
async function forward(req, res, requestId, method, url) {
  try {
    const upstream = await fetch(`${config.ordersUrl}${url}`, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Request-Id': requestId },
      body: method === 'GET' ? undefined : await readBody(req),
      signal: AbortSignal.timeout(5000),
    });
    res.writeHead(upstream.status, {
      'Content-Type': upstream.headers.get('content-type') ?? 'application/json',
    });
    res.end(Buffer.from(await upstream.arrayBuffer()));
  } catch (err) {
    console.error('orders call failed:', err.message);
    send(res, 502, { error: 'orders is unavailable' });
  }
}

async function handle(req, res) {
  const { pathname } = new URL(req.url, 'http://gateway');
  const requestId = req.headers['x-request-id'] || randomUUID();
  res.setHeader('X-Request-Id', requestId);

  if (req.method === 'GET' && pathname === '/health') return send(res, 200, { status: 'ok' });

  if (!pathname.startsWith('/api/')) return send(res, 404, { error: 'not found' });
  if (req.headers['x-api-key'] !== config.apiKey) {
    return send(res, 401, { error: 'missing or invalid API key' });
  }

  const meta = { 'x-request-id': requestId };
  let m;
  if (req.method === 'GET' && pathname === '/api/products') {
    return catalog.listProducts({}, meta)
      .then((r) => send(res, 200, { products: r.products.map(product) }))
      .catch((err) => catalogError(res, err));
  }
  if (req.method === 'GET' && (m = pathname.match(/^\/api\/products\/([^/]+)$/))) {
    return catalog.getProduct({ sku: decodeURIComponent(m[1]) }, meta)
      .then((p) => send(res, 200, product(p)))
      .catch((err) => catalogError(res, err));
  }
  if (req.method === 'POST' && pathname === '/api/orders') {
    return forward(req, res, requestId, 'POST', '/orders');
  }
  if (req.method === 'GET' && (m = pathname.match(/^\/api\/orders\/([^/]+)$/))) {
    return forward(req, res, requestId, 'GET', `/orders/${m[1]}`);
  }
  return send(res, 404, { error: 'not found' });
}

const server = createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error(err);
    if (!res.headersSent) send(res, 500, { error: 'internal error' });
  });
});

server.listen(config.port, () => console.log(`gateway listening on :${config.port}`));
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
