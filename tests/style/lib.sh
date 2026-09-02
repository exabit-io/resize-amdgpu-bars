#!/usr/bin/env bash
# shellcheck disable=SC2034
# (t_out/t_err/t_status are set here for consumers of this library)
# lib.sh - assertion helpers shared by the t*.sh test files.
#
# Each test file sources this, calls t_* assertions, and finishes with
# t_done.  Output is TAP-like ("ok N - desc" / "not ok N - desc") with a
# final "# pass=X fail=Y" summary line that run_tests.sh aggregates.

t_count=0
t_failed=0

t_timeout=''
if command -v timeout > /dev/null; then
	t_timeout=timeout
fi

t_ok() {
	(( ++t_count ))
	printf 'ok %d - %s\n' "$t_count" "$1"
}

# t_not_ok DESC [DETAIL]
t_not_ok() {
	local desc=$1 line
	(( ++t_count ))
	(( ++t_failed ))
	printf 'not ok %d - %s\n' "$t_count" "$desc"
	shift
	if (( $# )); then
		while IFS= read -r line; do
			printf '#   %s\n' "$line"
		done <<<"$*"
	fi
}

# t_is DESC GOT WANT -- byte equality
t_is() {
	if [[ $2 == "$3" ]]; then
		t_ok "$1"
	else
		t_not_ok "$1" "got:  ${2@Q}
want: ${3@Q}"
	fi
}

# t_like DESC GOT SUBSTRING -- containment
t_like() {
	if [[ $2 == *"$3"* ]]; then
		t_ok "$1"
	else
		t_not_ok "$1" "got:  ${2@Q}
want substring: ${3@Q}"
	fi
}

# t_rc DESC WANT GOT -- exit status equality
t_rc() {
	if (( $3 == $2 )); then
		t_ok "$1"
	else
		t_not_ok "$1" "exit status: got $3, want $2"
	fi
}

# t_run CMD [ARG...] -- run a command (20s timeout when available) and
# capture stdout/stderr/status into t_out/t_err/t_status
t_run() {
	local out_f err_f
	out_f=$(mktemp "${TMPDIR:-/tmp}/goto-t.XXXXXX")
	err_f=$(mktemp "${TMPDIR:-/tmp}/goto-t.XXXXXX")
	if [[ -n $t_timeout ]]; then
		"$t_timeout" 20 "$@" > "$out_f" 2> "$err_f"
	else
		"$@" > "$out_f" 2> "$err_f"
	fi
	t_status=$?
	t_out=$(< "$out_f")
	t_err=$(< "$err_f")
	rm -f "$out_f" "$err_f"
}

# t_diff DESC FILE_WANT GOT_TEXT -- compare captured text to a golden file
t_diff() {
	local want
	want=$(< "$2")
	if [[ $3 == "$want" ]]; then
		t_ok "$1"
	else
		t_not_ok "$1" "$(diff <(printf '%s\n' "$want") \
		    <(printf '%s\n' "$3") | head -12)"
	fi
}

t_done() {
	printf '# pass=%d fail=%d\n' "$(( t_count - t_failed ))" "$t_failed"
	(( t_failed == 0 ))
}
