#!/bin/bash
#
# AMD GPU Resizable-BAR script v6.1 for Mac Pro 7,1 (any MPX card mix)
#
# v6.1 (2026-09-02): the Phase 3 XGMI hive summary read xgmi_hive_info as a
#   file; it is a directory (xgmi_hive_info/xgmi_hive_id), so every read was
#   empty and the "grep -v" in the summary pipeline exited 1. Under
#   "set -e -o pipefail" that killed the script after "KFD topology nodes",
#   before the Plan-achieved summary, with exit 1 (unit shown as failed even
#   though all GPUs were resized and bound). Read the id file; never let the
#   summary pipeline fail. Same hazard fixed for the KFD node count (find on a
#   missing topology dir) so a box without KFD still gets its summary.
#
# WHAT THIS DOES
#   Finds every AMD GPU in the machine, enlarges its BAR0 (the CPU-visible
#   VRAM aperture) to the largest size the device advertises, re-enumerates
#   only the PCI subtree(s) that contain GPUs so the kernel re-sizes the bridge
#   windows, and then loads amdgpu exactly once. If a die ends up without an
#   assigned BAR it is fenced off from the driver instead of handed to it.
#
# WHY v6 EXISTS
#   v5.x had the four Vega II Duo dies, their two root ports, the sixteen
#   bridges of the chains and the ReBAR register offset hard-coded. That was
#   fine for one fixed machine and nothing else. v6 discovers all of it at run
#   time so that:
#     * cards can be added, removed or moved between MPX bays (Radeon Pro
#       580X, W5500X, W5700X, W6600X, W6800X, W6800X Duo, W6900X, Vega II,
#       Vega II Duo, in any combination, with or without IFL bridges);
#     * other PCIe devices (Mellanox ConnectX-4 with SR-IOV VFs, InfiniBand
#       HCAs, PLX-based M.2 carriers, ...) can come and go and renumber the
#       bus without the script touching them: only subtrees that contain
#       nothing but GPU functions are ever unbound, removed or rescanned, and
#       the rescan is issued on that subtree's own root bus, never globally;
#     * every GPU gets the largest BAR it supports (8 GiB on a W5500X, 16 GiB
#       on a W5700X, 32 GiB on a Vega II / W6800X ...), and a GPU with no
#       Resizable BAR capability at all (580X) is simply left alone and still
#       gets its driver.
#
# THE HARD SAFETY RULE (unchanged since v5)
#   amdgpu must never be handed a GPU whose BAR0 (or any other memory BAR) is
#   unassigned. On such a device register reads return garbage, the driver
#   misdetects an SR-IOV virtual function ("MCBP is enabled") and waits
#   forever for a hypervisor mailbox ("trn=2 ACK should not assert!") in
#   uninterruptible D state. That wedges boot and cannot be killed. Every
#   code path that loads the driver goes through the bind guard first, and
#   modprobe runs under timeout(1).
#
# HOW THE NEGOTIATION WORKS
#   Plan 1  every resizable GPU at its own maximum size ("all-max").
#   Plan 2+ whichever GPUs lost their BAR in the previous attempt are demoted
#           to their baseline (firmware) size and the attempt is repeated; the
#           losers of that round are demoted too, and so on. This is what
#           v5's "first-large" plan did, derived from the actual result
#           instead of an assumption about which die loses.
#   Last    every GPU at baseline.
#   Every attempt is a full unbind / write ReBAR size / remove subtree /
#   rescan cycle, because writing a new size into the ReBAR control register
#   assigns nothing by itself: the bridge windows are only re-sized when the
#   kernel re-enumerates the subtree.
#
#   Why a die can lose at all: sibling bridge windows that each contain one
#   high-alignment BAR undersize their shared parent window on kernel 7.0
#   (upstream commit 3958bf16e2fe; fix in /root/0001-PCI-*.patch, verified
#   2026-09-02). Kernels 6.8 through 6.17 and a patched 7.0 fit everything on
#   plan 1. On an unpatched 7.0 nothing fits once the subtree has been
#   re-enumerated, not even baseline, and the bind guard is what keeps the
#   boot alive. See /root/AMDGPU-BAR-HANDOVER.md.
#
# MODES
#   (none)            interactive resize (asks y/N)
#   --force           non-interactive resize (systemd unit)
#   --diagnose-only   discover, report, change nothing
#   --dry-run         discover, report, and print the plans; change nothing
#   --revert          every GPU back to baseline, re-enumerate, load driver
#   --status          one-line machine-readable summary of the current state
#
# CONFIGURATION (optional, /etc/default/resize-gpu-bars, shell syntax)
#   MAX_SIZE_INDEX=15     cap every GPU at this ReBAR size index (2^(n+20) B;
#                         15 = 32 GiB, 14 = 16 GiB, 13 = 8 GiB). Empty = device max.
#   EXCLUDE_BDFS="0000:0b:00.0 ..."   GPUs to leave completely alone.
#   FORCE_PLAN=baseline   skip negotiation: all-max | baseline
#   MODPROBE_TIMEOUT=180  seconds (must stay below the unit's TimeoutStartSec)
#   PROBE_WAIT=60         seconds to wait for every unguarded GPU to bind
#
# REQUIREMENTS
#   root; kernel booted with pci=realloc; pciutils (lspci/setpci); util-linux
#   (flock); /etc/modprobe.d/amdgpu-blacklist.conf so amdgpu does not autoload
#   before this runs.
#
# EXIT CODES
#   0 everything at target and bound; 0 with warnings when a plan short of
#   all-max was needed; 1 on driver-load failure or a refused run.

# No errexit and no pipefail: both have silently killed this tool before
# (a "lsmod | grep -q" and an empty "grep -v" pipeline). Every return value
# that matters is checked explicitly instead.
set -u
shopt -s nullglob

# Sysfs strings and tool output are parsed byte-for-byte; a localised
# lspci or a user PATH with a wrapper setpci must not change the result.
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

VERSION="7.0"
DRIVER=amdgpu                  # the only driver this tool knows (scope decision)
LOCK_FILE=/run/lock/resize-gpu-bars.lock
SERVICE_NAME=resize-gpu-bars.service

# Test-only overrides (used by tests/test_resize_gpu_bars.sh, never in
# production): RESIZE_GPU_BARS_SYSFS points at a fake sysfs tree,
# RESIZE_GPU_BARS_STATE_DIR at a scratch runtime directory and
# RESIZE_GPU_BARS_CONFIG at a configuration file other than the system one;
# RESIZE_GPU_BARS_ALIAS_FILE replaces the driver's PCI alias table
# (modules.alias syntax, or one pattern per line).
SYSFS=${RESIZE_GPU_BARS_SYSFS:-/sys}
STATE_DIR=${RESIZE_GPU_BARS_STATE_DIR:-/run/resize-gpu-bars}
CONFIG_FILE=${RESIZE_GPU_BARS_CONFIG:-/etc/default/resize-gpu-bars}
ALIAS_FILE=${RESIZE_GPU_BARS_ALIAS_FILE:-}

# Defaults, overridable from CONFIG_FILE.
MAX_SIZE_INDEX=""
EXCLUDE_BDFS=""
FORCE_PLAN=""
MODPROBE_TIMEOUT=180
PROBE_WAIT=60
RESCAN_WAIT=30
MAX_ROUNDS=8

# Named delays (seconds). REMOVE_SETTLE lets the hot-unplug of a removed
# subtree finish before its bus is rescanned; BIND_SETTLE lets an unbind
# complete before the device's registers are written; RESCAN_POLL is the
# interval at which we look for removed devices to come back (and the grace
# period once they have, so late-appearing functions are seen too);
# PROBE_POLL is the interval at which driver binding is checked.
REMOVE_SETTLE=2
BIND_SETTLE=1
RESCAN_POLL=1
PROBE_POLL=1
# At verification a GPU that vanished is given REAPPEAR_WAIT seconds to come
# back (something else re-enumerated the bus under us) and REAPPEAR_SETTLE
# seconds after that for its driver to catch up.
REAPPEAR_WAIT=10
REAPPEAR_SETTLE=5

# Colour only for a person at a terminal (https://no-color.org): the journal
# is read by machines and by people with journalctl, not by a TTY.
if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi
# Every log entry is one plain-ASCII line; no blank lines, rules or boxes,
# so the journal stays greppable and small.
log_info()  { printf '%s[INFO]%s  %s\n' "$CYAN" "$NC" "$*" >&2; }
log_ok()    { printf '%s[OK]%s    %s\n' "$GREEN" "$NC" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_err()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
banner()    { printf '== %s ==\n' "$*" >&2; }

# validate_config -- checks the values that CONFIG_FILE may have set; prints
# one error line per bad variable, naming it and the file; returns 0 when
# everything is usable, 1 otherwise (the caller exits before touching anything)
validate_config() {
    local bad=0 v b
    if [[ -n $MAX_SIZE_INDEX ]] && ! { [[ $MAX_SIZE_INDEX =~ ^[0-9]+$ ]] && (( 10#$MAX_SIZE_INDEX <= 43 )); }; then
        log_err "MAX_SIZE_INDEX='$MAX_SIZE_INDEX' in $CONFIG_FILE: must be empty or an integer 0..43"; bad=1
    fi
    for v in MODPROBE_TIMEOUT PROBE_WAIT RESCAN_WAIT MAX_ROUNDS; do
        [[ ${!v} =~ ^[1-9][0-9]*$ ]] || { log_err "$v='${!v}' in $CONFIG_FILE: must be a positive integer"; bad=1; }
    done
    for b in $EXCLUDE_BDFS; do
        [[ $b =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || { log_err "EXCLUDE_BDFS entry '$b' in $CONFIG_FILE: must be a PCI address like 0000:0b:00.0"; bad=1; }
    done
    case $FORCE_PLAN in
        ""|all-max|baseline) ;;
        *) log_err "FORCE_PLAN='$FORCE_PLAN' in $CONFIG_FILE: must be empty, all-max or baseline"; bad=1 ;;
    esac
    return "$bad"
}
# load_config -- sources CONFIG_FILE when present and validates the result;
# returns validate_config's status
load_config() {
    if [[ -r $CONFIG_FILE ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" || { log_err "Cannot source $CONFIG_FILE"; return 1; }
    fi
    validate_config
}
load_config || exit 1

# ---------------------------------------------------------------------------
# Discovery state (filled by discover_gpus). All keyed by GPU BDF.
# ---------------------------------------------------------------------------
GPUS=()                       # ordered list of GPU BDFs (domain:bus:dev.fn)
declare -A GPU_NAME           # lspci short name
declare -A GPU_FUNCS          # all functions of the same device (GPU + audio ...)
declare -A GPU_REBAR_CAP      # ReBAR ext-cap offset (hex) or "" if none
declare -A GPU_REBAR_CTRL     # control register offset for BAR0 (hex) or ""
declare -A GPU_SUPPORTED      # bitmask of supported size indices for BAR0
declare -A GPU_MAX_INDEX      # target size index (device max, capped)
declare -A GPU_BASE_INDEX     # baseline (firmware) size index
declare -A GPU_CUR_INDEX      # size index currently programmed
declare -A GPU_ROOT           # re-enumeration root bridge BDF
declare -A GPU_ROOT_IMPURE    # "1" if the subtree above the root has non-GPU devices
GROUPS_LIST=()                # unique re-enumeration roots, in order
declare -A GROUP_MEMBERS      # root -> space-separated GPU BDFs
declare -A GROUP_RESCAN       # root -> sysfs rescan file to use
declare -A GROUP_CHAIN        # root -> bridges between root and the GPUs
ACTIVE_GROUPS=()              # groups the current plan attempt has to touch
ACHIEVED_PLAN="none"
LAST_LOSERS=""                # GPUs that lost a BAR in the last rejected plan
GUARD_BLOCKED=0               # GPUs the bind guard fenced off in this run
# Register state we own between a ReBAR write and the re-enumeration that
# makes the kernel see it. A "dirty" GPU decodes a different aperture size
# than the kernel assigned; handing it to a driver is what the bind guard
# exists to prevent, so the guard refuses while any GPU is dirty.
declare -A GPU_DIRTY          # "1" while a written size index has not been re-enumerated
declare -A GPU_DIRTY_FROM     # size index the kernel's current assignment corresponds to
declare -A GPU_DECODE_OFF     # "1" while we hold memory decode disabled around a write

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
sysdev() { echo "$SYSFS/bus/pci/devices/$1"; }
# sysfs_write PATH VALUE -- writes VALUE to a sysfs attribute; returns the
# write's status (the test harness replaces this to emulate the kernel)
sysfs_write() { [[ -w $1 ]] && echo "$2" > "$1"; } 2>/dev/null
# The module directory in sysfs, not "lsmod | grep": no pipeline to misread.
driver_loaded() { [[ -d $SYSFS/module/$DRIVER ]]; }
attr()   { cat "$(sysdev "$1")/$2" 2>/dev/null || true; }
is_bridge() { [[ $(attr "$1" class) == 0x0604* ]]; }
present()   { [[ -e $(sysdev "$1") ]]; }

# bytes_to_human BYTES -- prints BYTES in binary units ("32GiB", "256MiB");
# exact multiples are printed exactly, anything else via numfmt
bytes_to_human() {
    local b=$1
    if   (( b >= 1073741824 && b % 1073741824 == 0 )); then echo "$((b / 1073741824))GiB"
    elif (( b >= 1048576 && b % 1048576 == 0 ));       then echo "$((b / 1048576))MiB"
    elif (( b >= 1024 && b % 1024 == 0 ));             then echo "$((b / 1024))KiB"
    else numfmt --to=iec-i --suffix=B "$b" 2>/dev/null || echo "${b}B"; fi
}
# size_index_to_human INDEX -- prints the BAR size a ReBAR size index stands
# for (2^(INDEX+20) bytes), "n/a" for -1
size_index_to_human() {
    local idx=$1
    (( idx < 0 )) && { echo "n/a"; return; }
    bytes_to_human $(( 1 << (idx + 20) ))
}
# human_bytes BYTES -- like bytes_to_human, but 0 is "unassigned"
human_bytes() {
    (( $1 == 0 )) && { echo "unassigned"; return; }
    bytes_to_human "$1"
}
highest_bit() {   # highest set bit index of a hex bitmask, -1 if zero
    local v=$(( 16#${1#0x} )) i
    for (( i = 63; i >= 0; i-- )); do (( (v >> i) & 1 )) && { echo "$i"; return; }; done
    echo -1
}

# Parent device of a PCI function (BDF), or "" when its parent is a root bus.
pci_parent() {
    local p
    p=$(basename "$(dirname "$(readlink -f "$(sysdev "$1")")")")
    [[ $p =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && echo "$p" || echo ""
}
# Ancestors of a BDF from nearest to farthest (bridges only).
pci_ancestors() {
    local cur; cur=$(pci_parent "$1")
    while [[ -n $cur ]]; do echo "$cur"; cur=$(pci_parent "$cur"); done
}
# All endpoint (non-bridge) functions below a bridge.
subtree_endpoints() {
    find "$(readlink -f "$(sysdev "$1")")" -mindepth 1 -maxdepth 12 -type d \
        -regex '.*/[0-9a-f]+:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]\.[0-7]$' -printf '%f\n' 2>/dev/null \
        | while read -r b; do is_bridge "$b" || echo "$b"; done
}

# ---------------------------------------------------------------------------
# BAR state from sysfs. lspci omits an unassigned region entirely (seen on the
# failing 7.0 boot: no "Region 0" line at all for the BAR-less die), and the
# sysfs resource line for it is all zeros, so "unassigned" can only be judged
# against a list of BARs the device is known to have. That list is: BAR0
# (every GPU has one), every BAR with a resourceN_resize attribute, and every
# memory BAR seen with an address earlier in this boot (persisted in STATE_DIR
# because firmware assigns everything at POST, before any re-enumeration).
# ---------------------------------------------------------------------------
gpu_mem_bars() {   # prints the expected memory BAR indices of a GPU, sorted
    local g=$1 i line flags set="0" f=$STATE_DIR/bars-$1
    for i in 0 1 2 3 4 5; do
        line=$(sed -n "$((i + 1))p" "$(sysdev "$g")/resource" 2>/dev/null) || continue
        flags=${line##* }
        [[ -n $flags ]] && (( 16#${flags#0x} & 0x200 )) && set+=" $i"
        [[ -e $(sysdev "$g")/resource${i}_resize ]] && set+=" $i"
    done
    mkdir -p "$STATE_DIR"
    [[ -r $f ]] && set+=" $(cat "$f")"
    set=$(tr ' ' '\n' <<<"$set" | grep -E '^[0-5]$' | sort -un | tr '\n' ' ')
    echo "${set% }" > "$f"
    echo "${set% }"
}
bar_unassigned_list() {   # expected memory BARs whose start address is zero
    local g=$1 i line start out=""
    for i in $(gpu_mem_bars "$g"); do
        line=$(sed -n "$((i + 1))p" "$(sysdev "$g")/resource" 2>/dev/null) || { out+="$i "; continue; }
        start=${line%% *}
        [[ -z $start || $start == 0x0000000000000000 ]] && out+="$i "
    done
    echo "${out% }"
}
bar0_bytes() {
    local line start end
    line=$(sed -n '1p' "$(sysdev "$1")/resource" 2>/dev/null) || { echo 0; return; }
    start=${line%% *}; end=$(awk '{print $2}' <<<"$line")
    [[ -z $start || $start == 0x0000000000000000 ]] && { echo 0; return; }
    echo $(( 16#${end#0x} - 16#${start#0x} + 1 ))
}

# ---------------------------------------------------------------------------
# Resizable BAR capability access (setpci; the kernel's resourceN_resize
# write would try to re-assign in place, which is exactly what fails on the
# shared-window kernels, so we program the register and re-enumerate).
# ---------------------------------------------------------------------------
find_rebar_cap() {   # prints the ext-cap offset (hex, no 0x) or nothing
    lspci -s "$1" -vv 2>/dev/null | sed -n 's/.*Capabilities: \[\([0-9a-f]*\) v[0-9]*\] Physical Resizable BAR.*/\1/p' | head -1
}
# Walk the ReBAR entries and print the control register offset for BAR 0.
find_rebar_ctrl_for_bar0() {
    local bdf=$1 cap=$2 n i ctrl val
    ctrl=$(printf '%x' $(( 16#$cap + 8 )))
    val=$(setpci -s "$bdf" "0x$ctrl.l" 2>/dev/null) || return 1
    n=$(( (16#$val >> 5) & 0x7 )); (( n == 0 )) && n=1
    for (( i = 0; i < n; i++ )); do
        ctrl=$(printf '%x' $(( 16#$cap + 8 + 8 * i )))
        val=$(setpci -s "$bdf" "0x$ctrl.l" 2>/dev/null) || return 1
        if (( (16#$val & 0x7) == 0 )); then echo "$ctrl"; return 0; fi
    done
    return 1
}
# Supported-size bitmask from the capability register (kernels without the
# resourceN_resize sysfs attribute): cap bits 31:4 = indices 0..27, control
# bits 31:16 = indices 28..43.
read_supported_mask() {
    local bdf=$1 ctrl=${GPU_REBAR_CTRL[$1]:-} capreg cval
    [[ -n $ctrl ]] || { echo 0; return; }
    capreg=$(setpci -s "$bdf" "0x$(printf '%x' $(( 16#$ctrl - 4 ))).l" 2>/dev/null) || { echo 0; return; }
    cval=$(setpci -s "$bdf" "0x$ctrl.l" 2>/dev/null) || cval=0
    printf '%016x\n' $(( ((16#$capreg >> 4) & 0x0FFFFFFF) | (((16#$cval >> 16) & 0xFFFF) << 28) ))
}
read_size_index() {   # current BAR0 size index, -1 when unknown
    local bdf=$1 ctrl=${GPU_REBAR_CTRL[$1]:-} val
    [[ -n $ctrl ]] || { echo -1; return; }
    val=$(setpci -s "$bdf" "0x$ctrl.l" 2>/dev/null) || { echo -1; return; }
    echo $(( (16#$val >> 8) & 0x3F ))
}
# restore_decode BDF -- re-enables memory decode (COMMAND bit 1) if a size
# write disabled it; the kernel only touches that bit on a driver probe, and
# a fenced-off or rolled-back GPU never gets one; returns 0 when decode is on
restore_decode() {
    local bdf=$1 cmd
    [[ -n ${GPU_DECODE_OFF[$bdf]:-} ]] || return 0
    cmd=$(setpci -s "$bdf" COMMAND 2>/dev/null) || return 1
    setpci -s "$bdf" COMMAND="$(printf '%04x' $(( 16#$cmd | 0x2 )))" 2>/dev/null || return 1
    unset "GPU_DECODE_OFF[$bdf]"
    return 0
}
# write_size_index BDF INDEX -- programs BAR0's size index with memory decode
# held off for the write (PCIe 7.8.6) and restored afterwards, whatever the
# outcome; keeps GPU_DIRTY in step with what the register now says relative
# to the kernel's assignment; returns 0 when the readback equals INDEX
write_size_index() {
    local bdf=$1 want=$2 ctrl=${GPU_REBAR_CTRL[$1]:-} val new cmd have now rc=1
    [[ -n $ctrl ]] || return 1
    have=$(read_size_index "$bdf"); (( have >= 0 )) || return 1
    cmd=$(setpci -s "$bdf" COMMAND 2>/dev/null) || return 1
    if (( 16#$cmd & 0x2 )); then
        GPU_DECODE_OFF[$bdf]=1
        setpci -s "$bdf" COMMAND="$(printf '%04x' $(( 16#$cmd & ~0x2 )))" 2>/dev/null \
            || { unset "GPU_DECODE_OFF[$bdf]"; return 1; }
    fi
    if val=$(setpci -s "$bdf" "0x$ctrl.l" 2>/dev/null); then
        new=$(printf '%08x' $(( (16#$val & ~0x3F00) | (want << 8) )))
        setpci -s "$bdf" "0x$ctrl.l=$new" 2>/dev/null
    fi
    now=$(read_size_index "$bdf")
    [[ $now == "$want" ]] && rc=0
    if [[ -z ${GPU_DIRTY[$bdf]:-} && $now != "$have" ]]; then
        GPU_DIRTY[$bdf]=1; GPU_DIRTY_FROM[$bdf]=$have
    elif [[ -n ${GPU_DIRTY[$bdf]:-} && $now == "${GPU_DIRTY_FROM[$bdf]}" ]]; then
        unset "GPU_DIRTY[$bdf]" "GPU_DIRTY_FROM[$bdf]"
    fi
    restore_decode "$bdf" || log_warn "  $bdf: could not re-enable memory decode"
    return "$rc"
}
# rollback_dirty -- writes every dirty GPU's register back to the index the
# kernel's assignment corresponds to; returns 0 when no GPU is left dirty
rollback_dirty() {
    local g from left=0
    for g in "${!GPU_DIRTY[@]}"; do
        present "$g" || continue
        from=${GPU_DIRTY_FROM[$g]}
        if write_size_index "$g" "$from"; then
            log_info "  $g size index rolled back to $from"
        else
            log_err "  $g could not be rolled back; its register no longer matches the kernel's BAR assignment"; left=1
        fi
    done
    return "$left"
}
# mark_group_reenumerated ROOT -- forgets the dirty state of ROOT's members:
# once the kernel has removed and re-enumerated them its assignment is fresh
mark_group_reenumerated() {
    local g
    for g in ${GROUP_MEMBERS[$1]:-}; do unset "GPU_DIRTY[$g]" "GPU_DIRTY_FROM[$g]"; done
}

# ---------------------------------------------------------------------------
# Driver alias table: vendor 0x1002 + class 0x03 also matches cards the
# radeon driver owns, which are out of scope; the modalias check keeps them
# out of GPUS so they are never unbound, resized or guarded.
# ---------------------------------------------------------------------------
DRIVER_ALIASES=()
# load_driver_aliases -- fills DRIVER_ALIASES with $DRIVER's PCI alias
# patterns from ALIAS_FILE (tests), modinfo, or modules.alias; returns 0 when
# at least one pattern was found
load_driver_aliases() {
    local line src=""
    DRIVER_ALIASES=()
    if [[ -n $ALIAS_FILE ]]; then
        src=$ALIAS_FILE
    elif modinfo -F alias "$DRIVER" >/dev/null 2>&1; then
        src=$(mktemp -p "${TMPDIR:-/tmp}" "resize-gpu-bars.XXXXXX") || return 1
        modinfo -F alias "$DRIVER" 2>/dev/null | sed 's/^/alias /; s/$/ '"$DRIVER"'/' > "$src"
        local tmp=$src
    else
        src=/lib/modules/$(uname -r)/modules.alias
    fi
    while read -r line; do
        case $line in
            alias\ pci:*\ "$DRIVER") line=${line#alias }; DRIVER_ALIASES+=("${line% *}") ;;
            alias\ *) ;;
            pci:*) DRIVER_ALIASES+=("$line") ;;
        esac
    done < "$src" 2>/dev/null
    [[ -n ${tmp:-} ]] && rm -f "$tmp"
    (( ${#DRIVER_ALIASES[@]} > 0 ))
}
# match_modalias PATTERN MODALIAS -- true when MODALIAS matches the alias
# PATTERN (the table's "*" wildcards are shell globs)
match_modalias() {
    # shellcheck disable=SC2053  # unquoted on purpose: $1 is a glob pattern
    [[ $2 == $1 ]]
}
# driver_claims BDF -- true when $DRIVER's alias table matches the device's
# modalias; also true, with a warning, when no table could be read at all
driver_claims() {
    local modalias pat
    (( ${#DRIVER_ALIASES[@]} > 0 )) || return 0
    modalias=$(attr "$1" modalias)
    [[ -n $modalias ]] || return 0   # kernels without the attribute: cannot tell, accept
    for pat in "${DRIVER_ALIASES[@]}"; do match_modalias "$pat" "$modalias" && return 0; done
    return 1
}

# observed_baseline BDF CURRENT -- prints the size index the device had when
# it was first seen this boot, recording CURRENT in STATE_DIR on the first
# call. "Baseline" is what firmware programmed, not the smallest supported
# size: firmware that already enables ReBAR must never be shrunk on fallback.
# STATE_DIR is on /run, so the record lives exactly one boot.
observed_baseline() {
    local bdf=$1 cur=$2 f=$STATE_DIR/baseline-$1 saved
    if [[ -r $f ]] && saved=$(<"$f") && [[ $saved =~ ^[0-9]+$ ]]; then echo "$saved"; return 0; fi
    (( cur >= 0 )) || { echo "$cur"; return 0; }   # register unreadable: nothing to record
    if ! { mkdir -p "$STATE_DIR" && echo "$cur" > "$f"; } 2>/dev/null; then
        log_warn "  Could not record the baseline size of $bdf in $STATE_DIR"
    fi
    echo "$cur"
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
discover_gpus() {
    local d bdf vendor class
    # Start from nothing: a second discovery in the same process (status
    # after a run, the test harness) must not inherit stale members.
    GPUS=(); GROUPS_LIST=()
    GPU_NAME=(); GPU_FUNCS=(); GPU_REBAR_CAP=(); GPU_REBAR_CTRL=(); GPU_SUPPORTED=()
    GPU_MAX_INDEX=(); GPU_BASE_INDEX=(); GPU_CUR_INDEX=(); GPU_ROOT=(); GPU_ROOT_IMPURE=()
    GROUP_MEMBERS=(); GROUP_RESCAN=(); GROUP_CHAIN=()
    load_driver_aliases || log_warn "No PCI alias table for $DRIVER (module not installed for $(uname -r)?); accepting every AMD display device"
    for d in "$SYSFS"/bus/pci/devices/*; do
        bdf=$(basename "$d")
        vendor=$(attr "$bdf" vendor); class=$(attr "$bdf" class)
        [[ $vendor == 0x1002 && $class == 0x03* ]] || continue
        if ! driver_claims "$bdf"; then
            log_info "  $bdf $(lspci -mm -s "$bdf" 2>/dev/null | awk -F'"' '{print $6}'): not an $DRIVER device, skipped"; continue
        fi
        if [[ " $EXCLUDE_BDFS " == *" $bdf "* ]]; then
            log_info "  $bdf excluded by configuration"; continue
        fi
        GPUS+=("$bdf")
    done
    (( ${#GPUS[@]} > 0 )) || return 0

    local funcs anc root impure eps e
    for bdf in "${GPUS[@]}"; do
        GPU_NAME[$bdf]=$(lspci -mm -s "$bdf" 2>/dev/null | awk -F'"' '{print $6}')
        funcs=""
        for d in "$(sysdev "$bdf")"/../"${bdf%.*}".*; do funcs+="$(basename "$(readlink -f "$d")") "; done
        GPU_FUNCS[$bdf]=${funcs% }

        GPU_REBAR_CAP[$bdf]=$(find_rebar_cap "$bdf")
        GPU_REBAR_CTRL[$bdf]=""
        GPU_SUPPORTED[$bdf]=0
        GPU_MAX_INDEX[$bdf]=-1; GPU_BASE_INDEX[$bdf]=-1; GPU_CUR_INDEX[$bdf]=-1
        if [[ -n ${GPU_REBAR_CAP[$bdf]} ]]; then
            GPU_REBAR_CTRL[$bdf]=$(find_rebar_ctrl_for_bar0 "$bdf" "${GPU_REBAR_CAP[$bdf]}")
        fi
        if [[ -n ${GPU_REBAR_CTRL[$bdf]} ]]; then
            GPU_SUPPORTED[$bdf]=$(attr "$bdf" resource0_resize)
            [[ -n ${GPU_SUPPORTED[$bdf]} ]] || GPU_SUPPORTED[$bdf]=$(read_supported_mask "$bdf")
            GPU_CUR_INDEX[$bdf]=$(read_size_index "$bdf")
            local hi
            hi=$(highest_bit "${GPU_SUPPORTED[$bdf]}")
            if [[ -n $MAX_SIZE_INDEX ]] && (( hi > MAX_SIZE_INDEX )); then hi=$MAX_SIZE_INDEX; fi
            GPU_MAX_INDEX[$bdf]=$hi
            GPU_BASE_INDEX[$bdf]=$(observed_baseline "$bdf" "${GPU_CUR_INDEX[$bdf]}")
        fi

    done

    # Second pass (needs every GPU's function list): re-enumeration root =
    # highest ancestor whose subtree holds nothing but our GPU functions.
    for bdf in "${GPUS[@]}"; do
        root=""; impure=0
        while read -r anc; do
            [[ -n $anc ]] || continue
            eps=$(subtree_endpoints "$anc")
            local ok=1
            for e in $eps; do
                if ! is_gpu_function "$e"; then ok=0; break; fi
            done
            if (( ok )); then root=$anc; else impure=1; break; fi
        done < <(pci_ancestors "$bdf")
        GPU_ROOT[$bdf]=$root
        GPU_ROOT_IMPURE[$bdf]=$impure
    done

    # Group by root.
    local r members
    for bdf in "${GPUS[@]}"; do
        r=${GPU_ROOT[$bdf]}
        [[ -n $r ]] || r="none:$bdf"
        if [[ -z ${GROUP_MEMBERS[$r]:-} ]]; then GROUPS_LIST+=("$r"); GROUP_MEMBERS[$r]=$bdf
        else GROUP_MEMBERS[$r]+=" $bdf"; fi
    done
    for r in "${GROUPS_LIST[@]}"; do
        [[ $r == none:* ]] && { GROUP_RESCAN[$r]=""; GROUP_CHAIN[$r]=""; continue; }
        local parent bus
        parent=$(pci_parent "$r")
        if [[ -n $parent ]]; then
            GROUP_RESCAN[$r]="$(sysdev "$parent")/rescan"
        else
            bus=${r%:*}                    # domain:bus of the root port
            GROUP_RESCAN[$r]="$SYSFS/devices/pci${bus}/pci_bus/${bus}/rescan"
        fi
        members=""
        for bdf in ${GROUP_MEMBERS[$r]}; do
            for anc in $(pci_ancestors "$bdf"); do
                [[ " $members " == *" $anc "* ]] || members+="$anc "
                [[ $anc == "$r" ]] && break
            done
        done
        GROUP_CHAIN[$r]=$(tr ' ' '\n' <<<"${members% }" | sort | tr '\n' ' ')
    done
    return 0
}

# A function is "ours" if it is a listed GPU or another function of one.
is_gpu_function() {
    local f=$1 g
    for g in "${GPUS[@]}"; do
        [[ " ${GPU_FUNCS[$g]:-$g} " == *" $f "* ]] && return 0
    done
    return 1
}

resizable_gpus() { local g; for g in "${GPUS[@]}"; do [[ -n ${GPU_REBAR_CTRL[$g]} ]] && echo "$g"; done; }

# GPUs with any unassigned memory BAR (these must never meet the driver).
failed_gpus() {
    local g
    for g in "${GPUS[@]}"; do
        present "$g" || { echo "$g"; continue; }
        [[ -n $(bar_unassigned_list "$g") ]] && echo "$g"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
report_discovery() {
    local g r b
    log_info "GPUs found: ${#GPUS[@]}   re-enumeration groups: ${#GROUPS_LIST[@]}"
    for r in "${GROUPS_LIST[@]}"; do
        if [[ $r == none:* ]]; then
            log_warn "Group (no removable root): ${GROUP_MEMBERS[$r]} sits directly on a root bus; only in-place BAR writes are possible for it."
        else
            log_info "Group root $r  (rescan via ${GROUP_RESCAN[$r]})"
            for b in ${GROUP_CHAIN[$r]}; do
                local pref
                pref=$(lspci -s "$b" -vv 2>/dev/null | sed -n 's/.*Prefetchable memory behind bridge: *//p' | head -1)
                log_info "    bridge $b  pref window: ${pref:-none}"
            done
        fi
        for g in ${GROUP_MEMBERS[$r]}; do
            log_info "  GPU $g  ${GPU_NAME[$g]}"
            log_info "    functions: ${GPU_FUNCS[$g]}"
            if [[ -n ${GPU_REBAR_CTRL[$g]} ]]; then
                log_info "    ReBAR cap @0x${GPU_REBAR_CAP[$g]} ctrl @0x${GPU_REBAR_CTRL[$g]}  supported mask ${GPU_SUPPORTED[$g]}"
                log_info "    size index: current $(size_index_to_human "${GPU_CUR_INDEX[$g]}") (${GPU_CUR_INDEX[$g]})  baseline $(size_index_to_human "${GPU_BASE_INDEX[$g]}")  target $(size_index_to_human "${GPU_MAX_INDEX[$g]}")"
            elif [[ -n ${GPU_REBAR_CAP[$g]} ]]; then
                log_warn "    ReBAR capability present but no BAR0 entry found; will not resize"
            else
                log_info "    no Resizable BAR capability; will not resize (driver only)"
            fi
            log_info "    BAR0: $(human_bytes "$(bar0_bytes "$g")")   unassigned regions: $(bar_unassigned_list "$g")"
            local drv ovr
            drv=$(basename "$(readlink "$(sysdev "$g")/driver" 2>/dev/null)" 2>/dev/null || true)
            ovr=$(attr "$g" driver_override)
            [[ -n $drv ]] && log_info "    driver: $drv"
            [[ -n $ovr && $ovr != "(null)" ]] && log_warn "    driver_override='$ovr' (binding blocked by a previous run)"
            (( ${GPU_ROOT_IMPURE[$g]} )) && log_warn "    subtree above $r has non-GPU devices; parent window cannot be re-sized"
        done
    done
    # Everything else on the bus that we promise not to touch.
    local others=""
    for d in "$SYSFS"/bus/pci/devices/*; do
        b=$(basename "$d"); is_bridge "$b" && continue
        is_gpu_function "$b" && continue
        [[ -n $(pci_parent "$b") ]] || continue   # skip CPU/PCH functions on root buses
        others+="$b($(lspci -mm -s "$b" 2>/dev/null | awk -F'"' '{print $6}' | cut -c1-28)) "
    done
    [[ -n $others ]] && log_info "Other slot devices (never touched): $others"
    return 0
}

report_bars() {
    local g
    for g in "${GPUS[@]}"; do
        present "$g" || { log_info "    $g  (not present)"; continue; }
        log_info "    $g  BAR0=$(human_bytes "$(bar0_bytes "$g")")  unassigned: $(bar_unassigned_list "$g")"
    done
}

# ---------------------------------------------------------------------------
# Plan machinery: a plan is an associative array bdf -> size index
# ---------------------------------------------------------------------------
declare -A PLAN
plan_all_max()  { local g; for g in $(resizable_gpus); do PLAN[$g]=${GPU_MAX_INDEX[$g]}; done; }
plan_baseline() { local g; for g in $(resizable_gpus); do PLAN[$g]=${GPU_BASE_INDEX[$g]}; done; }
plan_is_baseline() { local g; for g in $(resizable_gpus); do [[ ${PLAN[$g]} == "${GPU_BASE_INDEX[$g]}" ]] || return 1; done; }
describe_plan() { local g out=""; for g in $(resizable_gpus); do out+="  $g=$(size_index_to_human "${PLAN[$g]}")"; done; echo "$out"; }

# group_needs_work ROOT -- true when the current plan has to touch ROOT: a
# member is missing, has an unassigned memory BAR, or is not at the planned
# size (register and assigned BAR0 both)
group_needs_work() {
    local g
    for g in ${GROUP_MEMBERS[$1]}; do
        present "$g" || return 0
        [[ -n $(bar_unassigned_list "$g") ]] && return 0
        [[ -n ${GPU_REBAR_CTRL[$g]} ]] || continue
        [[ $(read_size_index "$g") == "${PLAN[$g]}" ]] || return 0
        (( $(bar0_bytes "$g") == (1 << (PLAN[$g] + 20)) )) || return 0
    done
    return 1
}
# plan_active_groups -- fills ACTIVE_GROUPS with the groups the current plan
# has to touch; returns 0 when there is at least one
plan_active_groups() {
    local r
    ACTIVE_GROUPS=()
    for r in "${GROUPS_LIST[@]}"; do group_needs_work "$r" && ACTIVE_GROUPS+=("$r"); done
    (( ${#ACTIVE_GROUPS[@]} > 0 ))
}

# unbind_group_functions ROOT -- unbinds every driver from every function
# (audio included) of ROOT's member GPUs, because the subtree is about to be
# removed or the GPU resized in place; counts the unbinds in UNBOUND
UNBOUND=0
unbind_group_functions() {
    local g f drv
    for g in ${GROUP_MEMBERS[$1]}; do
        for f in ${GPU_FUNCS[$g]}; do
            [[ -L $(sysdev "$f")/driver ]] || continue
            drv=$(basename "$(readlink "$(sysdev "$f")/driver")")
            if sysfs_write "$SYSFS/bus/pci/drivers/$drv/unbind" "$f"; then
                log_ok "  Unbound $drv from $f"; UNBOUND=$((UNBOUND + 1))
            else
                log_warn "  Could not unbind $drv from $f"
            fi
        done
    done
    return 0
}
# unbind_active_groups -- unbinds only the GPUs the plan changes and their
# group members; a GPU that keeps its size (no ReBAR, excluded, already
# there) keeps its driver and its audio
unbind_active_groups() {
    local r
    UNBOUND=0
    for r in "${ACTIVE_GROUPS[@]}"; do unbind_group_functions "$r"; done
    (( UNBOUND > 0 )) && sleep "$BIND_SETTLE"
    return 0
}

# remove_group ROOT -- removes ROOT's subtree from the kernel's view so the
# rescan re-assigns it from scratch; returns the write's status
remove_group() {
    local r=$1
    if ! present "$r"; then log_warn "  $r not present (already removed?)"; return 0; fi
    if sysfs_write "$(sysdev "$r")/remove" 1; then
        log_ok "  Removed subtree under $r"; mark_group_reenumerated "$r"; return 0
    fi
    log_err "  FAILED to remove $r"
    return 1
}
# rescan_group ROOT -- rescans the bus above ROOT so the kernel re-enumerates
# its subtree; never the global /sys/bus/pci/rescan, which would re-probe
# every hot-pluggable device on the machine; returns the write's status
rescan_group() {
    local r=$1 f=${GROUP_RESCAN[$1]}
    if [[ ! -w $f ]]; then log_err "  $f is not writable; cannot re-enumerate $r"; return 1; fi
    log_info "  Rescanning $f"
    if ! sysfs_write "$f" 1; then log_err "  Rescan via $f failed"; return 1; fi
    return 0
}
# wait_for_gpus BDF... -- waits up to RESCAN_WAIT seconds for every listed
# GPU to be present again; returns 0 when all are
wait_for_gpus() {
    local waited found g want=$#
    for (( waited = 1; waited <= RESCAN_WAIT; waited++ )); do
        found=0
        for g in "$@"; do present "$g" && found=$((found + 1)); done
        if (( found == want )); then
            log_ok "  All $want GPU devices present after ${waited}s."
            sleep "$RESCAN_POLL"
            return 0
        fi
        sleep "$RESCAN_POLL"
    done
    log_err "  Only $found/$want GPU devices reappeared after ${RESCAN_WAIT}s."
    # A GPU that came back on a different BDF would look like "missing"; say so.
    local now=0 d
    for d in "$SYSFS"/bus/pci/devices/*; do [[ $(attr "$(basename "$d")" vendor) == 0x1002 && $(attr "$(basename "$d")" class) == 0x03* ]] && now=$((now + 1)); done
    (( now != ${#GPUS[@]} )) || log_warn "  $now AMD GPUs are present under different addresses; re-run the script."
    return 1
}
# reenumerate -- removes and rescans every active switched group and waits
# for its GPUs; a group whose remove or rescan fails is left alone (its GPUs
# become this attempt's losers); returns 0 when every group came back
reenumerate() {
    local r g rc=0 rescan=() expected=()
    for r in "${ACTIVE_GROUPS[@]}"; do
        [[ $r == none:* ]] && continue
        if remove_group "$r"; then rescan+=("$r"); else rc=1; fi
    done
    (( ${#rescan[@]} > 0 )) || return "$rc"
    sleep "$REMOVE_SETTLE"
    for r in "${rescan[@]}"; do
        if rescan_group "$r"; then
            for g in ${GROUP_MEMBERS[$r]}; do expected+=("$g"); done
        else
            rc=1; log_err "  GPUs of $r stay absent until the next boot: ${GROUP_MEMBERS[$r]}"
        fi
    done
    if (( ${#expected[@]} > 0 )); then wait_for_gpus "${expected[@]}" || rc=1; fi
    return "$rc"
}

apply_plan() {
    local g want have
    for g in $(resizable_gpus); do
        want=${PLAN[$g]}; have=$(read_size_index "$g")
        if [[ $have == "$want" ]]; then
            log_info "  $g already at index $want ($(size_index_to_human "$want"))"
        elif write_size_index "$g" "$want"; then
            log_ok "  $g size index $have -> $want ($(size_index_to_human "$want"))"
        else
            log_err "  $g FAILED to program size index $want"
            rollback_dirty || log_err "  A GPU is left with a size the kernel has not seen; the driver load will be refused"
            return 1
        fi
    done
    return 0
}

# try_plan NAME -- unbinds, programs and re-enumerates the groups the plan
# changes, then verifies every GPU's BARs; returns 0 when every memory BAR
# is assigned at the planned size, 1 otherwise with the losers in LAST_LOSERS
try_plan() {
    local name=$1
    log_info "Applying plan '$name':$(describe_plan)"
    if ! plan_active_groups; then
        log_ok "Plan '$name' is already in effect (BARs assigned at the requested sizes); no re-enumeration needed."
        return 0
    fi
    log_info "  Groups to re-enumerate: ${ACTIVE_GROUPS[*]}"
    unbind_active_groups
    apply_plan || return 1
    log_info "  Re-enumerating GPU subtrees so the kernel re-sizes the bridge windows..."
    reenumerate || log_warn "  Re-enumeration incomplete; verifying what is there"
    log_info "  Resulting BAR assignment:"; report_bars
    local bad g; bad=$(failed_gpus | tr '\n' ' ')
    # A BAR that is assigned but not at the requested size means the ReBAR
    # write did not take or the subtree was not really re-enumerated.
    for g in $(resizable_gpus); do
        [[ " $bad " == *" $g "* ]] && continue
        if (( $(bar0_bytes "$g") != (1 << (PLAN[$g] + 20)) )); then
            log_warn "  $g BAR0 is $(human_bytes "$(bar0_bytes "$g")"), not the requested $(size_index_to_human "${PLAN[$g]}")"
            bad+="$g "
        fi
    done
    if [[ -z ${bad// /} ]]; then
        log_ok "Plan '$name' verified: all ${#GPUS[@]} GPUs have every memory BAR assigned."
        return 0
    fi
    log_warn "Plan '$name' rejected: unassigned BARs on: $bad"
    LAST_LOSERS=$bad
    return 1
}

negotiate() {
    local round=1 g name
    LAST_LOSERS=""
    if (( $(resizable_gpus | wc -l) == 0 )); then
        log_info "No resizable GPU present; nothing to negotiate."
        ACHIEVED_PLAN="none-needed"
        [[ -z $(failed_gpus) ]]
        return
    fi
    case "$FORCE_PLAN" in
        baseline) plan_baseline; try_plan baseline && { ACHIEVED_PLAN=baseline; return 0; }; ACHIEVED_PLAN=none; return 1 ;;
        all-max)  plan_all_max;  try_plan all-max  && { ACHIEVED_PLAN=all-max;  return 0; }; ACHIEVED_PLAN=none; return 1 ;;
    esac

    plan_all_max
    name="all-max"
    while :; do
        if try_plan "$name"; then ACHIEVED_PLAN=$name; return 0; fi
        if plan_is_baseline; then break; fi
        (( round >= MAX_ROUNDS )) && { log_warn "Giving up after $round rounds."; break; }
        # Demote the losers; if a loser is not resizable (or already at
        # baseline) demote everything in its group instead.
        local demoted=0 r m
        for g in $LAST_LOSERS; do
            if [[ -n ${GPU_REBAR_CTRL[$g]:-} && ${PLAN[$g]} != "${GPU_BASE_INDEX[$g]}" ]]; then
                PLAN[$g]=${GPU_BASE_INDEX[$g]}; demoted=$((demoted + 1))
            else
                r=${GPU_ROOT[$g]:-}
                for m in ${GROUP_MEMBERS[$r]:-}; do
                    [[ -n ${GPU_REBAR_CTRL[$m]:-} && ${PLAN[$m]} != "${GPU_BASE_INDEX[$m]}" ]] || continue
                    PLAN[$m]=${GPU_BASE_INDEX[$m]}; demoted=$((demoted + 1))
                done
            fi
        done
        if (( demoted == 0 )); then plan_baseline; name="baseline"; else round=$((round + 1)); name="demote-losers-$round"; plan_is_baseline && name="baseline"; fi
        log_info "Falling back: $name"
    done
    ACHIEVED_PLAN="none"
    log_err "Every plan failed to produce a fully-assigned BAR layout."
    return 1
}

# ---------------------------------------------------------------------------
# Bind guard and driver load
# ---------------------------------------------------------------------------
block_binding()   { [[ -w $(sysdev "$1")/driver_override ]] && echo none > "$(sysdev "$1")/driver_override" 2>/dev/null; }
unblock_binding() { [[ -w $(sysdev "$1")/driver_override ]] && echo "" > "$(sysdev "$1")/driver_override" 2>/dev/null || true; }
clear_stale_overrides() { local g f; for g in "${GPUS[@]}"; do for f in ${GPU_FUNCS[$g]}; do unblock_binding "$f"; done; done; }

wait_for_probe() {
    local deadline=$(( SECONDS + PROBE_WAIT )) g pending stable=0 last=-1 nodes
    while (( SECONDS < deadline )); do
        pending=0
        for g in "${GPUS[@]}"; do
            [[ $(attr "$g" driver_override) == none ]] && continue
            [[ -L $(sysdev "$g")/driver ]] || pending=$((pending + 1))
        done
        nodes=$(find "$SYSFS"/class/kfd/kfd/topology/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if (( pending == 0 )); then
            # Hive/KFD topology keeps changing for a few seconds after bind.
            if (( nodes == last )); then stable=$((stable + 1)); else stable=0; last=$nodes; fi
            (( stable >= 3 )) && { log_ok "  All unguarded GPUs bound; KFD topology stable ($nodes nodes)."; return 0; }
        fi
        sleep "$PROBE_POLL"
    done
    log_warn "  Probe wait of ${PROBE_WAIT}s elapsed with $pending GPU(s) still unbound."
    return 0
}

guard_and_load_driver() {
    local g bad blocked=0 dirty=""
    bad=$(failed_gpus)
    # A GPU whose register was written this run but never re-enumerated
    # would be probed against a stale BAR assignment; only a fenced-off GPU
    # (in $bad, blocked below) may be left that way.
    for g in "${!GPU_DIRTY[@]}"; do
        present "$g" || continue
        [[ " ${bad//$'\n'/ } " == *" $g "* ]] || dirty+="$g "
    done
    if [[ -n $dirty ]]; then
        log_err "Size index written this run but not re-enumerated on: $dirty"
        log_err "The kernel's BAR assignment no longer matches the register; refusing to load $DRIVER. Reboot to recover."
        return 1
    fi
    if [[ -n $bad ]]; then
        log_warn "Some GPUs still have an unassigned memory BAR. $DRIVER misdetects such a device as an SR-IOV virtual function"
        log_warn "and hangs forever in the mailbox handshake, so binding is being blocked on those devices."
        for g in $bad; do
            if block_binding "$g"; then
                log_ok "  Blocked driver binding on $g (driver_override=none)"; blocked=$((blocked + 1))
            else
                log_err "  COULD NOT block binding on $g; refusing to load $DRIVER."
                log_err "  Loading it now would hang the boot. Reboot to recover."; return 1
            fi
            if [[ -n ${GPU_REBAR_CTRL[$g]:-} ]]; then
                if write_size_index "$g" "${GPU_BASE_INDEX[$g]}"; then
                    log_info "  Reset $g size index to ${GPU_BASE_INDEX[$g]} for the next boot"
                else
                    log_warn "  Could not reset the size index on $g"
                fi
            fi
        done
    fi
    GUARD_BLOCKED=$blocked

    if driver_loaded; then
        log_info "$DRIVER already loaded; re-binding the unguarded GPUs..."
        for g in "${GPUS[@]}"; do
            [[ $(attr "$g" driver_override) == none ]] && continue
            [[ -L $(sysdev "$g")/driver ]] || echo "$g" > "$SYSFS/bus/pci/drivers/$DRIVER/bind" 2>/dev/null || true
        done
    else
        log_info "Loading $DRIVER (timeout ${MODPROBE_TIMEOUT}s so boot can never wedge)..."
        if timeout --signal=TERM --kill-after=30 "$MODPROBE_TIMEOUT" modprobe "$DRIVER"; then
            log_ok "$DRIVER loaded."
        else
            local rc=$?
            if (( rc == 124 || rc == 137 )); then
                log_err "modprobe $DRIVER TIMED OUT after ${MODPROBE_TIMEOUT}s."
                log_err "A GPU is very likely stuck in the SR-IOV mailbox path."
                log_err "Check: dmesg | grep 'trn=2 ACK'; recovery needs a reboot."
            else
                log_err "modprobe $DRIVER failed (exit $rc)."
            fi
            return 1
        fi
    fi
    log_info "Waiting for driver probe and XGMI/KFD topology (up to ${PROBE_WAIT}s)..."
    wait_for_probe
    if (( blocked > 0 )); then
        log_warn "$blocked GPU(s) are present but intentionally driverless."
        log_warn "Clear with: echo > /sys/bus/pci/devices/<bdf>/driver_override"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
preflight() {
    local t
    (( EUID == 0 )) || { log_err "This script must be run as root."; exit 1; }
    for t in lspci setpci flock numfmt; do command -v "$t" >/dev/null || { log_err "$t not found (apt install pciutils util-linux coreutils)"; exit 1; }; done
    if grep -qw "pci=realloc" /proc/cmdline; then log_ok "Kernel booted with pci=realloc"
    else log_err "Kernel NOT booted with pci=realloc, required for bridge window sizing."; exit 1; fi
    log_info "Kernel $(uname -r); script v$VERSION; config ${CONFIG_FILE}$( [[ -r $CONFIG_FILE ]] || echo ' (absent, defaults)')"
    if driver_loaded; then
        log_warn "$DRIVER is already loaded; GPUs will be unbound before the resize (double-init path)."
        log_info "Tip: /etc/modprobe.d/amdgpu-blacklist.conf avoids this."
    else
        log_ok "$DRIVER not loaded (blacklist active); clean single-init path."
    fi
}

phase1_diagnose() {
    banner "Phase 1: Discovery and diagnostics"
    preflight
    discover_gpus
    if (( ${#GPUS[@]} == 0 )); then
        log_warn "No AMD GPU found on the PCI bus. Nothing to do."
        return 1
    fi
    report_discovery
}

phase2_resize() {
    banner "Phase 2: BAR resize (plan negotiation)"
    log_info "Clearing stale driver_override values..."; clear_stale_overrides
    negotiate
}

phase3_verify() {
    banner "Phase 3: Verification"
    local g large=0 baseline=0 driverless=0 missing=0 unassigned=0 total=${#GPUS[@]} drv b0 target vis
    for g in "${GPUS[@]}"; do
        log_info "GPU $g  ${GPU_NAME[$g]:-}"
        if ! present "$g"; then
            local waited=0
            while ! present "$g" && (( waited < REAPPEAR_WAIT )); do sleep 1; waited=$((waited + 1)); done
            if ! present "$g"; then log_err "  Device not present!"; missing=$((missing + 1)); continue; fi
            log_warn "  Device reappeared after ${waited}s: something else re-enumerated the bus during this run."
            sleep "$REAPPEAR_SETTLE"
        fi
        b0=$(bar0_bytes "$g")
        log_info "  BAR0: $(human_bytes "$b0")"
        if [[ -n $(bar_unassigned_list "$g") ]]; then
            log_err "  UNASSIGNED memory BAR(s): $(bar_unassigned_list "$g")"; unassigned=$((unassigned + 1))
        elif [[ -n ${GPU_REBAR_CTRL[$g]:-} ]]; then
            target=$(( 1 << (GPU_MAX_INDEX[$g] + 20) ))
            if (( b0 >= target )); then log_ok "  BAR0 is at target ($(size_index_to_human "${GPU_MAX_INDEX[$g]}"))."; large=$((large + 1))
            else log_info "  BAR0 below target $(size_index_to_human "${GPU_MAX_INDEX[$g]}")."; baseline=$((baseline + 1)); fi
        else
            log_info "  Not resizable; BAR0 as assigned by firmware."; large=$((large + 1))
        fi
        if [[ -L $(sysdev "$g")/driver ]]; then
            drv=$(basename "$(readlink "$(sysdev "$g")/driver")"); log_ok "  Bound to driver: $drv"
        else
            log_warn "  No driver bound."; driverless=$((driverless + 1))
        fi
        vis=$(attr "$g" mem_info_vis_vram_total); vis=${vis:-0}
        (( vis > 0 )) && log_ok "  Visible VRAM: $(bytes_to_human "$vis")"
        local hive; hive=$(attr "$g" xgmi_hive_info/xgmi_hive_id)
        [[ -n $hive ]] && log_info "  XGMI hive: $hive"
    done
    log_info "KFD topology:"
    if [[ -c /dev/kfd ]]; then log_ok "  /dev/kfd present ($(stat -c '%a %U:%G' /dev/kfd 2>/dev/null || echo unknown))"
    else log_warn "  /dev/kfd not found; KFD did not initialize."; fi
    # find exits 1 when KFD never initialized (no topology dir): wc still
    # prints 0, which is the answer we want.
    local nodes; nodes=$(find "$SYSFS"/class/kfd/kfd/topology/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    log_info "  KFD topology nodes: $nodes (includes 1 CPU node)"
    # The hive id lives in a directory (xgmi_hive_info/xgmi_hive_id); GPUs
    # without a hive contribute an empty line that awk 'NF' drops.
    local hives; hives=$(for g in "${GPUS[@]}"; do attr "$g" xgmi_hive_info/xgmi_hive_id; done | awk 'NF' | sort | uniq -c | awk '{printf "%sx%s ", $2, $1}')
    [[ -n $hives ]] && log_info "  XGMI hives (id x members): $hives"
    log_info "Summary:"
    log_info "  Plan achieved : ${ACHIEVED_PLAN}"
    log_info "  Large BARs    : ${large} / ${total}"
    log_info "  Baseline BARs : ${baseline} / ${total}"
    log_info "  Driverless    : ${driverless} / ${total}"
    mkdir -p "$STATE_DIR"
    printf 'plan=%s gpus=%d large=%d baseline=%d driverless=%d unassigned=%d missing=%d kfd_nodes=%d kernel=%s\n' \
        "$ACHIEVED_PLAN" "$total" "$large" "$baseline" "$driverless" "$unassigned" "$missing" "$nodes" "$(uname -r)" > "$STATE_DIR/summary" \
        || log_warn "Could not write $STATE_DIR/summary"
    (( driverless > 0 )) && log_warn "Some GPUs have no driver. See notes above."
    (( missing > 0 ))    && log_err "$missing GPU(s) were missing from sysfs at verification time."
    if (( large == total && driverless == 0 && missing == 0 && unassigned == 0 )); then
        log_ok "SUCCESS: all ${total} GPUs have their target BAR size and a driver."
    elif (( unassigned > 0 )); then
        log_info "Some GPUs could not get a BAR at any size: this kernel's PCI allocator undersizes the shared bridge window."
        log_info "See the kernel compatibility section of the README for kernels known to fit everything."
    fi
    return 0
}

do_revert() {
    banner "Revert: every GPU back to baseline"
    clear_stale_overrides
    plan_baseline
    if try_plan baseline; then ACHIEVED_PLAN=baseline; else ACHIEVED_PLAN=none; log_warn "Baseline re-enumeration incomplete."; fi
    banner "Loading driver"
    guard_and_load_driver || true
}

print_status() {
    discover_gpus 2>/dev/null
    local g out="gpus=${#GPUS[@]}"
    for g in "${GPUS[@]}"; do
        out+=" $g:bar0=$(human_bytes "$(bar0_bytes "$g")"),idx=${GPU_CUR_INDEX[$g]},max=${GPU_MAX_INDEX[$g]},drv=$(basename "$(readlink "$(sysdev "$g")/driver" 2>/dev/null)" 2>/dev/null || echo none),root=${GPU_ROOT[$g]:-none}"
    done
    [[ -r $STATE_DIR/summary ]] && out+=" last: $(cat "$STATE_DIR/summary")"
    echo "$out"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="${1:---resize}"
    case "$mode" in
        --status) print_status; exit 0 ;;
        --help|-h) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -80; exit 0 ;;
        --resize|--force|--diagnose-only|--dry-run|--revert) ;;
        *) log_err "Unknown mode '$mode' (try --help)"; exit 2 ;;
    esac

    log_info "resize-gpu-bars $VERSION: discovery, plan negotiation, bind guard, bounded driver load"

    # One instance at a time; a manual run under the boot-time service would
    # re-enumerate the bus underneath it and make both reports wrong.
    mkdir -p "$(dirname "$LOCK_FILE")"
    if ! exec 9>"$LOCK_FILE"; then log_err "Cannot open $LOCK_FILE"; exit 1; fi
    if ! flock -n 9; then log_err "Another instance holds $LOCK_FILE. Watch it: journalctl -u $SERVICE_NAME -b -f"; exit 1; fi

    phase1_diagnose || exit 0

    case "$mode" in
        --diagnose-only) log_info "Diagnostics complete. No changes made."; exit 0 ;;
        --dry-run)
            log_info "Plans that would be tried:"
            plan_all_max;  log_info "  all-max:$(describe_plan)"
            log_info "  then: demote whichever GPUs lose their BAR, round by round"
            plan_baseline; log_info "  baseline:$(describe_plan)"
            log_info "Dry run complete. No changes made."; exit 0 ;;
        --revert) do_revert; phase3_verify; exit 0 ;;
    esac

    log_warn "This will temporarily kill all GPU display output."
    log_warn "If running over SSH, the session should survive."
    if [[ $mode == --force ]]; then
        log_info "Non-interactive mode (--force). Proceeding..."
    else
        if [[ $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true) == activating ]]; then
            log_err "$SERVICE_NAME is still running. Watch it: journalctl -u $SERVICE_NAME -b -f"; exit 1
        fi
        read -rp "Proceed? (y/N): " confirm
        [[ ${confirm,,} == y ]] || { log_info "Aborted."; exit 0; }
    fi

    local resize_rc=0
    phase2_resize || resize_rc=$?
    (( resize_rc != 0 )) && log_warn "No plan produced a clean layout; continuing with the bind guard."

    banner "Loading driver"
    local load_rc=0
    guard_and_load_driver || load_rc=$?

    phase3_verify
    if (( load_rc != 0 )); then log_err "Driver load did not complete cleanly. See messages above."; exit 1; fi
    log_info "Done. Verify with: rocminfo / rocm-smi"
    exit 0
}

# Run main only when executed, so a test harness can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
