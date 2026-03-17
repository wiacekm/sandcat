#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/claude/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
}

teardown() {
	unstub_all
}

@test "customize_devcontainer_extensions adds extension for python" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions adds multiple extensions" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python java go

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"redhat.java"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"golang.go"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions preserves existing extensions" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"github.vscode-pull-request-github"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions removes placeholder with no extensions" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" node

	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure
}

@test "customize_devcontainer_extensions removes placeholder when extensions added" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure
}

@test "customize_devcontainer_extensions is a no-op for empty stacks" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON"

	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success
}
