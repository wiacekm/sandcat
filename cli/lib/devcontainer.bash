#!/usr/bin/env bash

# shellcheck source=stacks.bash
source "$SCT_LIBDIR/stacks.bash"

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
	sed -i.bak "s/__PROJECT_NAME__/${project_name}/g" "$devcontainer_json" && rm -f "${devcontainer_json}.bak"
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

	local insertion=""
	local stack cmd
	for stack in "${stacks[@]}"; do
		cmd=$(stack_mise_cmd "$stack")
		if [[ -n "$cmd" ]]; then
			insertion="${insertion}RUN ${cmd}\n"
		fi
	done

	# Insert before the END STACKS marker (portable sed for BSD + GNU)
	sed -i.bak "s|^# END STACKS|${insertion}# END STACKS|" "$dockerfile" && rm -f "${dockerfile}.bak"
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
	while IFS= read -r line; do
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
