#!/usr/bin/env bash

# shellcheck source=logging.bash
source "$SCT_LIBDIR/logging.bash"

# Compares a Docker volume timestamp with an image timestamp.
# Returns 0 (true) if the image is newer than the volume.
# Uses GNU date for timezone-aware comparison on Linux;
# falls back to lexicographic comparison (safe when the Docker
# daemon runs in UTC, e.g. Docker Desktop on macOS).
# Args:
#   $1 - Volume CreatedAt  (e.g. "2024-01-15 10:30:00 +0000 UTC")
#   $2 - Image Created     (e.g. "2024-01-15T10:30:00.123456789Z")
_image_newer_than_volume() {
	local volume_time=$1
	local image_time=$2

	# Try GNU date first — handles timezone offsets correctly.
	local vol_epoch img_epoch
	if vol_epoch=$(date -d "$volume_time" +%s 2>/dev/null) && \
	   img_epoch=$(date -d "$image_time" +%s 2>/dev/null); then
		(( img_epoch > vol_epoch ))
		return
	fi

	# Fallback: strip timezone, compare YYYY-MM-DDTHH:MM:SS strings.
	# Volume format: "2024-01-15 10:30:00 +0000 UTC" (space before time)
	# Image format:  "2024-01-15T10:30:00.123456789Z" (T before time)
	local vol_norm img_norm
	vol_norm=$(echo "$volume_time" | sed 's/ /T/' | cut -c1-19)
	img_norm=$(echo "$image_time" | cut -c1-19)
	[[ "$img_norm" > "$vol_norm" ]]
}

# Warns if the agent-home volume predates the current agent image.
# After an image rebuild the named volume still holds old contents,
# so packages installed during the build (mise toolchains, Claude Code,
# etc.) are hidden by the stale volume overlay.
# Args:
#   $1 - Path to the compose file
warn_stale_home_volume() {
	local compose_file=$1

	command -v yq &>/dev/null || return 0

	local project_name
	project_name=$(yq -r '.name // ""' "$compose_file") || return 0
	[[ -n "$project_name" ]] || return 0

	local volume_name="${project_name}_agent-home"
	local image_name="${project_name}-agent"

	# No volume yet (first run) — nothing to warn about.
	docker volume inspect "$volume_name" &>/dev/null || return 0

	local volume_time image_time
	volume_time=$(docker volume inspect --format '{{.CreatedAt}}' "$volume_name" 2>/dev/null) || return 0
	image_time=$(docker image inspect --format '{{.Created}}' "$image_name" 2>/dev/null) || return 0

	if _image_newer_than_volume "$volume_time" "$image_time"; then
		echo "The agent image was rebuilt since the agent-home volume was created." | warning
		echo "Packages installed during the build may not be visible." | warning
		echo "To fix, stop containers and remove the volume:" | warning
		echo "  sandcat compose down && docker volume rm $volume_name" | warning
	fi
}
