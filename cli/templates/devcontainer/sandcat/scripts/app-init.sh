#!/bin/bash
#
# Entrypoint for containers that share the wg-client's network namespace.
# Installs the mitmproxy CA cert, disables commit signing, loads env vars
# and secret placeholders from sandcat.env, runs vscode-user setup (git
# identity, Java trust store, Claude Code update), then drops to vscode
# and exec's the container's main command.
#
set -e

CA_CERT="/mitmproxy-config/mitmproxy-ca-cert.pem"

# The CA cert is guaranteed to exist: app depends_on wg-client (healthy),
# which depends_on mitmproxy (healthy), whose healthcheck requires both
# wireguard.conf and mitmproxy-ca-cert.pem.
if [ ! -f "$CA_CERT" ]; then
    echo "mitmproxy CA cert not found at $CA_CERT" >&2
    exit 1
fi

cp "$CA_CERT" /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates

# Node.js ignores the system trust store and bundles its own CA certs.
# Point it at the mitmproxy CA so TLS verification works for Node-based
# tools (e.g. Anthropic SDK).
export NODE_EXTRA_CA_CERTS="$CA_CERT"

# Force Node.js to use the system CA store (via OpenSSL) instead of its
# bundled Mozilla roots. Required for tools that bundle their own Node.js
# binary where NODE_EXTRA_CA_CERTS alone may not suffice.
#
# --require ca-inject.js patches tls.createSecureContext so the mitmproxy CA
# is included even when callers pin specific CAs (bypasses cert pinning).
CA_INJECT="/usr/local/lib/sandcat/ca-inject.js"
SANDCAT_NODE_OPTS="--use-openssl-ca"
if [ -f "$CA_INJECT" ]; then
    SANDCAT_NODE_OPTS="$SANDCAT_NODE_OPTS --require $CA_INJECT"
fi
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$SANDCAT_NODE_OPTS"

cat > /etc/profile.d/sandcat-node-ca.sh << NODEEOF
export NODE_EXTRA_CA_CERTS="/mitmproxy-config/mitmproxy-ca-cert.pem"
export NODE_OPTIONS="\${NODE_OPTIONS:+\$NODE_OPTIONS }$SANDCAT_NODE_OPTS"
NODEEOF

# Some CLIs don't consistently use the system trust store in all code paths.
# Export common CA-related env vars so TLS clients prefer the updated Debian
# CA bundle (which now includes the mitmproxy CA).
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export SSL_CERT_FILE="$CA_BUNDLE"
export SSL_CERT_DIR="/etc/ssl/certs"
export CURL_CA_BUNDLE="$CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
export GIT_SSL_CAINFO="$CA_BUNDLE"
cat > /etc/profile.d/sandcat-ca.sh << CAEOF
export SSL_CERT_FILE="$CA_BUNDLE"
export SSL_CERT_DIR="/etc/ssl/certs"
export CURL_CA_BUNDLE="$CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
export GIT_SSL_CAINFO="$CA_BUNDLE"
CAEOF

# GPG keys are not forwarded into the container (credential isolation),
# so commit signing would always fail.  Git env vars have the highest
# precedence, overriding system/global/local/worktree config files.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"
cat > /etc/profile.d/sandcat-git.sh << 'GITEOF'
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"
GITEOF

# Source env vars and secret placeholders (if available)
SANDCAT_ENV="/mitmproxy-config/sandcat.env"
if [ -f "$SANDCAT_ENV" ]; then
    . "$SANDCAT_ENV"
    # Make vars available to new shells (e.g. VS Code terminals in dev
    # containers) that won't inherit the entrypoint's environment.
    cp "$SANDCAT_ENV" /etc/profile.d/sandcat-env.sh
    count=$(grep -c '^export ' "$SANDCAT_ENV" 2>/dev/null || echo 0)
    echo "Loaded $count env var(s) from $SANDCAT_ENV"
    grep '^export ' "$SANDCAT_ENV" | sed 's/=.*//' | sed 's/^export /  /'
else
    echo "No $SANDCAT_ENV found — env vars and secret substitution disabled"
fi

# Run vscode-user tasks: git identity, Java trust store, Cursor/Claude bootstrap.
# Preserve environment loaded from sandcat.env so user-init can read variables
# such as CURSOR_API_KEY reliably.
su -m vscode -c /usr/local/bin/app-user-init.sh

# Source all sandcat profile.d scripts from /etc/bash.bashrc so env vars
# are available in non-login shells (e.g. VS Code integrated terminals).
# Guard with a marker to avoid duplicating on container restart.
BASHRC_MARKER="# sandcat-profile-source"
if ! grep -q "$BASHRC_MARKER" /etc/bash.bashrc 2>/dev/null; then
    cat >> /etc/bash.bashrc << 'BASHRC_EOF'

# sandcat-profile-source
for _f in /etc/profile.d/sandcat-*.sh; do
    [ -r "$_f" ] && . "$_f"
done
unset _f
BASHRC_EOF
fi

exec gosu vscode "$@"
