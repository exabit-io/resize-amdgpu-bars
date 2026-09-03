#!/bin/bash
# test_resize_amdgpu_bars.sh - offline tests for resize-amdgpu-bars.
#
# Builds a fake sysfs tree (two Vega II Duo cards on separate root ports, a
# W5500X-like single GPU without a PLX chain, a 580X-like GPU without ReBAR,
# a GPU directly on a root bus, a radeon-only card, a Thunderbolt controller
# and a Mellanox NIC with SR-IOV VFs), stubs lspci / setpci and the amdgpu
# alias table, and replaces the kernel's re-enumeration with a rule so the
# plan negotiation can be exercised for kernels that behave like 6.x, like
# an unpatched 7.0, and like a size-limited window. Nothing real is touched.
#
#   ./test_resize_amdgpu_bars.sh path/to/resize-amdgpu-bars
#
# shellcheck disable=SC2154,SC2034  # the script's globals and knobs are
#                                   # defined by the sourced script and set
#                                   # here to steer it; shellcheck sees only
#                                   # one side of that
# shellcheck disable=SC2317  # logger overrides defined inside subshells
#                            # look unreachable to it
set -uo pipefail
SCRIPT=${1:?usage: $0 path/to/resize-amdgpu-bars}
if [[ ! -r $SCRIPT ]]; then
	echo "$0: cannot read $SCRIPT" >&2
	exit 2
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/rgb-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
export RESIZE_AMDGPU_BARS_SYSFS=$T/sys
export RESIZE_AMDGPU_BARS_STATE_DIR=$T/run
export RESIZE_AMDGPU_BARS_CONFIG=/dev/null
export RESIZE_AMDGPU_BARS_ALIAS_FILE=$T/modules.alias
SYSFS=$RESIZE_AMDGPU_BARS_SYSFS
# The alias table amdgpu would export: Vega20 (66A3) and Polaris (67DF); the
# Caicos line belongs to radeon and must be ignored.
cat > "$RESIZE_AMDGPU_BARS_ALIAS_FILE" <<'EOF_ALIAS'
alias pci:v00001002d000066A3sv*sd*bc*sc*i* amdgpu
alias pci:v00001002d000067DFsv*sd*bc*sc*i* amdgpu
alias pci:v00001002d00006779sv*sd*bc*sc*i* radeon
alias usb:v1D6Bp0002d*dc*dsc*dp*ic*isc*ip*in* usbcore
EOF_ALIAS
PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "  ok   $*"
}
fail() {
	FAIL=$((FAIL + 1))
	echo "  FAIL $*"
}
# assert_eq LABEL GOT WANT
assert_eq() {
	if [[ $2 == "$3" ]]; then
		ok "$1"
	else
		fail "$1: expected '$3', got '$2'"
	fi
}
# yesno COMMAND... -- prints yes when COMMAND succeeds, no otherwise
yesno() {
	if "$@"; then
		echo yes
	else
		echo no
	fi
}
# count PATTERN FILE -- grep -c, for the assertions on captured output
count() {
	grep -c -- "$1" "$2"
}
# count_in PATTERN STRING -- grep -c over a string
count_in() {
	grep -c -- "$1" <<<"$2"
}

# ---------------------------------------------------------------------------
# Fake tree builders
# ---------------------------------------------------------------------------
REG=$T/regs
mkdir -p "$REG" "$SYSFS/bus/pci/devices" "$SYSFS/bus/pci/drivers/amdgpu"
declare -A DEVPATH
# reg BDF NAME -- the fake register file's content
reg() {
	cat "$REG/$1.$2"
}
# override_of BDF -- the device's driver_override
override_of() {
	cat "${DEVPATH[$1]}/driver_override"
}
# mkdev BDF PARENT-PATH VENDOR CLASS [gpu|gpu-norebar|gpu-radeon]
mkdev() {
	local bdf=$1 parent=$2 vendor=$3 class=$4 kind=${5:-}
	local path=$parent/$bdf dev=0000 vend=${vendor#0x}
	mkdir -p "$path"
	echo "$vendor" > "$path/vendor"
	echo "$class" > "$path/class"
	: > "$path/driver_override"
	case $kind in
	gpu)
		dev=66A3
		;;
	gpu-norebar)
		dev=67DF
		;;
	gpu-radeon)
		dev=6779
		;;
	esac
	printf 'pci:v0000%sd0000%ssv0000106Bsd00000203bc%ssc%si00\n' \
	    "${vend^^}" "$dev" "${class:2:2}" "${class:4:2}" > "$path/modalias"
	DEVPATH[$bdf]=$path
	ln -sfn "$path" "$SYSFS/bus/pci/devices/$bdf"
	if [[ $kind == gpu ]]; then
		echo 000000000000ff00 > "$path/resource0_resize"
		echo 0000000000000004 > "$path/resource2_resize"
		# Index 8 (256 MB), BAR0 entry.
		printf '0x0000000000000800\n' > "$REG/$bdf.0x208.l"
		printf '0x0407\n' > "$REG/$bdf.COMMAND"
		set_bars "$bdf" 8 assigned
	elif [[ $kind == gpu-norebar || $kind == gpu-radeon ]]; then
		printf '0x0407\n' > "$REG/$bdf.COMMAND"
		set_bars "$bdf" 8 assigned
	fi
}
# set_bars BDF INDEX assigned|unassigned -- the resource file: BAR0 sized by
# INDEX, BAR2 2M, BAR5 512K
set_bars() {
	local bdf=$1 idx=$2 st=$3 f base
	f=${DEVPATH[$bdf]}/resource
	base=$(( 0x90000000000 + 16#${bdf:5:2} * 0x1000000000 ))
	if [[ $st == assigned ]]; then
		printf '0x%016x 0x%016x 0x000000000014220c\n' "$base" \
		    $(( base + (1 << (idx + 20)) - 1 )) > "$f"
		printf '0x%016x 0x%016x 0x0000000000000000\n' 0 0 >> "$f"
		printf '0x%016x 0x%016x 0x000000000014220c\n' \
		    $(( base + 0x800000000 )) $(( base + 0x8001fffff )) >> "$f"
	else
		printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 > "$f"
		printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 >> "$f"
		printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 >> "$f"
	fi
	{
		printf '0x%016x 0x%016x 0x%016x\n' 0 0 0
		printf '%s\n' \
		    '0x0000000000005000 0x00000000000050ff 0x0000000000040101' \
		    '0x0000000074400000 0x000000007447ffff 0x0000000000040200' \
		    '0x0000000074480000 0x000000007449ffff 0x0000000000046200'
	} >> "$f"
}
root_bus() {
	mkdir -p "$SYSFS/devices/pci$1/pci_bus/$1"
	: > "$SYSFS/devices/pci$1/pci_bus/$1/rescan"
	echo "$SYSFS/devices/pci$1"
}
BR=0x060400
GPU=0x030000
AUD=0x040300
NET=0x020000

build_tree() {
	local r
	# Card 1: Vega II Duo behind root port 06:00.0 (PLX + AMD bridge
	# chains)
	r=$(root_bus 0000:06)
	mkdev 0000:06:00.0 "$r" 0x8086 $BR
	mkdev 0000:07:00.0 "${DEVPATH[0000:06:00.0]}" 0x10b5 $BR
	mkdev 0000:08:08.0 "${DEVPATH[0000:07:00.0]}" 0x10b5 $BR
	mkdev 0000:09:00.0 "${DEVPATH[0000:08:08.0]}" 0x1002 $BR
	mkdev 0000:0a:00.0 "${DEVPATH[0000:09:00.0]}" 0x1002 $BR
	mkdev 0000:0b:00.0 "${DEVPATH[0000:0a:00.0]}" 0x1002 $GPU gpu
	mkdev 0000:0b:00.1 "${DEVPATH[0000:0a:00.0]}" 0x1002 $AUD
	mkdev 0000:08:10.0 "${DEVPATH[0000:07:00.0]}" 0x10b5 $BR
	mkdev 0000:0c:00.0 "${DEVPATH[0000:08:10.0]}" 0x1002 $BR
	mkdev 0000:0d:00.0 "${DEVPATH[0000:0c:00.0]}" 0x1002 $BR
	mkdev 0000:0e:00.0 "${DEVPATH[0000:0d:00.0]}" 0x1002 $GPU gpu
	mkdev 0000:0e:00.1 "${DEVPATH[0000:0d:00.0]}" 0x1002 $AUD
	# Card 2: same shape on root port 16:00.0
	r=$(root_bus 0000:16)
	mkdev 0000:16:00.0 "$r" 0x8086 $BR
	mkdev 0000:17:00.0 "${DEVPATH[0000:16:00.0]}" 0x10b5 $BR
	mkdev 0000:18:08.0 "${DEVPATH[0000:17:00.0]}" 0x10b5 $BR
	mkdev 0000:19:00.0 "${DEVPATH[0000:18:08.0]}" 0x1002 $BR
	mkdev 0000:1a:00.0 "${DEVPATH[0000:19:00.0]}" 0x1002 $BR
	mkdev 0000:1b:00.0 "${DEVPATH[0000:1a:00.0]}" 0x1002 $GPU gpu
	mkdev 0000:1b:00.1 "${DEVPATH[0000:1a:00.0]}" 0x1002 $AUD
	mkdev 0000:18:10.0 "${DEVPATH[0000:17:00.0]}" 0x10b5 $BR
	mkdev 0000:1c:00.0 "${DEVPATH[0000:18:10.0]}" 0x1002 $BR
	mkdev 0000:1d:00.0 "${DEVPATH[0000:1c:00.0]}" 0x1002 $BR
	mkdev 0000:1e:00.0 "${DEVPATH[0000:1d:00.0]}" 0x1002 $GPU gpu
	mkdev 0000:1e:00.1 "${DEVPATH[0000:1d:00.0]}" 0x1002 $AUD
	# A single-GPU MPX card straight behind a root port (W5500X-like,
	# 8 GB max)
	r=$(root_bus 0000:2a)
	mkdev 0000:2a:00.0 "$r" 0x8086 $BR
	mkdev 0000:2b:00.0 "${DEVPATH[0000:2a:00.0]}" 0x1002 $GPU gpu
	# 256M..8G
	echo 0000000000003f00 > "${DEVPATH[0000:2b:00.0]}/resource0_resize"
	mkdev 0000:2b:00.1 "${DEVPATH[0000:2a:00.0]}" 0x1002 $AUD
	# A GPU with no ReBAR at all (580X-like)
	r=$(root_bus 0000:3a)
	mkdev 0000:3a:00.0 "$r" 0x8086 $BR
	mkdev 0000:3b:00.0 "${DEVPATH[0000:3a:00.0]}" 0x1002 $GPU gpu-norebar
	# A GPU directly on a root bus (no root port above it to remove)
	r=$(root_bus 0000:60)
	mkdev 0000:60:00.0 "$r" 0x1002 $GPU gpu
	mkdev 0000:60:00.1 "$r" 0x1002 $AUD
	# A radeon-driver card (Caicos-like): AMD, class 03, not amdgpu's
	r=$(root_bus 0000:70)
	mkdev 0000:70:00.0 "$r" 0x8086 $BR
	mkdev 0000:71:00.0 "${DEVPATH[0000:70:00.0]}" 0x1002 $GPU gpu-radeon
	# Thunderbolt NHI and a Mellanox NIC with two VFs: must never be
	# touched
	r=$(root_bus 0000:24)
	mkdev 0000:24:00.0 "$r" 0x8086 $BR
	mkdev 0000:25:00.0 "${DEVPATH[0000:24:00.0]}" 0x8086 0x088000
	r=$(root_bus 0000:40)
	mkdev 0000:40:00.0 "$r" 0x8086 $BR
	mkdev 0000:41:00.0 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
	mkdev 0000:41:00.1 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
	mkdev 0000:41:00.2 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
	mkdev 0000:41:00.3 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
	# A GPU that shares its root port with a non-GPU device (impure
	# subtree)
	r=$(root_bus 0000:50)
	mkdev 0000:50:00.0 "$r" 0x8086 $BR
	mkdev 0000:51:00.0 "${DEVPATH[0000:50:00.0]}" 0x10b5 $BR
	mkdev 0000:52:00.0 "${DEVPATH[0000:51:00.0]}" 0x10b5 $BR
	mkdev 0000:53:00.0 "${DEVPATH[0000:52:00.0]}" 0x1002 $GPU gpu
	mkdev 0000:52:01.0 "${DEVPATH[0000:51:00.0]}" 0x10b5 $BR
	# NVMe on the same switch
	mkdev 0000:54:00.0 "${DEVPATH[0000:52:01.0]}" 0x144d 0x010802
}

# ---------------------------------------------------------------------------
# Stubs for lspci / setpci
# ---------------------------------------------------------------------------
lspci() {
	local bdf='' mm=0 vv=0 a
	while (( $# )); do
		a=$1
		shift
		case $a in
		-s)
			bdf=$1
			shift
			;;
		-mm)
			mm=1
			;;
		-vv)
			vv=1
			;;
		esac
	done
	[[ -n ${DEVPATH[$bdf]:-} ]] || return 0
	if (( mm )); then
		echo "$bdf \"Class\" \"Vendor\" \"Fake device $bdf\" -r00" \
		    '"Sub" "Sub"'
		return
	fi
	(( vv )) || return 0
	if [[ -e ${DEVPATH[$bdf]}/resource0_resize ]]; then
		printf '\tCapabilities: [200 v1] Physical Resizable BAR\n'
	fi
	if [[ $(<"${DEVPATH[$bdf]}/class") == 0x0604* ]]; then
		printf '\tPrefetchable memory behind bridge: '
		printf '90000000000-91fffffffff [size=128G] [32-bit]\n'
	fi
}
# Fault injection: SETPCI_FAIL_WRITES lists BDFs whose ReBAR control write
# fails; SETPCI_FAIL_AFTER=N makes every control write after the first N
# fail (-1: off). Each control write snapshots COMMAND into
# <bdf>.cmd_at_write.
SETPCI_FAIL_WRITES=''
SETPCI_FAIL_AFTER=-1
SETPCI_CTRL_WRITES=0
setpci() {
	local bdf='' arg
	while (( $# )); do
		arg=$1
		shift
		case $arg in
		-s)
			bdf=$1
			shift
			;;
		COMMAND=*)
			echo "0x${arg#*=}" > "$REG/$bdf.COMMAND"
			;;
		*=*)
			[[ " $SETPCI_FAIL_WRITES " == *" $bdf "* ]] && return 1
			if (( SETPCI_FAIL_AFTER >= 0 &&
			    SETPCI_CTRL_WRITES >= SETPCI_FAIL_AFTER )); then
				return 1
			fi
			SETPCI_CTRL_WRITES=$((SETPCI_CTRL_WRITES + 1))
			cp "$REG/$bdf.COMMAND" "$REG/$bdf.cmd_at_write"
			echo "0x${arg#*=}" > "$REG/$bdf.${arg%%=*}"
			;;
		*)
			[[ -r $REG/$bdf.$arg ]] || return 1
			sed 's/^0x//' "$REG/$bdf.$arg"
			;;
		esac
	done
}
# modprobe / timeout: loading the driver binds every present GPU that is
# not fenced off with driver_override=none, exactly what the kernel would do.
MODPROBE_CALLS=0
MODPROBE_RC=0
timeout() {
	shift 3
	"$@"
}
modprobe() {
	local g
	MODPROBE_CALLS=$((MODPROBE_CALLS + 1))
	(( MODPROBE_RC )) && return "$MODPROBE_RC"
	mkdir -p "$SYSFS/module/amdgpu"
	for g in "${gpus[@]}"; do
		[[ -e ${DEVPATH[$g]} ]] || continue
		[[ $(override_of "$g") != none ]] || continue
		ln -sfn "$SYSFS/bus/pci/drivers/amdgpu" "${DEVPATH[$g]}/driver"
	done
}
unload_driver() {
	local g
	rm -rf "$SYSFS/module/amdgpu"
	for g in "${gpus[@]}"; do
		rm -f "${DEVPATH[$g]}/driver"
	done
}
export -f lspci setpci timeout modprobe 2>/dev/null

# ---------------------------------------------------------------------------
build_tree
# shellcheck disable=SC1090
source "$SCRIPT"
set +e
# The kernel. The script's own reenumerate runs; the two sysfs steps it takes
# per group are replaced: remove_group always succeeds (the fake devices stay
# in place), rescan_group applies a RULE to decide which GPUs of that group
# get their BARs, or fails for the groups listed in RESCAN_FAIL_GROUPS.
#   6x        every GPU fits at any size
#   70vanilla in every group with 2+ GPUs the second GPU never fits
#   budget    a group fits only if the sum of its BAR0 sizes is <= 40 GB
RULE=6x
REENUM_CALLS=0
RESCAN_FAIL_GROUPS=''
# copy_function FROM TO -- defines TO with FROM's body
copy_function() {
	# shellcheck disable=SC1090  # the body comes from declare -f
	source <(declare -f "$1" | sed "1s/^$1 /$2 /")
}
copy_function reenumerate orig_reenumerate
copy_function rescan_group orig_rescan_group
copy_function sysfs_write orig_sysfs_write
reenumerate() {
	REENUM_CALLS=$((REENUM_CALLS + 1))
	orig_reenumerate
}
remove_group() {
	mark_group_reenumerated "$1"
	return 0
}
rescan_group() {
	local r=$1 g i sum=0 n=0 st
	local -n members=${group_members[$r]}
	[[ " $RESCAN_FAIL_GROUPS " == *" $r "* ]] && return 1
	for g in "${members[@]}"; do
		i=$(read_size_index "$g")
		(( i < 0 )) && i=8
		sum=$(( sum + (1 << (i + 20)) ))
	done
	for g in "${members[@]}"; do
		i=$(read_size_index "$g")
		(( i < 0 )) && i=8
		n=$((n + 1))
		st=assigned
		case $RULE in
		70vanilla)
			(( n >= 2 )) && st=unassigned
			;;
		budget)
			(( sum > 40 * 1073741824 && n >= 2 )) && st=unassigned
			;;
		esac
		set_bars "$g" "$i" "$st"
	done
	return 0
}
# sysfs writes: an unbind drops the device's driver link; a resource0_resize
# write is the kernel's in-place resize (reprograms the register and
# re-assigns BAR0, or fails leaving everything as it was when INPLACE_FAIL
# is set); everything else is a real write into the fake tree.
INPLACE_FAIL=0
INPLACE_WRITES=0
sysfs_write() {
	local bdf
	case $1 in
	*/unbind)
		rm -f "${DEVPATH[$2]}/driver"
		return 0
		;;
	*/drivers/amdgpu/bind)
		ln -sfn "$SYSFS/bus/pci/drivers/amdgpu" "${DEVPATH[$2]}/driver"
		return 0
		;;
	*/resource0_resize)
		INPLACE_WRITES=$((INPLACE_WRITES + 1))
		(( INPLACE_FAIL )) && return 1
		bdf=${1%/*}
		bdf=${bdf##*/}
		printf '0x%016x\n' $(( $2 << 8 )) > "$REG/$bdf.0x208.l"
		set_bars "$bdf" "$2" assigned
		return 0
		;;
	esac
	orig_sysfs_write "$@"
}
# bind_all -- every GPU function gets a driver link (amdgpu / snd_hda_intel)
bind_all() {
	local g f drv
	mkdir -p "$SYSFS/bus/pci/drivers/snd_hda_intel"
	for g in "${gpus[@]}"; do
		for f in ${gpu_funcs[$g]}; do
			drv=snd_hda_intel
			[[ $f == "$g" ]] && drv=amdgpu
			ln -sfn "$SYSFS/bus/pci/drivers/$drv" \
			    "${DEVPATH[$f]}/driver"
		done
	done
}
# bound BDF -- the driver the fake device is bound to, or none
bound() {
	local d
	if [[ -L ${DEVPATH[$1]}/driver ]]; then
		d=$(readlink "${DEVPATH[$1]}/driver")
		echo "${d##*/}"
	else
		echo none
	fi
}
# bound_state BDF -- bound or unbound
bound_state() {
	if [[ -L ${DEVPATH[$1]}/driver ]]; then
		echo bound
	else
		echo unbound
	fi
}
# members_of ROOT -- a group's GPUs, space-joined
members_of() {
	local -n m=${group_members[$1]}
	echo "${m[*]}"
}
# chain_of ROOT -- a group's bridge chain, space-joined
chain_of() {
	local -n c=${group_chain[$1]}
	echo "${c[*]}"
}

mkdir -p "$STATE_DIR"
echo 'sourced state'
# Every map must be usable before anything assigned to it: under set -u a
# "declare -A X" without "=()" is an unbound variable (the EXIT trap of a
# bare "diagnose" run died on exactly that).
got=$( (
	printf '%s' "${#gpu_dirty[@]}" "${#gpu_dirty_from[@]}" \
	    "${#gpu_decode_off[@]}" "${#override_set[@]}" \
	    "${#override_keep[@]}" "${#plan[@]}" "${#gpu_root[@]}"
	printf ' %s %s\n' "${!gpu_dirty[*]}" "${!override_set[*]}"
) 2>&1 )
assert_eq 'maps usable while empty under set -u' "$got" '0000000  '
got=$( ( touched=0; cleanup; echo "rc=$?" ) 2>&1 )
assert_eq 'cleanup runs on a pristine state' "$got" 'rc=0'
# reset_regs: every register back at index 8 with the BARs assigned there and
# nothing dirty, the state a fresh boot on this firmware starts from.
reset_regs() {
	local g
	for g in "${gpus[@]}"; do
		[[ -n ${gpu_rebar_ctrl[$g]} ]] || continue
		write_size_index "$g" 8 >/dev/null
	done
	for g in "${gpus[@]}"; do
		set_bars "$g" 8 assigned
	done
	gpu_dirty=()
	gpu_dirty_from=()
}
# No real waiting in the fake kernel.
REMOVE_SETTLE=0
BIND_SETTLE=0
RESCAN_POLL=0
PROBE_POLL=0
# Quiet.
log_info() {
	:
}
log_ok() {
	:
}
log_warn() {
	:
}
log_err() {
	:
}

echo 'discovery'
out=$( log_info() { echo "$*"; }; discover_gpus 2>&1 )
discover_gpus
assert_eq 'gpu count' "${#gpus[@]}" 8
assert_eq 'radeon card refused' \
	"$(count_in '0000:71:00.0 .*not an amdgpu device, skipped' "$out")" 1
assert_eq 'radeon card never in gpus' \
	"$(printf '%s\n' "${gpus[@]}" | grep -c 0000:71:00.0)" 0
assert_eq 'radeon card is not ours' "$(yesno is_gpu_function 0000:71:00.0)" no
assert_eq 'alias table loaded' "${#driver_aliases[@]}" 2
VEGA_ALIAS='pci:v00001002d000066A3sv*sd*bc*sc*i*'
CLASS_ALIAS='pci:v00001002d*sv*sd*bc03sc00i00*'
VEGA_MODALIAS=pci:v00001002d000066A3sv0000106Bsd00000203bc03sc00i00
assert_eq 'match: Vega II' \
	"$(yesno match_modalias "$VEGA_ALIAS" "$VEGA_MODALIAS")" yes
assert_eq 'match: class catch-all' \
	"$(yesno match_modalias "$CLASS_ALIAS" "$VEGA_MODALIAS")" yes
assert_eq 'no match: other device id' \
	"$(yesno match_modalias "$VEGA_ALIAS" \
	pci:v00001002d00006779sv0000106Bsd00000203bc03sc00i00)" no
assert_eq 'no match: other class' \
	"$(yesno match_modalias "$CLASS_ALIAS" \
	pci:v00001002d000066A3sv0000106Bsd00000203bc04sc03i00)" no
out=$(
	ALIAS_FILE=/dev/null
	log_warn() { echo "$*"; }
	discover_gpus 2>&1
	echo "gpus=${#gpus[@]}"
)
got=$(count_in 'No PCI alias table' "$out")
got+=":$(grep -o 'gpus=[0-9]*' <<<"$out")"
assert_eq 'no alias table: warns and accepts every AMD display device' \
	"$got" '1:gpus=9'
assert_eq 'group count' "${#group_roots[@]}" 6
got="${gpu_root[0000:60:00.0]}|$(members_of none:0000:60:00.0)"
got+="|${group_rescan[none:0000:60:00.0]}"
assert_eq 'root-bus GPU has no removable root' "$got" '|0000:60:00.0|'
assert_eq 'root of 0e:00.0' "${gpu_root[0000:0e:00.0]}" 0000:06:00.0
assert_eq 'root of 1b:00.0' "${gpu_root[0000:1b:00.0]}" 0000:16:00.0
assert_eq 'root of single card' "${gpu_root[0000:2b:00.0]}" 0000:2a:00.0
assert_eq 'root of impure card stops below the NVMe' \
	"${gpu_root[0000:53:00.0]}" 0000:52:00.0
assert_eq 'impure flag' "${gpu_root_impure[0000:53:00.0]}" 1
assert_eq 'group 06 members' "$(members_of 0000:06:00.0)" \
	'0000:0b:00.0 0000:0e:00.0'
want='0000:06:00.0 0000:07:00.0 0000:08:08.0 0000:08:10.0'
want+=' 0000:09:00.0 0000:0a:00.0 0000:0c:00.0 0000:0d:00.0'
assert_eq 'group 06 chain: every bridge between the root and its dies, sorted' \
	"$(chain_of 0000:06:00.0)" "$want"
assert_eq 'root-bus group has an empty chain' \
	"$(chain_of none:0000:60:00.0)" ''
assert_eq 'rescan target for a root port' "${group_rescan[0000:06:00.0]}" \
	"$SYSFS/devices/pci0000:06/pci_bus/0000:06/rescan"
assert_eq 'rescan target below a switch' "${group_rescan[0000:52:00.0]}" \
	"$SYSFS/bus/pci/devices/0000:51:00.0/rescan"
assert_eq 'functions incl. audio' "${gpu_funcs[0000:0b:00.0]}" \
	'0000:0b:00.0 0000:0b:00.1'
assert_eq 'rebar ctrl offset' "${gpu_rebar_ctrl[0000:0b:00.0]}" 208
assert_eq 'max index Vega' "${gpu_max_index[0000:0b:00.0]}" 15
assert_eq 'max index W5500X-like' "${gpu_max_index[0000:2b:00.0]}" 13
assert_eq 'baseline index' "${gpu_base_index[0000:0b:00.0]}" 8
assert_eq 'no-rebar GPU has no ctrl' "${gpu_rebar_ctrl[0000:3b:00.0]}" ''
assert_eq 'resizable count' "$(resizable_gpus | wc -l)" 7
assert_eq 'mellanox is not ours' "$(yesno is_gpu_function 0000:41:00.2)" no
assert_eq 'audio is ours' "$(yesno is_gpu_function 0000:0e:00.1)" yes
assert_eq 'expected mem BARs' "$(gpu_mem_bars 0000:0b:00.0)" '0 2 5'
assert_eq 'nothing unassigned at start' "$(failed_gpus | wc -l)" 0

echo 'baseline: observed at first discovery, kept for the boot'
assert_eq 'baseline recorded in STATE_DIR' \
	"$(<"$STATE_DIR/baseline-0000:0b:00.0")" 8
# A previous run left index 15.
printf '0x0000000000000f00\n' > "$REG/0000:0b:00.0.0x208.l"
discover_gpus
assert_eq 'later run: current index 15' "${gpu_cur_index[0000:0b:00.0]}" 15
assert_eq 'later run: baseline still 8' "${gpu_base_index[0000:0b:00.0]}" 8
# A fresh boot whose firmware already enabled ReBAR.
rm -f "$STATE_DIR"/baseline-*
discover_gpus
assert_eq 'firmware at 15: baseline 15, not the lowest supported 8' \
	"${gpu_base_index[0000:0b:00.0]}" 15
RULE=70vanilla
achieved_plan=none
negotiate 2>/dev/null
assert_eq 'fallback never wrote 8 on the firmware-15 die' \
	"$(read_size_index 0000:0b:00.0)" 15
assert_eq 'fallback plan keeps it at 15' "${plan[0000:0b:00.0]}" 15
assert_eq 'its sibling still falls back to its own baseline' \
	"${plan[0000:0e:00.0]}" 8
rm -f "$STATE_DIR"/baseline-*
RULE=6x
reset_regs
discover_gpus
assert_eq 'restored: baseline 8' "${gpu_base_index[0000:0b:00.0]}" 8

echo 'units'
assert_eq 'index 15 is 32GiB' "$(size_index_to_human 15)" 32GiB
assert_eq 'index 8 is 256MiB' "$(size_index_to_human 8)" 256MiB
assert_eq 'human_bytes agrees with size_index_to_human' \
	"$(human_bytes $(( 32 << 30 )))" "$(size_index_to_human 15)"
assert_eq 'human_bytes 0 is unassigned' "$(human_bytes 0)" unassigned

echo 'size register write'
if write_size_index 0000:0b:00.0 15; then
	ok 'write index 15'
else
	fail 'write index 15'
fi
assert_eq 'readback' "$(read_size_index 0000:0b:00.0)" 15
assert_eq 'memory decode disabled during write' \
	"$(reg 0000:0b:00.0 cmd_at_write)" 0x0405
assert_eq 'memory decode re-enabled after the write' \
	"$(reg 0000:0b:00.0 COMMAND)" 0x0407
assert_eq 'written GPU is dirty until re-enumerated' \
	"${gpu_dirty[0000:0b:00.0]:-}:${gpu_dirty_from[0000:0b:00.0]:-}" '1:8'
write_size_index 0000:0b:00.0 8 >/dev/null
assert_eq 'writing the old index back makes it clean again' \
	"${gpu_dirty[0000:0b:00.0]:-}" ''
printf '0x0405\n' > "$REG/0000:0b:00.0.COMMAND"
write_size_index 0000:0b:00.0 15 >/dev/null
write_size_index 0000:0b:00.0 8 >/dev/null
assert_eq 'decode left off when it was off before' \
	"$(reg 0000:0b:00.0 COMMAND)" 0x0405
printf '0x0407\n' > "$REG/0000:0b:00.0.COMMAND"

echo 'apply_plan partial failure: rollback, decode, no driver load'
gpu_dirty=()
gpu_dirty_from=()
REENUM_CALLS=0
MODPROBE_CALLS=0
plan_all_max
SETPCI_FAIL_WRITES=0000:0e:00.0
try_plan all-max 2>/dev/null
rc=$?
assert_eq 'plan fails' "$rc" 1
assert_eq 'first die rolled back to 8' "$(read_size_index 0000:0b:00.0)" 8
assert_eq 'failed die untouched' "$(read_size_index 0000:0e:00.0)" 8
assert_eq 'nothing dirty after rollback' "${#gpu_dirty[@]}" 0
assert_eq 'decode restored on the rolled-back die' \
	"$(reg 0000:0b:00.0 COMMAND)" 0x0407
assert_eq 'decode restored on the failed die' \
	"$(reg 0000:0e:00.0 COMMAND)" 0x0407
assert_eq 'no re-enumeration attempted' "$REENUM_CALLS" 0
guard_and_load_driver 2>/dev/null
rc=$?
assert_eq 'clean after rollback: driver loads' "$rc:$MODPROBE_CALLS" '0:1'
unload_driver
MODPROBE_CALLS=0
# One more write succeeds, then all fail.
SETPCI_FAIL_WRITES=''
SETPCI_FAIL_AFTER=$((SETPCI_CTRL_WRITES + 1))
try_plan all-max 2>/dev/null
rc=$?
assert_eq 'plan fails and rollback fails' "$rc" 1
assert_eq 'first die left at 15' "$(read_size_index 0000:0b:00.0)" 15
assert_eq 'first die dirty' "${gpu_dirty[0000:0b:00.0]:-}" 1
assert_eq 'decode still restored on the dirty die' \
	"$(reg 0000:0b:00.0 COMMAND)" 0x0407
out=$( log_err() { echo "$*"; }; guard_and_load_driver 2>&1 )
rc=$?
assert_eq 'guard refuses to load while a GPU is dirty' \
	"$rc:$MODPROBE_CALLS" '1:0'
assert_eq 'guard says why' \
	"$(count_in 'not re-enumerated on: 0000:0b:00.0' "$out")" 1
SETPCI_FAIL_AFTER=-1
if rollback_dirty 2>/dev/null; then
	ok 'rollback succeeds once setpci works'
else
	fail 'rollback'
fi
assert_eq 'register restored' \
	"$(read_size_index 0000:0b:00.0):${#gpu_dirty[@]}" '8:0'

echo 'negotiation: 6.x-like kernel'
RULE=6x
REENUM_CALLS=0
achieved_plan=none
negotiate 2>/dev/null
rc=$?
assert_eq 'rc' "$rc" 0
assert_eq 'plan' "$achieved_plan" all-max
assert_eq 'one re-enumeration' "$REENUM_CALLS" 1
assert_eq 'Vega at 32G' "$(bar0_bytes 0000:0b:00.0)" $(( 32 << 30 ))
assert_eq 'W5500X at 8G' "$(bar0_bytes 0000:2b:00.0)" $(( 8 << 30 ))
assert_eq 'no failures' "$(failed_gpus | wc -l)" 0

echo 'negotiation: fast path when already satisfied'
REENUM_CALLS=0
negotiate 2>/dev/null
assert_eq 'no re-enumeration needed' "$REENUM_CALLS" 0
assert_eq 'plan' "$achieved_plan" all-max

echo 'negotiation: unpatched-7.0-like kernel'
reset_regs
RULE=70vanilla
REENUM_CALLS=0
achieved_plan=none
negotiate 2>/dev/null
rc=$?
assert_eq 'rc' "$rc" 1
assert_eq 'plan' "$achieved_plan" none
assert_eq 'losers are the second dies' "$(failed_gpus | tr '\n' ' ')" \
	'0000:0e:00.0 0000:1e:00.0 '
assert_eq 'rounds: all-max, demote losers, demote their groups, baseline' \
	"$REENUM_CALLS" 4
assert_eq 'first dies were demoted to baseline in the end' \
	"${plan[0000:0b:00.0]}" 8

echo 'negotiation: size-limited window (demote-losers succeeds)'
reset_regs
RULE=budget
REENUM_CALLS=0
achieved_plan=none
negotiate 2>/dev/null
rc=$?
assert_eq 'rc' "$rc" 0
assert_eq 'plan' "$achieved_plan" demote-losers-2
assert_eq 'two rounds' "$REENUM_CALLS" 2
assert_eq 'first die large' "${plan[0000:0b:00.0]}" 15
assert_eq 'second die baseline' "${plan[0000:0e:00.0]}" 8
assert_eq 'single card untouched by the demotion' "${plan[0000:2b:00.0]}" 13
assert_eq 'no failures' "$(failed_gpus | wc -l)" 0

echo 're-enumeration is group-local and return-checked'
assert_eq 'no global rescan anywhere in the code' \
	"$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'bus/pci/rescan')" 0
group_rescan[0000:16:00.0]=$T/nonexistent/rescan
orig_rescan_group 0000:16:00.0 2>/dev/null
assert_eq 'missing rescan file is a failure' "$?" 1
group_rescan[0000:16:00.0]=$T
orig_rescan_group 0000:16:00.0 2>/dev/null
assert_eq 'failed write (a directory) is a failure' "$?" 1
group_rescan[0000:16:00.0]=$SYSFS/devices/pci0000:16/pci_bus/0000:16/rescan
orig_rescan_group 0000:16:00.0 2>/dev/null
rc=$?
assert_eq 'writable rescan file succeeds' \
	"$rc:$(<"$SYSFS/devices/pci0000:16/pci_bus/0000:16/rescan")" '0:1'
reset_regs
plan_all_max
RULE=6x
RESCAN_FAIL_GROUPS=0000:16:00.0
try_plan all-max 2>/dev/null
rc=$?
assert_eq 'a group whose rescan fails rejects the plan' "$rc" 1
assert_eq 'its GPUs are the losers' "${last_losers[*]}" \
	'0000:1b:00.0 0000:1e:00.0'
assert_eq 'the other group was re-enumerated normally' \
	"$(bar0_bytes 0000:0b:00.0)" $(( 32 << 30 ))
RESCAN_FAIL_GROUPS=''
reset_regs

echo 'only GPUs with a size change, and their group members, are unbound'
bind_all
RULE=6x
achieved_plan=none
negotiate 2>/dev/null
assert_eq 'plan' "$achieved_plan" all-max
assert_eq 'resized die unbound' "$(bound 0000:0b:00.0)" none
assert_eq 'its audio function unbound' "$(bound 0000:0b:00.1)" none
assert_eq 'GPU without ReBAR keeps amdgpu' "$(bound 0000:3b:00.0)" amdgpu
bind_all
REENUM_CALLS=0
negotiate 2>/dev/null
assert_eq 'already in effect: nothing re-enumerated' "$REENUM_CALLS" 0
got="$(bound 0000:0b:00.0),$(bound 0000:0b:00.1),$(bound 0000:2b:00.0)"
assert_eq 'already in effect: nothing unbound' "$got" \
	'amdgpu,snd_hda_intel,amdgpu'
write_size_index 0000:2b:00.0 8 >/dev/null
set_bars 0000:2b:00.0 8 assigned
gpu_dirty=()
gpu_dirty_from=()
negotiate 2>/dev/null
got="$(bound 0000:2b:00.0),$(bound 0000:2b:00.1),$(bound 0000:0b:00.0)"
got+=",$(bound 0000:0e:00.0),$(bound 0000:3b:00.0)"
assert_eq 'one card changed: only its group unbound' "$got" \
	'none,none,amdgpu,amdgpu,amdgpu'
assert_eq 'one card changed: only its group re-enumerated' \
	"${active_groups[*]}" 0000:2a:00.0
assert_eq 'one card changed: back at 8GiB' "$(bar0_bytes 0000:2b:00.0)" \
	$(( 8 << 30 ))
unload_driver
for g in "${gpus[@]}"; do
	for f in ${gpu_funcs[$g]}; do
		rm -f "${DEVPATH[$f]}/driver"
	done
done
reset_regs

echo 'config: validation'
# check_config LABEL EXPECTED-RC ASSIGNMENT... -- runs validate_config with
# the assignments applied (NAME=value, no shell quoting); messages land in
# $T/cfg.out
check_config() {
	local label=$1 want=$2 rc
	shift 2
	(
		for a in "$@"; do
			declare -- "$a"
		done
		log_err() { echo "$*"; }
		validate_config
	) > "$T/cfg.out" 2>&1
	rc=$?
	assert_eq "$label: rc" "$rc" "$want"
}
check_config 'defaults valid' 0
assert_eq 'defaults: no message' "$(<"$T/cfg.out")" ''
check_config 'MAX_SIZE_INDEX=44' 1 MAX_SIZE_INDEX=44
assert_eq 'MAX_SIZE_INDEX message names variable and file' \
	"$(count "MAX_SIZE_INDEX='44' in /dev/null" "$T/cfg.out")" 1
check_config 'MAX_SIZE_INDEX=abc' 1 MAX_SIZE_INDEX=abc
check_config 'MAX_SIZE_INDEX=15 ok' 0 MAX_SIZE_INDEX=15
check_config 'MAX_SIZE_INDEX=0 ok' 0 MAX_SIZE_INDEX=0
check_config 'MODPROBE_TIMEOUT=0' 1 MODPROBE_TIMEOUT=0
check_config 'PROBE_WAIT=-5' 1 PROBE_WAIT=-5
check_config 'RESCAN_WAIT empty' 1 RESCAN_WAIT=
check_config 'MAX_ROUNDS=8x' 1 MAX_ROUNDS=8x
check_config 'EXCLUDE_GPUS bad entry' 1 'EXCLUDE_GPUS=0000:0b:00.0 0b:00.0'
assert_eq 'EXCLUDE_GPUS message names the entry' \
	"$(count "EXCLUDE_GPUS entry '0b:00.0'" "$T/cfg.out")" 1
check_config 'EXCLUDE_GPUS two good entries' 0 \
	'EXCLUDE_GPUS=0000:0b:00.0 0000:1e:00.0'
check_config 'FORCE_PLAN=first-large' 1 FORCE_PLAN=first-large
check_config 'FORCE_PLAN=baseline ok' 0 FORCE_PLAN=baseline
check_config 'three faults' 1 MAX_SIZE_INDEX=99 MAX_ROUNDS=0 FORCE_PLAN=x
assert_eq 'one line per fault' "$(wc -l < "$T/cfg.out")" 3
echo 'config: unit budget (MODPROBE_TIMEOUT + kill grace + PROBE_WAIT below' \
	'TimeoutStartSec)'
check_config 'MODPROBE_TIMEOUT=600 over budget' 1 MODPROBE_TIMEOUT=600
want='MODPROBE_TIMEOUT=600 + PROBE_WAIT=60 in /dev/null: with the 30s kill'
want+=" grace that is 690s, not below the service's TimeoutStartSec of 480s"
assert_eq 'budget message names the values and the budget' \
	"$(count "$want" "$T/cfg.out")" 1
check_config 'MODPROBE_TIMEOUT=389 just inside' 0 MODPROBE_TIMEOUT=389
check_config 'MODPROBE_TIMEOUT=390 reaches the budget' 1 MODPROBE_TIMEOUT=390
check_config 'PROBE_WAIT=269 just inside' 0 PROBE_WAIT=269
check_config 'PROBE_WAIT=270 reaches the budget' 1 PROBE_WAIT=270
check_config 'budget not judged on a non-integer' 1 MODPROBE_TIMEOUT=lots
assert_eq 'one message, the integer one' \
	"$(wc -l < "$T/cfg.out"):$(count 'positive integer' "$T/cfg.out")" '1:1'
# shellcheck disable=SC2016  # the literal text of the script is wanted
assert_eq 'kill grace is the constant the modprobe timeout uses' \
	"$(count '--kill-after="$MODPROBE_KILL_GRACE"' "$SCRIPT")" 1
assert_eq 'validation did not leak into the harness' \
	"$MAX_SIZE_INDEX|$MAX_ROUNDS|$FORCE_PLAN" '|8|'

echo 'config: cap and exclusion'
reset_regs
MAX_SIZE_INDEX=14
EXCLUDE_GPUS=0000:0e:00.0
discover_gpus
assert_eq 'excluded GPU dropped' "${#gpus[@]}" 7
assert_eq 'excluded GPU makes its root impure' "${gpu_root[0000:0b:00.0]}" \
	0000:08:08.0
assert_eq 'cap applied' "${gpu_max_index[0000:0b:00.0]}" 14
assert_eq 'cap does not raise a small card' "${gpu_max_index[0000:2b:00.0]}" \
	13
MAX_SIZE_INDEX=''
EXCLUDE_GPUS=''

echo 'bind guard'
discover_gpus
reset_regs
set_bars 0000:1e:00.0 15 unassigned
assert_eq 'unassigned BARs detected from sysfs' \
	"$(bar_unassigned_list 0000:1e:00.0)" '0 2'
assert_eq 'failed list' "$(failed_gpus | tr '\n' ' ')" '0000:1e:00.0 '
block_binding 0000:1e:00.0
assert_eq 'override written' "$(override_of 0000:1e:00.0)" none
clear_stale_overrides
assert_eq 'override cleared' "$(override_of 0000:1e:00.0)" ''
echo 'bind guard: losers fenced off, register reset for the next boot,' \
	'driver loaded on the rest'
write_size_index 0000:1e:00.0 15 >/dev/null
mark_group_reenumerated 0000:16:00.0
MODPROBE_CALLS=0
guard_and_load_driver 2>/dev/null
rc=$?
assert_eq 'guard rc' "$rc" 0
assert_eq 'driver loaded once' "$MODPROBE_CALLS" 1
assert_eq 'loser gets driver_override=none' "$(override_of 0000:1e:00.0)" \
	none
assert_eq 'loser not bound' "$(bound_state 0000:1e:00.0)" unbound
assert_eq 'sibling bound' "$(bound_state 0000:1b:00.0)" bound
assert_eq 'loser register reset to baseline for the next boot' \
	"$(read_size_index 0000:1e:00.0)" 8
assert_eq 'decode restored after the reset write' \
	"$(reg 0000:1e:00.0 COMMAND)" 0x0407
assert_eq 'one GPU blocked' "$guard_blocked" 1
MODPROBE_RC=1
unload_driver
MODPROBE_CALLS=0
guard_and_load_driver 2>/dev/null
rc=$?
assert_eq 'modprobe failure is reported' "$rc:$MODPROBE_CALLS" '1:1'
MODPROBE_RC=0
unload_driver
clear_stale_overrides
gpu_dirty=()
gpu_dirty_from=()

echo 'root-bus GPU: resized in place by the kernel, never rescanned'
reset_regs
plan_all_max
RULE=6x
INPLACE_WRITES=0
REENUM_CALLS=0
before=$SETPCI_CTRL_WRITES
try_plan all-max 2>/dev/null
rc=$?
assert_eq 'plan verified' "$rc" 0
assert_eq 'root-bus GPU at 32GiB' "$(bar0_bytes 0000:60:00.0)" \
	$(( 32 << 30 ))
assert_eq "register reflects the kernel's write" \
	"$(read_size_index 0000:60:00.0)" 15
assert_eq 'one resource0_resize write' "$INPLACE_WRITES" 1
assert_eq 'root-bus GPU never dirty' "${gpu_dirty[0000:60:00.0]:-}" ''
assert_eq 'root-bus GPU was unbound for the in-place resize' \
	"${active_groups[-1]}" none:0000:60:00.0
assert_eq 'switched GPUs still use the register (6 of 7 writes)' \
	"$(( SETPCI_CTRL_WRITES - before ))" 6
reset_regs
plan_all_max
INPLACE_FAIL=1
INPLACE_WRITES=0
try_plan all-max 2>/dev/null
rc=$?
assert_eq 'in-place failure rejects the plan for that GPU' "$rc" 1
assert_eq 'it is the only loser' "${last_losers[*]}" 0000:60:00.0
assert_eq 'kernel kept 256MiB' "$(bar0_bytes 0000:60:00.0)" $(( 256 << 20 ))
assert_eq 'the others were resized' "$(bar0_bytes 0000:0b:00.0)" \
	$(( 32 << 30 ))
reset_regs
achieved_plan=none
negotiate 2>/dev/null
assert_eq 'negotiation demotes it and succeeds' \
	"$achieved_plan:${plan[0000:60:00.0]}:${plan[0000:0b:00.0]}" \
	'demote-losers-2:8:15'
INPLACE_FAIL=0
reset_regs

echo 'cleanup trap: overrides, decode, state report, idempotence, exit status'
discover_gpus
reset_regs
clear_stale_overrides
set_override 0000:0b:00.0 none    # ours for the run
block_binding 0000:1e:00.0        # deliberate: fenced-off GPU
printf '0x0405\n' > "$REG/0000:0e:00.0.COMMAND"
gpu_decode_off[0000:0e:00.0]=1
gpu_dirty[0000:0b:00.0]=1
gpu_dirty_from[0000:0b:00.0]=8
out=$(
	log_info() { echo "$*"; }
	log_warn() { echo "$*"; }
	touched=1
	cleanup
	echo ---
	cleanup
)
assert_eq 'cleanup: our override cleared' "$(override_of 0000:0b:00.0)" ''
assert_eq 'cleanup: deliberate override kept' "$(override_of 0000:1e:00.0)" \
	none
assert_eq 'cleanup: decode re-enabled' "$(reg 0000:0e:00.0 COMMAND)" 0x0407
assert_eq 'cleanup: one state line per GPU' "$(count_in '^state of ' "$out")" 8
want='^state of 0000:0b:00.0: size index 8 (written, not re-enumerated)'
assert_eq 'cleanup: dirty GPU called out' "$(count_in "$want" "$out")" 1
assert_eq 'cleanup: second run does nothing' \
	"$(sed -n '/^---$/,$p' <<<"$out" | wc -l)" 1
out=$(
	log_info() { echo "$*"; }
	log_warn() { echo "$*"; }
	gpu_dirty=()
	override_set=()
	gpu_decode_off=()
	touched=1
	run_complete=1
	cleanup
)
assert_eq 'cleanup: silent after a complete clean run' "$out" ''
( install_traps; exit 2 ) 2>/dev/null
assert_eq 'EXIT trap preserves the exit status' "$?" 2
( install_traps; kill -TERM $BASHPID; echo unreachable ) 2>/dev/null
assert_eq 'SIGTERM exits 143 after cleanup' "$?" 143
( install_traps; kill -INT $BASHPID; echo unreachable ) 2>/dev/null
assert_eq 'SIGINT exits 130 after cleanup' "$?" 130
gpu_dirty=()
gpu_dirty_from=()
gpu_decode_off=()
clear_stale_overrides
override_set=()
override_keep=()

echo 'verification: phase 3 with and without XGMI hives'
# v6.0 died here when no GPU exposed a hive (the attribute is a directory, so
# the per-GPU read was empty and "grep -v" exited 1 under errexit+pipefail).
# The script no longer uses errexit, but the summary must still come out.
set_bars 0000:1e:00.0 15 assigned
discover_gpus
while read -r g; do
	set_bars "$g" "${gpu_max_index[$g]}" assigned
done < <(resizable_gpus)
for g in "${gpus[@]}"; do
	ln -sfn "$SYSFS/bus/pci/drivers/amdgpu" "${DEVPATH[$g]}/driver"
done
# run_phase3 -- prints the log lines; rc is phase3_verify's
run_phase3() {
	(
		log_info() { echo "$*"; }
		log_ok() { echo "$*"; }
		log_warn() { echo "$*"; }
		log_err() { echo "$*"; }
		achieved_plan=all-max
		phase3_verify
	) 2>/dev/null
}
rm -f "$STATE_DIR/summary"
out=$(run_phase3)
rc=$?
assert_eq 'no hive anywhere: rc' "$rc" 0
assert_eq 'no hive anywhere: reached SUCCESS' "$(count_in 'SUCCESS:' "$out")" 1
want='plan=all-max gpus=8 large=8 baseline=0 driverless=0 unassigned=0'
want+=' missing=0 kfd_nodes=0'
assert_eq 'no hive anywhere: summary written' \
	"$(sed -n 's/ kernel=.*//p' "$STATE_DIR/summary" 2>/dev/null)" "$want"
for g in 0000:0b:00.0 0000:0e:00.0; do
	mkdir -p "${DEVPATH[$g]}/xgmi_hive_info"
	echo 111 > "${DEVPATH[$g]}/xgmi_hive_info/xgmi_hive_id"
done
for g in 0000:1b:00.0 0000:1e:00.0; do
	mkdir -p "${DEVPATH[$g]}/xgmi_hive_info"
	echo 222 > "${DEVPATH[$g]}/xgmi_hive_info/xgmi_hive_id"
done
out=$(run_phase3)
rc=$?
assert_eq 'two hives: rc' "$rc" 0
assert_eq 'two hives: per-GPU hive id' "$(count_in 'XGMI hive: 111' "$out")" 2
got=$(sed -n 's/.*XGMI hives (id x members): //p' <<<"$out")
assert_eq 'two hives: summary' "$got" '111x2 222x2 '
for g in "${gpus[@]}"; do
	rm -f "${DEVPATH[$g]}/driver"
done

echo 'command line: subcommands, version, help, check'
LOCK_FILE=$T/lock
# Root, tools and pci=realloc are not the harness's business.
preflight() {
	return 0
}
# run_main ARGS... -- stdout in $T/main.out, log lines (stderr) in
# $T/main.err; rc returned
run_main() {
	(
		log_info() { echo "[INFO]  $*" >&2; }
		log_ok() { echo "[OK]    $*" >&2; }
		log_warn() { echo "[WARN]  $*" >&2; }
		log_err() { echo "[ERROR] $*" >&2; }
		main "$@"
	) > "$T/main.out" 2> "$T/main.err"
}
run_main --version
assert_eq '--version' "$?:$(<"$T/main.out")" '0:resize-amdgpu-bars 1.0'
run_main --help
assert_eq '--help rc' "$?" 0
assert_eq '--help comes from usage()' \
	"$(count '^Usage: resize-amdgpu-bars' "$T/main.out")" 1
assert_eq '--help documents the three exit statuses' \
	"$(grep -cE '^  [012]  ' "$T/main.out")" 3
assert_eq '--help lists every subcommand' \
	"$(grep -cE '^  (resize|status|check|dry-run|diagnose|revert) ' \
	"$T/main.out")" 6
run_main bogus
assert_eq 'unknown argument exits 1' "$?" 1
run_main --diagnose-only
assert_eq 'pre-release flag spelling is not accepted' "$?" 1
run_main status
rc=$?
assert_eq 'status rc' "$rc" 0
STATUS_RE='^gpus=8( [0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]:bar0=[^,]+'
STATUS_RE+=',idx=-?[0-9]+,max=-?[0-9]+,drv=[^,]+,root=[^ ]+){8}'
STATUS_RE+='( last: plan=.*)?$'
assert_eq 'status line format' "$(grep -cE "$STATUS_RE" "$T/main.out")" 1
assert_eq 'status: one line, nothing else on stdout' \
	"$(wc -l < "$T/main.out")" 1
run_main diagnose
assert_eq 'diagnose' "$?:$(count 'Diagnostics complete' "$T/main.err")" '0:1'
assert_eq 'diagnose shows the six groups' \
	"$(count '^\[INFO\]  Group ' "$T/main.err")" 6
run_main dry-run
assert_eq 'dry-run' "$?:$(count 'Dry run complete' "$T/main.err")" '0:1'
echo 'read-only commands leave the state directory as they found it'
# A record from an earlier run of this boot: bars-* deliberately short of
# what discovery sees (BAR5 missing), so a rewrite would show up. The
# baseline-* files are the one record a read-only command may create (first
# observation, 2.2); here they exist already and must not change either.
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
while read -r g; do
	echo 8 > "$STATE_DIR/baseline-$g"
done < <(resizable_gpus)
echo '0 2' > "$STATE_DIR/bars-0000:0b:00.0"
echo 'plan=x' > "$STATE_DIR/summary"
touch -d '2000-01-01 00:00:00' "$STATE_DIR"/*
# state_files -- the state directory's entries, sorted, space-joined
state_files() {
	find "$STATE_DIR" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' '
}
before=$(state_files)
run_main status
run_main diagnose
run_main dry-run
assert_eq 'read-only: no file added or removed' "$(state_files)" "$before"
assert_eq 'read-only: bars-* content unchanged' \
	"$(<"$STATE_DIR/bars-0000:0b:00.0")" '0 2'
assert_eq 'read-only: nothing under the state dir touched' \
	"$(find "$STATE_DIR" -mindepth 1 -newermt '2000-01-02' | wc -l)" 0
got=$(
	record_bars=0
	echo '0 2' > "$STATE_DIR/bars-0000:0e:00.0"
	set_bars 0000:0e:00.0 8 assigned
	gpu_mem_bars 0000:0e:00.0
	cat "$STATE_DIR/bars-0000:0e:00.0"
)
assert_eq 'read-only: the record is still read' "$got" $'0 2 5\n0 2'
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
# No journal in the harness.
journalctl() {
	:
}
CHECK_LOG=$T/matrix.log
run_main check -1
rc=$?
want='verdict=OTHER - inspect.*windows=(live only).*kfd=(live only)'
got="$rc:$(count "$want" "$T/main.out")"
got+=":$(yesno test -e "$T/matrix.log")"
assert_eq 'check -1: verdict line, live-only fields, nothing appended' \
	"$got" '0:1:no'
run_main check
rc=$?
CHECK_RE='verdict=OTHER - inspect  plan=\?  .*windows=[^ ]+=.*bar0=([^ ]+ ){8}'
CHECK_RE+=' +kfd=[0-9]+  xgmi_hives=[0-9]+'
got="$rc:$(grep -cE "$CHECK_RE" "$T/main.out")"
got+=":$(count '(appended to' "$T/main.out"):$(wc -l < "$T/matrix.log")"
assert_eq 'check: live fields from sysfs, line appended' "$got" '0:1:1:1'
run_main check -2
assert_eq 'check rejects other arguments' "$?" 1
unset -f journalctl

echo 'full runs through main: exit status 0 / 2 / 1, journal hygiene'
unload_driver
reset_regs
clear_stale_overrides
RULE=6x
MODPROBE_RC=0
# No ROCm tools on this box.
have_tool() {
	return 1
}
run_main resize --force
rc=$?
got="$(count 'unassigned regions: none' "$T/main.err")"
got+=":$(count 'unassigned: none' "$T/main.err")"
got+=":$(grep -cE 'unassigned( regions)?: *$' "$T/main.err")"
assert_eq 'empty unassigned lists print none, never an empty value' "$got" \
	'8:8:0'
assert_eq 'Done line without ROCm tools names status' \
	"$(count '^\[INFO\]  Done. Check with: resize-amdgpu-bars status$' \
	"$T/main.err")" 1
assert_eq 'all-max on a 6.x-like kernel: exit 0' "$rc" 0
assert_eq 'SUCCESS line' "$(count 'SUCCESS:' "$T/main.err")" 1
assert_eq 'Plan achieved line' \
	"$(count 'Plan achieved : all-max' "$T/main.err")" 1
got="$(count 'Large BARs    : 8 / 8' "$T/main.err")"
got+=":$(count 'Driverless    : 0 / 8' "$T/main.err")"
assert_eq 'check tool strings present' "$got" '1:1'
got="$(bound 0000:0b:00.0),$(bound 0000:60:00.0),$(bound 0000:3b:00.0)"
assert_eq 'every GPU bound' "$got" 'amdgpu,amdgpu,amdgpu'
assert_eq 'journal: no blank lines' "$(count '^$' "$T/main.err")" 0
assert_eq 'journal: plain ASCII' \
	"$(LC_ALL=C grep -c '[^ -~]' "$T/main.err")" 0
assert_eq 'journal: no rule or box lines' \
	"$(grep -cE '^\[[A-Z]+\] +[-=_#*]{4,}' "$T/main.err")" 0
assert_eq 'journal: one-line phase banners' \
	"$(count '^== Phase ' "$T/main.err")" 3
assert_eq 'journal: nothing on stdout' "$(wc -c < "$T/main.out")" 0
assert_eq 'resize records the memory BARs it saw' \
	"$(cat "$STATE_DIR/bars-0000:0b:00.0" 2>/dev/null)" '0 2 5'
# One ROCm tool present.
have_tool() {
	[[ $1 == rocm-smi ]]
}
run_main resize --force
rc=$?
assert_eq 'second run takes the fast path: exit 0, nothing re-enumerated' \
	"$rc:$(count 'no re-enumeration needed' "$T/main.err")" '0:1'
assert_eq 'Done line with a ROCm tool names it' \
	"$(count '^\[INFO\]  Done. Verify with: rocminfo / rocm-smi$' \
	"$T/main.err")" 1
have_tool() {
	return 1
}
unload_driver
reset_regs
clear_stale_overrides
RULE=70vanilla
run_main resize --force
rc=$?
assert_eq 'unpatched-7.0-like kernel: exit 2 (bind guard holding)' "$rc" 2
assert_eq 'second dies fenced off' \
	"$(override_of 0000:0e:00.0),$(override_of 0000:1e:00.0)" 'none,none'
assert_eq 'first dies bound' "$(bound 0000:0b:00.0),$(bound 0000:1b:00.0)" \
	'amdgpu,amdgpu'
got="$(count 'Plan achieved : none' "$T/main.err")"
got+=":$(count 'Driverless    : 2 / 8' "$T/main.err")"
got+=":$(count 'rejected: unassigned BARs on: ' "$T/main.err")"
assert_eq 'verdict strings' "$got" '1:1:4'
assert_eq 'fenced-off dies reset to baseline for the next boot' \
	"$(read_size_index 0000:0e:00.0):$(read_size_index 0000:1e:00.0)" '8:8'
unload_driver
reset_regs
clear_stale_overrides
override_set=()
override_keep=()
RULE=6x
MODPROBE_RC=1
run_main resize --force
assert_eq 'modprobe failure: exit 1' "$?" 1
MODPROBE_RC=0
unload_driver
reset_regs
SETPCI_FAIL_AFTER=$((SETPCI_CTRL_WRITES + 1))
run_main resize --force
rc=$?
got="$rc:$(count 'not re-enumerated on: 0000:0b:00.0' "$T/main.err")"
if [[ -d $SYSFS/module/amdgpu ]]; then
	got+=':loaded'
else
	got+=':not-loaded'
fi
assert_eq 'register left dirty: exit 1, driver never loaded' "$got" \
	'1:1:not-loaded'
want='state of 0000:0b:00.0: size index 15 (written, not re-enumerated)'
assert_eq 'cleanup reported the dirty die' "$(count "$want" "$T/main.err")" 1
SETPCI_FAIL_AFTER=-1
gpu_dirty=()
gpu_dirty_from=()
unload_driver
reset_regs
clear_stale_overrides
run_main resize --force
assert_eq 'recovered: exit 0' "$?" 0
run_main revert
rc=$?
got="$rc:$(count 'Plan achieved : baseline' "$T/main.err")"
got+=":$(bound 0000:0b:00.0):$(bar0_bytes 0000:0b:00.0)"
assert_eq 'revert: exit 0, baseline plan, everything bound' "$got" \
	"0:1:amdgpu:$(( 256 << 20 ))"
unload_driver
reset_regs
clear_stale_overrides

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
