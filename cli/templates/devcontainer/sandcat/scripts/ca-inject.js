/**
 * Node.js preload script that injects the mitmproxy CA into all TLS contexts.
 *
 * Some tools (e.g. Cursor CLI) pin specific CA certificates for their API
 * endpoints by passing an explicit `ca` option to tls.createSecureContext().
 * This bypasses NODE_EXTRA_CA_CERTS and --use-openssl-ca.
 *
 * This script patches tls.createSecureContext so the mitmproxy CA is always
 * included alongside any caller-specified CAs, allowing mitmproxy to
 * transparently intercept TLS traffic for secret substitution.
 *
 * Loaded via: NODE_OPTIONS="--require /path/to/ca-inject.js"
 */
'use strict';

const CA_CERT_PATH = '/mitmproxy-config/mitmproxy-ca-cert.pem';

try {
  const tls = require('tls');
  const fs = require('fs');

  if (!fs.existsSync(CA_CERT_PATH)) return;

  const mitmCA = fs.readFileSync(CA_CERT_PATH, 'utf8');
  const _createSecureContext = tls.createSecureContext;

  tls.createSecureContext = function patchedCreateSecureContext(options) {
    if (options && options.ca) {
      const extra = Array.isArray(options.ca) ? options.ca : [options.ca];
      options = Object.assign({}, options, { ca: [...extra, mitmCA] });
    }
    return _createSecureContext.call(this, options);
  };
} catch (_) {
  // Silently ignore — TLS patching is best-effort.
}
