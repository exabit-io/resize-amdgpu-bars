# Security

## What this tool is

resize-amdgpu-bars runs as root, once per boot, from a systemd unit that
starts before the display manager. It rewrites PCI configuration space,
removes and rescans PCI buses, and loads a kernel module. There is no
network access, no listener, no setuid component and no interface exposed
to unprivileged users; the only inputs it reads are sysfs, the output of
`lspci` and `setpci`, and `/etc/default/resize-amdgpu-bars`.

## What it writes

As root, and only on AMD GPUs that `amdgpu` claims:

- PCI configuration space, through `setpci`: the Resizable BAR control
  register (the size index) and the COMMAND register (memory decode is
  disabled around the size change and re-enabled afterwards) of the GPUs
  it resizes.
- sysfs, through plain writes: `remove` on the root bridge of a GPU
  subtree and `rescan` on that root's own bus; `driver_override`, `unbind`
  and `bind` of GPU functions and their sibling functions (HDMI audio);
  `resourceN_resize` of a GPU that sits directly on a root bus.
- One kernel module load: `modprobe amdgpu`, under `timeout(1)`.
- Its own files: `/run/resize-amdgpu-bars/` (per-boot state),
  `/run/lock/resize-amdgpu-bars.lock`, and, from the `check` subcommand,
  `/var/log/resize-amdgpu-bars/kernel-matrix.log`.

## What it never touches

- Any PCI device that is not a function of an AMD GPU handled by `amdgpu`,
  and any bridge whose subtree contains such a device. NICs, HCAs, NVMe
  controllers, Thunderbolt controllers and SR-IOV virtual functions are
  never unbound, removed or rescanned. The tool lists them at discovery as
  the devices it promises to leave alone.
- The global `/sys/bus/pci/rescan`.
- Firmware, NVRAM, the bootloader, the kernel command line, the initramfs,
  or any configuration file. (The package's maintainer scripts run
  `update-initramfs` and `update-grub` at install and removal; the tool
  itself does not.)
- Anything on the network.

The systemd unit runs the tool with `ProtectSystem=strict`,
`ProtectHome=yes`, `PrivateTmp=yes`, `PrivateNetwork=yes`,
`NoNewPrivileges=yes`, a capability bounding set of `CAP_SYS_ADMIN`,
`CAP_SYS_RAWIO`, `CAP_DAC_OVERRIDE` and `CAP_SYS_MODULE`, and read-write
access only to `/sys/bus/pci`, `/sys/devices`, `/run/lock` and its own
runtime directory. `ProtectKernelModules` and `ProtectKernelTunables` are
off because loading `amdgpu` and writing sysfs are the job.

## Configuration file

`/etc/default/resize-amdgpu-bars` is sourced as shell by a root process. It is
a root-owned file under `/etc` with the same trust as any other file there;
the tool validates the values it uses but cannot make sourcing a file safe
against a writer who already has root. Keep it root-owned and not
world-writable, as the package installs it.

## Known hazards

Handing `amdgpu` a GPU with an unassigned BAR0 hangs the machine in
uninterruptible sleep; the bind guard exists to prevent that, and clearing
a `driver_override` the guard set, while the BAR is still unassigned, will
reproduce the hang. Running `resize` on a live system unbinds every AMD GPU
and every process using one loses it; the package never starts the unit for
that reason. Neither is a vulnerability, but both are worth knowing before
running the tool by hand.

## Reporting

Report a vulnerability privately by email to security@exabit.io. Do not
open a public issue for it.
Include the version (`resize-amdgpu-bars --version`), the distribution and
kernel, and what you observed; a `diagnose` output helps when the problem
depends on the topology. You will get an acknowledgement, and a fix or an
explanation before anything is published. Ordinary bugs go to the issue
tracker with the material listed in the README under "Reporting bugs".
