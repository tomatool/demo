import path from 'node:path';
import grpc from '@grpc/grpc-js';
import protoLoader from '@grpc/proto-loader';

export const grpcStatus = grpc.status;

// catalogClient returns promise-based calls to catalog. Every call has a
// two second deadline and carries the given metadata.
export function catalogClient(address, protoDir) {
  const definition = protoLoader.loadSync(path.join(protoDir, 'catalog/v1/catalog.proto'), {
    includeDirs: [protoDir],
    longs: Number,
    defaults: true,
  });
  const { CatalogService } = grpc.loadPackageDefinition(definition).catalog.v1;
  // Reconnect quickly after catalog restarts, rather than after up to two
  // minutes of gRPC's default backoff, and retry a call that finds catalog
  // unavailable for a moment.
  const client = new CatalogService(address, grpc.credentials.createInsecure(), {
    'grpc.initial_reconnect_backoff_ms': 100,
    'grpc.max_reconnect_backoff_ms': 500,
    'grpc.service_config': JSON.stringify({
      methodConfig: [{
        name: [{ service: 'catalog.v1.CatalogService' }],
        retryPolicy: {
          maxAttempts: 5,
          initialBackoff: '0.1s',
          maxBackoff: '0.5s',
          backoffMultiplier: 2,
          retryableStatusCodes: ['UNAVAILABLE'],
        },
      }],
    }),
  });

  const call = (method) => (request, meta = {}) => new Promise((resolve, reject) => {
    const metadata = new grpc.Metadata();
    for (const [key, value] of Object.entries(meta)) metadata.set(key, value);
    client[method](request, metadata, { deadline: Date.now() + 2000 }, (err, reply) =>
      err ? reject(err) : resolve(reply));
  });

  return { getProduct: call('GetProduct'), listProducts: call('ListProducts') };
}
