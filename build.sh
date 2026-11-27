#!/usr/bin/env bash
# Build TapCore for rootless iOS (arm64) and package it as a .deb.
#
#   Linux / WSL:  needs Theos in /opt/theos (toolchain + iPhoneOS16.5.sdk), ldid, dpkg-deb
#   macOS (CI):   needs Xcode, ldid, dpkg; set TAPCORE_SDK to an iPhoneOS16.5.sdk from theos/sdks
#
# Usage, from the repo root:  bash build.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d ' \r\n' < "$DIR/VERSION")"

if [ "$(uname -s)" = "Darwin" ]; then
  CLANG="$(xcrun --find clang)"
  SDK="${TAPCORE_SDK:?Set TAPCORE_SDK to an iPhoneOS16.5.sdk directory (theos/sdks)}"
  TOOLCHAIN_FLAGS=()
  PLATFORM_FLAGS=()            # Apple ld derives the platform version from -target and the SDK
else
  TOOLCHAIN="/opt/theos/toolchain/linux/iphone/bin"
  CLANG="$TOOLCHAIN/clang"
  SDK="${TAPCORE_SDK:-/opt/theos/sdks/iPhoneOS16.5.sdk}"
  TOOLCHAIN_FLAGS=(-B"$TOOLCHAIN")
  PLATFORM_FLAGS=(-Wl,-platform_version,ios,15.0,16.5)
fi

LUA_SRC="$DIR/third_party/lua-5.3.6/src"
BUILD="$DIR/build"
APP="$BUILD/TapCore.app"
mkdir -p "$DIR/third_party" "$BUILD/lua_obj" "$APP"

if [ ! -f "$LUA_SRC/lapi.c" ]; then
  echo "[0/5] Downloading Lua 5.3.6..."
  curl -fsSL https://www.lua.org/ftp/lua-5.3.6.tar.gz | tar -xz -C "$DIR/third_party"
fi

COMMON_FLAGS=(
  ${TOOLCHAIN_FLAGS[@]+"${TOOLCHAIN_FLAGS[@]}"}
  -target arm64-apple-ios15.0
  -arch arm64
  -miphoneos-version-min=15.0
  -isysroot "$SDK"
  -O2
)

echo "[1/5] Building Lua 5.3.6 objects (arm64)..."
if [ ! -f "$BUILD/lua_obj/linit.o" ]; then
  LUA_FILES=(
    lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c
    lmem.c lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c
    ltm.c lundump.c lvm.c lzio.c
    lauxlib.c lbaselib.c lbitlib.c lcorolib.c ldblib.c liolib.c
    lmathlib.c loslib.c lstrlib.c ltablib.c lutf8lib.c loadlib.c linit.c
  )
  for f in "${LUA_FILES[@]}"; do
    obj="$BUILD/lua_obj/${f%.c}.o"
    if [ "$f" = "loslib.c" ]; then
      # iOS SDK has no system(); route os.execute through /var/jb/bin/sh
      sed 's/int stat = system(cmd);/extern int tapcore_ios_system(const char *); int stat = tapcore_ios_system(cmd);/' \
        "$LUA_SRC/loslib.c" > "$BUILD/lua_obj/loslib_ios.c"
      "$CLANG" "${COMMON_FLAGS[@]}" -DLUA_USE_POSIX -I"$LUA_SRC" -c "$BUILD/lua_obj/loslib_ios.c" -o "$obj"
    else
      "$CLANG" "${COMMON_FLAGS[@]}" -DLUA_USE_POSIX -c "$LUA_SRC/$f" -o "$obj"
    fi
  done
fi

echo "[2/5] Building tapcore daemon..."
"$CLANG" "${COMMON_FLAGS[@]}" \
  ${PLATFORM_FLAGS[@]+"${PLATFORM_FLAGS[@]}"} \
  -fobjc-arc \
  -Wl,-dead_strip \
  "-DTAPCORE_VERSION=\"$VERSION\"" \
  -I"$LUA_SRC" \
  -I"$DIR/src" \
  -framework Foundation \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework CoreVideo \
  -framework ImageIO \
  -framework IOSurface \
  -framework Vision \
  -framework Photos \
  "$DIR/src/lua_socket.m" \
  "$DIR/src/lua_json.m" \
  "$DIR/src/lua_http.m" \
  "$DIR/src/backup_upload.m" \
  "$DIR/src/core.m" \
  "$DIR/src/runner.m" \
  "$DIR/src/web.m" \
  "$DIR/src/main.m" \
  "$BUILD/lua_obj"/*.o \
  -lm \
  -o "$BUILD/tapcore"
ldid -S"$DIR/entitlements.plist" "$BUILD/tapcore"

echo "[3/5] Building TapCoreInput.dylib..."
"$CLANG" "${COMMON_FLAGS[@]}" \
  -dynamiclib \
  -Wl,-dead_strip \
  ${PLATFORM_FLAGS[@]+"${PLATFORM_FLAGS[@]}"} \
  -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.dylib \
  -fobjc-arc \
  -framework Foundation \
  -framework CoreFoundation \
  -framework UIKit \
  "$DIR/tweak/TapCoreInput.m" \
  -o "$BUILD/TapCoreInput.dylib"
ldid -S "$BUILD/TapCoreInput.dylib"

echo "[4/5] Building TapCore.app..."
"$CLANG" "${COMMON_FLAGS[@]}" \
  ${PLATFORM_FLAGS[@]+"${PLATFORM_FLAGS[@]}"} \
  -fobjc-arc \
  -framework Foundation \
  -framework UIKit \
  -framework WebKit \
  -Wl,-dead_strip \
  -framework AudioToolbox \
  "$DIR/app/main.m" \
  -o "$APP/TapCore"
cp "$DIR/app/Info.plist" "$APP/Info.plist"
cp "$DIR/app/AppIcon60x60@2x.png" "$DIR/app/AppIcon60x60@3x.png" "$APP/"
ldid -S"$DIR/app/entitlements.plist" "$APP/TapCore"

echo "[5/5] Packaging com.tapcore_${VERSION}_iphoneos-arm64.deb..."
# Stage in a temp dir: a Windows drive mounted in WSL (NTFS) cannot hold the 0755/0644 modes dpkg-deb requires.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"
JB="$STAGE/var/jb"
install -d "$JB/usr/bin" "$JB/Library/LaunchDaemons" "$JB/Library/MobileSubstrate/DynamicLibraries" \
           "$JB/Applications/TapCore.app" "$JB/usr/share/tapcore/web" "$JB/usr/share/tapcore/lib" "$STAGE/DEBIAN"

install -m 0755 "$BUILD/tapcore"                         "$JB/usr/bin/tapcore"
install -m 0644 "$DIR/packaging/com.tapcore.daemon.plist" "$JB/Library/LaunchDaemons/com.tapcore.daemon.plist"
install -m 0755 "$BUILD/TapCoreInput.dylib"              "$JB/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.dylib"
install -m 0644 "$DIR/tweak/TapCoreInput.plist"          "$JB/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.plist"
install -m 0755 "$APP/TapCore"                           "$JB/Applications/TapCore.app/TapCore"
install -m 0644 "$APP/Info.plist" "$APP/AppIcon60x60@2x.png" "$APP/AppIcon60x60@3x.png" "$JB/Applications/TapCore.app/"
install -m 0644 "$DIR/web/index.html"                    "$JB/usr/share/tapcore/web/index.html"
install -m 0644 "$DIR/scripts/sv.lua"                    "$JB/usr/share/tapcore/sv.lua"

for s in preinst postinst prerm; do
  tr -d '\r' < "$DIR/packaging/$s" > "$STAGE/DEBIAN/$s"
  chmod 0755 "$STAGE/DEBIAN/$s"
done
INSTALLED_KB="$(du -sk "$STAGE/var" | cut -f1)"
tr -d '\r' < "$DIR/packaging/control" | sed "s/@VERSION@/$VERSION/" > "$STAGE/DEBIAN/control"
echo "Installed-Size: $INSTALLED_KB" >> "$STAGE/DEBIAN/control"
chmod 0644 "$STAGE/DEBIAN/control"

DEB="$BUILD/com.tapcore_${VERSION}_iphoneos-arm64.deb"
rm -f "$BUILD"/com.tapcore_*_iphoneos-arm64.deb
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$DEB" >/dev/null

ls -lh "$BUILD/tapcore" "$BUILD/TapCoreInput.dylib" "$APP/TapCore" "$DEB"
echo "Next: bash tools/make_repo.sh   (copies the .deb into docs/ and rebuilds the Sileo index)"
