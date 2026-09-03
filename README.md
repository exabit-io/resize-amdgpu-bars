# resize-gpu-bars

Resizable BAR for AMD GPUs behind PCIe switches.

`resize-gpu-bars` enlarges the CPU-visible VRAM aperture (BAR0) of every AMD
GPU handled by `amdgpu` to the largest size the card supports, on machines
where the usual ways of doing that do not work: cards with an on-board PCIe
switch (dual-die cards, MPX modules), cards in switched enclosures and
expansion chassis, Thunderbolt eGPUs, and firmware that leaves the aperture
at 256 MiB. It does this once per boot, before the driver loads, by
programming the Resizable BAR size and then making the kernel re-enumerate
the GPU subtree so that every bridge window above the GPU is re-sized for
the new BAR. A GPU whose BAR could not be assigned is fenced off from the
driver instead of being handed to it, which on `amdgpu` is the difference
between a degraded boot and a hung one.

The reference platform is the Mac Pro 7,1 with its MPX modules. Apple's
firmware leaves every GPU aperture at 256 MiB, the dual-die modules put two
GPUs behind one PCIe switch, and each die sits four bridge windows below its
root port. It is the idealised instance of the problem and the reason the
tool exists, so this README tells that story first. The tool itself
discovers the topology at run time and is not specific to that machine.

## The problem: a large BAR behind a switch

A PCI device's BAR is placed inside the memory window of the bridge directly
above it, which is placed inside the window of the bridge above that, and so
on up to the root port. Firmware sizes those windows at power-on for the BAR
sizes it programmed. Growing a BAR from 256 MiB to 32 GiB therefore needs
every window up the chain to grow as well, and a window can only grow if its
parent has room for it.

On the Mac Pro 7,1 a Vega II Duo module looks like this to the kernel (real
addresses from `lspci -t`; the second module is identical on buses 16 to
1e):

```
0000:06:00.0  Intel root port           <- one prefetchable window shared
|                                          by both dies of the module
\-0000:07:00.0  PLX PEX 8747 upstream port (the switch on the module)
  |
  +-0000:08:08.0  PLX downstream port
  | \-0000:09:00.0  AMD bridge
  |   \-0000:0a:00.0  AMD bridge
  |     \-0000:0b:00.0  Vega 20, die 0    (0b:00.1 is its HDMI audio)
  |
  \-0000:08:10.0  PLX downstream port
    \-0000:0c:00.0  AMD bridge
      \-0000:0d:00.0  AMD bridge
        \-0000:0e:00.0  Vega 20, die 1    (0e:00.1 is its HDMI audio)
```

Each die has a 32 GiB BAR0 and a 2 MiB doorbell BAR2, both prefetchable, so
each die's chain of windows must hold 32 GiB + 2 MiB, and a 32 GiB BAR must
start on a 32 GiB boundary. The two chains meet at `08:08.0` and `08:10.0`,
which are siblings inside the single window of `07:00.0` and `06:00.0`.
That shared window is the crux: it has to be large enough for both children
at their real alignment, and nothing about the device tells the root port
that.

## Why the usual ways fail here

**The driver's own resize.** `amdgpu` tries to grow BAR0 at probe time
through the kernel's `pci_resize_resource()`. That path releases the bridge
windows above the device and tries to re-assign them in place, and it fails
closed as soon as one of them cannot be grown where it is. Behind the switch
it gives up:

```
amdgpu 0000:1b:00.0: BAR 0 [mem 0xbffe0000000-0xbffefffffff 64bit pref]: old value restored
amdgpu 0000:1b:00.0: Not enough PCI address space for a large BAR.
amdgpu 0000:1b:00.0: [drm] Detected VRAM RAM=32752M, BAR=256M
```

The driver carries on with a 256 MiB aperture. Nothing hangs, and nothing
gets bigger.

**A bare register write.** Writing the new size index into the Resizable
BAR control register with `setpci` changes the size the device reports, but
it assigns nothing. The kernel still believes the BAR is 256 MiB, the bridge
windows are still sized for 256 MiB, and the device now decodes a 32 GiB
range that overlaps whatever else lives there. The windows only change when
the kernel enumerates the subtree again.

**The kernel's in-place path.** `echo 15 > resource0_resize` in sysfs is the
sanctioned interface and ends up in the same `pci_resize_resource()` as the
driver. It can re-assign a BAR in place when the device sits directly on a
root port with a single window above it, and that is exactly where
`resize-gpu-bars` uses it (tier 3 below). It cannot conjure a larger shared
window out of a chain of bridges that the firmware sized for something
smaller, and it has not been measured on the Duo chain; the driver's resize,
which uses the same function, fails there.

## The method

What does work is to let the kernel size the windows from scratch. The tool
runs in three phases:

1. **Discover.** Find every `amdgpu` device, its functions, its Resizable
   BAR capability and supported sizes, and every bridge between it and its
   root bus. Record the size index each GPU has at first discovery in this
   boot as its baseline: that is what the firmware programmed, and the tool
   never goes below it, so firmware that already enables Resizable BAR is
   never shrunk. Find each GPU's re-enumeration root, the highest bridge
   whose subtree contains nothing but GPU functions; on the module above
   that is `06:00.0`, and both dies share it, so they form one group.
2. **Resize.** Unbind the drivers from the GPUs that will be resized and
   their group members (nothing else), program the size index of every
   member with `setpci`, remove the group's root from the kernel's view,
   and rescan that root's own bus. With `pci=realloc` on the command line
   the kernel then sizes every window of the subtree for the BARs it finds,
   and on a 6.x kernel both dies come back with a 32 GiB BAR0 inside a
   96 GiB root-port window. Only that bus is rescanned; there is never a
   global rescan, and other devices on the machine are never touched. If a
   GPU comes back without a BAR, the plan is rejected: the losers are put
   back to their baseline and the cycle repeats, round by round, down to
   every GPU at baseline. A GPU directly on a root bus, with nothing above
   it to remove, uses the kernel's in-place `resource0_resize` path instead.
3. **Load.** Any GPU that still has an unassigned memory BAR is fenced off
   with `driver_override=none`. Then `modprobe amdgpu` runs once, under a
   timeout, and the tool waits for the driver to bind and for the KFD
   topology to settle before it verifies and summarises the result.

Two rules hold throughout: a Resizable BAR register write is never followed
by a driver load without a re-enumeration in between, and nothing outside
the GPU subtrees is unbound, removed or rescanned.

## Safety: the bind guard and the 7.0 kernel

`amdgpu` must never be handed a GPU whose BAR0 is unassigned. On such a
device the register reads that identify the part return garbage, the driver
concludes it is an SR-IOV virtual function and waits forever for a
hypervisor mailbox that does not exist:

```
amdgpu 0000:0e:00.0: MCBP is enabled
amdgpu 0000:0e:00.0: trn=2 ACK should not assert! wait again !
INFO: task irq/34-aerdrv:1554 blocked for more than 122 seconds.
```

`modprobe` wedges in uninterruptible sleep holding the device mutex,
SIGKILL does not touch it, and the remaining GPUs are never probed. Only a
reboot recovers. That is a hard hang, not a degraded outcome, and the bind
guard exists to make it impossible: every code path that loads the driver
first sets `driver_override=none` on any GPU with an unassigned BAR, and
`modprobe` runs under `timeout(1)` so that the boot can never wedge even if
the guard were bypassed. A guarded GPU stays visible to `lspci`, driverless;
the tool reports it and exits with status 2.

The guard has been exercised for real. Linux 7.0 (upstream 7.0.12 and
Ubuntu's 7.0.0-30 build) sizes a shared parent window as the plain sum of
its child windows and never learns that each child needs a start aligned to
the 32 GiB BAR inside it. The root-port window is sized 64 GiB + 4 MiB where
96 GiB + 2 MiB are needed, and the second die of every module loses its BAR,
deterministically, at every size, including the 256 MiB baseline once the
firmware's windows are gone:

```
pci 0000:06:00.0: bridge window [mem 0x90000000000-0x910003fffff 64bit pref]: assigned
pci 0000:08:08.0: bridge window [mem 0x90000000000-0x908001fffff 64bit pref]: assigned
pci 0000:08:10.0: bridge window [mem size 0x800200000 64bit pref]: can't assign; no space
pci 0000:0e:00.0: BAR 0 [mem size 0x800000000 64bit pref]: can't assign; no space
```

On that kernel the tool tries every plan, every plan fails, the guard holds
`0e:00.0` and `1e:00.0` driverless, and the boot finishes with two working
dies instead of hanging. See "Kernel compatibility" for the regression and
its fix.

## Support tiers

"Tier" is a commitment; "tested" is a fact. The two are never conflated.

| tier | hardware | support | tested |
|---|---|---|---|
| 1 | MPX modules in a Mac Pro 7,1: Radeon Pro 580X, W5500X, W5700X, W6600X, W6800X, W6800X Duo, W6900X, Vega II, Vega II Duo (with or without Infinity Fabric Link) | supported | tested so far: Vega II Duo x2 |
| 2 | any other amdgpu card with an on-board PCIe switch (Radeon Pro V340, Radeon Pro Duo, ...) or any amdgpu card in a switched enclosure / expansion chassis / Thunderbolt eGPU | applicable by design, reports welcome | untested |
| 3 | amdgpu card directly on a root port, firmware without ReBAR | works via the kernel's in-place resize path | untested |
| out | anything not driven by amdgpu | refused at discovery with a clear message | n/a |

No card is listed as supported that has not been booted; see
`CONTRIBUTING.md` for what a boot test consists of.

Platforms: Ubuntu 24.04 LTS and its HWE kernels are the tier-1 reference
platform. Ubuntu ships GRUB, so the `/etc/default/grub.d` drop-in is the
supported way `pci=realloc` gets onto the kernel command line. rEFInd and
OpenCore are tier 2, best effort: documented below, not automated. Other
Debian derivatives with GRUB are expected to work. Anything else is out of
scope for 7.0.

## Install

The package needs `bash`, `pciutils`, `kmod` and `systemd`, and uses
`initramfs-tools` and `grub2-common` when they are present. Install the
`.deb` from the release page:

```
sudo apt install ./resize-gpu-bars_7.0_all.deb
```

or build it from source:

```
sudo apt install debhelper scdoc shellcheck
dpkg-buildpackage -us -uc -b
sudo apt install ../resize-gpu-bars_7.0_all.deb
```

The package installs these files:

| path | purpose |
|---|---|
| `/usr/sbin/resize-gpu-bars` | the tool |
| `/usr/lib/systemd/system/resize-gpu-bars.service` | runs `resize-gpu-bars resize --force` early in boot; enabled on install, never started by the package |
| `/usr/lib/modprobe.d/resize-gpu-bars.conf` | `blacklist amdgpu`, so udev does not load the driver before the resize; override from `/etc/modprobe.d` if needed |
| `/etc/default/grub.d/resize-gpu-bars.cfg` | adds `pci=realloc` to the kernel command line |
| `/etc/default/resize-gpu-bars` | configuration, every key optional |
| `/usr/share/man/man8/resize-gpu-bars.8` | manual page for the tool |
| `/usr/share/man/man5/resize-gpu-bars.conf.5` | manual page for the configuration file |
| `/usr/share/resize-gpu-bars/tests/` | the offline test harness |

Installation runs `update-initramfs -u -k all` (the blacklist has to reach
every initramfs) and `update-grub`. **A reboot is required**: the blacklist
and `pci=realloc` take effect at boot, and the package never starts the
service on a running system, because a start unbinds and re-initialises
every AMD GPU and every process using one loses it. To apply without a
reboot, and with that understanding, run `sudo systemctl start
resize-gpu-bars.service` yourself.

## First boot

The service runs before the display manager. Screens attached to AMD GPUs
stay dark until `amdgpu` is loaded at the end of the run, typically a minute
or so into the boot on a machine with two dual-die modules: discovery, one
re-enumeration cycle of about ten seconds, the driver load, and up to a
minute of waiting for the KFD topology to settle. Progress is written to the
journal and the console line by line, so a boot that looks stalled can be
checked from another terminal or over SSH with `journalctl -u
resize-gpu-bars -b -f`. Do not start a second copy of the tool while the
service is running; it refuses anyway, because it would re-enumerate the
bus underneath the first one.

## Verification

```
sudo resize-gpu-bars check
```

prints one line for this boot and appends it to
`/var/log/resize-gpu-bars/kernel-matrix.log`. The line to expect on a
machine where everything worked is (wrapped here):

```
2026-09-02T13:50:14  7.0.0-30-generic  verdict=WORKS  plan=all-max
  large=4/4  driverless=0/4  windows=0000:06:00.0=128G 0000:16:00.0=128G
  bar0=32GiB 32GiB 32GiB 32GiB  kfd=5  xgmi_hives=1  traces=0  rejected=0
```

`verdict=WORKS`, `large=N/N` and `driverless=0/N` are the three fields that
matter. Then:

```
journalctl -u resize-gpu-bars -b       # ends with "SUCCESS:" and exit 0
sudo resize-gpu-bars status            # one line, bar0=... per GPU
rocminfo | grep -c gfx                 # with ROCm: one agent per die
```

## Subcommands

One binary, `resize-gpu-bars`, with subcommands. Every subcommand needs
root. `--help` prints the usage summary and `--version` the version. The
manual page `resize-gpu-bars(8)` is the authoritative reference; this is the
tour.

### resize

```
sudo resize-gpu-bars                 # asks "Proceed? (y/N)"
sudo resize-gpu-bars resize --force  # no question; what the service runs
```

The default subcommand. Interactively it asks first, because every display
on an AMD GPU goes black for the duration and every process using a GPU
loses it. Exit status 0 means every GPU has its target BAR and a driver, 2
means the bind guard is holding at least one GPU driverless (the rest are
usable), 1 means an error. A manual `resize` is refused while the service is
still running its own.

### status

```
$ sudo resize-gpu-bars status
gpus=4 0000:0b:00.0:bar0=32GiB,idx=15,max=15,drv=amdgpu,root=0000:06:00.0 ...
  last: plan=all-max gpus=4 large=4 baseline=0 driverless=0 unassigned=0
  missing=0 kfd_nodes=5 kernel=7.0.0-30-generic
```

One machine-readable line (wrapped here): the number of GPUs, then for each
GPU its BAR0 size, programmed size index, target index, bound driver and
re-enumeration root, then the summary of the last run in this boot if there
was one. Read-only; always exits 0.

### check

```
sudo resize-gpu-bars check       # this boot: journal + live sysfs; appended
sudo resize-gpu-bars check -1    # previous boot: journal only; not appended
```

The per-boot verdict line shown under "Verification". Use `-1` after a
boot that had to be rebooted away from, for example one where the guard
fired; the live-only fields (`windows`, `bar0`, `kfd`) read `(live only)`.

### dry-run

```
$ sudo resize-gpu-bars dry-run
...
Plans that would be tried:
  all-max:   0000:0b:00.0=32 GiB  0000:0e:00.0=32 GiB
             0000:1b:00.0=32 GiB  0000:1e:00.0=32 GiB
  then: demote whichever GPUs lose their BAR, round by round
  baseline:  0000:0b:00.0=256 MiB  0000:0e:00.0=256 MiB
             0000:1b:00.0=256 MiB  0000:1e:00.0=256 MiB
Dry run complete. No changes made.
```

Discovery plus the plan list. Changes nothing.

### diagnose

```
$ sudo resize-gpu-bars diagnose
Kernel booted with pci=realloc
amdgpu not loaded (blacklist active); clean single-init path.
GPUs found: 4   re-enumeration groups: 2
Group root 0000:06:00.0  (rescan via /sys/devices/pci0000:06/pci_bus/0000:06/rescan)
    bridge 0000:06:00.0  pref window: 90000000000-91fffffffff [size=128G]
    bridge 0000:07:00.0  pref window: 90000000000-91fffffffff [size=128G]
    bridge 0000:08:08.0  pref window: 90000000000-90fffffffff [size=64G]
    ...
  GPU 0000:0b:00.0  Vega 20 [Radeon Pro Vega II/Radeon Pro Vega II Duo]
    functions: 0000:0b:00.0 0000:0b:00.1
    ReBAR cap @0x200 ctrl @0x208  supported mask 000000000000ff00
    size index: current 32 GiB (15)  baseline 256 MiB (8)  target 32 GiB (15)
    BAR0: 32GiB   unassigned regions:
    driver: amdgpu
  ...
Other slot devices (never touched): 0000:01:00.0(ANS2 NVMe Controller) ...
Diagnostics complete. No changes made.
```

Everything the tool knows: every GPU, its Resizable BAR capability, its
current, baseline and target size, every bridge above it with that bridge's
prefetchable window, the group it belongs to, and the list of every other
slot device the tool promises to leave alone. A device with vendor 0x1002
that `amdgpu` does not claim (a `radeon`-era card) is reported here and
skipped. Changes nothing; this is the first thing to run on a new machine
and the first thing to attach to a bug report.

### revert

```
sudo resize-gpu-bars revert
```

Every resizable GPU back to its baseline size, re-enumerate, load the driver
behind the guard. Returns to the firmware layout without a reboot. On an
unpatched 7.0 kernel this does not help once a subtree has been
re-enumerated (see "Kernel compatibility"); reboot instead.

## Configuration

`/etc/default/resize-gpu-bars`, shell syntax, every key optional. The file is
validated when it is read; a bad value stops the run with a message and exit
status 1 before any device is touched. `resize-gpu-bars.conf(5)` has the
full reference.

| key | default | meaning |
|---|---|---|
| `MAX_SIZE_INDEX` | empty (device maximum) | cap every GPU at this size index; 2^(n+20) bytes, so 15 = 32 GiB, 14 = 16 GiB, 13 = 8 GiB, 8 = 256 MiB |
| `EXCLUDE_BDFS` | empty | GPUs to leave completely alone, e.g. `"0000:0b:00.0 0000:0e:00.0"`; not resized, not unbound, subtree never removed |
| `FORCE_PLAN` | empty (negotiate) | `all-max` or `baseline`: try exactly one plan |
| `MODPROBE_TIMEOUT` | 180 | seconds before `modprobe amdgpu` is killed |
| `PROBE_WAIT` | 60 | seconds to wait for every unguarded GPU to bind and KFD to settle |
| `RESCAN_WAIT` | 30 | seconds to wait for the GPUs to reappear after a rescan |
| `MAX_ROUNDS` | 8 | demote-and-retry rounds before falling back to baseline |

`GPU_DRIVER`, accepted by 6.x, is gone: the tool handles `amdgpu` devices
only. Keep `MODPROBE_TIMEOUT + PROBE_WAIT + MAX_ROUNDS x RESCAN_WAIT` below
the unit's `TimeoutStartSec` (480 s), or raise that with a drop-in.

## Troubleshooting

### The guard fired

`check` says `verdict=FAILS (bind guard held)`, `status` shows `drv=none`
for one or more GPUs, the service exited 2, and the journal has:

```
Plan 'all-max' rejected: unassigned BARs on: 0000:0e:00.0 0000:1e:00.0
...
Every plan failed to produce a fully-assigned BAR layout.
Blocked driver binding on 0000:0e:00.0 (driver_override=none)
Blocked driver binding on 0000:1e:00.0 (driver_override=none)
```

The machine is up, the other GPUs work, and the guarded ones are present
but driverless. Look at `journalctl -k -b | grep "can't assign"`: if the
losers are the second die of each dual-die card and the kernel is 7.0, this
is the kernel regression under "Kernel compatibility"; boot a 6.x kernel or
a patched 7.0. If it is something else, `diagnose` output and the two
journals are what a bug report needs.

### The display went black

That is expected while `resize` runs: the driver is unbound, the GPU
subtree is removed and rescanned, and the screen comes back when `amdgpu`
binds at the end. If it does not come back, the GPU driving the display is
either still being probed (wait for `PROBE_WAIT`) or is being held by the
guard. Log in over SSH or from another console and run `status` and the
journal. A guarded GPU cannot drive a display until its BAR is assigned,
which on the reference platform means a reboot into a kernel that sizes the
window correctly.

### Clearing driver_override

A guarded GPU has `none` in `/sys/bus/pci/devices/<bdf>/driver_override`.
Clearing it and binding `amdgpu` hangs the machine if the BAR is still
unassigned, so check first: `diagnose` must show an empty `unassigned
regions:` for the device. Only then:

```
echo > /sys/bus/pci/devices/0000:0e:00.0/driver_override
echo 0000:0e:00.0 > /sys/bus/pci/drivers/amdgpu/bind
```

The tool clears its own overrides at the start of every run and on exit,
including when it is interrupted, so a stale override normally means a
previous run was killed hard. After a reboot the firmware re-assigns every
BAR and the override is gone with the rest of the sysfs state.

### Reading the journal

```
journalctl -u resize-gpu-bars -b          # this boot's run
journalctl -u resize-gpu-bars -b -1       # previous boot
journalctl -k -b | grep -E "can't assign|bridge window|BAR 0"
```

The run logs one line per event, plain ASCII. The lines that decide the
outcome: `Plan '...' verified` or `Plan '...' rejected`, `Blocked driver
binding on`, `amdgpu loaded`, `Plan achieved :`, `Driverless :`, and
finally `SUCCESS:` or the reason there was none. The kernel log carries the
allocation trace of every rescan and the SR-IOV mailbox messages that mean
a BAR-less device met the driver.

### Reading the check line

`verdict=WORKS` needs `plan=all-max` and a `SUCCESS` line in the journal.
`FAILS (bind guard held)` means no plan verified. `NO RESIZABLE GPU` means
no card with a Resizable BAR capability was found. `OTHER` is anything else,
including a run that had not finished when `check` ran; run it again after
the service reports finished. `TRACE/SRIOV NOISE` is appended when the
kernel log has an Oops, a hung task or the mailbox messages, and always
deserves a look. The remaining fields are described in `resize-gpu-bars(8)`.

### Other messages

`Kernel NOT booted with pci=realloc`: the unit fails at once with this
message until the parameter is on the command line. On GRUB, check that
`/etc/default/grub.d/resize-gpu-bars.cfg` exists and run `update-grub`; on
other bootloaders see the next section. `Another instance holds
/run/lock/resize-gpu-bars.lock`: the service is still running; watch it
instead. `N AMD GPUs are present under different addresses`: a GPU came
back on a different bus number after the rescan, which happens when
something else re-enumerated the bus during the run; run `resize` again.

## Non-GRUB bootloaders

The `/etc/default/grub.d` drop-in does nothing on rEFInd or OpenCore. Until
`pci=realloc` is on the kernel command line by other means, the service
fails at every boot with the `Kernel NOT booted with pci=realloc` message,
the blacklist keeps `amdgpu` from loading, and there is no GPU driver.
Adding the parameter by hand is best effort and not automated. Check with
`grep -w pci=realloc /proc/cmdline` after the next boot.

rEFInd reads the options for a Linux kernel from `refind_linux.conf` next
to the kernel in `/boot`. Add `pci=realloc` to each line you boot from:

```
"Boot with standard options"  "root=UUID=... ro quiet splash pci=realloc"
"Boot to single-user mode"    "root=UUID=... ro single pci=realloc"
```

If the entry is defined as a `menuentry` stanza in `refind.conf` instead,
add it to that stanza's `options` line.

OpenCore booting Linux through its OpenLinuxBoot driver takes the options
from the distribution's boot loader entries when it finds them, and
otherwise from the driver's arguments in `config.plist`. To add a parameter
for every autodetected Linux kernel:

```
<key>UEFI</key>
<dict>
  <key>Drivers</key>
  <array>
    <dict>
      <key>Path</key>
      <string>OpenLinuxBoot.efi</string>
      <key>Enabled</key>
      <true/>
      <key>Arguments</key>
      <string>autoopts=pci=realloc</string>
    </dict>
  </array>
</dict>
```

A custom entry under `Misc -> Entries` takes the parameter in its
`Arguments` string in the same way. Consult the OpenCore documentation for
the version you run; the key names above are the ones in use at the time of
writing.

## Kernel compatibility

| kernel | result on the reference platform |
|---|---|
| 6.8 through 6.17 (Ubuntu 6.8.0-138, 6.11.0-29, 6.14.0-37, 6.17.0-42 verified) | every die gets its 32 GiB BAR on the first plan; 96 GiB root-port window (48 GiB per die) |
| 7.0 unpatched (upstream 7.0.12, Ubuntu 7.0.0-30) | shared root-port window undersized; second die of each dual-die module loses its BAR at every size; guard holds it driverless; boot completes with the other dies |
| 7.0 with the one-line fix | every die on the first plan; 128 GiB root-port window (the fix pads each child to its alignment) |

The 7.0 behaviour is a regression from commit 3958bf16e2fe ("PCI: Stop
over-estimating bridge window size"). Since that commit `pbus_size_mem()`
in `drivers/pci/setup-bus.c` sizes a bridge window as the plain sum of its
children, which is exact when every child's size is a multiple of the
alignment of the children placed after it. That holds for BARs, whose size
equals their alignment, but not for bridge windows, whose size is the sum
of what is below them while their alignment is that of the largest BAR
below them. Two sibling windows of 32 GiB + 2 MiB at 32 GiB alignment need
a 96 GiB + 2 MiB span and get 64 GiB + 4 MiB. The proposed fix changes
`size += max(r_size, align)` to `size += ALIGN(r_size, align)`, a no-op for
BARs, and has been verified on upstream 7.0.12 and on Ubuntu's 7.0.0-30
build, cold boot and warm reboot.

On an unpatched 7.0 there is no in-place recovery: once the kernel has
re-sized the window, even the 256 MiB baseline no longer fits, because the
firmware's original windows were larger than the kernel's sum. The bind
guard is what keeps such a boot alive, with the second die of each module
driverless. Until the fix is in the distribution kernel, run a 6.x kernel,
or a 7.0 build that carries the patch. Patched Ubuntu HWE kernel packages
exist as a stopgap in a private repository; they are not part of this
project and are not a supported configuration.

Upstream thread: (link to be added once the report is on linux-pci).

## Known issues

- Unpatched Linux 7.0 leaves the second die of every dual-die module
  driverless. See above.
- A GPU that shares a bridge with a non-GPU device gets a lower
  re-enumeration root, or none, and the windows above that point cannot be
  re-sized. `diagnose` reports it as "subtree above ... has non-GPU
  devices".
- Excluding one die of a dual-die module with `EXCLUDE_BDFS` also stops the
  other die's shared windows from being re-sized, because the shared
  subtree is no longer removable.
- A GPU that comes back on a different bus number after the rescan (another
  device was hot-plugged or re-enumerated during the run) makes the run
  fail with a message asking for a re-run; hot-plug during a run is not
  handled.
- BAR sizes between the baseline and the maximum (8 GiB, 16 GiB) have not
  been exercised on the 7.0 kernel, and the sysfs `resource0_resize` path
  has not been measured on a switched chain.
- Tier 2 and tier 3 hardware is untested; the offline harness models it,
  the box has not. Reports with `diagnose` output are welcome.
- The 6.x aliases print a deprecation warning on every use.

## Licence

MIT. See `debian/copyright` for the full text.

## Reporting bugs

Open an issue with:

- the output of `sudo resize-gpu-bars check -1` for the boot in question
  (or `check` if it is the current boot),
- `journalctl -u resize-gpu-bars -b` (or `-b -1`) for that boot,
- `sudo resize-gpu-bars diagnose`,
- for a guard or hang report, `journalctl -k -b | grep -E "can't assign|
  bridge window|BAR|amdgpu"`,
- the kernel (`uname -r`), the distribution, the bootloader, and the cards.

Security issues go to the maintainer privately; see `SECURITY.md`.
