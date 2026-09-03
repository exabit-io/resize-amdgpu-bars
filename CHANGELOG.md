# Changelog

Upstream history of resize-amdgpu-bars. Versions before 6.0 were a single
script maintained on the reference machine and never packaged; their entries
are reconstructed from the script headers.

## 7.0 (unreleased)

First public release. Same method as 6.2 with a production finish and the
edge cases found in the 6.2 audit. Scope is fixed: AMD GPUs driven by
`amdgpu`, nothing else.

### Correctness and safety

- A Resizable BAR register write is never followed by a driver load without
  a re-enumeration. A GPU whose register was written is marked dirty; the
  driver is not loaded while any dirty GPU has not been re-enumerated, and a
  write that fails part-way through a plan is rolled back.
- The baseline is the size index observed at first discovery in this boot,
  persisted in the runtime directory, instead of the lowest index the device
  supports. Firmware that already enables Resizable BAR is never shrunk on
  fallback.
- GPUs directly on a root bus use the kernel's sysfs `resource0_resize`
  path, which re-assigns the BAR in place; register-plus-rescan stays for
  switched topologies. Previously such GPUs had their register written and
  were never rescanned, so the plan always failed verification.
- Memory decode is re-enabled by the tool after every register write it
  makes, instead of relying on the kernel's re-probe.
- The global `/sys/bus/pci/rescan` fallback is gone. A group whose own
  rescan file is not writable is a failure for that group; the return value
  of the rescan write is checked.
- Only GPUs being resized, and the other members of their groups, are
  unbound. A card without a Resizable BAR capability keeps its driver and
  its audio.
- Non-amdgpu devices are refused at discovery: vendor and class are checked
  against the `amdgpu` module alias table, so a `radeon`-era card is
  reported and skipped.
- `/etc/default/resize-amdgpu-bars` is validated when read: integers in range,
  PCI address syntax for `EXCLUDE_BDFS`, `FORCE_PLAN` in the allowed set. A
  bad value stops the run with a message and exit status 1.
- An exit handler on EXIT, TERM and INT clears `driver_override`, restores
  memory decode on dirty GPUs, and logs what was left in what state when the
  unit's start timeout or Ctrl-C interrupts a run.
- `LC_ALL=C` and an explicit `PATH`; `set -e` dropped in favour of explicit
  return checks (two of the three bugs in the tool's history were errexit
  plus pipefail); `set -u` kept.
- The `GPU_DRIVER` configuration key is removed.
- Two `local` leaks fixed; the magic sleeps after remove and after bind are
  named constants.

### Production finish

- Colour only when standard error is a terminal; `NO_COLOR` honoured. The
  journal receives plain ASCII, one line per event, no banners or rules.
- `--version`; `--help` generated from a usage function.
- Consistent units: GiB and MiB everywhere.
- Distinct exit codes: 0 full success, 2 degraded (bind guard holding one or
  more GPUs driverless), 1 error. The unit declares `SuccessExitStatus=2`.
- Home-directory paths, dated session notes and kernel test lore removed
  from every shipped file. History is in this file; kernel facts are in the
  README's compatibility section.
- The harness's sysfs override is `RESIZE_AMDGPU_BARS_SYSFS`, documented as
  test-only, alongside `RESIZE_AMDGPU_BARS_STATE_DIR`.

### Packaging and unit

- The `amdgpu` blacklist moves from `/etc/modprobe.d/amdgpu-blacklist.conf`
  to `/usr/lib/modprobe.d/resize-amdgpu-bars.conf`, so it is removed with the
  package (a conffile survived `apt remove` and left the box with no GPU
  driver until purge) and can still be overridden from `/etc/modprobe.d`.
- `update-initramfs -u -k all` in postinst and postrm; `-u` alone rebuilt
  only the newest kernel's initramfs.
- `ExecStartPre=udevadm settle` dropped from the unit; the tool waits for
  its devices itself and the settle failure was a source of confusion at
  boot.
- Unit hardening: `UMask`, `PrivateNetwork`, `RestrictNamespaces`,
  `RestrictRealtime`, `RestrictSUIDSGID`, `LockPersonality`,
  `SystemCallArchitectures`, `ProtectClock`, `ProtectHostname`,
  `ProtectKernelLogs`, `ProtectControlGroups`. `ProtectKernelModules` and
  `ProtectKernelTunables` stay off (modprobe, sysfs writes).
- `Documentation=man:resize-amdgpu-bars(8)` in the unit; the redundant
  `ConditionPathExists` is gone.
- `debian/control` gains `Homepage`, `Vcs-Git`, `Vcs-Browser` and a
  current `Standards-Version`; the long description states the scope and
  the topology. Full MIT licence text in `debian/copyright`.
- Build-time check that the tool's version equals the changelog version.
- `debian/tests/control` runs the harness and the style fixture under
  autopkgtest.
- Unit and package descriptions no longer name a machine model; the Mac Pro
  appears in the README as the reference platform.

### Naming and CLI

- One binary, `resize-amdgpu-bars`, with subcommands `resize` (default;
  `--force` for non-interactive), `status`, `check [-1]`, `dry-run`,
  `diagnose`, `revert`, plus `--version` and `--help`. The separate
  `resize-amdgpu-bars-check` folds in as `check`.
- `check` counts distinct XGMI hive ids instead of "Add node" lines (which
  double-counted on a re-run), drops the legacy `all-large` plan name from
  its acceptance, and no longer parses `ls`.

### Documentation

- Manual pages `resize-amdgpu-bars(8)` and `resize-amdgpu-bars.conf(5)` from
  scdoc sources under `man/`.
- README rewritten around the bridge-window problem, with the reference
  platform as the case study, support tiers, every subcommand, a
  configuration reference, troubleshooting, non-GRUB bootloaders and kernel
  compatibility.
- `CHANGELOG.md`, `CONTRIBUTING.md` (harness, style fixture, boot-test
  checklist) and `SECURITY.md`.

### Style and tests

- Formatting pass to the project style guide (tabs, 80 columns, single
  quotes, `printf`, parameter expansion), shellcheck clean at `-S style`,
  the style fixture vendored under `tests/style/`.
- Mutable globals lowercased, per-group lists as arrays, `while read -r`
  over `for x in $(fn)`.
- New harness cases for every correctness item above, the exit codes, the
  `status` line format, and the guard path with stubbed `modprobe` and
  `timeout`. The harness takes the script path as a required argument.
- CI runs the harness, the style fixture, shellcheck, `dpkg-buildpackage`
  and `lintian`.

## 6.2 (2026-09-02)

Packaging only; the script is unchanged (6.1).

- `dh_installsystemd --no-start`. The 6.0 to 6.1 upgrade started the unit
  because it was in the failed state, which unbound and re-initialised all
  four GPUs on a running machine. The unit is now only enabled; it runs at
  the next boot or on an explicit `systemctl start`, and postinst says so.

## 6.1 (2026-09-02)

- Phase 3 verification read the XGMI hive id from `xgmi_hive_info` as a
  file; it is a directory (`xgmi_hive_info/xgmi_hive_id`), so every read was
  empty and the `grep -v` in the summary pipeline exited 1. Under
  `set -e -o pipefail` that ended the script after "KFD topology nodes",
  before the plan summary, with exit status 1: the unit showed as failed
  although every GPU had been resized and bound. The id file is read, and
  the summary and KFD node-count pipelines can no longer fail the run.
- Test harness: `phase3_verify` runs under errexit and pipefail with and
  without XGMI hives (58 checks).

## 6.0 (2026-09-02)

First packaged release. Everything 5.x had hard-coded is discovered at run
time.

- Run-time discovery of GPUs, their functions, the Resizable BAR capability
  and control register offset, supported sizes, and the bridge chain above
  each GPU. Any mix of cards, with or without Infinity Fabric Link bridges,
  and other PCIe devices coming and going on the bus.
- Re-enumeration root per GPU: the highest bridge whose subtree holds
  nothing but GPU functions. Only such subtrees are ever unbound, removed
  or rescanned, on their own root bus; NICs, HCAs, NVMe carriers and SR-IOV
  virtual functions elsewhere are never touched.
- Generic plan negotiation: all-max, then demote whichever GPUs lost their
  BAR round by round, then baseline. Replaces 5.x's fixed three-plan list.
- Unassigned-BAR detection from sysfs `resource` against a per-boot list of
  the memory BARs each GPU is known to have (lspci omits an unassigned
  region entirely).
- Instance lock; a manual run is refused while the boot-time service is
  working.
- `--dry-run` and `--status`; optional `/etc/default/resize-amdgpu-bars` with
  `MAX_SIZE_INDEX`, `EXCLUDE_BDFS`, `FORCE_PLAN`, `GPU_DRIVER`, timeouts.
- Offline test harness with a fake sysfs tree, stubbed `lspci`/`setpci`,
  and a rule that stands in for the kernel's re-enumeration (kernels that
  behave like 6.x, like an unpatched 7.0, and like a size-limited window).
- `resize-amdgpu-bars-check`: one-line per-boot verdict appended to a matrix
  log.
- Debian packaging: unit, blacklist, GRUB drop-in, default configuration,
  harness as `dh_auto_test`.
- A GPU without a Resizable BAR capability is left alone and still gets
  its driver.

## 5.1 (2026-09-02)

- Refuse a manual run while the boot-time service is still working.
- Tolerate a concurrent re-enumeration of the bus during verification.
- Print an unambiguous `SUCCESS` line when every die is large and bound.
- Kernel matrix recorded: 6.8, 6.11, 6.14 and 6.17 fit every die on the
  first plan; unpatched 7.0 undersizes the shared root-port window and the
  second die of each card loses its BAR at every size. The regression was
  traced to `pbus_size_mem()` in `drivers/pci/setup-bus.c`, a one-line fix
  was written and verified on upstream 7.0.12 and on the Ubuntu 7.0 build.

## 5.0 (2026-08-31)

Rewrite after 4.x produced an unkillable boot hang.

- Plan negotiation: all dies large; first die per card large, the rest at
  baseline; all dies at baseline. The first plan that fully verifies wins.
  Every attempt is a complete remove and rescan cycle from the top-level
  bridges, because writing a size index into the control register assigns
  nothing by itself.
- Hard bind guard: before `modprobe`, any die lacking an assigned BAR0 or
  BAR2 gets `driver_override` set so that `amdgpu` cannot bind to it and
  cannot enter the SR-IOV mailbox path. Healthy dies bind normally.
- `modprobe` under `timeout(1)` so that the service can never wedge the
  boot.
- On total failure the size indices are reset to 256 MiB so that the next
  boot starts from a firmware-assignable layout.
- Root cause of the 4.x hang documented: a die with an unassigned BAR0 is
  misdetected by `amdgpu` as an SR-IOV virtual function and the driver waits
  forever for a hypervisor mailbox, in uninterruptible sleep.

## 4.0 and earlier (2026-08)

Single-machine scripts for the Mac Pro 7,1 with four Vega II Duo dies
hard-coded: write the control register with `setpci`, remove the two
top-level bridges, rescan, load `amdgpu`. 4.0 introduced the `amdgpu`
blacklist so that the driver initialises once with the large BARs (a double
initialisation broke KFD), loaded the driver by `modprobe` after the
rescan, and always loaded the driver even when the resize had failed, which
is what turned a recoverable BAR failure into the boot hang that 5.0 fixed.
