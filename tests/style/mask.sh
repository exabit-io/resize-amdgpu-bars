#!/bin/bash
# mask.sh - the pass-2 masker (__gt_mask) of goto.sh from
# https://github.com/nbritton/bash_goto (MIT, see LICENSE in this directory),
# extracted verbatim so that t02_style.sh can blank quoted text and heredoc
# bodies before its code-pattern checks. Nothing else of goto.sh is needed.
#
# shellcheck disable=SC2034,SC1003,SC2016
# (SC2034: scanner state lives in locals this copy never reads back, as
# upstream; SC1003/SC2016: the masker matches literal backslashes and
# emits literal '$(' tokens on purpose)

# pass 2 - mask quoted text and heredoc bodies, preserving offsets and
#          newlines so that pass 3 can scan for keywords without tripping
#          over `echo "done"` or a heredoc containing the word `label`
# ---------------------------------------------------------------------------
__gt_mask() {
	local s=$1
	local n=${#s} i=0 c out='' q='' qret='' hd='' hdtab=''
	local chk ln='' j d dq x next tab old aq=''
	local arith=0 arraydepth=0 subdepth=0
	local -a pend=() pendtab=() subret=()
	while (( i < n )); do
		c=${s:i:1}
		# inside a heredoc body: everything is masked; a line equal
		# to the delimiter (minus leading tabs for <<-) ends the body
		if [[ -n $hd ]]; then
			if [[ $c == $'\n' ]]; then
				chk=$ln
				if [[ -n $hdtab ]]; then
					while [[ $chk == $'\t'* ]]; do
						chk=${chk#$'\t'}
					done
				fi
				if [[ $chk == "$hd" ]]; then
					hd=
					if (( ${#pend[@]} )); then
						hd=${pend[0]}
						hdtab=${pendtab[0]}
						pend=("${pend[@]:1}")
						pendtab=("${pendtab[@]:1}")
					fi
				fi
				out+=$'\n'
				ln=
			else
				out+=X
				ln+=$c
			fi
			(( i++ ))
			continue
		fi
		# Array-assignment values and extglob patterns are words, not
		# commands.  Parentheses and quotes still need balancing so
		# scanning resumes at the exact byte after the closing paren.
		if (( arraydepth > 0 )); then
			if [[ -n $aq ]]; then
				if [[ $c == '\' && $aq == '"' ]]; then
					out+=X
					(( i++ ))
					if [[ ${s:i:1} == $'\n' ]]; then
						out+=$'\n'
					else
						out+=X
					fi
				else
					[[ $c == "$aq" ]] && aq=
					if [[ $c == $'\n' ]]; then
						out+=$'\n'
					else
						out+=X
					fi
				fi
				(( i++ ))
				continue
			fi
			case $c in
			"'"|'"')
				aq=$c
				out+=X
				;;
			'\')
				out+=X
				(( i++ ))
				[[ ${s:i:1} == $'\n' ]] &&
				    out+=$'\n' || out+=X
				;;
			'(')
				(( ++arraydepth ))
				out+='('
				;;
			')')
				(( --arraydepth ))
				out+=')'
				;;
			$'\n') out+=$'\n' ;;
			*) out+=X ;;
			esac
			(( i++ ))
			continue
		fi
		# Arithmetic is data to the command scanner.  Mask its body so
		# a variable named `goto` or `done` cannot become compiler
		# syntax; only the delimiters remain visible.
		if (( arith > 0 )); then
			if [[ $c == '(' && ${s:i+1:1} == '(' ]]; then
				(( ++arith ))
				out+='(('
				(( i += 2 ))
			elif [[ $c == ')' && ${s:i+1:1} == ')' ]]; then
				(( --arith ))
				out+='))'
				(( i += 2 ))
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'
				(( i++ ))
			else
				out+=X
				(( i++ ))
			fi
			continue
		fi
		# inside a single-quoted string
		if [[ $q == "'" ]]; then
			if [[ $c == "'" ]]; then
				q=
				out+="'"
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'  # keep mask/source lines aligned
			else
				out+=X
			fi
			(( i++ ))
			continue
		fi
		# inside a `...` command substitution: mask it like a quoted
		# region so its words never reach the scanner (a goto in there
		# cannot work anyway - it would run in a subshell - and is
		# rejected separately by __gt_chk_backtick)
		if [[ $q == '`' ]]; then
			if [[ $c == '\' ]]; then
				if [[ ${s:i+1:1} == $'\n' ]]; then
					out+=X$'\n'
				else
					out+=XX
				fi
				(( i += 2 ))
				continue
			elif [[ $c == '`' ]]; then
				q=$qret
				qret=
				out+='`'
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'
			else
				out+=X
			fi
			(( i++ ))
			continue
		fi
		# inside a double-quoted string
		if [[ $q == '"' ]]; then
			if [[ $c == '\' ]]; then
				if [[ ${s:i+1:1} == $'\n' ]]; then
					out+=X$'\n'
				else
					out+=XX
				fi
				(( i += 2 ))
			elif [[ $c == '$' && ${s:i+1:1} == '(' &&
			    ${s:i+2:1} != '(' ]]; then
				out+='$('
				(( ++subdepth ))
				subret[subdepth]='"'
				q=
				(( i += 2 ))
				continue
			elif [[ $c == '`' ]]; then
				q='`'
				qret='"'
				out+='`'
				(( i++ ))
			elif [[ $c == '"' ]]; then
				q=
				out+='"'
				(( i++ ))
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'
				(( i++ ))
			else
				out+=X
				(( i++ ))
			fi
			continue
		fi
		# bare code
		case $c in
		'$')
			if [[ ${s:i+1:2} == '((' ]]; then
				out+='$(('
				(( ++arith ))
				(( i += 3 ))
				continue
			elif [[ ${s:i+1:1} == '(' ]]; then
				out+='$('
				(( ++subdepth ))
				unset 'subret[subdepth]'
				(( i += 2 ))
				continue
			fi
			out+=$c
			;;
		"'"|'"')
			q=$c
			out+=$c
			;;
		'`')
			q=$c
			qret=
			out+=$c
			;;
		'(')
			# `((` opens an arithmetic context.  Canonical bash
			# output writes nested subshells as `( (` with a
			# space, so an unspaced `((` here is always
			# arithmetic - and inside it, `<<` is a left shift,
			# not a heredoc.
			if [[ ${s:i-1:1} == [=@+?!*] ]]; then
				arraydepth=1
				out+='('
				(( i++ ))
				continue
			elif [[ ${s:i+1:1} == '(' ]]; then
				(( ++arith ))
				out+='(('
				(( i += 2 ))
				continue
			fi
			(( subdepth > 0 )) && (( ++subdepth ))
			out+=$c
			;;
		')')
			if (( arith > 0 )) && [[ ${s:i+1:1} == ')' ]]; then
				(( --arith ))
				out+='))'
				(( i += 2 ))
				continue
			fi
			out+=$c
			if (( subdepth > 0 )); then
				old=$subdepth
				(( --subdepth ))
				if [[ -n ${subret[old]+x} ]]; then
					q=${subret[old]}
					unset 'subret[old]'
				fi
			fi
			;;
		'\')
			out+='\'
			if [[ ${s:i+1:1} == $'\n' ]]; then
				out+=$'\n'
			else
				out+=X
			fi
			(( i++ ))
			;;
		'<')
			# inside (( )) a `<<` is a left shift, not a heredoc
			if [[ ${s:i+1:1} == '<' ]] && (( arith == 0 )); then
				if [[ ${s:i+2:1} == '<' ]]; then
					out+='<<<'  # herestring, no heredoc
					(( i += 3 ))
					continue
				fi
				j=$(( i + 2 ))
				d=
				dq=
				tab=
				if [[ ${s:j:1} == '-' ]]; then
					tab=1
					(( j++ ))
				fi
				while [[ ${s:j:1} == [' '$'\t'] ]]; do
					(( j++ ))
				done
				while (( j < n )); do
					x=${s:j:1}
					if [[ $dq == "'" ]]; then
						if [[ $x == "'" ]]; then
							dq=
						else
							d+=$x
						fi
					elif [[ $dq == A ]]; then
						if [[ $x == "'" ]]; then
							dq=
						elif [[ $x == '\' ]]; then
							(( j++ ))
							d+=${s:j:1}
						else
							d+=$x
						fi
					elif [[ $dq == '"' ]]; then
						if [[ $x == '"' ]]; then
							dq=
						elif [[ $x == '\' ]]; then
							(( j++ ))
							d+=${s:j:1}
						else
							d+=$x
						fi
					else
						case $x in
						"'"|'"') dq=$x ;;
						'$')
							next=${s:j+1:1}
							case $next in
							"'")
								dq=A
								(( j++ ))
								;;
							'"')
								dq='"'
								(( j++ ))
								;;
							*)
								d+=$x
								;;
							esac
							;;
						'\')
							(( j++ ))
							d+=${s:j:1}
							;;
						[$' \t\n;&|<>']) break ;;
						*) d+=$x ;;
						esac
					fi
					(( j++ ))
				done
				pend+=("$d")
				pendtab+=("$tab")
				out+='<<'
				(( i += 2 ))
				continue
			fi
			out+=$c
			;;
		$'\n')
			out+=$'\n'
			if (( ${#pend[@]} )); then
				hd=${pend[0]}
				hdtab=${pendtab[0]}
				pend=("${pend[@]:1}")
				pendtab=("${pendtab[@]:1}")
				ln=
			fi
			;;
		*)
			out+=$c
			;;
		esac
		(( i++ ))
	done
	printf '%s' "$out"
}
