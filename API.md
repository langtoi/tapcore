# TapCore — Tài liệu API đầy đủ

Hệ thống gồm **2 cổng HTTP** và **1 bộ API Lua native**:
- **Cổng Web / Control (`:8080`, tự fallback `:8088` nếu `:8080` đang bận):** luôn chạy cùng daemon `tapcore` (quản lý script, chụp màn hình, crop, OCR, record touch, test chạm/gõ).
- **Cổng `sv.lua` (`:3000`):** mở khi bạn chạy script `sv.lua` (tương thích 100% client BAS / `X_3.xml`).

> Xem cổng Web hiện tại đang mở trên iPhone: đọc file `/tmp/tapcore.port` hoặc nhìn ngay trên màn hình chính của app **TapCore**.

---

## Phần 1 — Control & Studio REST API (`http://<IP>:8080` hoặc `:8088`)

### 1.1. Tương thích điều khiển kiểu AutoTouch / BAS
| Method | Endpoint | Mô tả |
|---|---|---|
| `GET` | `/control/start_playing?path=/sv.lua` | Chạy file `.lua` bất kỳ trong thư mục Scripts (nếu đang chạy đúng file đó thì giữ nguyên và trả `200`) |
| `GET` | `/control/stop_playing` | Dừng ngay lập tức script đang chạy |

### 1.2. Giao diện Web, Trạng thái & Cấu hình
| Method | Endpoint | Body / Query | Mô tả |
|---|---|---|---|
| `GET` | `/` | — | Mở giao diện **TapCore Web Studio** trên trình duyệt |
| `GET` | `/api/status` | — | Trả về JSON: `ip`, `web_port`, `running`, `script`, `uptime_s`, `last_error`, `screen_w`, `screen_h`, `sender_id`, `recording`, `record_events`, `auto_start_script`, `scripts_dir` |
| `POST` | `/api/config` | `{"auto_start_script":"sv.lua","web_port":8080,"fallback_port":8088,"scripts_dir":"..."}` | Cập nhật cấu hình (đặt `"auto_start_script":""` để tắt tự chạy khi boot) |

### 1.3. Live Console Log
| Method | Endpoint | Mô tả |
|---|---|---|
| `GET` | `/api/logs?since=0` | Lấy các dòng log mới hơn `id = since` (bao gồm `print()` trong Lua, `RUN`, `ERR`, `INP`, `IMG`, `REC`, `WEB`) |
| `POST` | `/api/logs/clear` | Xóa sạch bộ đệm log |

### 1.4. Quản lý & Chạy Script Lua
| Method | Endpoint | Body | Mô tả |
|---|---|---|---|
| `GET` | `/api/scripts` | — | Liệt kê tất cả file `.lua` (`name`, `path`, `size`, `mtime`, `running`) |
| `GET` | `/api/script?path=sv.lua` | — | Đọc nội dung text của file `.lua` |
| `POST` | `/api/script?path=my.lua` | Raw UTF-8 Lua code | Tạo mới hoặc ghi đè file `.lua` |
| `DELETE` | `/api/script?path=my.lua` | — | Xóa file `.lua` |
| `POST` | `/api/run?path=my.lua` | — | Chạy file `.lua` (tự dừng script cũ nếu đang chạy) |
| `POST` | `/api/stop` | — | Dừng script đang chạy tức thì |

### 1.5. Chụp màn hình, Crop & Quản lý `Screenshots/`
| Method | Endpoint | Body / Query | Mô tả |
|---|---|---|---|
| `GET` | `/api/capture` | `?delay=3&save=cap.png&json=1` | Chụp màn hình tức thì (hoặc trễ `delay` giây) trả `image/png`. Nếu truyền `save`, tự lưu vào `Screenshots/`; thêm `json=1` để trả JSON thay vì bytes ảnh |
| `POST` | `/api/crop` | `{"source":"live","x":100,"y":200,"width":150,"height":80,"save":"btn.png"}` | Cắt ảnh từ màn hình hiện tại (`"live"`) hoặc từ file đã lưu (`"cap.png"`) và lưu vào `Screenshots/btn.png` |
| `GET` | `/api/screenshots` | — | Liệt kê danh sách ảnh trong `Screenshots/` |
| `GET` | `/api/screenshot/file?name=btn.png` | — | Tải file ảnh PNG/JPG |
| `POST` | `/api/screenshot/upload?name=btn.png` | Raw image bytes | Upload file ảnh vào `Screenshots/` |
| `DELETE` | `/api/screenshot/file?name=btn.png` | — | Xóa file ảnh |

### 1.6. Vision OCR & Điều khiển nhanh trực tiếp (không cần chạy `sv.lua`)
| Method | Endpoint | Body | Mô tả |
|---|---|---|---|
| `POST` | `/api/ocr` | `{"region":[x,y,w,h],"languages":["en-US"]}` *(hoặc `{}`)* | Chạy Apple Vision OCR trả `{width, height, elapsed_ms, items:[{text, x, y, box:{x,y,width,height}}]}` |
| `POST` | `/api/test` | `{"op":"tap","x":560,"y":1200}` | Chạm 1 điểm |
| `POST` | `/api/test` | `{"op":"swipe","x1":950,"y1":1200,"x2":150,"y2":1200,"steps":18}` | Vuốt từ `(x1,y1)` đến `(x2,y2)` |
| `POST` | `/api/test` | `{"op":"home"}` | Bấm nút Home |
| `POST` | `/api/test` | `{"op":"text","data":"hello123"}` | Gõ chữ trực tiếp bằng phím cứng HID |
| `POST` | `/api/test` | `{"op":"color","x":560,"y":1200}` | Đọc mã màu pixel trả `{color, hex}` |

### 1.7. Touch Recorder (Ghi thao tác chạm & vuốt thật)
| Method | Endpoint | Mô tả |
|---|---|---|
| `POST` | `/api/record/start` | Bắt đầu ghi toàn bộ chạm/vuốt thật trên màn hình iPhone qua IOKit HID callback |
| `POST` | `/api/record/stop?save=rec1.lua` | Dừng ghi, trả `{events, lua, saved}` (bỏ `?save=` nếu chỉ muốn lấy chuỗi `lua`) |
| `GET` | `/api/record/status` | Kiểm tra `{recording, events, lua}` hiện tại |

### 1.8. Công cụ hệ thống (`uicache`, `respring`, `restart_daemon`)
| Method | Endpoint | Body | Mô tả |
|---|---|---|---|
| `POST` | `/api/system` | `{"op":"uicache"}` | Chạy `uicache -a` làm mới icon Home Screen |
| `POST` | `/api/system` | `{"op":"respring"}` | Khởi động lại SpringBoard (`sbreload` / `killall -9 SpringBoard`) |
| `POST` | `/api/system` | `{"op":"restart_daemon"}` | Khởi động lại `tapcore` để áp dụng cổng/cấu hình mới |

---

## Phần 2 — HTTP API của `sv.lua` (`POST http://<IP>:3000`)

Chỉ hoạt động khi đang chạy `sv.lua` (bấm **Play** trong app/web hoặc gọi `GET :8080/control/start_playing?path=/sv.lua`).

| Loại lệnh | Ví dụ JSON body / Header |
|---|---|
| **Chạy đoạn Lua tùy ý** | `{"action":"RUNLUA","data":"return execute('/var/jb/usr/bin/x-container list')"}` |
| **Mở URL / Deep Link** | `{"action":"URL","data":"twitter://settings/profile"}` |
| **Gõ chữ** | `{"action":"TEXT","data":"6d2o9h3g1dux"}` |
| **Tìm & bấm Text (OCR)** | `{"text":"Next","timeout":15,"ex":true,"offset":0,"action":"click","region":null}` *(action: `check`, `click`, `click3`, `hold`)* |
| **Tìm & bấm Ảnh mẫu** | `{"action":"click","image_path":"Screenshots/btn.png","threshold":0.9,"timeout":10,"region":{"x":0,"y":0,"width":500,"height":500}}` |
| **Tìm 1 màu / mẫu màu** | `{"action":"COLOR","mode":"click","timeout":15,"script":"findColor(0xFFFFFF, 0) -- 0xFFFFFF, (500,500)"}` |
| **Kiểm tra đa điểm neo** | `{"action":"POINTS","mode":"click","timeout":5,"tolerance":8,"script":"0x00BA7C, (930,387)\n0xFFFFFF, (1006,387)"}` |
| **Lưu ảnh vào Album Photos** | Header `X-Action: SAVE_PHOTO` + `Content-Length: <bytes>`, body = dữ liệu ảnh JPG/PNG |
| **Tắt `sv.lua`** | `{"action":"STOP"}` |

---

## Phần 3 — Danh sách hàm Lua Native tích hợp trong `tapcore`

Bạn có thể gọi trực tiếp các hàm sau trong bất kỳ file `.lua` nào hoặc qua `RUNLUA`:

### Chạm, Vuốt & Phím cứng
- `touchDown(id, x, y)` — nhấn ngón tay `id` tại tọa độ pixel `(x, y)`
- `touchMove(id, x, y)` — di chuyển ngón tay `id` đến `(x, y)`
- `touchUp(id, x, y)` — nhấc ngón tay `id` tại `(x, y)`
- `usleep(microseconds)` — ngủ theo microsecond (hỗ trợ cả số thực, tự cắt nhỏ để bấm Stop thoát ngay)
- `keyDown(keyType)` / `keyUp(keyType)` — nhấn/nhả phím cứng với hằng số:
  - `KEY_TYPE.HOME_BUTTON` (hoặc `KEY_TYPE.MENU_BUTTON`)
  - `KEY_TYPE.VOLUME_UP_BUTTON`
  - `KEY_TYPE.VOLUME_DOWN_BUTTON`
  - `KEY_TYPE.POWER_BUTTON`

### Gõ chữ & Clipboard
- `inputText(str)` — chuỗi ASCII đi thẳng qua phím cứng IOKit HID (chạy mọi app kể cả ô Password); chuỗi có Unicode đi qua `TapCoreInput.dylib`
- `copyText(str)` — ghi vào `UIPasteboard` thông qua `TapCoreInput.dylib` trong app đang mở

### Đọc màn hình, Màu, OCR & Tìm ảnh
- `getColor(x, y)` → số nguyên RGB `0xRRGGBB`
- `getColors({{x1,y1}, {x2,y2}, ...})` → bảng `{rgb1, rgb2, ...}` (chỉ chụp màn hình 1 lần)
- `findColors(colors, count, region, debug, rightToLeft, bottomToTop)` → `{{x, y}, ...}`
- `ocr({method = OCR_METHOD.IOS_VISION, languages = {"en-US"}, correct = true, region = {x,y,w,h}})` → bảng `{{text = "...", rectangle = {topLeft, topRight, bottomLeft, bottomRight}}, ...}`
- `findImage(fullPath, count, threshold, region, debug, method)` → `{{cx, cy}, ...}`

### Hệ thống, App & Photos
- `execute(cmd)` → chạy lệnh shell qua `/var/jb/bin/sh` (có sẵn `PATH` rootless), trả về chuỗi `stdout+stderr`
- `openURL(url)` → mở URL / deep link qua `LSApplicationWorkspace` (fallback `uiopen`)
- `appKill(bundleId)` → tắt cưỡng bức app (vd `appKill("com.burbn.instagram")`)
- `rootDir()` → đường dẫn thư mục Scripts hiện tại (mặc định `/var/jb/var/mobile/Library/AutoTouch/Scripts`)
- `saveToSystemAlbum(path)` *(alias: `saveImageToAlbum`, `saveToAlbum`)* → lưu ảnh vào thư viện Photos
- `clearSystemAlbum()` → xóa toàn bộ ảnh trong thư viện Photos
- `print(...)` → in trực tiếp ra **Live Console** của Web Studio & app `TapCore`

### Thư viện Lua tích hợp sẵn (không cần cài ngoài)
- `local socket = require("socket")` — `gettime`, `bind`, `settimeout`, `accept`, `receive`, `send`, `close`
- `local json = require("json")` — `encode`, `decode`, `null`
