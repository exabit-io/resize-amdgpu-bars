resize-amdgpu-bars(8)

# NAME

resize-amdgpu-bars - Resizable BAR for AMD GPUs behind PCIe switches

# SYNOPSIS

*resize-amdgpu-bars* [*resize*] [*--force*]++
*resize-amdgpu-bars* *status*++
*resize-amdgpu-bars* *check* [*-1*]++
*resize-amdgpu-bars* *dry-run*++
*resize-amdgpu-bars* *diagnose*++
*resize-amdgpu-bars* *revert*++
*resize-amdgpu-bars* *--version* | *--help*

# DESCRIPTION

*resize-amdgpu-bars* enlarges the CPU-visible VRAM aperture (BAR0) of every AMD
GPU driven by *amdgpu* to the largest size the device advertises through its
Resizable BAR capability, makes the kernel re-size the bridge windows above
the GPU so that the larger BAR can actually be assigned, and then loads
*amdgpu* exactly once. A GPU whose BAR could not be assigned is fenced off
from the driver instead of being handed to it, because *amdgpu* hangs the boot
in uninterruptible sleep when it probes a device with an unassigned BAR0.

The tool exists for GPUs that sit behind one or more PCIe bridges: cards with
an on-board PCIe switch (dual-die cards, MPX modules), cards in switched
enclosures or expansion chassis, and Thunderbolt eGPUs. On such a topology
neither the driver's own resize at probe time nor a bare write to the
Resizable BAR control register produces a large BAR, because the bridge
windows above the device were sized by firmware for the small BAR and are not
grown in place. See _HOW IT WORKS_.

It is normally run once per boot by *resize-amdgpu-bars.service*, before any
display manager and before *amdgpu* would otherwise autoload. It can also be
run by hand, as root, to inspect the state of the machine or to redo the
resize.

Only devices driven by *amdgpu* are handled. Any other PCI device, including
AMD GPUs that need the *radeon* driver, is reported at discovery and left
alone.

# SUBCOMMANDS

The first argument selects the subcommand. With no argument, *resize* is
assumed.

*resize* [*--force*]
	Discover the GPUs, negotiate a BAR layout, re-enumerate the GPU
	subtrees, load *amdgpu* behind the bind guard and verify the result.
	Interactively this asks for confirmation (default: no) because every
	display attached to an AMD GPU goes black for the duration of the run
	and every process using a GPU loses it. *--force* skips the question;
	this is what the service runs. A manual *resize* is refused while the
	service is still running its own.

*status*
	Print one machine-readable line describing the current state: number
	of GPUs, and for each GPU its BAR0 size, programmed size index, target
	index, bound driver and re-enumeration root, followed by the summary
	of the last run in this boot if there was one. Exit status is 0
	regardless of the state described. Read-only.

*check* [*-1*]
	Print the one-line verdict for this boot, combining the service
	journal with the live sysfs state, and append it to
	_/var/log/resize-amdgpu-bars/kernel-matrix.log_ so that boots on different
	kernels and cards can be compared. With *-1* the previous boot is
	judged from its journal alone (live-only fields are marked as such)
	and nothing is appended. Read-only apart from the log file. The fields
	are described in _CHECK OUTPUT_.

*dry-run*
	Discover, report, and print the plans *resize* would try, in order.
	Changes nothing. Read-only.

*diagnose*
	Discover and report: every GPU, its functions, its Resizable BAR
	capability and supported sizes, its current and baseline size index,
	every bridge between it and its root bus with that bridge's
	prefetchable window, the re-enumeration group it belongs to, and every
	other slot device the tool promises never to touch. Changes nothing.
	Read-only.

*revert*
	Program every resizable GPU back to its baseline size (see _HOW IT
	WORKS_), re-enumerate, and load the driver behind the bind guard. Use
	this to return to the firmware layout without a reboot. Requires
	*pci=realloc* like *resize* does.

# OPTIONS

*--force*
	With *resize*: do not ask for confirmation.

*-1*
	With *check*: judge the previous boot instead of this one.

*--version*
	Print the version and exit.

*--help*
	Print the usage summary and exit.

# EXIT STATUS

*0*
	Full success: every GPU has every memory BAR assigned at the requested
	size and is bound to *amdgpu*. Also returned by the read-only
	subcommands, by *revert* when the baseline layout verified, and when no
	AMD GPU was found (there is nothing to do).

*2*
	Degraded: the run completed and the driver is loaded, but the bind
	guard is holding one or more GPUs driverless because no plan produced
	an assigned BAR for them. The other GPUs are usable. The service
	declares this status a success (*SuccessExitStatus=2*) so that the boot
	is not marked failed; monitoring can still tell the difference. The
	usual cause is the kernel regression described in _SAFETY_.

*1*
	Error: refused to run (not root, no *pci=realloc*, another instance
	holds the lock, invalid configuration, missing tool), the driver load
	failed or timed out, or a GPU disappeared during the run. The message
	on standard error says which.

# CONFIGURATION FILE

_/etc/default/resize-amdgpu-bars_ is sourced as shell syntax if it exists. Every
key is optional. It caps the target size (*MAX_SIZE_INDEX*), excludes GPUs by
address (*EXCLUDE_BDFS*), forces a single plan (*FORCE_PLAN*) and sets the
timeouts (*MODPROBE_TIMEOUT*, *PROBE_WAIT*, *RESCAN_WAIT*, *MAX_ROUNDS*). The
file is validated when it is read; a bad value is reported and the tool exits
with status 1 before touching anything. See *resize-amdgpu-bars.conf*(5) for the
keys, their defaults and their constraints.

# FILES

_/usr/sbin/resize-amdgpu-bars_
	The tool.

_/usr/lib/systemd/system/resize-amdgpu-bars.service_
	Runs *resize-amdgpu-bars resize --force* once per boot, before the
	display manager. Enabled on package installation; never started by the
	package.

_/usr/lib/modprobe.d/resize-amdgpu-bars.conf_
	*blacklist amdgpu*. Stops udev from autoloading the driver before the
	service runs; an explicit *modprobe amdgpu* still works, which is how
	the service loads it. Removed with the package. To change it, place a
	file with the same name under _/etc/modprobe.d/_, which takes precedence,
	and run *update-initramfs -u -k all*.

_/etc/default/grub.d/resize-amdgpu-bars.cfg_
	Adds *pci=realloc* to *GRUB_CMDLINE_LINUX_DEFAULT*. Without
	*pci=realloc* the kernel will not re-size bridge windows on a rescan
	and the tool refuses to run.

_/etc/default/resize-amdgpu-bars_
	Configuration, see *resize-amdgpu-bars.conf*(5).

_/run/resize-amdgpu-bars/_
	Per-boot state: the summary of the last run (_summary_), the size
	index observed at first discovery for each GPU (the baseline), and the
	list of memory BARs each GPU is expected to have. Cleared at reboot.

_/run/lock/resize-amdgpu-bars.lock_
	Instance lock. A second instance, including a manual run while the
	service is working, exits with status 1.

_/var/log/resize-amdgpu-bars/kernel-matrix.log_
	One line per *check* run, appended.

# ENVIRONMENT

*NO_COLOR*
	When set (to any value), no colour escape sequences are emitted.
	Colour is only ever used when standard error is a terminal; the
	journal never receives escape sequences.

*RESIZE_AMDGPU_BARS_SYSFS*
	Root of the sysfs tree to operate on, default _/sys_. For the offline
	test harness only; do not set it on a real system.

*RESIZE_AMDGPU_BARS_STATE_DIR*
	Per-boot state directory, default _/run/resize-amdgpu-bars_. For the test
	harness only.

*RESIZE_AMDGPU_BARS_CHECK_LOG*
	Matrix log that *check* appends to, default
	_/var/log/resize-amdgpu-bars/kernel-matrix.log_. For the test harness
	only.

# HOW IT WORKS

## The problem

A PCI device's BAR is placed inside the memory window of the bridge directly
above it, which is placed inside the window of the bridge above that, and so
on up to the root port. Firmware sizes those windows at power-on for the BAR
sizes it programmed, typically 256 MiB for a GPU. Growing a BAR to 32 GiB
therefore needs every window up the chain to grow as well, and a window can
only grow if its parent has room for it.

Directly on a root port there is a single window, the kernel can re-assign it
in place, and the driver's own resize at probe time (or a write to
_resourceN_resize_ in sysfs) works. Behind a switch there are several
windows, they belong to bridges the driver does not own, and the in-place
path gives up as soon as one of them cannot be moved or grown where it is.
Writing the Resizable BAR control register with *setpci* changes the size the
device reports, but assigns nothing: the kernel only re-sizes bridge windows
when it enumerates the subtree, so after a bare register write the device
sits with a BAR the kernel still believes to be small, or with no BAR at all.

## The method

Every run goes through three phases.

Discovery. Every PCI device with vendor 0x1002 and a display class is
checked against the *amdgpu* module alias table; anything else is reported
and skipped. For each GPU the tool records its sibling functions (HDMI
audio), its Resizable BAR capability and control register, the supported
sizes, the size index currently programmed, and every bridge between it and
its root bus. The size index observed at first discovery in this boot is
stored in the state directory as the GPU's baseline: it is what the firmware
programmed, and the tool never goes below it, so firmware that already
enables Resizable BAR is never shrunk. The re-enumeration root of a GPU is
the highest bridge whose subtree contains nothing but functions of GPUs the
tool handles; GPUs sharing a root form a group. A GPU whose subtree shares a
bridge with any other device gets a lower root, or none.

Resize. Any *driver_override* left by an earlier run is cleared. Only the
GPUs that will be resized, and the other members of their groups, are
unbound from their drivers; a GPU without a Resizable BAR capability keeps
its driver and its audio. Then the plans are tried in order:

- _all-max_: every resizable GPU at the largest size it supports, capped by
  *MAX_SIZE_INDEX*.
- _demote-losers-N_: the GPUs that lost their BAR in the previous attempt
  are put back to their baseline and the attempt is repeated, up to
  *MAX_ROUNDS* times.
- _baseline_: every GPU at its baseline.

*FORCE_PLAN* replaces the list with a single plan. For a group behind a
switch, an attempt programs the size index of every member with *setpci*
(memory decode is disabled around the write and re-enabled by the tool
afterwards), removes the group's root from the kernel's view, and rescans the
root's own bus so that the kernel, booted with *pci=realloc*, re-sizes every
window of the subtree from scratch. Only that bus is rescanned; the tool
never triggers a global rescan, and a group whose rescan file is not
writable is a failure for that group, not a reason to rescan everything. A
GPU directly on a root bus, where nothing can be removed and rescanned, uses
the kernel's in-place path instead: the size is written to
_resourceN_resize_ in sysfs and the kernel re-assigns the BAR where it is.
An attempt verifies only if every GPU came back with every memory BAR
assigned and BAR0 at the requested size.

Load. Before *amdgpu* is loaded, every GPU that still has an unassigned
memory BAR gets *driver_override* set to *none*, so the driver cannot bind
to it, and its size index is programmed back to the baseline so that the
next boot starts from a layout the firmware can assign. Then *modprobe
amdgpu* runs under a timeout, the tool waits for every unguarded GPU to bind
and for the KFD topology to settle, and the result is verified and
summarised.

## Two invariants

A Resizable BAR register write is never followed by a driver load without a
re-enumeration in between. If an attempt fails part-way (a register write
that does not take, a subtree that does not come back), the affected GPUs are
marked and the driver is not loaded until they have been re-enumerated or
their register has been restored. On an interrupt (systemd's start timeout,
Ctrl-C) the exit handler clears *driver_override*, restores memory decode on
every GPU whose register was written, and logs what was left in what state.

Nothing outside the GPU subtrees is touched. NICs, HCAs, NVMe carriers,
Thunderbolt controllers and SR-IOV virtual functions elsewhere on the bus are
never unbound, removed or rescanned, and the tool lists them at discovery as
the devices it promises to leave alone.

# SAFETY

## The bind guard

*amdgpu* must never be handed a GPU whose BAR0 is unassigned. On such a
device the register reads that identify the part return garbage, the driver
concludes it is an SR-IOV virtual function and waits forever for a
hypervisor mailbox that does not exist. *modprobe* wedges in uninterruptible
sleep holding the device mutex; SIGKILL does not touch it, the AER interrupt
thread blocks behind it, and the rest of the GPUs are never probed. Only a
reboot recovers. Every code path in this tool that loads the driver goes
through the guard first, and *modprobe* runs under *timeout*(1) so that the
service can never wedge the boot even if the guard is somehow bypassed. A
guarded GPU is present, visible to *lspci*, and driverless; the tool reports
it, exits with status 2, and prints the command that lifts the guard.

## The 7.0 kernel regression

Kernels 6.8 through 6.17 size a shared parent window for the worst-case
packing of its children, and two dies behind one root port both get their
large BAR on the first plan. Linux 7.0 (upstream 7.0.12, Ubuntu 7.0.0-30)
sizes the parent as the plain sum of the child windows and never learns that
each child needs a start aligned to its own large BAR; the second child of
every such pair loses its BAR at every size, including the baseline, once the
subtree has been re-enumerated. This is a regression from commit 3958bf16e2fe
("PCI: Stop over-estimating bridge window size") with a one-line fix in
_drivers/pci/setup-bus.c_. On an unpatched 7.0 the bind guard keeps the boot
alive with the second die of each dual-die card driverless, and *check*
reports the guard held. Run a 6.x kernel or a 7.0 build that carries the fix.

## What the tool writes

As root it writes the Resizable BAR control register and the COMMAND
register of the GPUs it resizes (via *setpci*), the _remove_ and _rescan_
attributes of the GPU subtrees, the _driver_override_, _unbind_ and _bind_
attributes of the GPU functions, the _resourceN_resize_ attribute of GPUs on
a root bus, and its own state and log files. It loads one kernel module,
*amdgpu*. It does not write firmware, the kernel command line, the
bootloader or any configuration file.

# CHECK OUTPUT

*check* prints one line of space-separated _key=value_ fields, prefixed by
the boot time and kernel release (wrapped here to fit the page):

```
2026-09-02T13:50:14  7.0.0-30-generic  verdict=WORKS  plan=all-max
  large=4/4  driverless=0/4
  windows=0000:06:00.0=128G 0000:16:00.0=128G
  bar0=32GiB 32GiB 32GiB 32GiB  kfd=5  xgmi_hives=1
  traces=0  rejected=0
```

*verdict*
	*WORKS*: the achieved plan is _all-max_ and the run ended with
	SUCCESS. *FAILS (bind guard held)*: no plan verified and the guard
	is holding at least one GPU. *NO RESIZABLE GPU*: no GPU with a
	Resizable BAR capability was found. *OTHER*: anything else, including
	a run that has not finished; inspect the journal. *TRACE/SRIOV NOISE*
	is appended when the kernel log carries an Oops, a hung task, or the
	SR-IOV mailbox messages.

*plan*
	The plan that verified, as logged by the run.

*large*, *driverless*
	GPUs at their target size, and GPUs without a driver, over the number
	of GPUs.

*windows*
	Prefetchable window size of every re-enumeration root, from *lspci*.
	Live only.

*bar0*
	BAR0 size of every GPU, from *status*. Live only.

*kfd*
	Number of KFD topology nodes, including the CPU node. Live only.

*xgmi_hives*
	Number of distinct XGMI hive ids in the kernel log.

*traces*, *rejected*
	Number of kernel traces, and number of plans rejected during the run.

# SEE ALSO

*resize-amdgpu-bars.conf*(5), *setpci*(8), *lspci*(8), *systemd.service*(5),
*journalctl*(1)

The README shipped with the package tells the full story of the bridge-window
problem on the reference platform and covers installation, troubleshooting
and non-GRUB bootloaders.

# AUTHORS

Exabit, Inc. MIT licence. Report bugs with the output of *resize-amdgpu-bars
check -1* and *journalctl -u resize-amdgpu-bars -b* attached.
