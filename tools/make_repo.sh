#!/usr/bin/env bash
# Rebuild the Sileo/APT repo served by GitHub Pages from docs/.
# Run after build.sh:  wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/tools/make_repo.sh'
# Sileo source URL:    https://langtoi.github.io/tapcore/
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$DIR/docs"
VERSION="$(tr -d ' \r\n' < "$DIR/VERSION")"
DEB="$DIR/build/com.tapcore_${VERSION}_iphoneos-arm64.deb"

[ -f "$DEB" ] || { echo "Missing $DEB - run build.sh first" >&2; exit 1; }
mkdir -p "$REPO/debs"
cp "$DEB" "$REPO/debs/"

cd "$REPO"
dpkg-scanpackages -m debs /dev/null 2>/dev/null > Packages
gzip  -9nkf Packages
bzip2 -9kf  Packages
xz    -9kf  Packages

{
  echo "Origin: TapCore"
  echo "Label: TapCore"
  echo "Suite: stable"
  echo "Version: $VERSION"
  echo "Codename: ios"
  echo "Architectures: iphoneos-arm64"
  echo "Components: main"
  echo "Description: TapCore - AutoTouch-compatible automation for rootless iOS"
  echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "MD5Sum:"
  for f in Packages Packages.gz Packages.bz2 Packages.xz; do
    printf ' %s %s %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
  done
  echo "SHA256:"
  for f in Packages Packages.gz Packages.bz2 Packages.xz; do
    printf ' %s %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
  done
} > Release

touch .nojekyll
echo "Repo updated in $REPO:"
ls -l debs Packages* Release
