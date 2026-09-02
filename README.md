# resize-gpu-bars

Boot-time Resizable BAR enlargement for AMD GPUs on the Mac Pro 7,1 (any mix
of MPX cards: Radeon Pro 580X, W5500X, W5700X, W6600X, W6800X, W6800X Duo,
W6900X, Vega II, Vega II Duo, with or without Infinity Fabric Link bridges),
with a bind guard that keeps amdgpu away from a die whose BAR could not be
assigned. Other PCIe devices (NICs, HCAs, NVMe carriers, SR-IOV VFs) are
never touched: only subtrees that contain nothing but GPU functions are
re-enumerated, on their own root bus.

## What the package installs

| path | purpose |
|---|---|
| `/usr/sbin/resize_gpu_bars.sh` | the script (`--help` for modes) |
| `/usr/sbin/resize-gpu-bars-check` | one-line per-boot verdict, appended to `/var/log/resize-gpu-bars/kernel-matrix.log` |
| `/usr/lib/systemd/system/resize-gpu-bars.service` | runs the script with `--force` early in boot; enabled on install, never started or restarted by the package (that would unbind and re-initialise every GPU) |
| `/etc/modprobe.d/amdgpu-blacklist.conf` | keeps amdgpu from autoloading before the resize (initramfs is refreshed on install) |
| `/etc/default/grub.d/resize-gpu-bars.cfg` | adds `pci=realloc` to the kernel command line (`update-grub` is run on install) |
| `/etc/default/resize-gpu-bars` | optional overrides (size cap, exclusions, forced plan, timeouts) |
| `/usr/share/resize-gpu-bars/tests/` | offline test harness with a fake sysfs tree |

**A reboot is required after installation** (blacklist + `pci=realloc`).

## After the first boot

```bash
journalctl -u resize-gpu-bars.service -b      # expect "Plan 'all-max' verified" and "SUCCESS:"
resize-gpu-bars-check                         # one line: verdict=WORKS plan=all-max large=N/N
resize_gpu_bars.sh --status
rocminfo | grep -c gfx                        # with ROCm installed
```

## Kernel requirement

Kernels 6.8 through 6.17 fit every die on the first plan. Unpatched 7.0
(Ubuntu 7.0.0-30, upstream 7.0.12) undersizes the shared root-port window
whenever two dies sit behind one root port (Duo cards), so the second die of
each card loses its BAR at every size; the bind guard then leaves it
driverless. Use a 6.x kernel or a 7.0 build carrying the fix for
`drivers/pci/setup-bus.c` (upstream commit 3958bf16e2fe regression; the
patch and a rebuilt Ubuntu HWE kernel ship in the same local repository as
this package).

## Removal

`apt purge resize-gpu-bars` disables the unit, removes the blacklist and the
GRUB drop-in, and refreshes the initramfs and GRUB. Reboot afterwards.
