# tools/

Maintainer tools that are not installed by the package.

## apt-publish.sh

Indexes and signs the flat apt repository on the `apt-repo` branch, which
GitHub Pages serves at https://exabit-io.github.io/resize-amdgpu-bars.
The release workflow's `publish-apt` job runs it with the release's
`.deb`; by hand it is

```
git worktree add ../apt-repo apt-repo
GNUPGHOME=/path/to/exabit-apt-keyring \
    tools/apt-publish.sh --key 6043AD7B3533F615C15F48D0472316650F4BE230 \
    ../apt-repo resize-amdgpu-bars_1.1_all.deb
```

then commit and push `../apt-repo`. Suite `stable`, component `main`,
architecture `amd64`; the key is the Exabit, Inc. apt repository key,
`packages@exabit.io`, never a personal key. Needs `apt-utils` and `gpg`.

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
   fails under the same undersized window) and that paragraph was marked
   `[TO CONFIRM by experiment]`. This script was that experiment. It ran on
   2026-09-03 on 7.0.12 and the answer was "it fails, but lower down than
   predicted"; the report now carries the measured result (see "Result").
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
firmware's 770 MiB parent window. It cannot, and not for the reason first
expected: see "Result" below.

### Result (2026-09-03, 7.0.12-vanilla, firmware layout, 0000:0b:00.0)

Run from a no-die-bound boot (unit masked, amdgpu never loaded, all four
dies at index 8, shared window `06:00.0`/`07:00.0` = 770 MiB). Evidence:
`/root/linux-pci-bug-evidence/resource0-resize-7.0.12-vanilla-0b:00.0/`.

| step | what happened |
|---|---|
| `echo 15 > resource0_resize` | write error `ENOSPC` after ~0.45 s; no hang |
| kernel, release phase | `0b:00.0` BAR 0 and BAR 2 `releasing`; `0a:00.0`, `09:00.0`, `08:08.0` windows `releasing`; then `07:00.0` and `06:00.0` (the shared window, `0x9ffc0000000-0x9fff01fffff`) `was not released (still contains assigned resources)` |
| kernel, assign phase | `08:08.0`/`09:00.0`/`0a:00.0` `bridge window [mem size 0x800200000 64bit pref]: can't assign; no space`; `0b:00.0` BAR 0 and BAR 2 likewise; both BARs `old value restored` |
| after the write | `resource0_resize` still index 8, BAR0 still 256 MiB at its firmware address |
| `echo 8` (restore) | rc=0, same release/assign lines, everything back where it was |
| final | `bridge-windows.txt` before and after byte-identical; `0b:00.1` re-bound to `snd_hda_intel` |

What it means: the sibling die `0e:00.0` is assigned inside the shared
window, so `pci_resize_resource()` never releases that window and never
re-sizes it. The three bridges below it then need 32 GiB + 2 MiB inside
770 MiB and fail. The path stops one level *below* `pbus_size_mem()`, so:

- The maintainer's objection is answered, but not with "it fails under the
  same sum". The sanctioned interface does not reach the buggy code on a
  dual-die module at all; only the register write + rescan (the tool's
  method, and the report's reproducer) and amdgpu's probe-time
  `pci_resize_resource()` from a freshly enumerated tree do.
- The sysfs path is not a workaround on a dual-die module on any kernel,
  6.17 and fixed 7.0 included: the pin is the sibling's BARs, not the
  window arithmetic. This replaced the report's predicted "parent re-sized
  to 64G+4M" paragraph with the measured one.
- To-do 2.3 (root-bus GPUs use the sysfs path) is unaffected: a GPU on a
  root port has no sibling in its window.

### Not run, and what would be learned

| kernel | write | question |
|---|---|---|
| 7.0 + fix (7.0.0-30 +barfix1, 7.0.12-barfix) | 15 → 8 → 15 | the shrink should fit in place; whether the grow-back fits inside the already 32 GiB-sized shared window without releasing it has not been measured |
| 6.17 | 15 → 8 → 15 | same question, 48G/96G-style windows |
| any | restore fails | verdict says ATTENTION, script refuses to re-bind; the die is BAR-less: reboot, do not modprobe |

### Recording a result

Done for the 7.0.12 run above; for any further run:

1. Copy the evidence directory into `/root/linux-pci-bug-evidence/` as
   `resource0-resize-<kernel>-<die>/` and add it to the bundle list in
   the report's note-to-self.
2. In `/root/linux-pci-bug-report.txt`, replace the paragraph marked
   `[TO CONFIRM by experiment]` in "What I have not tested" with the
   measured result (the write's return value, the two dmesg lines, the
   parent window before and after), then regenerate the mbox with
   `/root/linux-pci-bug-report-mkmbox.sh`.
3. In the repository README ("Why the usual ways fail here" and "Kernel
   compatibility"), say what was measured; if the path worked somewhere it
   was not expected to, say exactly where.
4. Add the run to the tables above with the real numbers.
