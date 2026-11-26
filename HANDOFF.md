# TapCore — Technical Handoff

Technical notes for an engineer or AI picking up TapCore. Full API details are in [API.md](API.md).

TapCore is the new name of the project previously called `ghost-atd` / GhostStudio. The `.deb` removes the old install automatically.

---

## 1. Goal & context
- Replace **AutoTouch** (`ATTweak.dylib` hooks SpringBoard, can trigger Safe Mode, needs a license) with a lightweight, stable runtime that runs `sv.lua` (HTTP `:3000`) unmodified for the **BAS** client.
- Real BAS payload mix (331 requests to `:3000`): **66%** Vision OCR (`text` + `click`/`check`/`click3`/`hold`), **21%** `RUNLUA` (`execute`, `touchDown/Move/Up`, `keyDown/Up HOME_BUTTON`, `clearSystemAlbum`, `copyText`, `appKill`), **5%** `URL`, **5%** `TEXT`, **3%** `COLOR`/`findColor`, **<1%** `findImage`.
- Components:
  1. Root daemon `tapcore`: Lua 5.3.6 + 21 native functions + multi-script runner + web server + touch recorder + system tools.
  2. `TapCoreInput.dylib`: only serves `copyText` and Unicode typing; **hooks nothing and skips SpringBoard**.
  3. iOS app `TapCore.app` (UIKit, bundle id `com.tapcore.app`).
  4. Web Studio `web/index.html` (no CDN dependencies).

---

## 2. Build environment & test device
- **Build:** Windows + WSL Ubuntu with `/opt/theos` (`clang` LLVM-19, `ld64.lld`, `/opt/theos/sdks/iPhoneOS16.5.sdk`, `ldid`, `dpkg-deb`, `dpkg-scanpackages`).
- **Test device:** iPhone X (`iPhone10,3`, `1125×2436`), **iOS 16.7.12** (`20H364`), **rootless** jailbreak (`/var/jb`, Dopamine/Procursus).
  - The shell on the device is `/var/jb/bin/sh` (**there is no `/bin/sh`**).
  - Device IPs and SSH passwords are not stored in the repo; `tools/deploy_verify.py` reads the password from `TAPCORE_SSH_PASS` or prompts for it.

---

## 3. Source layout

```text
tapcore/
├── VERSION                   # Package version (.deb and Sileo repo)
├── build.sh                  # Build Lua objects, daemon, dylib, app, then package the .deb
├── entitlements.plist        # Private entitlements for the daemon (HID, IOSurface, QuartzCore, Photos)
├── API.md / HANDOFF.md / README.md
├── src/
│   ├── tapcore.h             # Shared header (paths, internal API)
│   ├── core.m                # 21 native APIs: IOKit HID touch/key/recorder, CARenderServer, OCR, findImage, IPC :3001, logger
│   ├── runner.m              # Multi-script runner (instant Stop via lua_sethook), config.json, print() -> Live Console
│   ├── web.m                 # HTTP server :8080 (fallback :8088), REST API, /control/*, /api/system
│   ├── lua_socket.m          # LuaSocket replacement on POSIX sockets with interruptible poll()
│   ├── lua_json.m            # json.lua replacement on NSJSONSerialization
│   └── main.m                # Entry point: raise Jetsam to 512 MB, IPC, config, web server, auto-start
├── tweak/
│   ├── TapCoreInput.m        # Dylib: Darwin notify com.tapcore.cmd -> TCP 127.0.0.1:3001 -> UIPasteboard / UIKeyInput
│   └── TapCoreInput.plist    # Filter: com.apple.UIKit
├── app/                      # TapCore.app: main.m, Info.plist, entitlements, icon PNGs
├── web/index.html            # Web Studio
├── scripts/sv.lua            # Reference sv.lua for BAS (installed only when the device has none)
├── packaging/                # control, preinst, postinst, prerm, com.tapcore.daemon.plist
├── assets/make_icons.py      # Renders the TapCore logo to every PNG size
├── tools/
│   ├── make_repo.sh          # Copy the .deb into docs/debs and generate Packages*, Release
│   └── deploy_verify.py      # Install the .deb on one device over SSH and run smoke tests
└── docs/                     # Sileo repo served by GitHub Pages: https://langtoi.github.io/tapcore/
```

### Installed paths on a rootless iPhone
| Component | Path |
|---|---|
| Daemon | `/var/jb/usr/bin/tapcore` |
| LaunchDaemon | `/var/jb/Library/LaunchDaemons/com.tapcore.daemon.plist` (label `com.tapcore.daemon`) |
| Dylib | `/var/jb/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.dylib` + `.plist` |
| App | `/var/jb/Applications/TapCore.app` |
| Web UI, reference sv.lua | `/var/jb/usr/share/tapcore/web/index.html`, `/var/jb/usr/share/tapcore/sv.lua` |
| Configuration | `/var/jb/var/mobile/Library/TapCore/config.json` |
| Scripts, template images | `/var/jb/var/mobile/Library/AutoTouch/Scripts/` and `Screenshots/` (AutoTouch name kept so BAS needs no changes) |
| Runtime | `/tmp/tapcore.port` (active web port), `/tmp/tapcore.log` |

---

## 4. Build, release & install

```bash
# 1. Build + package the .deb (WSL)
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/build.sh'

# 2. Refresh the Sileo repo in docs/
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/tools/make_repo.sh'

# 3. Commit + push: GitHub Pages serves docs/ and Sileo sees the new version
git add -A && git commit -m "TapCore x.y.z" && git push
```

- **New release:** bump `VERSION`, then repeat the three steps.
- **Install on an iPhone:** Sileo → Sources → add `https://langtoi.github.io/tapcore/` → install **TapCore**.
- **Quick dev install on one device over SSH:** `python tools\deploy_verify.py <iphone-ip>`.
- `preinst` removes the old `ghost-atd` install (daemon `com.ghost.atd`, `ghost_input.dylib`, `GhostStudio.app`) and migrates `config.json` to the TapCore folder.

---

## 5. Critical iOS 16.7.12 notes (do not regress)
1. **Touch & swipe (`IOHIDEvent`):** detect the real digitizer `SenderID` via `IOHIDEventSystemClientCopyServices` (`PrimaryUsagePage == 0x0D`, `PrimaryUsage == 0x04/0x05`) and set `kIOHIDEventFieldDigitizerIsDisplayIntegrated = 1`. `touchDown/Move/Up` use `fingerID = id + 1` to avoid `fingerID = 0`.
2. **Typing:** pure ASCII is always typed with the HID keyboard (`IOHIDEventCreateKeyboardEvent`, `usagePage = 0x07`), which also works in password fields. **Do not call `UIKeyboardImpl insertText:` before HID**: on iOS 16 it acknowledges without filling password fields. The dylib is only for `copyText` (the CLI daemon gets `PBErrorDomain Code=11`) and non-ASCII strings.
3. **Screen capture & OCR:** one reusable `IOSurfaceRef` + `CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0)` (~17 ms/frame). Do not use `kIOSurfaceIsGlobal`. Requires `iokit-user-client-class` (`IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`) + `no-sandbox` + `QuartzCore.global-capture/secure-capture/displayable-context` entitlements.
4. **Jetsam:** launchd daemons get a low memory limit and OCR gets killed. Call `memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 512, ...)` and set `JetsamMemoryLimit = 512` in the plist.
5. **OCR `region`:** use `CVPixelBufferCreateWithIOSurface` + `VNRecognizeTextRequest.regionOfInterest` (avoid `initWithCGImage:`, which crashes easily inside a daemon).
6. **Fractional `usleep`:** the 25 ms slicing loop uses `int64_t rem = llround(us)`; a `double` remainder loops forever.
7. **Double-Home:** `keyUp` waits at least 20 ms after `keyDown` so SpringBoard registers a double-click.
8. **Rootless shell:** there is no `/bin/sh`, so `execute()` uses `fork/execl` with `/var/jb/bin/sh`; `loslib.c` is patched at build time to replace `system()` with `tapcore_ios_system()`. Package maintainer scripts use the `#!/var/jb/bin/sh` shebang.
9. **`appKill`:** `BKSTerminateApplication...` + look up `CFBundleExecutable` via `LSApplicationProxy`, then `killall -9`.
10. **Linking Lua with `ld64.lld`:** do not archive `liblua.a` with GNU `ar` (no Mach-O symbol index); link `build/lua_obj/*.o` directly.
11. **Packaging:** stage the `.deb` on the Linux filesystem (`mktemp -d`), because `/mnt/d` (NTFS) cannot hold the 0755/0644 modes `dpkg-deb` requires.

---

## 6. Known limitations / possible next steps
- Ports `:8080` and `:3000` have no authentication and the daemon runs as root: trusted LAN only.
- Stop cannot interrupt a blocking native call (`execute` running a long command, OCR, `saveToSystemAlbum`).
- Lua `io.popen` still calls `/bin/sh` and fails on rootless; use `execute()` instead.
- `usleep` is capped at 60 seconds per call; `findImage` returns only one match.
- The Sileo repo is unsigned (no `Release.gpg` / `InRelease`).
- If another service holds `:8080` (e.g. `com.catscript.server`), TapCore runs on `:8088`.
