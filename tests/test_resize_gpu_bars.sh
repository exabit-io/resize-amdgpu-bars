#!/bin/bash
# test_resize_gpu_bars.sh — offline tests for resize_gpu_bars.sh v6.
#
# Builds a fake sysfs tree (two Vega II Duo cards on separate root ports, a
# W5500X-like single GPU without a PLX chain, a 580X-like GPU without ReBAR,
# a Thunderbolt controller and a Mellanox NIC with SR-IOV VFs), stubs lspci /
# setpci, and replaces the kernel's re-enumeration with a rule so the plan
# negotiation can be exercised for kernels that behave like 6.x, like an
# unpatched 7.0, and like a size-limited window. Nothing real is touched.
#
#   ./test_resize_gpu_bars.sh path/to/resize_gpu_bars.sh
set -uo pipefail
SCRIPT=${1:?usage: $0 path/to/resize_gpu_bars.sh}
[[ -r $SCRIPT ]] || { echo "$0: cannot read $SCRIPT" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/rgb-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
export RESIZE_GPU_BARS_SYSFS=$T/sys RESIZE_GPU_BARS_STATE_DIR=$T/run RESIZE_GPU_BARS_CONFIG=/dev/null
SYSFS=$RESIZE_GPU_BARS_SYSFS
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
    DEVPATH[$bdf]=$path
    ln -sfn "$path" "$SYSFS/bus/pci/devices/$bdf"
    if [[ $kind == gpu ]]; then
        echo 000000000000ff00 > "$path/resource0_resize"; echo 0000000000000004 > "$path/resource2_resize"
        printf '0x0000000000000800\n' > "$REG/$bdf.0x208.l"    # index 8 (256 MB), BAR0 entry
        printf '0x0407\n' > "$REG/$bdf.COMMAND"
        set_bars "$bdf" 8 assigned
    elif [[ $kind == gpu-norebar ]]; then
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
    # Thunderbolt NHI and a Mellanox NIC with two VFs — must never be touched
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
setpci() {
    local bdf="" arg
    while (( $# )); do arg=$1; shift; case $arg in -s) bdf=$1; shift ;; *=*) echo "${arg#*=}" | sed 's/^/0x/' > "$REG/$bdf.${arg%%=*}" ;; *) [[ -r $REG/$bdf.$arg ]] && sed 's/^0x//' "$REG/$bdf.$arg" || return 1 ;; esac; done
}
export -f lspci setpci 2>/dev/null

# ---------------------------------------------------------------------------
build_tree
# shellcheck disable=SC1090
source "$SCRIPT"; set +e
# The kernel: apply a RULE to decide which GPUs get their BARs after rescan.
#   6x        every GPU fits at any size
#   70vanilla in every group with 2+ GPUs the second GPU never fits
#   budget    a group fits only if the sum of its BAR0 sizes is <= 40 GB
RULE=6x
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
    done
    REENUM_CALLS=$((REENUM_CALLS + 1))
    return 0
}

mkdir -p "$STATE_DIR"
# No real waiting in the fake kernel.
REMOVE_SETTLE=0; BIND_SETTLE=0; RESCAN_POLL=0; PROBE_POLL=0
log_info() { :; }; log_ok() { :; }; log_warn() { :; }; log_err() { :; }   # quiet

echo "discovery"
discover_gpus
assert_eq "gpu count" "${#GPUS[@]}" 7
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

echo "units"
assert_eq "index 15 is 32GiB" "$(size_index_to_human 15)" 32GiB
assert_eq "index 8 is 256MiB" "$(size_index_to_human 8)" 256MiB
assert_eq "human_bytes agrees with size_index_to_human" "$(human_bytes $(( 32 << 30 )))" "$(size_index_to_human 15)"
assert_eq "human_bytes 0 is unassigned" "$(human_bytes 0)" unassigned

echo "size register write"
write_size_index 0000:0b:00.0 15 && ok "write index 15" || fail "write index 15"
assert_eq "readback" "$(read_size_index 0000:0b:00.0)" 15
assert_eq "memory decode disabled during write" "$(cat "$REG/0000:0b:00.0.COMMAND")" "0x0405"
write_size_index 0000:0b:00.0 8 >/dev/null

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
for g in "${GPUS[@]}"; do [[ -n ${GPU_REBAR_CTRL[$g]} ]] && write_size_index "$g" 8 >/dev/null; done
RULE=70vanilla; REENUM_CALLS=0; ACHIEVED_PLAN=none
negotiate 2>/dev/null; rc=$?
assert_eq "rc" "$rc" 1
assert_eq "plan" "$ACHIEVED_PLAN" none
assert_eq "losers are the second dies" "$(failed_gpus | tr '\n' ' ')" "0000:0e:00.0 0000:1e:00.0 "
assert_eq "rounds tried: all-max, demote losers, demote their groups, baseline" "$REENUM_CALLS" 4
assert_eq "first dies were demoted to baseline in the end" "${PLAN[0000:0b:00.0]}" 8

echo "negotiation: size-limited window (demote-losers succeeds)"
for g in "${GPUS[@]}"; do [[ -n ${GPU_REBAR_CTRL[$g]} ]] && write_size_index "$g" 8 >/dev/null; done
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
for g in "${GPUS[@]}"; do [[ -n ${GPU_REBAR_CTRL[$g]} ]] && write_size_index "$g" 8 >/dev/null; done
MAX_SIZE_INDEX=14; EXCLUDE_BDFS="0000:0e:00.0"
discover_gpus
assert_eq "excluded GPU dropped" "${#GPUS[@]}" 6
assert_eq "excluded GPU makes its root impure" "${GPU_ROOT[0000:0b:00.0]}" "0000:08:08.0"
assert_eq "cap applied" "${GPU_MAX_INDEX[0000:0b:00.0]}" 14
assert_eq "cap does not raise a small card" "${GPU_MAX_INDEX[0000:2b:00.0]}" 13
MAX_SIZE_INDEX=""; EXCLUDE_BDFS=""

echo "bind guard"
discover_gpus
set_bars 0000:1e:00.0 15 unassigned
assert_eq "unassigned BARs detected from sysfs" "$(bar_unassigned_list 0000:1e:00.0)" "0 2"
assert_eq "failed list" "$(failed_gpus | tr '\n' ' ')" "0000:1e:00.0 "
block_binding 0000:1e:00.0 && assert_eq "override written" "$(cat "${DEVPATH[0000:1e:00.0]}/driver_override")" none
clear_stale_overrides; assert_eq "override cleared" "$(cat "${DEVPATH[0000:1e:00.0]}/driver_override")" ""

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
