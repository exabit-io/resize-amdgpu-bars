#!/usr/bin/env bash
# t02_style.sh - static conformance checks against bash-style-guide.md.
#
# Vendored from https://github.com/nbritton/bash_goto (test/t02_style.sh),
# MIT, see LICENSE and VENDORED.md in this directory. Upstream scans its own
# repository; this copy checks the files named on the command line instead,
# and accepts the shebang this package ships with (see VENDORED.md for the
# exact local changes, each marked "LOCAL:" below).
#
#   bash tests/style/t02_style.sh FILE...
#   STYLE_SHEBANG='#!/usr/bin/env bash' bash tests/style/t02_style.sh FILE...

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# LOCAL: no cd into the fixture directory, so the FILE arguments keep
# meaning what the caller typed; helpers are sourced by path instead
# shellcheck source=lib.sh
source "$here/lib.sh"
# LOCAL: the masker is vendored on its own (mask.sh) instead of sourcing
# the whole goto.sh compiler with --lib
# shellcheck source=mask.sh
source "$here/mask.sh"

# LOCAL: files come from the command line, not from the repository layout
if (( $# == 0 )); then
	printf 'usage: %s FILE...\n' "${BASH_SOURCE[0]}" >&2
	exit 2
fi
files=("$@")

# LOCAL: the required shebang is a parameter. The style guide asks for
# `#!/usr/bin/env bash`; this package deliberately ships `#!/bin/bash`
# (Debian policy for packaged scripts, decision recorded in the 7.0 plan),
# so that is the default here. Export STYLE_SHEBANG to check for another.
want_shebang=${STYLE_SHEBANG:-'#!/bin/bash'}

# expand tabs (tab stop 8) and return the display width in `width`
line_width() {
	local s=$1 i c
	width=0
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		if [[ $c == $'\t' ]]; then
			width=$(( width + 8 - width % 8 ))
		else
			(( ++width ))
		fi
	done
}

for f in "${files[@]}"; do
	# LOCAL: report the path as given (upstream strips its repo root)
	name=$f
	bad_shebang=''
	bad_width=''
	bad_indent=''
	bad_blank=''
	bad_trailing=''
	bad_bracket=''
	bad_backtick_sub=''
	bad_semi=''
	bad_kw=''
	blanks=0
	lineno=0
	while IFS= read -r line; do
		(( ++lineno ))
		# LOCAL: compare against $want_shebang (upstream: the literal)
		if (( lineno == 1 )) &&
		    [[ $line != "$want_shebang" ]]; then
			bad_shebang=$lineno
		fi
		line_width "$line"
		if (( width > 80 )); then
			bad_width+=" $lineno"
		fi
		# indentation must be tabs, never spaces
		if [[ $line == ' '* ]]; then
			bad_indent+=" $lineno"
		fi
		# at most one blank line in a row
		if [[ -z $line ]]; then
			(( ++blanks ))
			(( blanks > 1 )) && bad_blank+=" $lineno"
		else
			blanks=0
		fi
		if [[ $line == *' ' || $line == *$'\t' ]]; then
			bad_trailing+=" $lineno"
		fi
		# skip pure comment lines for the code-pattern checks
		trimmed=${line#"${line%%[![:space:]]*}"}
		[[ $trimmed == '#'* ]] && continue
		# check the masked line so that quoted text cannot look
		# like code (this also exercises the masker itself)
		line=$(__gt_mask "$line")
		# a line marked POSIX must parse in a POSIX shell, where
		# [[ ]] does not exist
		[[ $line == *POSIX* ]] && continue
		# single-bracket test (allow [[ ... ]])
		if [[ $line =~ (^|[^\[])\[[[:space:]] ]]; then
			bad_bracket+=" $lineno"
		fi
		# backtick command substitution
		if [[ $line =~ =\`|\$\(\` ]]; then
			bad_backtick_sub+=" $lineno"
		fi
		# no trailing semicolon (case terminators ;; are fine)
		if [[ $line == *';' && $line != *';;' ]]; then
			bad_semi+=" $lineno"
		fi
		# banned words: function keyword, let, readonly, seq
		if [[ $line =~ ^[[:space:]]*function[[:space:]] ]] ||
		    [[ $line =~ (^|[[:space:]])(let|readonly)[[:space:]] ]] ||
		    [[ $line =~ (^|[[:space:]\$\(])seq[[:space:]] ]]; then
			bad_kw+=" $lineno"
		fi
	done < "$f"

	# LOCAL: the description names the shebang actually required
	if [[ -z $bad_shebang ]]; then
		t_ok "$name: shebang is $want_shebang"
	else
		t_not_ok "$name: shebang is $want_shebang"
	fi
	if [[ -z $bad_width ]]; then
		t_ok "$name: no line exceeds 80 columns (tab=8)"
	else
		t_not_ok "$name: no line exceeds 80 columns" "lines:$bad_width"
	fi
	if [[ -z $bad_indent ]]; then
		t_ok "$name: indentation is tabs, not spaces"
	else
		t_not_ok "$name: indentation is tabs" "lines:$bad_indent"
	fi
	if [[ -z $bad_blank ]]; then
		t_ok "$name: no more than one blank line in a row"
	else
		t_not_ok "$name: blank line runs" "lines:$bad_blank"
	fi
	if [[ -z $bad_trailing ]]; then
		t_ok "$name: no trailing whitespace"
	else
		t_not_ok "$name: trailing whitespace" "lines:$bad_trailing"
	fi
	if [[ -z $bad_bracket ]]; then
		t_ok "$name: uses double-bracket tests only"
	else
		t_not_ok "$name: single-bracket test" "lines:$bad_bracket"
	fi
	if [[ -z $bad_backtick_sub ]]; then
		t_ok "$name: no backtick command substitution"
	else
		t_not_ok "$name: backtick substitution" \
		    "lines:$bad_backtick_sub"
	fi
	if [[ -z $bad_semi ]]; then
		t_ok "$name: no trailing semicolons"
	else
		t_not_ok "$name: trailing semicolons" "lines:$bad_semi"
	fi
	if [[ -z $bad_kw ]]; then
		t_ok "$name: no banned keywords (function/let/readonly/seq)"
	else
		t_not_ok "$name: banned keyword" "lines:$bad_kw"
	fi
done

# LOCAL: upstream exempts its two runtimes (goto.sh, goto_trap.sh) from
# the eval check; nothing here is exempt
for f in "${files[@]}"; do
	name=$f
	hits=$(grep -cE '(^[[:space:]]*|\$\()eval[[:space:]]' "$f") || :
	if [[ ${hits:-0} == 0 ]]; then
		t_ok "$name: no eval"
	else
		t_not_ok "$name: no eval" "count: $hits"
	fi
done

# when shellcheck is installed, the whole tree must lint clean
if command -v shellcheck > /dev/null; then
	# same flags as `make lint`, so the two can never disagree
	t_run shellcheck -x -P SCRIPTDIR -S style "${files[@]}"
	t_rc 'shellcheck is clean on all sources' 0 "$t_status"
else
	t_ok 'shellcheck not installed here - skipped (advisory)'
fi

t_done
