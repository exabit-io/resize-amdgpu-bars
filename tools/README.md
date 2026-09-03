# tools/

Maintainer tools that are not installed by the package.

## experiment-resource0-resize.sh

**Question it answers:** does the kernel's own in-place Resizable BAR path,
`echo INDEX > /sys/bus/pci/devices/BDF/resource0_resize`, work for an AMD
GPU die that sits behind a PCIe switch, and what does it do to the bridge
windows above the die?

**Why it matters, twice:**

1. The linux-pci report (`/root/linux-pci-bug-report.txt`, to-do 10.1)
   reproduces the 7.0 bridge-window undersizing with a ReBAR register write
   plus a rescan. The one objection a maintainer will raise is "why not the
   sysfs path?". The report answers that from the code (the sysfs write
   re-sizes the bridge windows through the same `pbus_size_mem()` sum, so it
   fails under the same undersized window) but the paragraph is marked
   `[TO CONFIRM by experiment]`. This script is that experiment.
2. To-do 2.3 makes root-bus GPUs use the sysfs path. Knowing what the path
   does behind a switch decides what the README says the kernel's in-place
   resize can and cannot do.

### What the kernel does on that write (v7.0.12, drivers/pci/pci-sysfs.c,
rebar.c, setup-bus.c)

`resource_resize_store()` refuses with `-EBUSY` while a driver is bound,
clears memory decoding, evicts a console framebuffer if the device is
VGA-class, then calls `pci_resize_resource()` →
`pci_do_resource_release_and_resize()`: it programs the new size into the
ReBAR control register, releases the device's BARs that share the window,
and calls `pbus_reassign_bridge_resources()`, which walks up the bridge
chain re-sizing each window that no longer fits, using the same
`pbus_size_mem()` arithmetic the boot-time enumeration uses. If a level
cannot be placed, everything is put back (`old value restored`) and the
write returns `-ENOSPC`. Finally `pci_assign_unassigned_bus_resources()`
runs on the device's bus and memory decoding is re-enabled.

So there is no separate "in-place" allocator: the sysfs path is the
register write plus a *partial* re-enumeration, driven from the device
upward instead of from the root port downward.

### Usage

```
tools/experiment-resource0-resize.sh [OPTIONS] BDF

  BDF                 the die, e.g. 0000:0b:00.0 (0b:00.0 is accepted)
  --index N           size index to write; default 15 (32 GiB)
  --allow-hive        proceed although the die shares a live XGMI hive
                      with other bound dies
  --evidence-dir DIR  where to put the evidence
                      (default /var/tmp/resource0-resize-experiment)
  --bind-timeout SEC  bound on each re-bind write (default 120)
  --i-understand      actually do it; without it: checks + plan, exit 3
  -h, --help
```

Exit status: 0 the experiment ran and the die is back as found; 1 a
precondition failed or bad usage, nothing touched; 3 refused for lack of
`--i-understand`, nothing touched; 4 the experiment ran but the restore or
the re-bind did not complete (read the verdict, do not modprobe).

What it does with `--i-understand`, on the named die and nothing else:

1. Takes the `/run/lock/resize-amdgpu-bars.lock` flock so the unit cannot run
   underneath it.
2. Snapshot `0-before`: `lspci -vv` of the die's functions and every bridge
   above it, their `resource` files, the bridge window lines, the ReBAR
   control register (read with `setpci`, never written), the driver of each
   function, the hive id, `dmesg | tail -300`.
3. Unbinds the driver from each function of the die (`amdgpu` from `.0`,
   `snd_hda_intel` from `.1`), by writing the function to the driver's
   `unbind`. No `driver_override`. Snapshot `1-unbound`.
4. Drops a marker into the kernel log, writes the index to
   `resource0_resize`, records the write's return value and error text
   (`writes.log`), BAR0 as read back (`index-after-write.txt`), the dmesg
   delta since the marker (`dmesg-delta-write.txt`). Snapshot
   `2-after-write`.
5. Writes the original index back; same records (`dmesg-delta-restore.txt`).
   Snapshot `3-after-restore`.
6. Re-binds each function to the driver it had, via `echo BDF >
   /sys/bus/pci/drivers/DRV/bind` under `timeout --signal=KILL SEC`, and
   **only if BAR0 is assigned**. If the driver is not loaded it does not
   load it (no `modprobe`, ever) and says so. Snapshot `4-final`, full
   `dmesg`, verdict.

Steps 5 and 6 also run from the EXIT/INT/TERM/HUP trap, so a Ctrl-C after
step 3 still restores and re-binds.

It never writes `remove`, `rescan`, a `setpci` register, or anything on
another device.

### Preconditions it checks (all before anything is written)

- root; `pci=realloc` on the command line; `resize-amdgpu-bars.service` not
  `activating`; the die is an AMD display-class device with a
  `resource0_resize` attribute and an assigned BAR0.
- The requested index is in the supported mask and differs from the
  current one. A die that is already at 32 GiB (the normal state on this
  box) is refused with the default `--index 15`; use `--index 8` there. The
  script then restores 15, so both directions are exercised: shrink in
  step 4, grow back through the whole bridge chain in step 5.
- **No AMD GPU in the machine has an unassigned memory BAR.** A BAR-less
  die is what hangs amdgpu; on an unpatched 7.0 boot (2/4 dies) the script
  refuses outright.
- **The die is not one node of a live XGMI hive with other bound dies**,
  unless `--allow-hive`. This is the risky bit: unbinding one node while
  its peers stay bound takes a node out of the hive under the driver. The
  v6.1 upgrade unbound all four dies at once on 7.0 without incident, but
  a single-node unbind has not been exercised here.
- No process holds `/dev/dri/by-path/pci-BDF-*` or `/dev/kfd` (`fuser`).

### The clean way to run it on the Mac Pro

Boot once with no die bound, so there is no hive to tear and nothing to
re-bind:

```
# one-shot: keep amdgpu out and the unit off for this boot only
# (GRUB: press e, append to the linux line)
    modprobe.blacklist=amdgpu systemd.mask=resize-amdgpu-bars.service
```

then as root:

```
tools/experiment-resource0-resize.sh --index 8 0000:0b:00.0
tools/experiment-resource0-resize.sh --index 8 --i-understand 0000:0b:00.0
```

The first invocation prints the plan and the check results and exits 3;
the second runs it. On such a boot the script has nothing to unbind and
nothing to re-bind (amdgpu is not loaded and it never loads it); reboot
normally afterwards and the unit takes over. Running on the live, working
box instead needs `--allow-hive` and accepts the hive risk above.

To exercise the failure mode itself (the maintainer's question), run it on
a kernel **without** the fix, e.g. `linux-image-7.0.12-vanilla`, on the die
that did get its BAR (`0b:00.0`), also from a no-die-bound boot: with the
sibling `0e:00.0` BAR-less the "no unassigned BAR anywhere" check refuses;
that is deliberate. So on an unfixed kernel the experiment must start from
the firmware layout: boot vanilla with `modprobe.blacklist=amdgpu
systemd.mask=resize-amdgpu-bars.service` (all four dies at 256 MiB, windows
as firmware left them) and write `--index 15` to one die. The verdict then
shows whether the in-place path can grow a single die to 32 GiB inside the
firmware's 770 MiB parent window (it cannot: the chain must grow, and
growing re-sizes the shared root-port window with the buggy sum).

### Expected outcomes and what each one means

| kernel | write | expected | meaning |
|---|---|---|---|
| 7.0 + fix (7.0.0-30 +barfix1, 7.0.12-barfix) | 15 → 8 → 15 | both writes rc=0, BAR0 back at 32 GiB, `bridge-windows.txt` shows the chain shrink and grow | the sysfs path works behind the switch once the sizing is right; 2.3 can rely on it for root-bus GPUs |
| 6.17 | 15 → 8 → 15 | as above, windows 48G/96G style | same |
| 7.0.12-vanilla, firmware layout | 8 → 15 | write rc=28 (`ENOSPC`), dmesg `can't assign; no space` then `old value restored`, BAR0 still 256 MiB | the objection is answered: the sanctioned interface fails identically, because it re-sizes the parent with the same sum |
| any | restore fails | verdict says ATTENTION, script refuses to re-bind | the die is BAR-less; reboot; do not modprobe |

### Recording the result

1. Copy the evidence directory into `/root/linux-pci-bug-evidence/` as
   `resource0-resize-<kernel>-<die>/` and add it to the bundle list in
   the report's note-to-self.
2. In `/root/linux-pci-bug-report.txt`, replace the paragraph marked
   `[TO CONFIRM by experiment]` in "What I have not tested" with the
   measured result (the write's return value, the two dmesg lines, the
   parent window before and after), then regenerate the mbox with
   `/root/linux-pci-bug-report-mkmbox.sh`.
3. In the repository README, compatibility section: add the sysfs path to
   the list of what fails behind a switch on unpatched 7.0, or, if it
   worked somewhere it was not expected to, say exactly where.
4. Add a row to the table above with the real numbers, and tick to-do 10.2.
