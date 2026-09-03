resize-amdgpu-bars-check(8)

# NAME

resize-amdgpu-bars-check - one-line verdict for a resize-amdgpu-bars boot

# SYNOPSIS

*resize-amdgpu-bars-check* [*-1*]

# DESCRIPTION

Reads the journal of the current boot (or, with *-1*, the previous one) for
resize-amdgpu-bars.service and the kernel, plus live sysfs and
*resize-amdgpu-bars status* for the current boot, and prints one line that
scores the boot. For the current boot the line is also appended to a matrix
log so kernels and cards can be compared across reboots. Read-only.

The line carries, space-separated: boot time, kernel version, *verdict=*
(WORKS, FAILS (bind guard held), NO RESIZABLE GPU, OTHER - inspect, with
"+ TRACE/SRIOV NOISE" appended when the kernel log shows traces or the
SR-IOV mailbox wait), *plan=*, *large=*, *driverless=*, *windows=* (the
prefetchable window of every root port that carries a GPU), *bar0=* (every
GPU's BAR0 size), *kfd=* (KFD topology nodes), *xgmi_hives=* (distinct XGMI
hive ids from sysfs), *traces=*, *rejected=* and the list of GPUs the bind
guard held back, if any. Live-only fields read "(live only)" for a previous
boot.

# ENVIRONMENT

*LOG*
	Matrix log path. Default
	/var/log/resize-amdgpu-bars/kernel-matrix.log.

*RESIZE_AMDGPU_BARS_SYSFS*
	Test-only: sysfs root to read instead of /sys.

# FILES

/var/log/resize-amdgpu-bars/kernel-matrix.log

# SEE ALSO

*resize-amdgpu-bars*(8), *journalctl*(1)
