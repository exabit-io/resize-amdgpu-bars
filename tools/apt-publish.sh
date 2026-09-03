#!/bin/bash
# apt-publish.sh - index and sign the flat apt repository that GitHub Pages
# serves for resize-amdgpu-bars (to-do 9.3).
#
#   tools/apt-publish.sh [--key FINGERPRINT] REPO_DIR [FILE.deb ...]
#
# Copies each FILE.deb into REPO_DIR/pool/main/<package>/, rebuilds
# dists/stable/main/binary-amd64/Packages{,.gz,.xz} with apt-ftparchive,
# writes dists/stable/Release and signs it (Release.gpg detached, InRelease
# clearsigned) with the key in the current GNUPGHOME: the Exabit, Inc. apt
# repository key, packages@exabit.io, whose public half is committed as
# keys/resize-amdgpu-bars.gpg and served from the same place. The release
# workflow runs this on the apt-repo branch; a maintainer can run it the
# same way locally.
#
# Layout of REPO_DIR (the apt-repo branch):
#   pool/main/<package>/<package>_<version>_all.deb
#   dists/stable/main/binary-amd64/Packages{,.gz,.xz}
#   dists/stable/{Release,Release.gpg,InRelease}
#   keys/resize-amdgpu-bars.{gpg,asc}
#
# Client line:
#   deb [signed-by=/etc/apt/keyrings/resize-amdgpu-bars.gpg]
#       https://exabit-io.github.io/resize-amdgpu-bars stable main
set -euo pipefail
export LC_ALL=C

prog=${0##*/}
suite=stable
component=main
arch=amd64
origin='Exabit, Inc.'
label=resize-amdgpu-bars
description='resize-amdgpu-bars: Resizable BAR for AMD GPUs behind PCIe'
description+=' switches'
key=''

usage() {
	printf 'usage: %s [--key FINGERPRINT] REPO_DIR [FILE.deb ...]\n' "$prog"
}

die() {
	printf '%s: error: %s\n' "$prog" "$*" >&2
	exit 1
}

while (($#)); do
	case $1 in
	--key)
		(($# > 1)) || die '--key needs a fingerprint'
		key=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option: $1"
		;;
	*)
		break
		;;
	esac
done
(($#)) || { usage >&2; exit 2; }
repo=$1
shift
[[ -d $repo ]] || die "not a directory: $repo"
for f; do
	[[ -f $f ]] || die "not a file: $f"
done
command -v apt-ftparchive > /dev/null \
	|| die 'apt-ftparchive missing (install apt-utils)'

for f; do
	pkg=$(dpkg-deb -f "$f" Package)
	dest=$repo/pool/$component/$pkg
	mkdir -p "$dest"
	cp -- "$f" "$dest/"
	printf 'added %s\n' "$dest/${f##*/}"
done

cd "$repo"
bin=dists/$suite/$component/binary-$arch
mkdir -p "$bin"
apt-ftparchive packages pool > "$bin/Packages"
gzip -9 -k -f "$bin/Packages"
xz -9 -k -f "$bin/Packages"
apt-ftparchive \
	-o "APT::FTPArchive::Release::Origin=$origin" \
	-o "APT::FTPArchive::Release::Label=$label" \
	-o "APT::FTPArchive::Release::Suite=$suite" \
	-o "APT::FTPArchive::Release::Codename=$suite" \
	-o "APT::FTPArchive::Release::Architectures=$arch" \
	-o "APT::FTPArchive::Release::Components=$component" \
	-o "APT::FTPArchive::Release::Description=$description" \
	release "dists/$suite" > "dists/$suite/Release"
rm -f "dists/$suite/Release.gpg" "dists/$suite/InRelease"
gpg_opts=(--batch --yes)
[[ $key ]] && gpg_opts+=(--local-user "$key")
gpg "${gpg_opts[@]}" --detach-sign --armor \
	-o "dists/$suite/Release.gpg" "dists/$suite/Release"
gpg "${gpg_opts[@]}" --clearsign \
	-o "dists/$suite/InRelease" "dists/$suite/Release"

printf 'published %s %s %s:\n' "$repo" "$suite" "$component"
grep -E '^(Package|Version|Filename):' "$bin/Packages"
