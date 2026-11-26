#!/usr/bin/env bash
# Rebuild the Sileo/APT repo served by GitHub Pages from docs/.
# Run from the repo root after build.sh:  bash tools/make_repo.sh
# Works on Linux/WSL and macOS (needs dpkg-deb, openssl, gzip, bzip2, xz).
# Sileo source URL: https://langtoi.github.io/tapcore/
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$DIR/docs"
VERSION="$(tr -d ' \r\n' < "$DIR/VERSION")"
NAME="com.tapcore_${VERSION}_iphoneos-arm64.deb"
DEB="$DIR/build/$NAME"

[ -f "$DEB" ] || { echo "Missing $DEB - run build.sh first" >&2; exit 1; }
mkdir -p "$REPO/debs"
# Keep only the package being published; older versions stay in git history.
find "$REPO/debs" -name 'com.tapcore_*_iphoneos-arm64.deb' ! -name "$NAME" -delete
cp "$DEB" "$REPO/debs/"

hash_of() { openssl dgst "-$1" -r "$2" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }

cd "$REPO"
: > Packages
for deb in debs/*.deb; do
  dpkg-deb -f "$deb" >> Packages
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
