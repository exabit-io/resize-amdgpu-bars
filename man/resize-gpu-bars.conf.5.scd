resize-gpu-bars.conf(5)

# NAME

resize-gpu-bars.conf - configuration file for resize-gpu-bars

# SYNOPSIS

_/etc/default/resize-gpu-bars_

# DESCRIPTION

*resize-gpu-bars*(8) reads _/etc/default/resize-gpu-bars_ at the start of
every run, if the file exists. The file is sourced by the shell, so it uses
shell assignment syntax: one _KEY=value_ per line, values with spaces in
double quotes, *#* starts a comment. Every key is optional; an absent key
takes the default given below. Nothing else in the file is used, and the
file should contain nothing but assignments and comments.

The file is validated when it is read. A value that is not an integer where
an integer is expected, an integer outside its range, a malformed PCI
address in *EXCLUDE_BDFS*, or a *FORCE_PLAN* outside the allowed set is
reported on standard error and the tool exits with status 1 before touching
any device. The service therefore fails loudly at boot rather than part-way
through a resize.

Do not confuse this file with _/usr/lib/modprobe.d/resize-gpu-bars.conf_,
which holds the *amdgpu* blacklist and is not a configuration file of the
tool.

# KEYS

*MAX_SIZE_INDEX*=_n_
	Cap every GPU at Resizable BAR size index _n_. A size index _n_ means
	2^(_n_+20) bytes; the tool targets the largest index a device
	supports, or _n_ if that is smaller. Empty (the default) means the
	device maximum. Integer, 0 to 43. A device that does not support the
	capped index is targeted at the largest index it does support below
	the cap.

	```
	index   8   9    10   11   12   13   14    15    16
	BAR   256M 512M 1G   2G   4G   8G   16G   32G   64G   (MiB / GiB)
	```

*EXCLUDE_BDFS*="_bdf_ [_bdf_ ...]"
	GPUs to leave completely alone, as space-separated PCI addresses in
	the form _domain:bus:device.function_, for example
	*"0000:0b:00.0 0000:0e:00.0"*. An excluded GPU is not resized and not
	unbound, its subtree is never removed or rescanned, and its driver
	loads normally with whatever BAR the firmware assigned. Note that a
	GPU sharing a bridge with an excluded GPU cannot have its window
	re-sized either, because the shared subtree is no longer removable.
	Default: empty.

*FORCE_PLAN*=_all-max_|_baseline_
	Skip the negotiation and try exactly one plan. _all-max_ puts every
	resizable GPU at its target size and, if that does not verify, gives
	up and leaves the bind guard to deal with the losers. _baseline_ puts
	every GPU at the size observed at first discovery in this boot, which
	is what *resize-gpu-bars revert* does. Empty (the default) negotiates:
	all-max first, then demote the losers round by round, then baseline.

*MODPROBE_TIMEOUT*=_seconds_
	How long *modprobe amdgpu* may run before it is sent SIGTERM (and
	SIGKILL 30 seconds later). A driver that hangs in the SR-IOV mailbox
	path cannot be killed at all; the timeout exists so that the service
	fails and boot continues instead of waiting forever. Default: 180.

*PROBE_WAIT*=_seconds_
	How long to wait, after the driver is loaded, for every unguarded GPU
	to bind and for the KFD topology to stop changing. Default: 60.

*RESCAN_WAIT*=_seconds_
	How long to wait for every GPU to reappear after a subtree has been
	removed and its bus rescanned. Default: 30.

*MAX_ROUNDS*=_n_
	Maximum number of demote-and-retry rounds between the _all-max_ plan
	and the _baseline_ plan. Each round is a full unbind, program,
	remove, rescan cycle of about ten seconds. Default: 8.

*GPU_DRIVER*
	Accepted by 6.x, no longer read: the tool handles *amdgpu* devices
	only.

# TIMING CONSTRAINT

The service unit stops the run after *TimeoutStartSec* (480 seconds by
default). The budget is discovery, up to *MAX_ROUNDS* re-enumeration cycles
of about ten seconds each, *MODPROBE_TIMEOUT* plus the 30-second kill grace,
*PROBE_WAIT*, and a margin. Keep *MODPROBE_TIMEOUT* + *PROBE_WAIT* +
*MAX_ROUNDS* x *RESCAN_WAIT* comfortably below *TimeoutStartSec*, or raise
the latter with a drop-in under
_/etc/systemd/system/resize-gpu-bars.service.d/_.

# EXAMPLE

```
# /etc/default/resize-gpu-bars
# Cap at 16 GiB, leave the card in bay 2 alone, allow a slow driver.
MAX_SIZE_INDEX=14
EXCLUDE_BDFS="0000:1b:00.0 0000:1e:00.0"
MODPROBE_TIMEOUT=300
```

# FILES

_/etc/default/resize-gpu-bars_
	This file. Shipped with every key commented out and its default
	shown.

_/run/resize-gpu-bars/_
	Where the baseline size index of each GPU is recorded for the current
	boot; not a configuration file, but the reason *baseline* means what
	it means.

# SEE ALSO

*resize-gpu-bars*(8), *systemd.unit*(5)
