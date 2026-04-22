#!/usr/bin/env bash

# shellcheck source=stacks.bash
source "$SCT_LIBDIR/stacks.bash"
# shellcheck source=agents.bash
source "$SCT_LIBDIR/agents.bash"

# Replaces __PROJECT_NAME__ placeholder with the actual project name in devcontainer.json.
#
# Uses `sed` because `yq` does not support JSONC
# Args:
#   $1 - Path to the devcontainer.json file
#   $2 - Project name to substitute
customize_devcontainer_json() {
	local devcontainer_json=$1
	local project_name=$2

	# Use sed in a way that works on both BSD (macOS) and GNU (Linux)
	# Escape sed metacharacters in project_name (& and \ have special meaning)
	local escaped_name
	escaped_name=$(printf '%s' "$project_name" | sed 's/[&\\/]/\\&/g')
	sed -i.bak "s/__PROJECT_NAME__/${escaped_name}/g" "$devcontainer_json" && rm -f "${devcontainer_json}.bak"
}

# Inserts RUN mise lines into the Dockerfile for selected stacks.
# Lines are inserted before the "# END STACKS" marker.
# Args:
#   $1 - Path to the Dockerfile
#   $@ - Stack names (remaining args)
customize_dockerfile() {
	local dockerfile=$1
	shift
	if [[ $# -eq 0 ]]; then
		return
	fi
	local stacks=("$@")

	local run_lines=()
	local stack cmd
	for stack in "${stacks[@]}"; do
		cmd=$(stack_mise_cmd "$stack")
		if [[ -n "$cmd" ]]; then
			run_lines+=("RUN ${cmd}")
		fi
	done

	# Build the output file, inserting RUN lines before the END STACKS marker.
	# Uses a while-read loop instead of sed to avoid & escaping issues.
	local tmpfile="${dockerfile}.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "# END STACKS" ]]; then
			local l
			for l in "${run_lines[@]}"; do
				printf '%s\n' "$l"
			done
		fi
		printf '%s\n' "$line"
	done < "$dockerfile" > "$tmpfile"
	mv "$tmpfile" "$dockerfile"
}

# Adds VS Code extensions for selected stacks to devcontainer.json.
# Replaces the // __STACK_EXTENSIONS__ placeholder line.
# Args:
#   $1 - Path to the devcontainer.json file
#   $@ - Stack names (remaining args)
customize_devcontainer_extensions() {
	local devcontainer_json=$1
	shift

	local ext_lines=""
	local stack ext
	for stack in "$@"; do
		ext=$(stack_extension "$stack")
		if [[ -n "$ext" ]]; then
			ext_lines="${ext_lines}				\"${ext}\","$'\n'
		fi
	done

	# Build the output file, replacing the placeholder line
	local tmpfile="${devcontainer_json}.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__STACK_EXTENSIONS__"* ]]; then
			if [[ -n "$ext_lines" ]]; then
				printf '%s' "$ext_lines"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_json" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_json"
}

# Replaces provider-specific placeholders in generated templates.
# Args:
#   $1 - Path to devcontainer directory
#   $2 - Agent name
customize_agent_templates() {
	local devcontainer_dir=$1
	local agent=$2

	local extension settings_block environment_block docker_install_block docker_home_prep_block user_init_block
	local mitm_addon_file mitm_http2
	extension=$(sct_agent_vscode_extension "$agent")
	settings_block=$(sct_agent_devcontainer_settings_block "$agent")
	environment_block=$(sct_agent_compose_environment_block "$agent")
	docker_install_block=$(sct_agent_docker_install_block "$agent")
	docker_home_prep_block=$(sct_agent_docker_home_prep_block "$agent")
	user_init_block=$(sct_agent_user_init_block "$agent")
	case "$agent" in
		cursor)
			mitm_addon_file="mitmproxy_addon_cursor.py"
			mitm_http2="true"
			;;
		claude|*)
			mitm_addon_file="mitmproxy_addon_claude.py"
			mitm_http2="true"
			;;
	esac

	local tmpfile

	# devcontainer.json placeholders
	tmpfile="$devcontainer_dir/devcontainer.json.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__AGENT_EXTENSION__"* ]]; then
			if [[ -n "$extension" ]]; then
				printf '				"%s",\n' "$extension"
			fi
		elif [[ "$line" == *"__AGENT_SETTINGS__"* ]]; then
			if [[ -n "$settings_block" ]]; then
				printf '%s\n' "$settings_block"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_dir/devcontainer.json" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_dir/devcontainer.json"

	# compose-all.yml placeholder (omit entire block when agent has no env entries)
	tmpfile="$devcontainer_dir/compose-all.yml.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__AGENT_ENVIRONMENT_BLOCK__"* ]]; then
			if [[ -n "$environment_block" ]]; then
				printf '%s\n' "$environment_block"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_dir/compose-all.yml" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_dir/compose-all.yml"

	# Dockerfile provider install/home blocks
	tmpfile="$devcontainer_dir/Dockerfile.app.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__AGENT_DOCKER_INSTALL__"* ]]; then
			if [[ -n "$docker_install_block" ]]; then
				printf '%s\n' "$docker_install_block"
			fi
		elif [[ "$line" == *"__AGENT_DOCKER_HOME_PREP__"* ]]; then
			if [[ -n "$docker_home_prep_block" ]]; then
				printf '%s\n' "$docker_home_prep_block"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_dir/Dockerfile.app" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_dir/Dockerfile.app"

	# app-user-init provider block
	tmpfile="$devcontainer_dir/sandcat/scripts/app-user-init.sh.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__AGENT_USER_INIT__"* ]]; then
			if [[ -n "$user_init_block" ]]; then
				printf '%s\n' "$user_init_block"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_dir/sandcat/scripts/app-user-init.sh" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_dir/sandcat/scripts/app-user-init.sh"

	# mitmproxy command/addon placeholders
	tmpfile="$devcontainer_dir/sandcat/compose-proxy.yml.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line//__AGENT_MITM_ADDON__/$mitm_addon_file}"
		line="${line//__MITM_HTTP2__/$mitm_http2}"
		printf '%s\n' "$line"
	done < "$devcontainer_dir/sandcat/compose-proxy.yml" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_dir/sandcat/compose-proxy.yml"
}
