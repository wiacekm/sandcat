#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DOCKERFILE="$BATS_TEST_TMPDIR/Dockerfile.app"
	cp "$SCT_TEMPLATEDIR/devcontainer/Dockerfile.app" "$DOCKERFILE"
}

teardown() {
	unstub_all
}

@test "customize_dockerfile inserts RUN line for single stack" {
	customize_dockerfile "$DOCKERFILE" python

	run grep "^RUN mise use -g python@3$" "$DOCKERFILE"
	assert_success
}

@test "customize_dockerfile inserts RUN lines for multiple stacks" {
	customize_dockerfile "$DOCKERFILE" node java rust

	run grep "^RUN mise use -g node@lts$" "$DOCKERFILE"
	assert_success

	run grep "^RUN mise use -g java@lts$" "$DOCKERFILE"
	assert_success

	run grep "^RUN mise use -g rust@latest$" "$DOCKERFILE"
	assert_success
}

@test "customize_dockerfile inserts lines before END STACKS marker" {
	customize_dockerfile "$DOCKERFILE" python

	run grep -n "^RUN mise use -g python" "$DOCKERFILE"
	assert_success
	local run_line
	run_line=$(grep -n "^RUN mise use -g python" "$DOCKERFILE" | cut -d: -f1)

	local marker_line
	marker_line=$(grep -n "^# END STACKS" "$DOCKERFILE" | cut -d: -f1)

	(( run_line < marker_line ))
}

@test "customize_dockerfile preserves END STACKS marker" {
	customize_dockerfile "$DOCKERFILE" python

	run grep "^# END STACKS" "$DOCKERFILE"
	assert_success
}

@test "customize_dockerfile is a no-op with no stacks" {
	local before
	before=$(cat "$DOCKERFILE")

	customize_dockerfile "$DOCKERFILE"

	local after
	after=$(cat "$DOCKERFILE")
	assert_equal "$after" "$before"
}

@test "customize_dockerfile handles ampersands in mise commands (scala)" {
	customize_dockerfile "$DOCKERFILE" scala

	run grep "mise use -g scala@latest && mise use -g sbt@latest && mise use -g scala-cli@latest" "$DOCKERFILE"
	assert_success

	# Verify the END STACKS marker is not corrupted
	run grep "^# END STACKS$" "$DOCKERFILE"
	assert_success
}

@test "customize_dockerfile preserves Java trust store block" {
	customize_dockerfile "$DOCKERFILE" java

	run grep "mise where java" "$DOCKERFILE"
	assert_success
}
