#!/usr/bin/env bash

# Returns supported agents as a space-separated list.
sct_available_agents() {
	echo "claude cursor"
}

# Returns 0 if agent is valid.
# Args:
#   $1 - Agent name
sct_is_valid_agent() {
	local agent=$1
	local item
	for item in $(sct_available_agents); do
		if [[ "$item" == "$agent" ]]; then
			return 0
		fi
	done
	return 1
}

# Returns the optional config mount env var for an agent.
# Args:
#   $1 - Agent name
sct_agent_mount_env_var() {
	local agent=$1
	case "$agent" in
		claude) echo "SANDCAT_MOUNT_CLAUDE_CONFIG" ;;
		cursor) echo "SANDCAT_MOUNT_CURSOR_CONFIG" ;;
		*)      echo "" ;;
	esac
}

# Returns one-line API key help text for init output.
# Args:
#   $1 - Agent name
sct_agent_api_key_help() {
	local agent=$1
	case "$agent" in
		claude) echo "ANTHROPIC_API_KEY  your Anthropic API key (for Claude Code)" ;;
		cursor) echo "CURSOR_API_KEY     your Cursor API key (for Cursor CLI)" ;;
		*)      echo "ANTHROPIC_API_KEY  API key for your selected agent" ;;
	esac
}

# Returns extension id for a selected agent.
# Args:
#   $1 - Agent name
sct_agent_vscode_extension() {
	local agent=$1
	case "$agent" in
		claude) echo "anthropic.claude-code" ;;
		cursor) echo "anysphere.cursor" ;;
		*)      echo "" ;;
	esac
}

# Returns devcontainer settings block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_devcontainer_settings_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
				// Sandcat provides the security boundary (network isolation,
				// secret substitution, iptables kill-switch), so permission
				// prompts inside the container add friction without meaningful
				// security benefit. Remove these if you prefer interactive
				// permission approval.
				"claudeCode.allowDangerouslySkipPermissions": true,
				"claudeCode.initialPermissionMode": "bypassPermissions",
				// Optional: override the default Claude model.
				"claudeCode.selectedModel": "opus"
EOF
			;;
		cursor)
			cat <<'EOF'
				// Cursor CLI support currently uses compatibility defaults for
				// auth/network config. Add Cursor-specific settings here if needed.
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns compose fragment for services.agent environment (full YAML block).
# For agents with no compose-level env vars, returns empty (omit key entirely —
# Docker Compose rejects `environment:` with no mapping).
# Args:
#   $1 - Agent name
sct_agent_compose_environment_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
    environment:
      - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
EOF
			;;
		cursor|*)
			echo ""
			;;
	esac
}

# Returns Dockerfile install block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_docker_install_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Install Claude Code (native binary — no Node.js required).
RUN curl -fsSL https://claude.ai/install.sh | bash
EOF
			;;
		cursor)
			cat <<'EOF'
# Install Cursor CLI.
RUN curl https://cursor.com/install -fsS | bash
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns Dockerfile config-home preparation block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_docker_home_prep_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Pre-create ~/.claude so Docker bind-mounts (CLAUDE.md, agents/, commands/)
# don't cause it to be created as root-owned.
RUN mkdir -p /home/vscode/.claude
RUN echo 'alias claude-yolo="claude --dangerously-skip-permissions"' >> /home/vscode/.bashrc
EOF
			;;
		cursor)
			cat <<'EOF'
# Pre-create Cursor config directories so optional host config mounts do not
# create them as root-owned.
RUN mkdir -p /home/vscode/.cursor /home/vscode/.config/cursor
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns app-user-init bootstrap block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_user_init_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Seed the onboarding flag so Claude Code uses the API key without interactive
# setup. Only written when the user configured an ANTHROPIC_API_KEY secret.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
fi

# Claude Code is installed at build time (Dockerfile.app).
# Background update so it doesn't block startup.
(claude install >/dev/null 2>&1 &)
EOF
			;;
		cursor)
			cat <<'EOF'
# Seed Cursor auth config with the real API key from the mitmproxy volume.
# Cursor CLI uses a native TLS module with cert pinning, so mitmproxy cannot
# MITM its API traffic for placeholder substitution. Instead, TLS passthrough
# is enabled (--ignore-hosts) and the real key is injected here at startup.
# The secrets file is on the mitmproxy-config volume (read-only mount).
SANDCAT_SECRETS="/mitmproxy-config/sandcat-secrets.json"
if [ -f "$SANDCAT_SECRETS" ] && command -v jq >/dev/null 2>&1; then
    CURSOR_REAL_KEY="$(jq -r '.CURSOR_API_KEY // empty' "$SANDCAT_SECRETS")"
    if [ -n "$CURSOR_REAL_KEY" ]; then
        CURSOR_AUTH_CONFIG="$HOME/.config/cursor/auth.json"
        mkdir -p "$(dirname "$CURSOR_AUTH_CONFIG")"
        jq -n --arg key "$CURSOR_REAL_KEY" '{"apiKey":$key}' > "$CURSOR_AUTH_CONFIG"
        unset CURSOR_REAL_KEY

        # cursor-agent reads CURSOR_API_KEY from the env var (not auth.json).
        # Write an override script that reads the real value from the JSON
        # file at source time. app-init.sh sources this after user-init,
        # replacing the placeholder with the real value.
        cat > /tmp/sandcat-env-override.sh << 'OVERRIDE'
_SCSF="/mitmproxy-config/sandcat-secrets.json"
if [ -f "$_SCSF" ] && command -v jq >/dev/null 2>&1; then
    _val="$(jq -r '.CURSOR_API_KEY // empty' "$_SCSF")"
    [ -n "$_val" ] && export CURSOR_API_KEY="$_val"
    unset _val
fi
unset _SCSF
OVERRIDE
    fi
fi

# Cursor CLI networking bootstrap.
# Some proxy/TLS environments are unstable with HTTP/2 streaming, so always
# enforce the Cursor CLI HTTP/1 compatibility setting.
if command -v jq >/dev/null 2>&1; then
    for CURSOR_CLI_CONFIG in "$HOME/.config/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"; do
        mkdir -p "$(dirname "$CURSOR_CLI_CONFIG")"
        if [ ! -f "$CURSOR_CLI_CONFIG" ]; then
            echo '{"version":1}' > "$CURSOR_CLI_CONFIG"
        fi
        tmp="$(mktemp)"
        jq \
            '.network = (.network // {}) | .network.useHttp1ForAgent = true' \
            "$CURSOR_CLI_CONFIG" > "$tmp" \
            && mv "$tmp" "$CURSOR_CLI_CONFIG" \
            || { rm -f "$tmp"; echo "Warning: failed to update $CURSOR_CLI_CONFIG via jq" >&2; }
    done
else
    echo "Warning: jq not found; cannot apply Cursor CLI HTTP/1 bootstrap config" >&2
fi
EOF
			;;
		*)
			echo ""
			;;
	esac
}
