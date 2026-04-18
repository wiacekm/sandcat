#!/usr/bin/env bash

# Logging helpers
# Example usage:
# `echo 'Terrible error' | error`

if ! tput sgr0 &>/dev/null; then
	# Color output is best-effort; logging must never fail if TERM is unset
	# or if terminal capabilities are unavailable.
	_sct_tput() { :; }
else
	_sct_tput() {
		tput "$@" 2>/dev/null || true
	}
fi

_log() {
	local color=$1 label=$2
	local ts line
	# shellcheck disable=SC2312
	ts=$(date +%T)
	while IFS= read -r line; do
		echo -n "$ts "
		_sct_tput setaf "$color"
		_sct_tput bold
		echo -n "$label "
		_sct_tput sgr0
		echo "$line"
	done
} >&2

info()    { _log 4 '[INFO]'; }
warning() { _log 3 '[WARN]'; }
error()   { _log 1 '[ERROR]'; }
