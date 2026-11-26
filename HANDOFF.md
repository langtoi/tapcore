# TapCore — Technical Handoff

Tài liệu kỹ thuật để AI hoặc kỹ sư khác tiếp nhận và phát triển tiếp TapCore. API chi tiết xem [API.md](API.md).

TapCore là tên mới của dự án trước đây gọi là `ghost-atd` / GhostStudio. Gói `.deb` tự gỡ bản cũ khi cài.

---

## 1. Mục tiêu & bối cảnh
- Thay thế **AutoTouch** (`ATTweak.dylib` hook SpringBoard, dễ gây Safe Mode, cần license) bằng một runtime nhẹ, ổn định, chạy nguyên văn `sv.lua` (HTTP `:3000`) cho client **BAS**.
- Thống kê payload BAS thực tế (331 request `:3000`): **66%** Vision OCR (`text` + `click`/`check`/`click3`/`hold`), **21%** `RUNLUA` (`execute`, `touchDown/Move/Up`, `keyDown/Up HOME_BUTTON`, `clearSystemAlbum`, `copyText`, `appKill`), **5%** `URL`, **5%** `TEXT`, **3%** `COLOR`/`findColor`, **<1%** `findImage`.
- Thành phần:
  1. Daemon root `tapcore`: Lua 5.3.6 + 21 hàm native + Multi-Script Runner + Web Server + Touch Recorder + System Tools.
  2. Dylib `TapCoreInput.dylib`: chỉ phục vụ `copyText` và gõ Unicode; **không hook hàm nào, bỏ qua SpringBoard**.
  3. App iOS `TapCore.app` (UIKit, bundle id `com.tapcore.app`).
  4. Web Studio `web/index.html` (không phụ thuộc CDN).

---

## 2. Môi trường build & máy test
- **Build:** Windows + WSL Ubuntu với `/opt/theos` (`clang` LLVM-19, `ld64.lld`, `/opt/theos/sdks/iPhoneOS16.5.sdk`, `ldid`, `dpkg-deb`, `dpkg-scanpackages`).
- **Máy test:** iPhone X (`iPhone10,3`, `1125×2436`), **iOS 16.7.12** (`20H364`), jailbreak **rootless** (`/var/jb`, Dopamine/Procursus).
  - Shell trên máy là `/var/jb/bin/sh` (**không có `/bin/sh`**).
  - IP và mật khẩu SSH không ghi trong repo; `tools/deploy_verify.py` đọc mật khẩu từ biến môi trường `TAPCORE_SSH_PASS` hoặc hỏi khi chạy.

---

## 3. Cấu trúc mã nguồn

```text
tapcore/
├── VERSION                   # Phiên bản gói (.deb và repo Sileo)
├── build.sh                  # Build Lua objs, daemon, dylib, app rồi đóng gói .deb
├── entitlements.plist        # Private entitlements cho daemon (HID, IOSurface, QuartzCore, Photos)
├── API.md / HANDOFF.md / README.md
├── src/
│   ├── tapcore.h             # Header dùng chung (đường dẫn, API nội bộ)
│   ├── core.m                # 21 API native: IOKit HID touch/key/recorder, CARenderServer, OCR, findImage, IPC :3001, logger
│   ├── runner.m              # Multi-script runner (Stop tức thì bằng lua_sethook), config.json, print() -> Live Console
│   ├── web.m                 # HTTP server :8080 (fallback :8088), REST API, /control/*, /api/system
│   ├── lua_socket.m          # Thay LuaSocket bằng POSIX socket + poll() ngắt được
│   ├── lua_json.m            # Thay json.lua bằng NSJSONSerialization
│   └── main.m                # Entry: nâng Jetsam 512MB, IPC, config, web server, auto-start
├── tweak/
│   ├── TapCoreInput.m        # Dylib: Darwin notify com.tapcore.cmd -> TCP 127.0.0.1:3001 -> UIPasteboard / UIKeyInput
│   └── TapCoreInput.plist    # Filter com.apple.UIKit
├── app/                      # TapCore.app: main.m, Info.plist, entitlements, icon PNG
├── web/index.html            # Web Studio
├── scripts/sv.lua            # sv.lua chuẩn của BAS (được cài kèm nếu máy chưa có)
├── packaging/                # control, preinst, postinst, prerm, com.tapcore.daemon.plist
├── assets/make_icons.py      # Vẽ logo TapCore ra mọi kích thước PNG
├── tools/
│   ├── make_repo.sh          # Copy .deb vào docs/debs và tạo Packages*, Release
│   └── deploy_verify.py      # Cài .deb qua SSH lên 1 máy và chạy kiểm tra nhanh
└── docs/                     # Repo Sileo, phục vụ bởi GitHub Pages: https://langtoi.github.io/tapcore/
```

### Đường dẫn sau khi cài trên iPhone rootless
| Thành phần | Đường dẫn |
|---|---|
| Daemon | `/var/jb/usr/bin/tapcore` |
| LaunchDaemon | `/var/jb/Library/LaunchDaemons/com.tapcore.daemon.plist` (label `com.tapcore.daemon`) |
| Dylib | `/var/jb/Library/MobileSubstrate/DynamicLibraries/TapCoreInput.dylib` + `.plist` |
| App | `/var/jb/Applications/TapCore.app` |
| Web UI, sv.lua mẫu | `/var/jb/usr/share/tapcore/web/index.html`, `/var/jb/usr/share/tapcore/sv.lua` |
| Cấu hình | `/var/jb/var/mobile/Library/TapCore/config.json` |
| Scripts, ảnh mẫu | `/var/jb/var/mobile/Library/AutoTouch/Scripts/` và `Screenshots/` (giữ tên AutoTouch để BAS không phải sửa) |
| Runtime | `/tmp/tapcore.port` (cổng web đang chạy), `/tmp/tapcore.log` |

---

## 4. Build, phát hành & cài đặt

```bash
# 1. Build + đóng gói .deb (WSL)
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/build.sh'

# 2. Cập nhật repo Sileo trong docs/
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/tools/make_repo.sh'

# 3. Commit + push: GitHub Pages phục vụ docs/ -> Sileo thấy bản mới
git add -A && git commit -m "TapCore x.y.z" && git push
```

- **Phát hành bản mới:** tăng số trong `VERSION`, chạy lại 3 bước trên.
- **Cài trên iPhone:** Sileo → Sources → thêm `https://langtoi.github.io/tapcore/` → cài **TapCore**.
- **Cài thử nhanh 1 máy qua SSH (dev):** `python tools\deploy_verify.py <iphone-ip>`.
- `preinst` tự gỡ bản cũ `ghost-atd` (daemon `com.ghost.atd`, `ghost_input.dylib`, `GhostStudio.app`) và chuyển `config.json` sang thư mục TapCore.

---

## 5. Các điểm kỹ thuật sống còn trên iOS 16.7.12 (tránh lặp lại)
1. **Chạm & vuốt (`IOHIDEvent`):** tự dò `SenderID` thật của digitizer qua `IOHIDEventSystemClientCopyServices` (`PrimaryUsagePage == 0x0D`, `PrimaryUsage == 0x04/0x05`) và set `kIOHIDEventFieldDigitizerIsDisplayIntegrated = 1`. `touchDown/Move/Up` dùng `fingerID = id + 1` để tránh `fingerID = 0`.
2. **Gõ chữ:** chuỗi thuần ASCII luôn gõ bằng phím cứng HID (`IOHIDEventCreateKeyboardEvent`, `usagePage = 0x07`), chạy được cả ô Password. **Không gọi `UIKeyboardImpl insertText:` trước HID** vì trên iOS 16 nó ACK giả. Dylib chỉ dùng cho `copyText` (daemon CLI bị `PBErrorDomain Code=11`) và chuỗi non-ASCII.
3. **Chụp màn hình & OCR:** 1 `IOSurfaceRef` tái sử dụng + `CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0)` (~17 ms/frame). Không dùng `kIOSurfaceIsGlobal`. Cần entitlements `iokit-user-client-class` (`IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`) + `no-sandbox` + `QuartzCore.global-capture/secure-capture/displayable-context`.
4. **Jetsam:** daemon dưới launchd bị giới hạn RAM thấp làm OCR bị kill. Gọi `memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 512, ...)` và khai báo `JetsamMemoryLimit = 512` trong plist.
5. **OCR `region`:** dùng `CVPixelBufferCreateWithIOSurface` + `VNRecognizeTextRequest.regionOfInterest` (tránh `initWithCGImage:` vì dễ crash trong daemon).
6. **`usleep` số thực:** vòng chia lát 25 ms dùng `int64_t rem = llround(us)`; dùng `double` sẽ lặp vô hạn.
7. **Double-Home:** `keyUp` tự đệm tối thiểu 20 ms sau `keyDown` để SpringBoard nhận double-click.
8. **Shell rootless:** không có `/bin/sh` → `execute()` dùng `fork/execl` với `/var/jb/bin/sh`; `loslib.c` được patch lúc build thay `system()` bằng `tapcore_ios_system()`. Script cài đặt trong `.deb` cũng dùng shebang `#!/var/jb/bin/sh`.
9. **`appKill`:** `BKSTerminateApplication...` + tra `CFBundleExecutable` qua `LSApplicationProxy` rồi `killall -9`.
10. **Build Lua với `ld64.lld`:** không đóng `liblua.a` bằng GNU `ar`; link thẳng `build/lua_obj/*.o`.
11. **Đóng gói:** stage `.deb` trên filesystem Linux (`mktemp -d`), vì `/mnt/d` (NTFS) không giữ quyền 0755/0644 mà `dpkg-deb` yêu cầu.

---

## 6. Giới hạn đã biết / việc có thể làm tiếp
- Cổng `:8080` và `:3000` không có xác thực, daemon chạy root: chỉ dùng trong mạng LAN tin cậy.
- Lệnh Stop không ngắt được hàm native đang chặn (`execute` chạy lệnh lâu, OCR, `saveToSystemAlbum`).
- `io.popen` của Lua vẫn gọi `/bin/sh` nên không chạy trên rootless; dùng `execute()` thay thế.
- `usleep` giới hạn 60 giây mỗi lần gọi; `findImage` chỉ trả 1 kết quả.
- Nếu máy còn dịch vụ khác chiếm `:8080` (ví dụ `com.catscript.server`), TapCore tự chạy ở `:8088`.
