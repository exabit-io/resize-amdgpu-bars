#!/bin/bash
# install-gfx906-stack.sh - add the five third-party apt repositories the
# gfx906 workstation stack is built from, their signing keys and the apt
# pins that keep them winning, then install the 68 packages that come from
# them.
#
#   tools/install-gfx906-stack.sh [OPTIONS]
#
#     --only=GROUP[,GROUP...]   install these groups only
#     --skip=GROUP[,GROUP...]   install everything but these
#     --repos-only              sources, keys and pins; install nothing
#     --latest                  newest in each repo, not the pinned versions
#     --dry-run                 print what would be done
#     -h, --help
#
# Groups, and what each one is for:
#
#   gfx906  58  ROCm 10.0.0-gfx906 for Vega 20 / MI50 / MI60. AMD dropped
#               gfx906 from ROCm; mixa3607 builds AMD's TheRock with gfx906
#               enabled and publishes the debs.
#   torch    1  python3-torch-gfx906 2.13.0, built against that ROCm.
#   barfix   6  kernel 7.0.0-31-generic +barfix1, the Ubuntu 7.0 HWE kernel
#               plus the PCI shared-window fix (see the repository README).
#   bars     1  resize-amdgpu-bars 1.1.
#   t2       2  applesmc-t2 and t2fanrd: SMC fan control on Apple T2 Macs.
#               The DKMS module must exist for the kernel that will boot or
#               the machine thermal-throttles silently.
#
# Ubuntu 24.04 (noble) amd64. The package set was verified by resolving the
# whole transaction against an empty dpkg status in a scratch apt root: the
# roots below pull exactly 68 packages from the five repositories, plus
# about 490 ordinary Ubuntu packages, nearly all of them dependencies of
# python3-torch-gfx906.
#
# Not included: the linux-t2-* kernels the t2 repository also carries. The
# barfix kernel is the one that boots; the t2 kernels are an alternative,
# not a companion.
set -euo pipefail
export LC_ALL=C

prog=${0##*/}

# Versions. --latest drops every one of these.
rocm_version='10.0.0-gfx906+20260917140126'
rvs_version='1.6.109-gfx906+20260802001858'
transferbench_version='1.69.0-7.14+gfx906+20260826041541'
torch_version='2.13.0+gfx906.20260917140126-1'
kernel_abi='7.0.0-31'
kernel_version='7.0.0-31.31~24.04.1+barfix1'
bars_version='1.1'
applesmc_version='0.1.4'
t2fanrd_version='0.1.0-4'

# Repositories and the fingerprint each key must have.
gfx906_uri='https://s3.arkprojects.space/apt-gfx906/ubuntu'
gfx906_key_url="$gfx906_uri/gpg"
gfx906_key_fpr='0C24FB39EE3BB45D57F91BF1AF961156FCDA33BD'

exabit_releases='https://github.com/exabit-io/resize-amdgpu-bars/releases'
barfix_uri="$exabit_releases/download/kernel-7.0.0-31.31-24.04.1-barfix1"
torch_uri="$exabit_releases/download/pytorch-2.13.0-gfx906-rocm10.0"
bars_uri='https://exabit-io.github.io/resize-amdgpu-bars'
exabit_key_url="$bars_uri/keys/resize-amdgpu-bars.asc"
exabit_key_fpr='6043AD7B3533F615C15F48D0472316650F4BE230'

t2_pages='https://adityagarg8.github.io/t2-ubuntu-repo'
t2_release='https://github.com/AdityaGarg8/t2-ubuntu-repo/releases'
t2_release+='/download/noble'
t2_key_url="$t2_pages/KEY.gpg"
t2_key_fpr='9F9873A566A73E27CFF0294FE2E496114ACDBFD4'

# The twelve roots that pull all 58 gfx906 packages. The five UNVERSIONED
# metas are listed on purpose: they float to whatever ROCm stream is newest
# in the repository, which is how a half-installed second stream arrives by
# surprise. The version pin below is what holds them.
gfx906_pkgs=(
	amdrocm10.0
	amdrocm10.0-gfx906
	amdrocm-core-sdk10.0
	amdrocm-core-sdk10.0-gfx906
	amdrocm-hpc-sdk10.0-gfx906
	amdrocm-amdsmi
	amdrocm-blas
	amdrocm-llvm
	amdrocm-rand
	amdrocm-runtime
)

all_groups=(gfx906 torch barfix bars t2)
selected=("${all_groups[@]}")
latest=0
dry_run=0
repos_only=0

usage() {
	printf 'usage: %s [--only=GROUPS] [--skip=GROUPS]' "$prog"
	printf ' [--repos-only] [--latest] [--dry-run]\n'
	printf '       groups: %s\n' "${all_groups[*]}"
}

die() {
	printf '%s: error: %s\n' "$prog" "$*" >&2
	exit 1
}

say() {
	printf '==> %s\n' "$*"
}

run() {
	if ((dry_run)); then
		printf '    would run: %s\n' "$*"
	else
		"$@"
	fi
}

# write FILE -- install stdin as FILE, or show the plan under --dry-run
write() {
	if ((dry_run)); then
		cat >/dev/null
		printf '    would write: %s\n' "$1"
	else
		cat >"$1"
		chmod 0644 "$1"
	fi
}

chosen() {
	local g
	for g in "${selected[@]}"; do
		[[ $g == "$1" ]] && return 0
	done
	return 1
}

known_group() {
	local g
	for g in "${all_groups[@]}"; do
		[[ $g == "$1" ]] && return 0
	done
	return 1
}

# pinned NAME VERSION -- NAME=VERSION, or bare NAME under --latest
pinned() {
	if ((latest)); then
		printf '%s' "$1"
	else
		printf '%s=%s' "$1" "$2"
	fi
}

# fetch_key URL FINGERPRINT DEST... -- download the key, refuse it unless
# its primary fingerprint is FINGERPRINT, then install it at each DEST,
# dearmored unless DEST ends in .asc.
fetch_key() {
	local url=$1 want=$2 tmp got dest
	shift 2
	if ((dry_run)); then
		printf '    would fetch %s -> %s\n' "$url" "$*"
		return 0
	fi
	tmp=$(mktemp -d)
	# shellcheck disable=SC2064 # expand tmp now, not at trap time
	trap "rm -rf '$tmp'" RETURN
	curl -fsSL --retry 3 --proto '=https' "$url" -o "$tmp/key"
	got=$(gpg --show-keys --with-colons "$tmp/key" 2>/dev/null |
		awk -F: '/^fpr:/ { print $10; exit }')
	[[ $got == "$want" ]] ||
		die "bad key fingerprint for $url: ${got:-none}, want $want"
	gpg --dearmor <"$tmp/key" >"$tmp/key.gpg"
	for dest in "$@"; do
		if [[ $dest == *.asc ]]; then
			install -m 0644 "$tmp/key" "$dest"
		else
			install -m 0644 "$tmp/key.gpg" "$dest"
		fi
		printf '    %s (%s)\n' "$dest" "$want"
	done
}

while (($#)); do
	case $1 in
	--only=*)
		IFS=, read -r -a selected <<<"${1#*=}"
		;;
	--skip=*)
		IFS=, read -r -a skipped <<<"${1#*=}"
		keep=()
		for group in "${all_groups[@]}"; do
			wanted=1
			for s in "${skipped[@]}"; do
				[[ $group == "$s" ]] && wanted=0
			done
			((wanted)) && keep+=("$group")
		done
		selected=("${keep[@]}")
		;;
	--repos-only)
		repos_only=1
		;;
	--latest)
		latest=1
		;;
	--dry-run)
		dry_run=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown argument: $1"
		;;
	esac
	shift
done

((${#selected[@]})) || die 'no groups selected'
for group in "${selected[@]}"; do
	known_group "$group" ||
		die "unknown group: $group (groups: ${all_groups[*]})"
done

((EUID == 0)) || ((dry_run)) || die 'run as root'
[[ $(dpkg --print-architecture) == amd64 ]] || die 'amd64 only'
# shellcheck disable=SC1091 # /etc/os-release is not a project file
. /etc/os-release
[[ ${VERSION_CODENAME:-} == noble ]] ||
	printf '%s: warning: built for Ubuntu 24.04 (noble), this is %s\n' \
		"$prog" "${VERSION_CODENAME:-unknown}" >&2

note=''
((latest)) && note=' (unpinned)'
say "groups: ${selected[*]}$note"

say 'prerequisites'
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y --no-install-recommends ca-certificates curl gnupg
run install -d -m 0755 /etc/apt/keyrings

if chosen gfx906; then
	say 'gfx906 repository (ROCm for Vega 20, mixa3607)'
	fetch_key "$gfx906_key_url" "$gfx906_key_fpr" \
		/etc/apt/keyrings/apt-gfx906.asc
	write /etc/apt/sources.list.d/gfx906.sources <<-EOF
		Types: deb
		URIs: $gfx906_uri
		Suites: noble
		Components: main
		Architectures: amd64
		Signed-By: /etc/apt/keyrings/apt-gfx906.asc
	EOF
	# The repository carries two complete ROCm streams side by side and
	# the unversioned metas track the newest, so an unattended upgrade
	# can change the stack under you. Priority above 1000 so apt
	# downgrades back if a newer stream appears.
	if ((latest)); then
		run rm -f /etc/apt/preferences.d/rocm-gfx906
	else
		write /etc/apt/preferences.d/rocm-gfx906 <<-EOF
			# Hold the gfx906 ROCm stack on one stream.
			Package: amdrocm*
			Pin: version $rocm_version
			Pin-Priority: 1001
		EOF
	fi
fi

if chosen torch; then
	say 'pytorch-gfx906 repository (Exabit, Inc.)'
	fetch_key "$exabit_key_url" "$exabit_key_fpr" \
		/etc/apt/keyrings/exabit-apt.gpg
	write /etc/apt/sources.list.d/pytorch-gfx906.sources <<-EOF
		# PyTorch for gfx906 on ROCm 10.0, built and signed by Exabit,
		# Inc. and published as a signed flat apt repository inside a
		# GitHub release.
		Types: deb
		URIs: $torch_uri
		Suites: ./
		Signed-By: /etc/apt/keyrings/exabit-apt.gpg
	EOF
fi

if chosen barfix; then
	say "linux-hwe-7.0-barfix repository (kernel $kernel_version)"
	fetch_key "$exabit_key_url" "$exabit_key_fpr" \
		/etc/apt/keyrings/exabit-apt.gpg
	write /etc/apt/sources.list.d/linux-hwe-7.0-barfix.sources <<-EOF
		# The Ubuntu 7.0 HWE kernel plus the PCI shared-window fix,
		# built and signed by Exabit, Inc. The GitHub release is itself
		# a signed flat apt repository.
		Types: deb
		URIs: $barfix_uri
		Suites: ./
		Signed-By: /etc/apt/keyrings/exabit-apt.gpg
	EOF
fi

if chosen bars; then
	say 'resize-amdgpu-bars repository (Exabit, Inc.)'
	fetch_key "$exabit_key_url" "$exabit_key_fpr" \
		/etc/apt/keyrings/resize-amdgpu-bars.gpg
	write /etc/apt/sources.list.d/resize-amdgpu-bars.list <<-EOF
		deb [signed-by=/etc/apt/keyrings/resize-amdgpu-bars.gpg] \
$bars_uri stable main
	EOF
fi

if chosen barfix || chosen bars; then
	# Pin on the label, not the origin: apt_preferences(5) splits the
	# release line on commas, so "o=Exabit, Inc." never matches and the
	# repository quietly stays at the default 500. The kernel needs the
	# 1001 because Ubuntu's own 7.0.0-31.31~24.04.2 respin sorts above
	# ...~24.04.1+barfix1 and would replace the fix.
	if ((latest)); then
		run rm -f /etc/apt/preferences.d/exabit
	else
		write /etc/apt/preferences.d/exabit <<-EOF
			# Prefer Exabit, Inc. packages over the Ubuntu archive,
			# including over a later respin of the same kernel ABI.
			Package: *
			Pin: release l=linux-hwe-7.0-barfix
			Pin-Priority: 1001

			Package: *
			Pin: release l=resize-amdgpu-bars
			Pin-Priority: 1001
		EOF
	fi
fi

if chosen t2; then
	say 't2-ubuntu-repo (AdityaGarg8): fan control, no t2 kernels'
	fetch_key "$t2_key_url" "$t2_key_fpr" \
		/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg
	write /etc/apt/sources.list.d/t2.list <<-EOF
		deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] \
$t2_pages ./
		deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] \
$t2_release ./
	EOF
fi

say 'apt update'
run apt-get update

if ((repos_only)); then
	say 'sources, keys and pins are in place; nothing installed'
	exit 0
fi

pkgs=()
if chosen gfx906; then
	for p in "${gfx906_pkgs[@]}"; do
		pkgs+=("$(pinned "$p" "$rocm_version")")
	done
	pkgs+=("$(pinned rocm-validation-suite "$rvs_version")")
	pkgs+=("$(pinned amdrocm7.14-transferbench "$transferbench_version")")
fi
if chosen torch; then
	pkgs+=("$(pinned python3-torch-gfx906 "$torch_version")")
fi
if chosen barfix; then
	# linux-image pulls linux-modules, linux-headers pulls the ABI
	# headers, linux-tools pulls the ABI tools: six packages.
	for p in image headers tools; do
		pkgs+=("$(pinned "linux-$p-$kernel_abi-generic" \
			"$kernel_version")")
	done
fi
if chosen bars; then
	pkgs+=("$(pinned resize-amdgpu-bars "$bars_version")")
fi
if chosen t2; then
	pkgs+=("$(pinned applesmc-t2 "$applesmc_version")")
	pkgs+=("$(pinned t2fanrd "$t2fanrd_version")")
fi

say "installing ${#pkgs[@]} packages and their dependencies"
printf '    %s\n' "${pkgs[@]}"
run apt-get install -y "${pkgs[@]}"

if chosen t2 && ((dry_run == 0)); then
	# The dpkg trigger builds the DKMS module for the running kernel
	# only. Build it for every installed kernel that has headers, or fan
	# control is dead on the next boot and nothing says so.
	say 'building applesmc-t2 for every installed kernel with headers'
	for build in /lib/modules/*/build; do
		[[ -e $build ]] || continue
		kver=${build%/build}
		kver=${kver##*/}
		printf '    %s: ' "$kver"
		if dkms autoinstall -k "$kver" >/dev/null 2>&1; then
			printf 'ok\n'
		else
			printf 'FAILED, see dkms status\n'
		fi
	done
	systemctl enable --now t2fanrd || true
fi

say 'done'
cat <<-EOF

	Next steps
	  * Reboot into $kernel_abi-generic ($kernel_version) and check that
	    it is what came up: uname -r, and dmesg for the BAR sizes.
	    Ubuntu's own $kernel_abi respin carries the same GRUB menu text.
	  * On a T2 Mac, after every boot: systemctl is-active t2fanrd. If it
	    is dead: dkms autoinstall -k "\$(uname -r)", modprobe applesmc,
	    then restart the service.
	  * ROCm installs into /opt/rocm; check that it sees the dies with
	    /opt/rocm/bin/rocminfo | grep -c gfx906
	  * python3 -c 'import torch; print(torch.cuda.is_available())'
	  * Do not add AMD's official ROCm repository alongside the gfx906
	    one; the packages conflict.
EOF
