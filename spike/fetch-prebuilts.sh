#!/usr/bin/env bash
# Fetch what the exec spike ships, into spike/src/main/{jniLibs,assets} (both gitignored):
#   - Termux's Android build of proot (+ its loader, libtalloc, libandroid-shmem), renamed to
#     lib*.so so Android extracts them to nativeLibraryDir, the one place a targetSdk 29+ app
#     may exec from. patchelf points their DT_NEEDED entries at the renamed libraries.
#   - Ubuntu 24.04 base arm64 rootfs, as an asset the app unpacks on first run.
# Needs curl, ar (binutils), tar, xz and patchelf. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"

TERMUX=https://packages.termux.dev/apt/termux-main
UBUNTU=https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release
libs=src/main/jniLibs/arm64-v8a
assets=src/main/assets
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$libs" "$assets"

curl -fsSL "$TERMUX/dists/stable/main/binary-aarch64/Packages" > "$work/Packages"
for pkg in proot libtalloc libandroid-shmem; do
  f=$(awk -v p="$pkg" '$1 == "Package:" { hit = ($2 == p) } hit && $1 == "Filename:" { print $2; exit }' "$work/Packages")
  [ -n "$f" ] || { echo "no $pkg in the Termux index" >&2; exit 1; }
  echo "termux: $f"
  mkdir -p "$work/$pkg"
  curl -fsSL "$TERMUX/$f" -o "$work/$pkg.deb"
  (cd "$work/$pkg" && ar x "../$pkg.deb" && tar xf data.tar.*)
done
usr=data/data/com.termux/files/usr
install -m 755 "$work/proot/$usr/bin/proot" "$libs/libproot.so"
install -m 755 "$work/proot/$usr/libexec/proot/loader" "$libs/libproot-loader.so"
install -m 644 "$(readlink -f "$work/libtalloc/$usr/lib/libtalloc.so.2")" "$libs/libtalloc.so"
install -m 644 "$work/libandroid-shmem/$usr/lib/libandroid-shmem.so" "$libs/libandroid-shmem.so"
# RUNPATH points into Termux's prefix; the app sets LD_LIBRARY_PATH instead.
patchelf --remove-rpath --replace-needed libtalloc.so.2 libtalloc.so "$libs/libproot.so"
patchelf --remove-rpath --set-soname libtalloc.so "$libs/libtalloc.so"
patchelf --remove-rpath "$libs/libandroid-shmem.so"

tarball=$(curl -fsSL "$UBUNTU/" | grep -o 'ubuntu-base-[0-9.]*-base-arm64\.tar\.gz' | sort -uV | tail -1)
[ -n "$tarball" ] || { echo "no arm64 tarball listed at $UBUNTU" >&2; exit 1; }
echo "ubuntu: $tarball"
curl -fsSL "$UBUNTU/$tarball" -o "$assets/rootfs.tar.gz"
echo "$tarball" > "$assets/rootfs.txt"

ls -l "$libs" "$assets"
