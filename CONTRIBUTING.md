# Contributing

resize-gpu-bars is a root tool that rewrites PCI configuration space and
re-enumerates buses on a running machine. The bar for a change is
correspondingly high: every change runs through the offline harness, every
behavioural change is boot-tested on real hardware before it is called
supported, and no card is listed as supported that has not been booted.

## Layout

| path | what |
|---|---|
| `resize-gpu-bars` | the tool, one bash script |
| `tests/test_resize_gpu_bars.sh` | the offline harness |
| `tests/style/` | the style fixture (`t02_style.sh`, `lib.sh`, the masker) |
| `man/*.scd` | scdoc sources for the manual pages |
| `conf/default/` | the shipped `/etc/default` files |
| `debian/` | packaging |

## Running the harness

```
bash tests/test_resize_gpu_bars.sh ./resize-gpu-bars
```

The script path is a required argument. The harness builds a fake sysfs
tree under a temporary directory (two dual-die cards on separate root
ports, a single GPU without a switch, a GPU without a Resizable BAR
capability, a Thunderbolt controller and a NIC with SR-IOV virtual
functions), stubs `lspci`, `setpci`, `modprobe` and `timeout`, and replaces
the kernel's re-enumeration with a rule so that the negotiation can be
exercised for kernels that behave like 6.x, like an unpatched 7.0, and like
a size-limited window. It points the tool at the fake tree with
`RESIZE_GPU_BARS_SYSFS` and `RESIZE_GPU_BARS_STATE_DIR`; nothing real is
touched, and it does not need root. Every check prints `ok` or `FAIL`; the
exit status is the number of failures.

A change to the tool's behaviour comes with a harness case that fails
without the change and passes with it. The cases added for 7.0 (partial
`apply_plan` failure, observed baseline, root-bus GPU via
`resource0_resize`, decode restored, non-writable rescan, non-resizable GPU
left bound, non-amdgpu card refused, configuration validation, trap
cleanup, exit codes, `status` line format, the guard path) are the pattern
to follow.

## Style

The project follows Dave Eddy's bash style guide, with two deliberate
deviations: `#!/bin/bash` (Debian policy for packaged scripts) and the GNU
tools `find -printf`, `numfmt` and `readlink -f` (the tool reads Linux sysfs
and cannot run anywhere else). The style fixture under `tests/style/` is
vendored from the guide's test suite with the shebang check adjusted for
that decision, and runs as part of `dh_auto_test`:

```
bash tests/style/t02_style.sh resize-gpu-bars
shellcheck -S style resize-gpu-bars tests/test_resize_gpu_bars.sh
```

Both must be clean. A shellcheck note that is wrong for this code is
disabled on the line with a reason, never globally. In short: tabs for
indentation, 80 columns at tab stop 8, single quotes for literal strings,
`printf` rather than `echo -e`, parameter expansion rather than `basename`,
`dirname`, `cat` or `cut` where it will do, `while read -r` over `for x in
$(fn)`, lowercase for mutable globals and uppercase for constants, `set -u`
without `set -e`, and every return value checked explicitly. Function
comments take one form: `# name ARGS - purpose; prints X; returns Y`. They
explain why, never the session in which the code was written.

Documentation is plain Markdown wrapped at 80 columns, without emoji. The
manual pages are the authoritative reference; the README is the tour.
Shipped files carry no home-directory paths, dated notes or machine names:
history goes to `CHANGELOG.md`, kernel facts to the README.

## Boot testing

The harness models the kernel; it cannot replace it. A change to discovery,
the negotiation, the re-enumeration, the guard or the driver load is not
done until it has been booted on real hardware behind a switch, and a card
is not listed as supported in the README until someone has booted it and
sent the results. That includes hardware in tier 2 and tier 3 of the support
table: "applicable by design" stays that way until a boot says otherwise.

A boot test is a full power-off boot with the package installed and the
unit enabled, on the kernel being claimed. What to run once the machine is
up and the unit reports finished:

```
systemctl status resize-gpu-bars.service    # active (exited), status 0
journalctl -u resize-gpu-bars -b            # the run, start to finish
journalctl -k -b | grep -E "can't assign|Call Trace|BUG:|trn=2 ACK"
sudo resize-gpu-bars check                  # the verdict line
sudo resize-gpu-bars status
sudo resize-gpu-bars diagnose
rocminfo | grep -c gfx                      # with ROCm installed
```

What the journal must contain, in this order:

- `Kernel booted with pci=realloc`
- `amdgpu not loaded (blacklist active)`: the single-init path, not the
  unbind path
- one `GPUs found:` line with the expected count and group count
- `Plan 'all-max' verified` on the first attempt, with no `rejected` line
  before it, unless the test is deliberately of a fallback
- `amdgpu loaded`
- `All unguarded GPUs bound; KFD topology stable`
- `Plan achieved : all-max`, `Driverless : 0 / N`
- `SUCCESS: all N GPUs have their target BAR size and a driver`

The kernel log must have no `can't assign`, no `Call Trace`, no `BUG:`, no
hung task, and none of the SR-IOV mailbox messages (`MCBP is enabled`,
`trn=2 ACK`).

The `check` line must read, for N GPUs of which all are resizable:

```
verdict=WORKS  plan=all-max  large=N/N  driverless=0/N
```

with `traces=0`, `rejected=0`, one `windows=` entry per re-enumeration root
at the size the kernel chose, `bar0=` at the target size for every GPU, and
for cards with XGMI one hive with every die in it. A reference run on two
Vega II Duo modules reads `verdict=WORKS plan=all-max large=4/4
driverless=0/4`, `windows=0000:06:00.0=128G 0000:16:00.0=128G` on a
patched 7.0 kernel (96G on 6.x), `kfd=5`, `xgmi_hives=1`.

A boot test of the guard is the same procedure on an unpatched 7.0 kernel:
the run must end with exit status 2, `verdict=FAILS (bind guard held)`,
`driverless=` equal to the number of second dies, every guarded die present
in `lspci` with `driver_override` reading `none`, the other dies bound, and
no mailbox message anywhere in the kernel log. A hang, a trace, a different
set of losers, or a die that came back at the wrong size is new information:
capture both journals before rebooting.

Send the `check` line, the two journals and the `diagnose` output with the
pull request or the report. State the card, the slot or bay, the machine,
the kernel and the bootloader.

## Commits and pull requests

One logical change per commit, with the reason in the message. A
formatting-only change is its own commit with no logic in it. The packaging
version, the tool's `--version` and the top entry of `CHANGELOG.md` must
agree; the build checks the first two. Add a line to `CHANGELOG.md` under
the unreleased entry for anything a user would notice.

## Security

Do not open a public issue for a vulnerability; see `SECURITY.md`.
