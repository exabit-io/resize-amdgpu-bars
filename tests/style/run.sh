#!/bin/bash
# run.sh - run the vendored bash style fixture against the files named on
# the command line. Output is TAP-like; the exit status is 0 only when every
# check passes. See VENDORED.md for where the fixture comes from and what
# was changed.
#
#   tests/style/run.sh resize_gpu_bars.sh [FILE...]
#   STYLE_SHEBANG='#!/usr/bin/env bash' tests/style/run.sh FILE...

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.

if (( $# == 0 )); then
	printf 'usage: %s FILE...\n' "$0" >&2
	exit 2
fi

exec bash "$here/t02_style.sh" "$@"
