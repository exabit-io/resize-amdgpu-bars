#!/bin/bash
# test_resize_gpu_bars.sh — offline tests for resize_gpu_bars.sh v6.
#
# Builds a fake sysfs tree (two Vega II Duo cards on separate root ports, a
# W5500X-like single GPU without a PLX chain, a 580X-like GPU without ReBAR,
# a radeon-only card, a Thunderbolt controller and a Mellanox NIC with SR-IOV
# VFs), stubs lspci / setpci and the amdgpu alias table, and replaces the
# kernel's re-enumeration with a rule so the plan negotiation can be
# exercised for kernels that behave like 6.x, like an unpatched 7.0, and
# like a size-limited window. Nothing real is touched.
#
#   ./test_resize_gpu_bars.sh path/to/resize_gpu_bars.sh
set -uo pipefail
SCRIPT=${1:?usage: $0 path/to/resize_gpu_bars.sh}
[[ -r $SCRIPT ]] || { echo "$0: cannot read $SCRIPT" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/rgb-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
export RESIZE_GPU_BARS_SYSFS=$T/sys RESIZE_GPU_BARS_STATE_DIR=$T/run RESIZE_GPU_BARS_CONFIG=/dev/null
export RESIZE_GPU_BARS_ALIAS_FILE=$T/modules.alias
SYSFS=$RESIZE_GPU_BARS_SYSFS
# The alias table amdgpu would export: Vega20 (66A3) and Polaris (67DF); the
# Caicos line belongs to radeon and must be ignored.
cat > "$RESIZE_GPU_BARS_ALIAS_FILE" <<'EOF_ALIAS'
alias pci:v00001002d000066A3sv*sd*bc*sc*i* amdgpu
alias pci:v00001002d000067DFsv*sd*bc*sc*i* amdgpu
alias pci:v00001002d00006779sv*sd*bc*sc*i* radeon
alias usb:v1D6Bp0002d*dc*dsc*dp*ic*isc*ip*in* usbcore
EOF_ALIAS
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1: expected '$3', got '$2'"; }

# ---------------------------------------------------------------------------
# Fake tree builders
# ---------------------------------------------------------------------------
REG=$T/regs; mkdir -p "$REG" "$SYSFS/bus/pci/devices" "$SYSFS/bus/pci/drivers/amdgpu"
declare -A DEVPATH
mkdev() {   # mkdev <bdf> <parent-path> <vendor> <class> [gpu]
    local bdf=$1 parent=$2 vendor=$3 class=$4 kind=${5:-}
    local path=$parent/$bdf; mkdir -p "$path"
    echo "$vendor" > "$path/vendor"; echo "$class" > "$path/class"
    : > "$path/driver_override"
    local dev=0000
    case $kind in gpu) dev=66A3 ;; gpu-norebar) dev=67DF ;; gpu-radeon) dev=6779 ;; esac
    local vend=${vendor#0x}
    printf 'pci:v0000%sd0000%ssv0000106Bsd00000203bc%ssc%si00\n' "${vend^^}" "$dev" "${class:2:2}" "${class:4:2}" > "$path/modalias"
    DEVPATH[$bdf]=$path
    ln -sfn "$path" "$SYSFS/bus/pci/devices/$bdf"
    if [[ $kind == gpu ]]; then
        echo 000000000000ff00 > "$path/resource0_resize"; echo 0000000000000004 > "$path/resource2_resize"
        printf '0x0000000000000800\n' > "$REG/$bdf.0x208.l"    # index 8 (256 MB), BAR0 entry
        printf '0x0407\n' > "$REG/$bdf.COMMAND"
        set_bars "$bdf" 8 assigned
    elif [[ $kind == gpu-norebar || $kind == gpu-radeon ]]; then
        printf '0x0407\n' > "$REG/$bdf.COMMAND"
        set_bars "$bdf" 8 assigned
    fi
}
# resource file: BAR0 sized by index, BAR2 2M, BAR5 512K; state assigned|unassigned
set_bars() {
    local bdf=$1 idx=$2 st=$3 f base
    f=${DEVPATH[$bdf]}/resource
    base=$(( 0x90000000000 + 16#${bdf:5:2} * 0x1000000000 ))
    if [[ $st == assigned ]]; then
        printf '0x%016x 0x%016x 0x000000000014220c\n' "$base" $(( base + (1 << (idx + 20)) - 1 )) > "$f"
        printf '0x%016x 0x%016x 0x0000000000000000\n' 0 0 >> "$f"
        printf '0x%016x 0x%016x 0x000000000014220c\n' $(( base + 0x800000000 )) $(( base + 0x8001fffff )) >> "$f"
    else
        printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 > "$f"; printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 >> "$f"
        printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 >> "$f"
    fi
    printf '0x%016x 0x%016x 0x%016x\n' 0 0 0 >> "$f"
    printf '0x0000000000005000 0x00000000000050ff 0x0000000000040101\n' >> "$f"
    printf '0x0000000074400000 0x000000007447ffff 0x0000000000040200\n' >> "$f"
    printf '0x0000000074480000 0x000000007449ffff 0x0000000000046200\n' >> "$f"
}
root_bus() { mkdir -p "$SYSFS/devices/pci$1/pci_bus/$1"; : > "$SYSFS/devices/pci$1/pci_bus/$1/rescan"; echo "$SYSFS/devices/pci$1"; }
BR=0x060400; GPU=0x030000; AUD=0x040300; NET=0x020000

build_tree() {
    local r
    # Card 1: Vega II Duo behind root port 06:00.0 (PLX + AMD bridge chains)
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
    # A single-GPU MPX card straight behind a root port (W5500X-like, 8 GB max)
    r=$(root_bus 0000:2a)
    mkdev 0000:2a:00.0 "$r" 0x8086 $BR
    mkdev 0000:2b:00.0 "${DEVPATH[0000:2a:00.0]}" 0x1002 $GPU gpu
    echo 0000000000003f00 > "${DEVPATH[0000:2b:00.0]}/resource0_resize"     # 256M..8G
    mkdev 0000:2b:00.1 "${DEVPATH[0000:2a:00.0]}" 0x1002 $AUD
    # A GPU with no ReBAR at all (580X-like)
    r=$(root_bus 0000:3a)
    mkdev 0000:3a:00.0 "$r" 0x8086 $BR
    mkdev 0000:3b:00.0 "${DEVPATH[0000:3a:00.0]}" 0x1002 $GPU gpu-norebar
    # A radeon-driver card (Caicos-like): AMD, class 03, not amdgpu's
    r=$(root_bus 0000:70)
    mkdev 0000:70:00.0 "$r" 0x8086 $BR
    mkdev 0000:71:00.0 "${DEVPATH[0000:70:00.0]}" 0x1002 $GPU gpu-radeon
    # Thunderbolt NHI and a Mellanox NIC with two VFs: must never be touched
    r=$(root_bus 0000:24)
    mkdev 0000:24:00.0 "$r" 0x8086 $BR
    mkdev 0000:25:00.0 "${DEVPATH[0000:24:00.0]}" 0x8086 0x088000
    r=$(root_bus 0000:40)
    mkdev 0000:40:00.0 "$r" 0x8086 $BR
    mkdev 0000:41:00.0 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
    mkdev 0000:41:00.1 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
    mkdev 0000:41:00.2 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
    mkdev 0000:41:00.3 "${DEVPATH[0000:40:00.0]}" 0x15b3 $NET
    # A GPU that shares its root port with a non-GPU device (impure subtree)
    r=$(root_bus 0000:50)
    mkdev 0000:50:00.0 "$r" 0x8086 $BR
    mkdev 0000:51:00.0 "${DEVPATH[0000:50:00.0]}" 0x10b5 $BR
    mkdev 0000:52:00.0 "${DEVPATH[0000:51:00.0]}" 0x10b5 $BR
    mkdev 0000:53:00.0 "${DEVPATH[0000:52:00.0]}" 0x1002 $GPU gpu
    mkdev 0000:52:01.0 "${DEVPATH[0000:51:00.0]}" 0x10b5 $BR
    mkdev 0000:54:00.0 "${DEVPATH[0000:52:01.0]}" 0x144d 0x010802     # NVMe on the same switch
}

# ---------------------------------------------------------------------------
# Stubs for lspci / setpci
# ---------------------------------------------------------------------------
lspci() {
    local bdf="" mm=0 vv=0 a
    while (( $# )); do a=$1; shift; case $a in -s) bdf=$1; shift ;; -mm) mm=1 ;; -vv) vv=1 ;; esac; done
    [[ -n ${DEVPATH[$bdf]:-} ]] || return 0
    if (( mm )); then echo "$bdf \"Class\" \"Vendor\" \"Fake device $bdf\" -r00 \"Sub\" \"Sub\""; return; fi
    if (( vv )); then
        [[ -e ${DEVPATH[$bdf]}/resource0_resize ]] && echo "	Capabilities: [200 v1] Physical Resizable BAR"
        [[ $(cat "${DEVPATH[$bdf]}/class") == 0x0604* ]] && echo "	Prefetchable memory behind bridge: 90000000000-91fffffffff [size=128G] [32-bit]"
    fi
}
# Fault injection: SETPCI_FAIL_WRITES lists BDFs whose ReBAR control write
# fails; SETPCI_FAIL_AFTER=N makes every control write after the first N
# fail (-1: off). Each control write snapshots COMMAND into <bdf>.cmd_at_write.
SETPCI_FAIL_WRITES=""; SETPCI_FAIL_AFTER=-1; SETPCI_CTRL_WRITES=0
setpci() {
    local bdf="" arg
    while (( $# )); do
        arg=$1; shift
        case $arg in
            -s) bdf=$1; shift ;;
            COMMAND=*) echo "0x${arg#*=}" > "$REG/$bdf.COMMAND" ;;
            *=*)
                [[ " $SETPCI_FAIL_WRITES " == *" $bdf "* ]] && return 1
                (( SETPCI_FAIL_AFTER >= 0 && SETPCI_CTRL_WRITES >= SETPCI_FAIL_AFTER )) && return 1
                SETPCI_CTRL_WRITES=$((SETPCI_CTRL_WRITES + 1))
                cp "$REG/$bdf.COMMAND" "$REG/$bdf.cmd_at_write"
                echo "0x${arg#*=}" > "$REG/$bdf.${arg%%=*}" ;;
            *) [[ -r $REG/$bdf.$arg ]] && sed 's/^0x//' "$REG/$bdf.$arg" || return 1 ;;
        esac
    done
}
# modprobe / timeout: loading the driver binds every present GPU that is
# not fenced off with driver_override=none, exactly what the kernel would do.
MODPROBE_CALLS=0; MODPROBE_RC=0
timeout() { shift 3; "$@"; }
modprobe() {
    local g
    MODPROBE_CALLS=$((MODPROBE_CALLS + 1))
    (( MODPROBE_RC )) && return "$MODPROBE_RC"
    mkdir -p "$SYSFS/module/amdgpu"
    for g in "${GPUS[@]}"; do
        [[ -e ${DEVPATH[$g]} && $(cat "${DEVPATH[$g]}/driver_override") != none ]] || continue
        ln -sfn "$SYSFS/bus/pci/drivers/amdgpu" "${DEVPATH[$g]}/driver"
    done
}
unload_driver() { local g; rm -rf "$SYSFS/module/amdgpu"; for g in "${GPUS[@]}"; do rm -f "${DEVPATH[$g]}/driver"; done; }
export -f lspci setpci timeout modprobe 2>/dev/null

# ---------------------------------------------------------------------------
build_tree
# shellcheck disable=SC1090
source "$SCRIPT"; set +e
# The kernel: apply a RULE to decide which GPUs get their BARs after rescan.
#   6x        every GPU fits at any size
#   70vanilla in every group with 2+ GPUs the second GPU never fits
#   budget    a group fits only if the sum of its BAR0 sizes is <= 40 GB
RULE=6x; REENUM_CALLS=0
reenumerate() {
    local r g i sum n
    for r in "${GROUPS_LIST[@]}"; do
        n=0; sum=0
        for g in ${GROUP_MEMBERS[$r]}; do
            i=$(read_size_index "$g"); (( i < 0 )) && i=8
            sum=$(( sum + (1 << (i + 20)) )); n=$((n + 1))
        done
        n=0
        for g in ${GROUP_MEMBERS[$r]}; do
            i=$(read_size_index "$g"); (( i < 0 )) && i=8
            n=$((n + 1))
            case $RULE in
                6x)        set_bars "$g" "$i" assigned ;;
                70vanilla) if (( n >= 2 )); then set_bars "$g" "$i" unassigned; else set_bars "$g" "$i" assigned; fi ;;
                budget)    if (( sum <= 40 * 1073741824 )); then set_bars "$g" "$i" assigned; else (( n >= 2 )) && set_bars "$g" "$i" unassigned || set_bars "$g" "$i" assigned; fi ;;
            esac
        done
        mark_group_reenumerated "$r"
    done
    REENUM_CALLS=$((REENUM_CALLS + 1))
    return 0
}

mkdir -p "$STATE_DIR"
# reset_regs: every register back at index 8 with the BARs assigned there and
# nothing dirty, the state a fresh boot on this firmware starts from.
reset_regs() {
    local g
    for g in "${GPUS[@]}"; do [[ -n ${GPU_REBAR_CTRL[$g]} ]] && write_size_index "$g" 8 >/dev/null; done
    for g in "${GPUS[@]}"; do set_bars "$g" 8 assigned; done
    GPU_DIRTY=(); GPU_DIRTY_FROM=()
}
# No real waiting in the fake kernel.
REMOVE_SETTLE=0; BIND_SETTLE=0; RESCAN_POLL=0; PROBE_POLL=0
log_info() { :; }; log_ok() { :; }; log_warn() { :; }; log_err() { :; }   # quiet

echo "discovery"
out=$( log_info() { echo "$*"; }; discover_gpus 2>&1 )
discover_gpus
assert_eq "gpu count" "${#GPUS[@]}" 7
assert_eq "radeon card refused" "$(grep -c '0000:71:00.0 .*not an amdgpu device, skipped' <<<"$out")" 1
assert_eq "radeon card never in GPUS" "$(printf '%s\n' "${GPUS[@]}" | grep -c 0000:71:00.0)" 0
assert_eq "radeon card is not ours" "$(is_gpu_function 0000:71:00.0 && echo yes || echo no)" no
assert_eq "alias table loaded" "${#DRIVER_ALIASES[@]}" 2
assert_eq "match: Vega II" "$(match_modalias 'pci:v00001002d000066A3sv*sd*bc*sc*i*' pci:v00001002d000066A3sv0000106Bsd00000203bc03sc00i00 && echo yes || echo no)" yes
assert_eq "match: class catch-all" "$(match_modalias 'pci:v00001002d*sv*sd*bc03sc00i00*' pci:v00001002d000066A3sv0000106Bsd00000203bc03sc00i00 && echo yes || echo no)" yes
assert_eq "no match: other device id" "$(match_modalias 'pci:v00001002d000066A3sv*sd*bc*sc*i*' pci:v00001002d00006779sv0000106Bsd00000203bc03sc00i00 && echo yes || echo no)" no
assert_eq "no match: other class" "$(match_modalias 'pci:v00001002d*sv*sd*bc03sc00i00*' pci:v00001002d000066A3sv0000106Bsd00000203bc04sc03i00 && echo yes || echo no)" no
out=$( ALIAS_FILE=/dev/null; log_warn() { echo "$*"; }; discover_gpus 2>&1; echo "gpus=${#GPUS[@]}" )
assert_eq "no alias table: warns and accepts every AMD display device" "$(grep -c 'No PCI alias table' <<<"$out"):$(grep -o 'gpus=[0-9]*' <<<"$out")" "1:gpus=8"
assert_eq "group count" "${#GROUPS_LIST[@]}" 5
assert_eq "root of 0e:00.0" "${GPU_ROOT[0000:0e:00.0]}" "0000:06:00.0"
assert_eq "root of 1b:00.0" "${GPU_ROOT[0000:1b:00.0]}" "0000:16:00.0"
assert_eq "root of single card" "${GPU_ROOT[0000:2b:00.0]}" "0000:2a:00.0"
assert_eq "root of impure card stops below the NVMe" "${GPU_ROOT[0000:53:00.0]}" "0000:52:00.0"
assert_eq "impure flag" "${GPU_ROOT_IMPURE[0000:53:00.0]}" 1
assert_eq "group 06 members" "${GROUP_MEMBERS[0000:06:00.0]}" "0000:0b:00.0 0000:0e:00.0"
assert_eq "rescan target for a root port" "${GROUP_RESCAN[0000:06:00.0]}" "$SYSFS/devices/pci0000:06/pci_bus/0000:06/rescan"
assert_eq "rescan target below a switch" "${GROUP_RESCAN[0000:52:00.0]}" "$SYSFS/bus/pci/devices/0000:51:00.0/rescan"
assert_eq "functions incl. audio" "${GPU_FUNCS[0000:0b:00.0]}" "0000:0b:00.0 0000:0b:00.1"
assert_eq "rebar ctrl offset" "${GPU_REBAR_CTRL[0000:0b:00.0]}" "208"
assert_eq "max index Vega" "${GPU_MAX_INDEX[0000:0b:00.0]}" 15
assert_eq "max index W5500X-like" "${GPU_MAX_INDEX[0000:2b:00.0]}" 13
assert_eq "baseline index" "${GPU_BASE_INDEX[0000:0b:00.0]}" 8
assert_eq "no-rebar GPU has no ctrl" "${GPU_REBAR_CTRL[0000:3b:00.0]}" ""
assert_eq "resizable count" "$(resizable_gpus | wc -l)" 6
assert_eq "mellanox is not ours" "$(is_gpu_function 0000:41:00.2 && echo yes || echo no)" no
assert_eq "audio is ours" "$(is_gpu_function 0000:0e:00.1 && echo yes || echo no)" yes
assert_eq "expected mem BARs" "$(gpu_mem_bars 0000:0b:00.0)" "0 2 5"
assert_eq "nothing unassigned at start" "$(failed_gpus | wc -l)" 0

echo "baseline: observed at first discovery, kept for the boot"
assert_eq "baseline recorded in STATE_DIR" "$(cat "$STATE_DIR/baseline-0000:0b:00.0")" 8
printf '0x0000000000000f00\n' > "$REG/0000:0b:00.0.0x208.l"       # a previous run left index 15
discover_gpus
assert_eq "later run: current index 15" "${GPU_CUR_INDEX[0000:0b:00.0]}" 15
assert_eq "later run: baseline still 8" "${GPU_BASE_INDEX[0000:0b:00.0]}" 8
rm -f "$STATE_DIR"/baseline-*                                        # a fresh boot whose firmware already enabled ReBAR
discover_gpus
assert_eq "firmware at 15: baseline 15, not the lowest supported 8" "${GPU_BASE_INDEX[0000:0b:00.0]}" 15
RULE=70vanilla; ACHIEVED_PLAN=none
negotiate 2>/dev/null
assert_eq "fallback never wrote 8 on the firmware-15 die" "$(read_size_index 0000:0b:00.0)" 15
assert_eq "fallback plan keeps it at 15" "${PLAN[0000:0b:00.0]}" 15
assert_eq "its sibling still falls back to its own baseline" "${PLAN[0000:0e:00.0]}" 8
rm -f "$STATE_DIR"/baseline-*; RULE=6x
reset_regs
discover_gpus
assert_eq "restored: baseline 8" "${GPU_BASE_INDEX[0000:0b:00.0]}" 8

echo "units"
assert_eq "index 15 is 32GiB" "$(size_index_to_human 15)" 32GiB
assert_eq "index 8 is 256MiB" "$(size_index_to_human 8)" 256MiB
assert_eq "human_bytes agrees with size_index_to_human" "$(human_bytes $(( 32 << 30 )))" "$(size_index_to_human 15)"
assert_eq "human_bytes 0 is unassigned" "$(human_bytes 0)" unassigned

echo "size register write"
write_size_index 0000:0b:00.0 15 && ok "write index 15" || fail "write index 15"
assert_eq "readback" "$(read_size_index 0000:0b:00.0)" 15
assert_eq "memory decode disabled during write" "$(cat "$REG/0000:0b:00.0.cmd_at_write")" "0x0405"
assert_eq "memory decode re-enabled after the write" "$(cat "$REG/0000:0b:00.0.COMMAND")" "0x0407"
assert_eq "written GPU is dirty until re-enumerated" "${GPU_DIRTY[0000:0b:00.0]:-}:${GPU_DIRTY_FROM[0000:0b:00.0]:-}" "1:8"
write_size_index 0000:0b:00.0 8 >/dev/null
assert_eq "writing the old index back makes it clean again" "${GPU_DIRTY[0000:0b:00.0]:-}" ""
printf '0x0405\n' > "$REG/0000:0b:00.0.COMMAND"
write_size_index 0000:0b:00.0 15 >/dev/null; write_size_index 0000:0b:00.0 8 >/dev/null
assert_eq "decode left off when it was off before" "$(cat "$REG/0000:0b:00.0.COMMAND")" "0x0405"
printf '0x0407\n' > "$REG/0000:0b:00.0.COMMAND"

echo "apply_plan partial failure: rollback, decode, no driver load"
GPU_DIRTY=(); GPU_DIRTY_FROM=(); REENUM_CALLS=0; MODPROBE_CALLS=0
plan_all_max
SETPCI_FAIL_WRITES="0000:0e:00.0"
try_plan all-max 2>/dev/null; rc=$?
assert_eq "plan fails" "$rc" 1
assert_eq "first die rolled back to 8" "$(read_size_index 0000:0b:00.0)" 8
assert_eq "failed die untouched" "$(read_size_index 0000:0e:00.0)" 8
assert_eq "nothing dirty after rollback" "${#GPU_DIRTY[@]}" 0
assert_eq "decode restored on the rolled-back die" "$(cat "$REG/0000:0b:00.0.COMMAND")" 0x0407
assert_eq "decode restored on the failed die" "$(cat "$REG/0000:0e:00.0.COMMAND")" 0x0407
assert_eq "no re-enumeration attempted" "$REENUM_CALLS" 0
guard_and_load_driver 2>/dev/null; rc=$?
assert_eq "clean after rollback: driver loads" "$rc:$MODPROBE_CALLS" "0:1"
unload_driver; MODPROBE_CALLS=0
SETPCI_FAIL_WRITES=""; SETPCI_FAIL_AFTER=$SETPCI_CTRL_WRITES; SETPCI_FAIL_AFTER=$((SETPCI_FAIL_AFTER + 1))   # one more write succeeds, then all fail
try_plan all-max 2>/dev/null; rc=$?
assert_eq "plan fails and rollback fails" "$rc" 1
assert_eq "first die left at 15" "$(read_size_index 0000:0b:00.0)" 15
assert_eq "first die dirty" "${GPU_DIRTY[0000:0b:00.0]:-}" 1
assert_eq "decode still restored on the dirty die" "$(cat "$REG/0000:0b:00.0.COMMAND")" 0x0407
out=$( log_err() { echo "$*"; }; guard_and_load_driver 2>&1 ); rc=$?
assert_eq "guard refuses to load while a GPU is dirty" "$rc:$MODPROBE_CALLS" "1:0"
assert_eq "guard says why" "$(grep -c 'not re-enumerated on: 0000:0b:00.0' <<<"$out")" 1
SETPCI_FAIL_AFTER=-1
rollback_dirty 2>/dev/null && ok "rollback succeeds once setpci works" || fail "rollback"
assert_eq "register restored" "$(read_size_index 0000:0b:00.0):${#GPU_DIRTY[@]}" "8:0"

echo "negotiation: 6.x-like kernel"
RULE=6x; REENUM_CALLS=0; ACHIEVED_PLAN=none
negotiate 2>/dev/null; rc=$?
assert_eq "rc" "$rc" 0
assert_eq "plan" "$ACHIEVED_PLAN" all-max
assert_eq "one re-enumeration" "$REENUM_CALLS" 1
assert_eq "Vega at 32G" "$(bar0_bytes 0000:0b:00.0)" $(( 32 << 30 ))
assert_eq "W5500X at 8G" "$(bar0_bytes 0000:2b:00.0)" $(( 8 << 30 ))
assert_eq "no failures" "$(failed_gpus | wc -l)" 0

echo "negotiation: fast path when already satisfied"
REENUM_CALLS=0; negotiate 2>/dev/null; assert_eq "no re-enumeration needed" "$REENUM_CALLS" 0; assert_eq "plan" "$ACHIEVED_PLAN" all-max

echo "negotiation: unpatched-7.0-like kernel"
reset_regs
RULE=70vanilla; REENUM_CALLS=0; ACHIEVED_PLAN=none
negotiate 2>/dev/null; rc=$?
assert_eq "rc" "$rc" 1
assert_eq "plan" "$ACHIEVED_PLAN" none
assert_eq "losers are the second dies" "$(failed_gpus | tr '\n' ' ')" "0000:0e:00.0 0000:1e:00.0 "
assert_eq "rounds tried: all-max, demote losers, demote their groups, baseline" "$REENUM_CALLS" 4
assert_eq "first dies were demoted to baseline in the end" "${PLAN[0000:0b:00.0]}" 8

echo "negotiation: size-limited window (demote-losers succeeds)"
reset_regs
RULE=budget; REENUM_CALLS=0; ACHIEVED_PLAN=none
negotiate 2>/dev/null; rc=$?
assert_eq "rc" "$rc" 0
assert_eq "plan" "$ACHIEVED_PLAN" demote-losers-2
assert_eq "two rounds" "$REENUM_CALLS" 2
assert_eq "first die large" "${PLAN[0000:0b:00.0]}" 15
assert_eq "second die baseline" "${PLAN[0000:0e:00.0]}" 8
assert_eq "single card untouched by the demotion" "${PLAN[0000:2b:00.0]}" 13
assert_eq "no failures" "$(failed_gpus | wc -l)" 0

echo "config: validation"
check_config() {   # check_config <label> <expected rc> <assignments...>; messages land in $T/cfg.out
    local label=$1 want=$2 rc; shift 2
    ( for a in "$@"; do eval "$a"; done; log_err() { echo "$*"; }; validate_config ) > "$T/cfg.out" 2>&1; rc=$?
    assert_eq "$label: rc" "$rc" "$want"
}
check_config "defaults valid" 0; assert_eq "defaults: no message" "$(cat "$T/cfg.out")" ""
check_config "MAX_SIZE_INDEX=44" 1 'MAX_SIZE_INDEX=44'; assert_eq "MAX_SIZE_INDEX message names variable and file" "$(grep -c "MAX_SIZE_INDEX='44' in /dev/null" "$T/cfg.out")" 1
check_config "MAX_SIZE_INDEX=abc" 1 'MAX_SIZE_INDEX=abc'
check_config "MAX_SIZE_INDEX=15 ok" 0 'MAX_SIZE_INDEX=15'
check_config "MAX_SIZE_INDEX=0 ok" 0 'MAX_SIZE_INDEX=0'
check_config "MODPROBE_TIMEOUT=0" 1 'MODPROBE_TIMEOUT=0'
check_config "PROBE_WAIT=-5" 1 'PROBE_WAIT=-5'
check_config "RESCAN_WAIT empty" 1 'RESCAN_WAIT='
check_config "MAX_ROUNDS=8x" 1 'MAX_ROUNDS=8x'
check_config "EXCLUDE_BDFS bad entry" 1 'EXCLUDE_BDFS="0000:0b:00.0 0b:00.0"'; assert_eq "EXCLUDE_BDFS message names the entry" "$(grep -c "EXCLUDE_BDFS entry '0b:00.0'" "$T/cfg.out")" 1
check_config "EXCLUDE_BDFS two good entries" 0 'EXCLUDE_BDFS="0000:0b:00.0 0000:1e:00.0"'
check_config "FORCE_PLAN=first-large" 1 'FORCE_PLAN=first-large'
check_config "FORCE_PLAN=baseline ok" 0 'FORCE_PLAN=baseline'
check_config "three faults" 1 'MAX_SIZE_INDEX=99' 'MAX_ROUNDS=0' 'FORCE_PLAN=x'; assert_eq "one line per fault" "$(wc -l < "$T/cfg.out")" 3
assert_eq "validation did not leak into the harness" "$MAX_SIZE_INDEX|$MAX_ROUNDS|$FORCE_PLAN" "|8|"

echo "config: cap and exclusion"
reset_regs
MAX_SIZE_INDEX=14; EXCLUDE_BDFS="0000:0e:00.0"
discover_gpus
assert_eq "excluded GPU dropped" "${#GPUS[@]}" 6
assert_eq "excluded GPU makes its root impure" "${GPU_ROOT[0000:0b:00.0]}" "0000:08:08.0"
assert_eq "cap applied" "${GPU_MAX_INDEX[0000:0b:00.0]}" 14
assert_eq "cap does not raise a small card" "${GPU_MAX_INDEX[0000:2b:00.0]}" 13
MAX_SIZE_INDEX=""; EXCLUDE_BDFS=""

echo "bind guard"
discover_gpus; reset_regs
set_bars 0000:1e:00.0 15 unassigned
assert_eq "unassigned BARs detected from sysfs" "$(bar_unassigned_list 0000:1e:00.0)" "0 2"
assert_eq "failed list" "$(failed_gpus | tr '\n' ' ')" "0000:1e:00.0 "
block_binding 0000:1e:00.0 && assert_eq "override written" "$(cat "${DEVPATH[0000:1e:00.0]}/driver_override")" none
clear_stale_overrides; assert_eq "override cleared" "$(cat "${DEVPATH[0000:1e:00.0]}/driver_override")" ""
echo "bind guard: losers fenced off, register reset for the next boot, driver loaded on the rest"
write_size_index 0000:1e:00.0 15 >/dev/null; mark_group_reenumerated 0000:16:00.0; MODPROBE_CALLS=0
guard_and_load_driver 2>/dev/null; rc=$?
assert_eq "guard rc" "$rc" 0
assert_eq "driver loaded once" "$MODPROBE_CALLS" 1
assert_eq "loser gets driver_override=none" "$(cat "${DEVPATH[0000:1e:00.0]}/driver_override")" none
assert_eq "loser not bound" "$([[ -L ${DEVPATH[0000:1e:00.0]}/driver ]] && echo bound || echo unbound)" unbound
assert_eq "sibling bound" "$([[ -L ${DEVPATH[0000:1b:00.0]}/driver ]] && echo bound || echo unbound)" bound
assert_eq "loser register reset to baseline for the next boot" "$(read_size_index 0000:1e:00.0)" 8
assert_eq "decode restored after the reset write" "$(cat "$REG/0000:1e:00.0.COMMAND")" 0x0407
assert_eq "one GPU blocked" "$GUARD_BLOCKED" 1
MODPROBE_RC=1; unload_driver; MODPROBE_CALLS=0
guard_and_load_driver 2>/dev/null; rc=$?
assert_eq "modprobe failure is reported" "$rc:$MODPROBE_CALLS" "1:1"
MODPROBE_RC=0; unload_driver; clear_stale_overrides; GPU_DIRTY=(); GPU_DIRTY_FROM=()

echo "verification: phase 3 with and without XGMI hives"
# v6.0 died here when no GPU exposed a hive (the attribute is a directory, so
# the per-GPU read was empty and "grep -v" exited 1 under errexit+pipefail).
# The script no longer uses errexit, but the summary must still come out.
set_bars 0000:1e:00.0 15 assigned
discover_gpus
for g in $(resizable_gpus); do set_bars "$g" "${GPU_MAX_INDEX[$g]}" assigned; done
for g in "${GPUS[@]}"; do ln -sfn "$SYSFS/bus/pci/drivers/amdgpu" "${DEVPATH[$g]}/driver"; done
run_phase3() {   # prints the log lines; rc is phase3_verify's
    ( log_info() { echo "$*"; }; log_ok() { echo "$*"; }; log_warn() { echo "$*"; }; log_err() { echo "$*"; }
      ACHIEVED_PLAN=all-max; phase3_verify ) 2>/dev/null
}
rm -f "$STATE_DIR/summary"
out=$(run_phase3); rc=$?
assert_eq "no hive anywhere: rc" "$rc" 0
assert_eq "no hive anywhere: reached SUCCESS" "$(grep -c 'SUCCESS:' <<<"$out")" 1
assert_eq "no hive anywhere: summary written" "$(sed -n 's/ kernel=.*//p' "$STATE_DIR/summary" 2>/dev/null)" "plan=all-max gpus=7 large=7 baseline=0 driverless=0 unassigned=0 missing=0 kfd_nodes=0"
for g in 0000:0b:00.0 0000:0e:00.0; do mkdir -p "${DEVPATH[$g]}/xgmi_hive_info"; echo 111 > "${DEVPATH[$g]}/xgmi_hive_info/xgmi_hive_id"; done
for g in 0000:1b:00.0 0000:1e:00.0; do mkdir -p "${DEVPATH[$g]}/xgmi_hive_info"; echo 222 > "${DEVPATH[$g]}/xgmi_hive_info/xgmi_hive_id"; done
out=$(run_phase3); rc=$?
assert_eq "two hives: rc" "$rc" 0
assert_eq "two hives: per-GPU hive id" "$(grep -c 'XGMI hive: 111' <<<"$out")" 2
assert_eq "two hives: summary" "$(sed -n 's/.*XGMI hives (id x members): //p' <<<"$out")" "111x2 222x2 "
for g in "${GPUS[@]}"; do rm -f "${DEVPATH[$g]}/driver"; done

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
