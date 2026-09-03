#!/bin/bash
# check.sh - static style checks for the project's bash sources, TAP-like
# output, exit 0 only when every check passes.
#
#   tests/style/check.sh FILE...
#
# Checks, per file: the shebang is #!/bin/bash (Debian policy for packaged
# scripts), no line exceeds 80 columns at tab stop 8, indentation is tabs,
# no trailing whitespace, no runs of blank lines, no eval, no backtick
# command substitution. Then shellcheck -S style over all files together,
# when shellcheck is installed.
set -u
export LC_ALL=C

n=0
fails=0
ok() { n=$((n + 1)); printf 'ok %d - %s\n' "$n" "$1"; }
not_ok() {
	n=$((n + 1)); fails=$((fails + 1))
	printf 'not ok %d - %s%s\n' "$n" "$1" "${2:+ ($2)}"
}

# bad_lines FILE PATTERN -- line numbers matching PATTERN (comments skipped
# for the code checks by the caller's pattern), comma separated
bad_lines() {
	grep -nE "$2" "$1" | cut -d: -f1 | paste -sd, -
}

# wide_lines FILE -- line numbers wider than 80 columns with tabs expanded
wide_lines() {
	expand -t 8 "$1" | awk 'length > 80 { printf "%s%d", s, NR; s = "," }'
}

# blank_runs FILE -- line numbers of a second consecutive blank line
blank_runs() {
	awk '/^$/ { if (p) printf "%s%d", s, NR; s = ","; p = 1; next }
	     { p = 0 }' "$1"
}

# report DESCRIPTION BAD_LINES -- ok when BAD_LINES is empty
report() {
	if [[ -z $2 ]]; then
		ok "$1"
	else
		not_ok "$1" "lines $2"
	fi
}

if (( $# == 0 )); then
	printf 'usage: %s FILE...\n' "$0" >&2
	exit 2
fi

for f in "$@"; do
	name=${f##*/}
	if [[ $(head -1 "$f") == '#!/bin/bash' ]]; then
		ok "$name: shebang is #!/bin/bash"
	else
		not_ok "$name: shebang is #!/bin/bash"
	fi
	report "$name: no line exceeds 80 columns" "$(wide_lines "$f")"
	report "$name: indentation is tabs" "$(bad_lines "$f" '^ +[^ ]')"
	report "$name: no trailing whitespace" \
		"$(bad_lines "$f" '[[:space:]]+$')"
	report "$name: no runs of blank lines" "$(blank_runs "$f")"
	report "$name: no eval" \
		"$(bad_lines "$f" '^[^#]*(^|[^[:alnum:]_])eval([[:space:]]|$)')"
	report "$name: no backtick substitution" "$(bad_lines "$f" '^[^#]*`')"
done

if command -v shellcheck > /dev/null; then
	if shellcheck -S style "$@" > /dev/null 2>&1; then
		ok 'shellcheck -S style is clean'
	else
		not_ok 'shellcheck -S style is clean'
	fi
else
	ok 'shellcheck not installed - skipped'
fi

printf '# pass=%d fail=%d\n' "$((n - fails))" "$fails"
(( fails == 0 ))
