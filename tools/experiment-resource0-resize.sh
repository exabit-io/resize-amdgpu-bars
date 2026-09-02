#!/bin/bash
# experiment-resource0-resize.sh - does the kernel's in-place Resizable BAR
# path (sysfs resourceN_resize) work for one AMD GPU die behind a PCIe
# switch?  A guarded, evidence-collecting experiment; read-only unless told
# otherwise.
#
# What it does with --i-understand, in order, on ONE die and nothing else:
#
#   1. snapshot: lspci -vv of the die and its whole bridge chain, the die's
#      resource file, the bridge windows, the ReBAR control register (read
#      only), dmesg
#   2. unbind the drivers from that die's functions only (the GPU and its
#      HDMI audio function); no driver_override, no other device
#   3. echo INDEX > resource0_resize; record the write's return value and
#      error text, the resource file, the bridge windows, the dmesg delta
#   4. echo ORIGINAL_INDEX > resource0_resize; record the same
#   5. re-bind each function to the driver it had, with a bounded timeout,
#      but only if BAR0 is assigned (a BAR-less die must never reach amdgpu:
#      it hangs the driver in an SR-IOV mailbox wait, unkillable)
#   6. snapshot again, print a verdict and the evidence directory
#
# Steps 4 and 5 also run from the EXIT trap, so Ctrl-C or an error after
# step 2 still restores the original size and re-binds.
#
# It never runs modprobe, never writes remove/rescan, never touches setpci
# writes or another die.
#
# Usage:
#   experiment-resource0-resize.sh [OPTIONS] BDF
#     BDF                 the die, e.g. 0000:0b:00.0 (0b:00.0 is accepted)
#     --index N           size index to write; default 15 (32 GiB). On a
#                         die that is already at 15 use --index 8 (256 MiB):
#                         the script then restores 15, which exercises the
#                         grow direction through the bridge chain
#     --allow-hive        proceed although the die is in an XGMI hive with
#                         other bound dies (see RISKS below)
#     --evidence-dir DIR  parent directory for the evidence
#                         (default /var/tmp/resource0-resize-experiment)
#     --bind-timeout SEC  bound on each re-bind write (default 120)
#     --i-understand      actually do it; without it: checks + plan, exit 3
#     -h, --help          this text
#
# Exit status: 0 experiment ran (whatever the kernel answered, the verdict
# says); 1 usage or a precondition failed, nothing was touched; 3 refused
# for lack of --i-understand, nothing was touched; 4 the experiment ran but
# the restore or the re-bind did not complete: read the verdict.
#
# RISKS (why --i-understand and --allow-hive exist)
#   - Unbinding amdgpu from a die kills every DRM/KFD client on it; the
#     script refuses if /dev/dri or /dev/kfd users are found.
#   - Unbinding ONE die of a live XGMI hive while its peers stay bound
#     removes a node from the hive under the driver; the peers keep running
#     with a torn hive until they are re-probed. amdgpu is expected to
#     survive it, but this has not been exercised here: hence --allow-hive.
#     The clean way is a boot with no die bound (see tools/README.md).
#   - The sysfs write clears memory decoding and, on a VGA-class device,
#     evicts any console framebuffer driver on it.
#   - If the kernel cannot restore the original size (it always tries: "old
#     value restored"), the die is BAR-less; the script then refuses to
#     re-bind and tells you so. Recovery is a reboot; the resize-gpu-bars
#     unit handles the next boot.

set -u
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

prog=${0##*/}
pci_devs=/sys/bus/pci/devices
lock_file=/run/lock/resize-gpu-bars.lock
state_dir=/run/resize-gpu-bars
bdf_re='^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$'

index=15
allow_hive=0
i_understand=0
bind_timeout=120
evidence_root=/var/tmp/resource0-resize-experiment
bdf=''

# experiment state, read by the EXIT trap
evid=''
orig_index=-1
unbound=0
wrote=0
restored=0
rebound=0
die_funcs=()
declare -A func_driver
ancestors=()
blocked=()
write_rc=''
write_err=''
restore_rc=''
restore_err=''
rebind_result=''

usage() {
	sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

log() {
	printf '%s: %s\n' "$prog" "$*" >&2
}

warn() {
	printf '%s: WARNING: %s\n' "$prog" "$*" >&2
}

die() {
	printf '%s: error: %s\n' "$prog" "$*" >&2
	exit 1
}

# attr BDF NAME -- print a sysfs attribute, empty when unreadable
attr() {
	local v
	v=$(< "$pci_devs/$1/$2") 2> /dev/null || v=''
	printf '%s' "$v"
}

# driver_of BDF -- driver name bound to the function, empty when none
driver_of() {
	local l
	l=$(readlink "$pci_devs/$1/driver" 2> /dev/null) || return 0
	printf '%s' "${l##*/}"
}

# bar_bytes BDF N -- size of BAR N from the resource file, 0 if unassigned
bar_bytes() {
	local line start end
	line=$(sed -n "$(( $2 + 1 ))p" "$pci_devs/$1/resource" 2> /dev/null)
	[[ -n $line ]] || {
		printf '0'
		return
	}
	start=${line%% *}
	end=${line#* }
	end=${end%% *}
	if [[ $start == 0x0000000000000000 ]]; then
		printf '0'
	else
		printf '%d' $(( 16#${end#0x} - 16#${start#0x} + 1 ))
	fi
}

# bytes_to_index BYTES -- ReBAR size index (2^(i+20) bytes), -1 for 0
bytes_to_index() {
	local b=$1 i=-1
	while (( b > 0 )); do
		b=$(( b >> 1 ))
		(( ++i ))
	done
	if (( i < 20 )); then
		printf '%d' -1
	else
		printf '%d' $(( i - 20 ))
	fi
}

# index_human N -- "32G", "256M"
index_human() {
	numfmt --to=iec $(( 1 << ($1 + 20) ))
}

# bar0_index BDF -- size index of the assigned BAR0, -1 when unassigned
bar0_index() {
	bytes_to_index "$(bar_bytes "$1" 0)"
}

# expected_mem_bars BDF -- the memory BARs the die is known to have: BAR0,
# every BAR with a resourceN_resize attribute, every BAR flagged memory in
# the resource file, and what resize-gpu-bars saw earlier this boot
expected_mem_bars() {
	local g=$1 i line flags set='0'
	for i in 0 1 2 3 4 5; do
		line=$(sed -n "$(( i + 1 ))p" "$pci_devs/$g/resource" \
		    2> /dev/null)
		flags=${line##* }
		[[ -n $flags ]] && (( 16#${flags#0x} & 0x200 )) && set+=" $i"
		[[ -e $pci_devs/$g/resource${i}_resize ]] && set+=" $i"
	done
	[[ -r $state_dir/bars-$g ]] && set+=" $(< "$state_dir/bars-$g")"
	tr ' ' '\n' <<< "$set" | grep -E '^[0-5]$' | sort -un | tr '\n' ' '
}

# unassigned_bars BDF -- expected memory BARs whose start address is zero
unassigned_bars() {
	local g=$1 i out=''
	for i in $(expected_mem_bars "$g"); do
		(( $(bar_bytes "$g" "$i") == 0 )) && out+="$i "
	done
	printf '%s' "${out% }"
}

# all_amd_gpus -- every vendor 0x1002 display-class function
all_amd_gpus() {
	local d
	for d in "$pci_devs"/*; do
		[[ $(attr "${d##*/}" vendor) == 0x1002 ]] || continue
		[[ $(attr "${d##*/}" class) == 0x03* ]] || continue
		printf '%s\n' "${d##*/}"
	done
}

# window_lines BDF -- the bridge's window lines from lspci -vv
window_lines() {
	lspci -vv -s "$1" 2> /dev/null |
	    grep -E 'behind bridge|I/O behind' |
	    sed 's/^[[:space:]]*//'
}

# rebar_ctrl_read BDF -- the BAR0 ReBAR control register, read only
rebar_ctrl_read() {
	local cap
	local re='s/.*Capabilities: \[\([0-9a-f]*\) v[0-9]*\] Physical.*/\1/p'
	cap=$(lspci -vv -s "$1" 2> /dev/null | sed -n "$re" | head -1)
	[[ -n $cap ]] || return 0
	setpci -s "$1" "0x$(printf '%x' $(( 16#$cap + 8 ))).l" 2> /dev/null
}

# kmsg_mark TAG -- drop a marker into the kernel log for dmesg deltas
kmsg_mark() {
	printf '%s: mark %s\n' "$prog" "$1" > /dev/kmsg 2> /dev/null || :
}

# dmesg_since TAG -- kernel log lines after the last marker TAG
dmesg_since() {
	dmesg 2> /dev/null | awk -v t="$prog: mark $1" '
		index($0, t) { buf = ""; next }
		{ buf = buf $0 "\n" }
		END { printf "%s", buf }'
}

# snapshot STAGE -- collect the evidence for one stage into $evid/STAGE/
snapshot() {
	local dir=$evid/$1 f b
	mkdir -p "$dir" || die "cannot create $dir"
	date -u '+%Y-%m-%dT%H:%M:%SZ' > "$dir/date.txt"
	uname -a > "$dir/uname.txt"
	cat /proc/cmdline > "$dir/cmdline.txt"
	{
		for b in "${ancestors[@]}" "${die_funcs[@]}"; do
			lspci -vv -s "$b" 2>&1
			printf '\n'
		done
	} > "$dir/lspci-vv-chain.txt"
	{
		for b in "${ancestors[@]}"; do
			printf '== %s\n' "$b"
			window_lines "$b"
		done
	} > "$dir/bridge-windows.txt"
	{
		for b in "${ancestors[@]}" "${die_funcs[@]}"; do
			printf '== %s\n' "$b"
			cat "$pci_devs/$b/resource" 2>&1
		done
	} > "$dir/resource-files.txt"
	{
		printf 'resource0_resize (supported mask): %s\n' \
		    "$(attr "$bdf" resource0_resize)"
		printf 'BAR0 bytes: %s (index %s)\n' \
		    "$(bar_bytes "$bdf" 0)" "$(bar0_index "$bdf")"
		printf 'ReBAR control register (BAR0 entry): %s\n' \
		    "$(rebar_ctrl_read "$bdf")"
		printf 'unassigned expected memory BARs: [%s]\n' \
		    "$(unassigned_bars "$bdf")"
		for f in "${die_funcs[@]}"; do
			printf 'driver %s: %s\n' "$f" "$(driver_of "$f")"
		done
		printf 'xgmi_hive_id: %s\n' \
		    "$(attr "$bdf" xgmi_hive_info/xgmi_hive_id)"
	} > "$dir/die-state.txt"
	dmesg 2> /dev/null | tail -300 > "$dir/dmesg-tail.txt"
	log "snapshot '$1' written to $dir"
}

# gather facts about the die: functions, drivers, ancestors, current size
gather() {
	local p d f
	[[ -e $pci_devs/$bdf ]] || die "no PCI device $bdf"
	[[ $(attr "$bdf" vendor) == 0x1002 ]] ||
	    die "$bdf is not an AMD device (vendor $(attr "$bdf" vendor))"
	[[ $(attr "$bdf" class) == 0x03* ]] ||
	    die "$bdf is not display-class (class $(attr "$bdf" class))"
	[[ -e $pci_devs/$bdf/resource0_resize ]] ||
	    die "$bdf has no resource0_resize attribute (no ReBAR / old kernel)"
	for d in "$pci_devs/${bdf%.*}".[0-7]; do
		[[ -e $d ]] || continue
		f=${d##*/}
		die_funcs+=("$f")
		func_driver[$f]=$(driver_of "$f")
	done
	p=$(readlink -f "$pci_devs/$bdf")
	for d in ${p//\// }; do
		[[ $d =~ $bdf_re ]] || continue
		[[ $d == "$bdf" ]] && continue
		ancestors+=("$d")
	done
	orig_index=$(bar0_index "$bdf")
}

# blocked_if COND MESSAGE -- record a blocking condition
blocked_if() {
	if (( $1 )); then
		blocked+=("$2")
		printf '  BLOCKED  %s\n' "$2" >&2
	else
		printf '  ok       %s\n' "${3:-$2}" >&2
	fi
}

check_preconditions() {
	local g u h hive hive_msg peers=0 mask users='' f
	log 'preconditions:'
	blocked_if $(( EUID != 0 )) 'must run as root' 'running as root'
	grep -qw 'pci=realloc' /proc/cmdline
	blocked_if $(( $? != 0 )) \
	    'pci=realloc is not on the kernel command line' \
	    'pci=realloc is on the kernel command line'
	if [[ $(systemctl is-active resize-gpu-bars.service 2> /dev/null) == \
	    activating ]]; then
		blocked_if 1 'resize-gpu-bars.service is still running'
	else
		blocked_if 0 'resize-gpu-bars.service is not running'
	fi
	blocked_if $(( orig_index < 0 )) \
	    "$bdf has no assigned BAR0 right now" \
	    "$bdf BAR0 is assigned: $(index_human "$orig_index")"
	mask=$(attr "$bdf" resource0_resize)
	if [[ -n $mask ]] && (( (16#$mask >> index) & 1 )); then
		blocked_if 0 \
		    "index $index ($(index_human "$index")) is supported"
	else
		blocked_if 1 "index $index is not in the supported mask $mask"
	fi
	blocked_if $(( index == orig_index )) \
	    "die is already at index $index; nothing to test (try --index 8)" \
	    "requested index $index differs from the current $orig_index"
	for g in $(all_amd_gpus); do
		u=$(unassigned_bars "$g")
		blocked_if $(( ${#u} > 0 )) \
		    "$g: memory BAR(s) $u unassigned; off limits" \
		    "$g has all expected memory BARs assigned"
	done
	hive=$(attr "$bdf" xgmi_hive_info/xgmi_hive_id)
	if [[ -n $hive ]]; then
		for g in $(all_amd_gpus); do
			[[ $g == "$bdf" ]] && continue
			[[ $(driver_of "$g") == amdgpu ]] || continue
			h=$(attr "$g" xgmi_hive_info/xgmi_hive_id)
			[[ $h == "$hive" ]] || continue
			(( ++peers ))
		done
	fi
	hive_msg="$bdf shares a live XGMI hive with $peers bound die(s)"
	if (( peers > 0 )); then
		blocked_if $(( ! allow_hive )) \
		    "$hive_msg; unbinding one hive node needs --allow-hive" \
		    "$hive_msg: --allow-hive given"
	else
		blocked_if 0 "$bdf is not in a live XGMI hive with bound peers"
	fi
	for f in /dev/dri/by-path/pci-"$bdf"-* /dev/kfd; do
		[[ -e $f ]] || continue
		u=$(fuser "$f" 2> /dev/null) || continue
		users+="$f:$u "
	done
	blocked_if $(( ${#users} > 0 )) \
		"device nodes are in use: $users" \
		'no process holds the die'"'"'s /dev/dri nodes or /dev/kfd'
	blocked_if $(( ! (index >= 0 && index <= 43) )) \
	    "index $index is out of range 0..43" "index $index is in range"
}

print_plan() {
	local f
	printf '\n%s\n' 'PLAN (nothing has been written yet):' >&2
	printf '  die:            %s (%s)\n' "$bdf" \
	    "$(lspci -s "$bdf" 2> /dev/null | cut -d' ' -f2-)" >&2
	printf '  functions:      %s\n' "${die_funcs[*]}" >&2
	for f in "${die_funcs[@]}"; do
		printf '    %s driver: %s\n' "$f" "${func_driver[$f]:-(none)}" \
		    >&2
	done
	printf '  bridge chain:   %s\n' "${ancestors[*]}" >&2
	printf '  BAR0 now:       %s (index %s)\n' \
	    "$(index_human "$orig_index")" "$orig_index" >&2
	printf '  will write:     echo %s > %s/%s/resource0_resize  (%s)\n' \
	    "$index" "$pci_devs" "$bdf" "$(index_human "$index")" >&2
	printf '  then restore:   echo %s > %s/%s/resource0_resize\n' \
	    "$orig_index" "$pci_devs" "$bdf" >&2
	printf '  then re-bind:   each function to the driver listed above,\n' \
	    >&2
	printf '                  timeout %ss each, only if BAR0 assigned\n' \
	    "$bind_timeout" >&2
	printf '  evidence:       %s/\n' "$evid" >&2
	printf '  never:          modprobe, remove, rescan, setpci writes,\n' \
	    >&2
	printf '                  any other device\n\n' >&2
}

# write_index N LABEL -- one sysfs write; stores rc and stderr
write_index() {
	local err rc
	err=$( { printf '%s\n' "$1" > "$pci_devs/$bdf/resource0_resize"; } \
	    2>&1 )
	rc=$?
	printf '%s\n' "rc=$rc err=${err:-(none)}" >> "$evid/writes.log"
	log "write $1 ($2): rc=$rc ${err:+error: $err}"
	printf -v "$3" '%s' "$rc"
	printf -v "$4" '%s' "$err"
	return "$rc"
}

restore_index() {
	(( restored )) && return 0
	restored=1
	kmsg_mark restore
	log "restoring index $orig_index on $bdf"
	write_index "$orig_index" restore restore_rc restore_err
	dmesg_since restore > "$evid/dmesg-delta-restore.txt"
	snapshot 3-after-restore
}

# rebind_all -- bind each function back to the driver it had, bounded
rebind_all() {
	local f drv rc
	(( rebound )) && return 0
	rebound=1
	if (( $(bar_bytes "$bdf" 0) == 0 )); then
		rebind_result='REFUSED: BAR0 unassigned after restore'
		warn "$bdf has NO BAR0 now; NOT re-binding amdgpu (would hang)"
		warn 'Leave the die driverless and reboot; do not modprobe.'
		return 1
	fi
	kmsg_mark rebind
	for f in "${die_funcs[@]}"; do
		drv=${func_driver[$f]}
		[[ -n $drv ]] || continue
		[[ -L $pci_devs/$f/driver ]] && continue
		if [[ ! -d /sys/bus/pci/drivers/$drv ]]; then
			rebind_result+="$f: driver $drv not loaded, skipped; "
			warn "$drv not loaded; $f stays unbound (no modprobe)"
			continue
		fi
		log "binding $f to $drv (timeout ${bind_timeout}s)"
		# shellcheck disable=SC2016
		# ($1/$2 are the child shell's own arguments, on purpose)
		timeout --signal=KILL "$bind_timeout" \
		    bash -c 'printf "%s\n" "$1" > "$2"' _ \
		    "$f" "/sys/bus/pci/drivers/$drv/bind" 2>> "$evid/writes.log"
		rc=$?
		if [[ -L $pci_devs/$f/driver ]]; then
			rebind_result+="$f: bound to $drv (rc=$rc); "
		else
			rebind_result+="$f: NOT bound (rc=$rc); "
			warn "$f is not bound after the bind write (rc=$rc)"
		fi
	done
	dmesg_since rebind > "$evid/dmesg-delta-rebind.txt"
	[[ $rebind_result != *'NOT bound'* ]]
}

cleanup() {
	local rc=$?
	trap - EXIT INT TERM HUP
	(( unbound || wrote )) || exit "$rc"
	if (( wrote && ! restored )); then
		warn 'interrupted after the experimental write; restoring'
		restore_index
	fi
	if (( unbound && ! rebound )); then
		rebind_all
	fi
	verdict
	exit "$rc"
}

unbind_all() {
	local f drv
	kmsg_mark unbind
	unbound=1
	for f in "${die_funcs[@]}"; do
		drv=${func_driver[$f]}
		[[ -n $drv ]] || continue
		log "unbinding $drv from $f"
		if ! printf '%s\n' "$f" > "/sys/bus/pci/drivers/$drv/unbind"
		then
			die "could not unbind $drv from $f; ReBAR untouched"
		fi
	done
	dmesg_since unbind > "$evid/dmesg-delta-unbind.txt"
}

verdict() {
	local after_write after_restore w r
	after_write=$(< "$evid/index-after-write.txt") 2> /dev/null ||
	    after_write='?'
	after_restore=$(bar0_index "$bdf")
	{
		printf '\nVERDICT for %s (kernel %s)\n' "$bdf" "$(uname -r)"
		if [[ $write_rc == 0 ]] && [[ $after_write == "$index" ]]; then
			w="the in-place resize SUCCEEDED: writing $index to"
			w+=" resource0_resize left BAR0 at"
			w+=" $(index_human "$index") with no rescan; the sysfs"
			w+=" path works here."
		elif [[ $write_rc == 0 ]]; then
			w="the write returned 0 but BAR0 reads back as index"
			w+=" $after_write, not $index; inspect the evidence."
		else
			w="the in-place resize FAILED: the write returned"
			w+=" rc=$write_rc (${write_err:-no message}); BAR0"
			w+=" afterwards: index $after_write. Look for \"can't"
			w+=" assign\" and \"old value restored\" in"
			w+=" dmesg-delta-write.txt: that is the same undersized"
			w+=" window outcome as the register+rescan path."
		fi
		if [[ $restore_rc == 0 ]] && (( after_restore == orig_index ))
		then
			r="Restore to index $orig_index: OK."
		else
			r="Restore to index $orig_index: rc=${restore_rc:-?}"
			r+=" (${restore_err:-no message}), BAR0 is now index"
			r+=" $after_restore. ATTENTION."
		fi
		printf '%s %s Re-bind: %s Bridge windows before/after are\n' \
		    "$w" "$r" "${rebind_result:-nothing to re-bind.}"
		printf 'in %s/*/bridge-windows.txt; kernel replies are in\n' \
		    "$evid"
		printf '%s/dmesg-delta-*.txt and writes.log.\n' "$evid"
		printf 'Record the result as described in tools/README.md.\n'
	} | fold -s -w 78 >&2
}

run_experiment() {
	local rc
	exec 9> "$lock_file" || die "cannot open $lock_file"
	flock -n 9 || die "another resize-gpu-bars instance holds $lock_file"
	mkdir -p "$evid" || die "cannot create $evid"
	: > "$evid/writes.log"
	snapshot 0-before
	trap cleanup EXIT INT TERM HUP
	unbind_all
	snapshot 1-unbound
	kmsg_mark write
	wrote=1
	write_index "$index" experiment write_rc write_err
	bar0_index "$bdf" > "$evid/index-after-write.txt"
	dmesg_since write > "$evid/dmesg-delta-write.txt"
	snapshot 2-after-write
	restore_index
	rebind_all
	rc=$?
	snapshot 4-final
	dmesg > "$evid/dmesg-full.txt" 2> /dev/null
	trap - EXIT INT TERM HUP
	verdict
	if [[ $restore_rc != 0 ]] || (( rc != 0 )) ||
	    (( $(bar0_index "$bdf") != orig_index )); then
		return 4
	fi
	return 0
}

main() {
	local arg
	while (( $# )); do
		arg=$1
		shift
		case $arg in
		-h|--help)
			usage
			exit 0
			;;
		--index)
			(( $# )) || die '--index needs a value'
			index=$1
			shift
			;;
		--index=*)
			index=${arg#*=}
			;;
		--allow-hive)
			allow_hive=1
			;;
		--evidence-dir)
			(( $# )) || die '--evidence-dir needs a value'
			evidence_root=$1
			shift
			;;
		--evidence-dir=*)
			evidence_root=${arg#*=}
			;;
		--bind-timeout)
			(( $# )) || die '--bind-timeout needs a value'
			bind_timeout=$1
			shift
			;;
		--bind-timeout=*)
			bind_timeout=${arg#*=}
			;;
		--i-understand)
			i_understand=1
			;;
		-*)
			die "unknown option $arg (see --help)"
			;;
		*)
			[[ -z $bdf ]] || die 'exactly one BDF, please'
			bdf=$arg
			;;
		esac
	done
	[[ -n $bdf ]] || die 'a die BDF is required (see --help)'
	[[ $bdf =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && bdf=0000:$bdf
	[[ $bdf =~ $bdf_re ]] || die "malformed BDF '$bdf'"
	[[ $index =~ ^[0-9]+$ ]] || die "--index must be a number, not '$index'"
	[[ $bind_timeout =~ ^[0-9]+$ ]] ||
	    die "--bind-timeout must be a number, not '$bind_timeout'"

	gather
	evid=$evidence_root/$(date -u '+%Y%m%d-%H%M%S')-$bdf
	print_plan
	check_preconditions
	if (( ${#blocked[@]} )); then
		printf '\n' >&2
		die "${#blocked[@]} blocking condition(s); nothing was touched"
	fi
	if (( ! i_understand )); then
		printf '\n' >&2
		log 'all checks passed; re-run with --i-understand to do it.'
		log 'Nothing was touched.'
		exit 3
	fi
	run_experiment
}

main "$@"
