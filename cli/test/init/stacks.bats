#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/stacks.bash
	source "$SCT_LIBDIR/stacks.bash"
}

teardown() {
	unstub_all
}

@test "stack_mise_cmd returns correct command for each stack" {
	run stack_mise_cmd node
	assert_output "mise use -g node@lts"

	run stack_mise_cmd python
	assert_output "mise use -g python@3"

	run stack_mise_cmd java
	assert_output "mise use -g java@lts"

	run stack_mise_cmd rust
	assert_output "mise use -g rust@latest"

	run stack_mise_cmd go
	assert_output "mise use -g go@latest"

	run stack_mise_cmd scala
	assert_output "mise use -g scala@latest && mise use -g sbt@latest && mise use -g scala-cli@latest"

	run stack_mise_cmd ruby
	assert_output "mise use -g ruby@latest"

	run stack_mise_cmd dotnet
	assert_output "mise use -g dotnet@latest"
}

@test "stack_extension returns extension ID for stacks with extensions" {
	run stack_extension python
	assert_output "ms-python.python"

	run stack_extension java
	assert_output "redhat.java"

	run stack_extension rust
	assert_output "rust-lang.rust-analyzer"

	run stack_extension go
	assert_output "golang.go"

	run stack_extension scala
	assert_output "scalameta.metals"

	run stack_extension ruby
	assert_output "shopify.ruby-lsp"

	run stack_extension dotnet
	assert_output "ms-dotnettools.csdevkit"
}

@test "stack_extension returns empty for node" {
	run stack_extension node
	assert_output ""
}

@test "stack_deps returns java for scala" {
	run stack_deps scala
	assert_output "java"
}

@test "stack_deps returns empty for non-dependent stacks" {
	run stack_deps node
	assert_output ""

	run stack_deps python
	assert_output ""
}

@test "resolve_stacks adds java before scala" {
	run resolve_stacks scala
	assert_output "java scala"
}

@test "resolve_stacks does not duplicate java when both selected" {
	run resolve_stacks java scala
	assert_output "java scala"
}

@test "resolve_stacks preserves order for independent stacks" {
	run resolve_stacks python node rust
	assert_output "python node rust"
}

@test "resolve_stacks handles single stack" {
	run resolve_stacks python
	assert_output "python"
}

@test "resolve_stacks handles empty input" {
	run resolve_stacks
	assert_output ""
}

@test "validate_stacks accepts valid stack names" {
	run validate_stacks node python java
	assert_success
}

@test "validate_stacks rejects invalid stack name" {
	run validate_stacks node invalid python
	assert_failure
	assert_output --partial "Invalid stack: invalid"
}

@test "validate_stacks lists available stacks on failure" {
	run validate_stacks invalid
	assert_failure
	assert_output --partial "expected:"
}
