#!/usr/bin/env bash
# Rebuild the Sileo/APT repo served by GitHub Pages from docs/.
# Usage:
#   bash tools/make_repo.sh                  # publish build/com.tapcore_<VERSION>_*.deb & refresh repo
#   bash tools/make_repo.sh --reindex        # refresh Packages* & Release from existing docs/debs/*.deb
#   bash tools/make_repo.sh --add <file.deb> # add/replace another package .deb & refresh repo
# Works on Linux/WSL and macOS (needs dpkg-deb, openssl, gzip, bzip2, xz).
# Sileo source URL: https://langtoi.github.io/tapcore/
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$DIR/docs"
VERSION="$(tr -d ' \r\n' < "$DIR/VERSION")"
NAME="com.tapcore_${VERSION}_iphoneos-arm64.deb"
DEB="$DIR/build/$NAME"

mkdir -p "$REPO/debs"

MODE="${1:-}"
if [ "$MODE" = "--reindex" ]; then
  :
elif [ "$MODE" = "--add" ]; then
  ADD_DEB="${2:-}"
  [ -n "$ADD_DEB" ] && [ -f "$ADD_DEB" ] || { echo "Usage: $0 --add <path/to/package.deb>" >&2; exit 1; }
  PKG_ID="$(dpkg-deb -f "$ADD_DEB" Package | tr -d ' \r\n')"
  [ -n "$PKG_ID" ] || { echo "Could not read Package field from $ADD_DEB" >&2; exit 1; }
  ADD_NAME="$(basename "$ADD_DEB")"
  find "$REPO/debs" -name "${PKG_ID}_*_iphoneos-arm64.deb" ! -name "$ADD_NAME" -delete
  cp "$ADD_DEB" "$REPO/debs/$ADD_NAME"
else
  [ -f "$DEB" ] || { echo "Missing $DEB - run build.sh first (or pass --reindex)" >&2; exit 1; }
  # Keep only the TapCore version being published; other packages in docs/debs/ are preserved.
  find "$REPO/debs" -name 'com.tapcore_*_iphoneos-arm64.deb' ! -name "$NAME" -delete
  cp "$DEB" "$REPO/debs/"
fi

hash_of() { openssl dgst "-$1" -r "$2" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }

cd "$REPO"
: > Packages
shopt -s nullglob
for deb in $(LC_ALL=C printf '%s\n' debs/*.deb | LC_ALL=C sort); do
  dpkg-deb -f "$deb" | tr -d '\r' >> Packages
  {
    echo "Filename: $deb"
    echo "Size: $(size_of "$deb")"
    echo "MD5sum: $(hash_of md5 "$deb")"
    echo "SHA1: $(hash_of sha1 "$deb")"
    echo "SHA256: $(hash_of sha256 "$deb")"
    echo
  } >> Packages
done
gzip  -9nc Packages > Packages.gz
bzip2 -9c  Packages > Packages.bz2
xz    -9c  Packages > Packages.xz

{
  echo "Origin: TapCore"
  echo "Label: TapCore"
  echo "Suite: stable"
  echo "Version: $VERSION"
  echo "Codename: ios"
  echo "Architectures: iphoneos-arm64"
  echo "Components: main"
  echo "Description: TapCore - lightweight Lua automation for rootless iOS"
  echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "MD5Sum:"
  for f in Packages Packages.gz Packages.bz2 Packages.xz; do
    echo " $(hash_of md5 "$f") $(size_of "$f") $f"
  done
  echo "SHA256:"
  for f in Packages Packages.gz Packages.bz2 Packages.xz; do
    echo " $(hash_of sha256 "$f") $(size_of "$f") $f"
  done
} > Release

touch .nojekyll
echo "Repo updated in $REPO:"
ls -l debs Packages* Release
