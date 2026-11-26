# TapCore — Technical Handoff

Technical notes for an engineer or AI picking up TapCore. Full API details are in [API.md](API.md).

TapCore is the new name of the project previously called `ghost-atd` / GhostStudio. The `.deb` removes the old install automatically.

---

## 1. Goal & context
- A lightweight, stable Lua automation runtime for rootless iOS that does not hook SpringBoard. It runs `sv.lua` (HTTP `:3000`) as the command server for the **BAS** client.
- Real BAS payload mix (331 requests to `:3000`): **66%** Vision OCR (`text` + `click`/`check`/`click3`/`hold`), **21%** `RUNLUA` (`execute`, `touchDown/Move/Up`, `keyDown/Up HOME_BUTTON`, `clearSystemAlbum`, `copyText`, `appKill`), **5%** `URL`, **5%** `TEXT`, **3%** `COLOR`/`findColor`, **<1%** `findImage`. OCR speed therefore dominates perceived speed.
- Components:
  1. Root daemon `tapcore`: Lua 5.3.6 + 21 native functions + multi-script runner + web server + touch recorder + system tools.
  2. `TapCoreInput.dylib`: only serves `copyText` and Unicode typing; **hooks nothing and skips SpringBoard**.
  3. iOS app `TapCore.app` (UIKit, bundle id `com.tapcore.app`).
  4. Web Studio `web/index.html` (no CDN dependencies).

---

## 2. Build environment & test device
- **CI build:** GitHub Actions `macos-15` with Xcode clang, `iPhoneOS16.5.sdk` from `theos/sdks`, `ldid` and `dpkg` from Homebrew.
- **Local build:** Linux/WSL with `/opt/theos` (`clang` LLVM-19, `ld64.lld`, `/opt/theos/sdks/iPhoneOS16.5.sdk`, `ldid`, `dpkg-deb`).
- **Test device:** iPhone X (`iPhone10,3`, A11, `1125×2436`), **iOS 16.7.12** (`20H364`), **rootless** jailbreak (`/var/jb`, Dopamine/Procursus).
  - The shell on the device is `/var/jb/bin/sh` (**there is no `/bin/sh`**).
  - No device IPs or passwords are stored in the repo.

---

## 3. Source layout

```text
tapcore/
├── .github/workflows/release.yml  # CI: build on macOS and publish to the Sileo repo on every push
├── VERSION                   # Package version (.deb and Sileo repo)
├── build.sh                  # Build Lua objects, daemon, dylib, app, then package the .deb
├── entitlements.plist        # Private entitlements for the daemon (HID, IOSurface, QuartzCore, Photos)
├── API.md / HANDOFF.md / README.md
├── src/
│   ├── tapcore.h             # Shared header (paths, version, internal API)
│   ├── core.m                # 21 native APIs: IOKit HID touch/key/recorder, CARenderServer, OCR engine, findImage, IPC :3001, logger
│   ├── runner.m              # Multi-script runner (instant Stop via lua_sethook), config.json, status, print() -> Live Console
│   ├── web.m                 # HTTP server :8080, REST API, /control/*, /api/system
│   ├── lua_socket.m          # Socket module on POSIX sockets: buffered reads, interruptible poll()
│   ├── lua_json.m            # json module on NSJSONSerialization
│   └── main.m                # Entry point: raise Jetsam to 512 MB, IPC, config, web server, auto-start
├── tweak/
│   ├── TapCoreInput.m        # Dylib: Darwin notify com.tapcore.cmd -> TCP 127.0.0.1:3001 -> UIPasteboard / UIKeyInput
│   └── TapCoreInput.plist    # Filter: com.apple.UIKit
├── app/                      # TapCore.app: main.m, Info.plist, entitlements, icon PNGs
├── web/index.html            # Web Studio
├── scripts/sv.lua            # BAS command server; installed on every update (previous copy kept as sv.lua.bak)
├── packaging/                # control, preinst, postinst, prerm, com.tapcore.daemon.plist
├── assets/make_icons.py      # Renders the TapCore logo to every PNG size
├── tools/
│   ├── make_repo.sh          # Copy the .deb into docs/debs and generate Packages*, Release
│   └── remote_install.py     # Install a local .deb on a device through the daemon API (no SSH)
└── docs/                     # Sileo repo served by GitHub Pages: https://langtoi.github.io/tapcore/
```

### Installed paths on a rootless iPhone
| Component | Path |
|---|---|
| Daemon | `/var/jb/usr/bin/tapcore` |
| LaunchDaemon | `/var/jb/Library/LaunchDaemons/com.tapcore.daemon.plist` (label `com.tapcore.daemon`) |
| Dylib | `/var/jb/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.dylib` + `.plist` |
| App | `/var/jb/Applications/TapCore.app` |
| Web UI, bundled sv.lua | `/var/jb/usr/share/tapcore/web/index.html`, `/var/jb/usr/share/tapcore/sv.lua` |
| Configuration | `/var/jb/var/mobile/Library/TapCore/config.json` |
| Scripts, template images | `/var/jb/var/mobile/Library/TapCore/Scripts/` and `Scripts/Screenshots/` |
| Runtime | `/tmp/tapcore.port` (active web port), `/tmp/tapcore.log` |

`postinst` moves scripts from the previous scripts folder into `TapCore/Scripts` once and leaves a symlink at the old location, so absolute paths in existing BAS projects keep working.

---

## 4. Build, test & release

Releases are automated by `.github/workflows/release.yml`:

1. Every push to `main` that touches the code (`src/`, `tweak/`, `app/`, `web/`, `scripts/`, `packaging/`, `build.sh`, `VERSION`, ...) starts the **Build & publish** workflow on a `macos-15` runner.
2. The runner installs `ldid`, `dpkg`, `xz` with Homebrew, fetches `iPhoneOS16.5.sdk` from `theos/sdks`, then runs `build.sh` (Xcode clang) and `tools/make_repo.sh`.
3. It commits `VERSION` and `docs/` back as `Release TapCore x.y.z` and asks GitHub Pages to rebuild.

- **Versioning:** bump `VERSION` for a minor/major release; if the current version is already published, the workflow bumps the patch number itself. Pull afterwards to get the release commit.
- **Test before pushing:** `bash build.sh`, then `python tools/remote_install.py <iphone-ip>`. The tool uploads the `.deb` through the running daemon, starts a one-shot launchd job (`com.tapcore.installer`) that runs `dpkg -i`, waits until the new daemon answers with the new `version` and a new `daemon_started`, and prints the dpkg log.
- **Local release (Linux/WSL with Theos):** `bash build.sh && bash tools/make_repo.sh`, then commit and push.

---

## 5. Critical iOS 16.7.12 notes (do not regress)
1. **Touch & swipe (`IOHIDEvent`):** detect the real digitizer `SenderID` via `IOHIDEventSystemClientCopyServices` (`PrimaryUsagePage == 0x0D`, `PrimaryUsage == 0x04/0x05`) and set `kIOHIDEventFieldDigitizerIsDisplayIntegrated = 1`. `touchDown/Move/Up` use `fingerID = id + 1` to avoid `fingerID = 0`.
2. **Typing & clipboard:** `inputText` / `copyText` return `true, how` or `false, reason` and log `INP` lines; `sv.lua` `TEXT` answers 500 when nothing was typed. Pure ASCII is always typed with the HID keyboard (`IOHIDEventCreateKeyboardEvent`, `usagePage = 0x07`), which also works in password fields. **Do not call `UIKeyboardImpl insertText:` before HID**: on iOS 16 it acknowledges without filling password fields. The dylib is only for `copyText` (the CLI daemon gets `PBErrorDomain Code=11`) and non-ASCII strings.
3. **Screen capture:** one reusable `IOSurfaceRef` + `CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0)` (~10–17 ms/frame). Do not use `kIOSurfaceIsGlobal`. Requires `iokit-user-client-class` (`IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`) + `no-sandbox` + `QuartzCore.global-capture/secure-capture/displayable-context` entitlements.
4. **OCR speed (measured on iPhone X / A11):**

   | Mode | Full screen | Region 1125×600 | Region 500×200 |
   |---|---|---|---|
   | `fast` | ~90 ms | ~30 ms | ~18 ms |
   | `accurate` | 2.9–4.5 s | ~3.3 s | ~1.8 s |

   - Accurate has a large fixed cost on A11 regardless of region size; avoid it in loops.
   - The engine copies only the requested region into a private, reused pixel buffer under `g_surfaceLock` (~10 ms), releases the lock, then runs Vision. `getColor` during an Accurate OCR answers in ~40–100 ms instead of waiting seconds.
   - Requests are cached per level and serialized by `g_ocrLock`. Do not pass the whole screen with `regionOfInterest`: cropping the buffer is what makes regions cheaper.
   - `sv.lua` text search: Fast passes every 80 ms; one Accurate pass only after Fast has missed for 1.5 s, at most once per 6 s, and only if the remaining timeout covers its measured cost. Measured: text on screen found in ~120 ms (was 4–7 s); timeouts are respected (2 s → 2.1 s).
   - **Settle before tapping:** Fast OCR sees text while a screen is still animating in, when apps ignore touches (a `click` returned 200 but nothing happened). For `click`/`hold`, the text must be found again at the same spot (±12 px) at least 0.25 s after it first appeared; `check` returns immediately. Taps hold the finger for 40 ms.
5. **Jetsam:** launchd daemons get a low memory limit and OCR gets killed. Call `memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 512, ...)` and set `JetsamMemoryLimit = 512` in the plist. `/api/status` reports `memory_mb` (phys_footprint).
6. **Thread priority:** the script worker runs at `QOS_CLASS_USER_INTERACTIVE`, web client threads at `QOS_CLASS_USER_INITIATED`.
7. **`sv.lua` accept loop:** `server:settimeout(0.5)` returns as soon as a request arrives (an empty `RUNLUA` round trip is ~15–40 ms); there is no idle polling. Touch events are dispatched immediately, no `usleep` is needed to flush them.
8. **Fractional `usleep`:** the 25 ms slicing loop uses `int64_t rem = llround(us)`; a `double` remainder loops forever.
9. **Double-Home:** `keyUp` waits at least 20 ms after `keyDown` so SpringBoard registers a double-click.
10. **Rootless shell:** there is no `/bin/sh`, so `execute()` uses `fork/execl` with `/var/jb/bin/sh`; `loslib.c` is patched at build time to replace `system()` with `tapcore_ios_system()`. Package maintainer scripts use the `#!/var/jb/bin/sh` shebang.
11. **`appKill`:** `BKSTerminateApplication...` + look up `CFBundleExecutable` via `LSApplicationProxy`, then `killall -9`.
12. **Linking Lua with `ld64.lld`:** do not archive `liblua.a` with GNU `ar` (no Mach-O symbol index); link `build/lua_obj/*.o` directly. All binaries are linked with `-dead_strip`.
13. **Packaging:** stage the `.deb` in a temp dir, because a Windows drive mounted in WSL (NTFS) cannot hold the 0755/0644 modes `dpkg-deb` requires.

---

## 6. Known limitations / possible next steps
- Ports `:8080` and `:3000` have no authentication and the daemon runs as root: trusted LAN only.
- Stop cannot interrupt a blocking native call (`execute` running a long command, an Accurate OCR, `saveToSystemAlbum`).
- Lua `io.popen` still calls `/bin/sh` and fails on rootless; use `execute()` instead.
- `usleep` is capped at 60 seconds per call; `findImage` returns only one match.
- The Sileo repo is unsigned (no `Release.gpg` / `InRelease`).
- The web server only uses `:8080`. If another server already holds `0.0.0.0:8080` (e.g. another automation framework), TapCore binds `8080` on each local IPv4 address instead (Wi-Fi IP, `127.0.0.1`, ...). The kernel delivers a connection to the most specific binding, so BAS requests to the iPhone's IP reach TapCore without removing the other server. Addresses are re-scanned every 3 s to follow Wi-Fi IP changes.
