# TapCore API Reference

TapCore exposes **two HTTP ports** and **a set of native Lua functions**:

- **Web / Control port (`:8080`, falls back to `:8088` when `:8080` is busy):** always served by the `tapcore` daemon (script management, screen capture, crop, OCR, touch recording, tap/type tests).
- **`sv.lua` port (`:3000`):** open while the `sv.lua` script is running (fully compatible with the BAS client).

> The active web port is written to `/tmp/tapcore.port` on the iPhone and shown on the home screen of the **TapCore** app.

---

## Part 1 — Control & Studio REST API (`http://<IP>:8080` or `:8088`)

### 1.1 Script control (used by BAS)
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/control/start_playing?path=/sv.lua` | Run any `.lua` file from the Scripts folder (if that same file is already running, it keeps running and returns `200`) |
| `GET` | `/control/stop_playing` | Stop the running script immediately |

### 1.2 Web UI, status & configuration
| Method | Endpoint | Body / Query | Description |
|---|---|---|---|
| `GET` | `/` | — | Open the **TapCore Web Studio** in a browser |
| `GET` | `/api/status` | — | JSON: `version`, `daemon_started`, `memory_mb`, `ip`, `web_port`, `running`, `script`, `uptime_s`, `last_error`, `screen_w`, `screen_h`, `sender_id`, `recording`, `record_events`, `auto_start_script`, `scripts_dir` |
| `POST` | `/api/config` | `{"auto_start_script":"sv.lua","web_port":8080,"fallback_port":8088,"scripts_dir":"..."}` | Update the configuration (set `"auto_start_script":""` to disable auto-start at boot) |

### 1.3 Live console log
| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/logs?since=0` | Log lines with `id > since` (includes Lua `print()`, `RUN`, `ERR`, `INP`, `IMG`, `REC`, `WEB`) |
| `POST` | `/api/logs/clear` | Clear the log buffer |

### 1.4 Lua script management
| Method | Endpoint | Body | Description |
|---|---|---|---|
| `GET` | `/api/scripts` | — | List all `.lua` files (`name`, `path`, `size`, `mtime`, `running`) |
| `GET` | `/api/script?path=sv.lua` | — | Read a `.lua` file as text |
| `POST` | `/api/script?path=my.lua` | Raw UTF-8 Lua code | Create or overwrite a `.lua` file |
| `DELETE` | `/api/script?path=my.lua` | — | Delete a `.lua` file |
| `POST` | `/api/run?path=my.lua` | — | Run a `.lua` file (stops the current script first) |
| `POST` | `/api/stop` | — | Stop the running script immediately |

### 1.5 Screen capture, crop & `Screenshots/`
| Method | Endpoint | Body / Query | Description |
|---|---|---|---|
| `GET` | `/api/capture` | `?delay=3&save=cap.png&json=1` | Capture the screen now (or after `delay` seconds) and return `image/png`. With `save`, also store it in `Screenshots/`; add `json=1` to get JSON instead of image bytes |
| `POST` | `/api/crop` | `{"source":"live","x":100,"y":200,"width":150,"height":80,"save":"btn.png"}` | Crop the live screen (`"live"`) or a saved file (`"cap.png"`) and save it as `Screenshots/btn.png` |
| `GET` | `/api/screenshots` | — | List images in `Screenshots/` |
| `GET` | `/api/screenshot/file?name=btn.png` | — | Download a PNG/JPG |
| `POST` | `/api/screenshot/upload?name=btn.png` | Raw image bytes | Upload an image into `Screenshots/` |
| `DELETE` | `/api/screenshot/file?name=btn.png` | — | Delete an image |

### 1.6 Vision OCR & direct device control (no `sv.lua` needed)
| Method | Endpoint | Body | Description |
|---|---|---|---|
| `POST` | `/api/ocr` | `{"level":"fast","region":[x,y,w,h],"languages":["en-US"]}` *(or `{}`)* | Run Apple Vision OCR. Options: `level` `"accurate"` (default) or `"fast"`, `region`, `languages`, `correct` (language correction, default on for accurate), `scale` (e.g. `0.5`), `min_text_height` (0–1). Returns `{width, height, level, capture_ms, vision_ms, elapsed_ms, items:[{text, x, y, confidence, box:{x,y,width,height}}]}` |
| `POST` | `/api/test` | `{"op":"tap","x":560,"y":1200}` | Tap one point |
| `POST` | `/api/test` | `{"op":"swipe","x1":950,"y1":1200,"x2":150,"y2":1200,"steps":18}` | Swipe from `(x1,y1)` to `(x2,y2)` |
| `POST` | `/api/test` | `{"op":"home"}` | Press the Home button |
| `POST` | `/api/test` | `{"op":"text","data":"hello123"}` | Type text into the focused field (ASCII via the HID keyboard, other text via the foreground app). Returns `{success, via}`; `409` if nothing was typed |
| `POST` | `/api/test` | `{"op":"copy","data":"some text"}` | Put text on the iPhone clipboard through the foreground app. Returns `{success, via}` (`via` = app that set it); `409` on the home screen |
| `POST` | `/api/test` | `{"op":"color","x":560,"y":1200}` | Read a pixel color, returns `{color, hex}` |

### 1.7 Touch recorder (records real taps & swipes)
| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/record/start` | Start recording all real touches through the IOKit HID callback |
| `POST` | `/api/record/stop?save=rec1.lua` | Stop recording, returns `{events, lua, saved}` (omit `?save=` to only get the `lua` string) |
| `GET` | `/api/record/status` | Current `{recording, events, lua}` |

### 1.8 System tools (`uicache`, `respring`, `restart_daemon`)
| Method | Endpoint | Body | Description |
|---|---|---|---|
| `POST` | `/api/system` | `{"op":"uicache"}` | Run `uicache -a` to refresh Home Screen icons |
| `POST` | `/api/system` | `{"op":"respring"}` | Restart SpringBoard (`sbreload` / `killall -9 SpringBoard`) |
| `POST` | `/api/system` | `{"op":"restart_daemon"}` | Restart the `tapcore` daemon to apply a new port/config |

---

## Part 2 — `sv.lua` HTTP API (`POST http://<IP>:3000`)

Only available while `sv.lua` is running (press **Play** in the app/web, or call `GET :8080/control/start_playing?path=/sv.lua`).

| Command | Example JSON body / header |
|---|---|
| **Run arbitrary Lua** | `{"action":"RUNLUA","data":"return execute('/var/jb/usr/bin/x-container list')"}` |
| **Open URL / deep link** | `{"action":"URL","data":"twitter://settings/profile"}` |
| **Type text** | `{"action":"TEXT","data":"6d2o9h3g1dux"}` |
| **Find & tap text (OCR)** | `{"text":"Next","timeout":15,"ex":true,"offset":0,"action":"click","region":null}` *(action: `check`, `click`, `click3`, `hold`; optional `"level"`: `"auto"` default = Fast passes with an occasional Accurate fallback, or `"fast"` / `"accurate"`)* |
| **Find & tap a template image** | `{"action":"click","image_path":"Screenshots/btn.png","threshold":0.9,"timeout":10,"region":{"x":0,"y":0,"width":500,"height":500}}` |
| **Find a color / color pattern** | `{"action":"COLOR","mode":"click","timeout":15,"script":"findColor(0xFFFFFF, 0) -- 0xFFFFFF, (500,500)"}` |
| **Check multiple anchor points** | `{"action":"POINTS","mode":"click","timeout":5,"tolerance":8,"script":"0x00BA7C, (930,387)\n0xFFFFFF, (1006,387)"}` |
| **Save a photo to the Photos album** | Header `X-Action: SAVE_PHOTO` + `Content-Length: <bytes>`, body = JPG/PNG data |
| **Stop `sv.lua`** | `{"action":"STOP"}` |

---

## Part 3 — Native Lua functions built into `tapcore`

Call these from any `.lua` file or through `RUNLUA`.

### Touch, swipe & hardware keys
- `touchDown(id, x, y)` — press finger `id` at pixel `(x, y)`
- `touchMove(id, x, y)` — move finger `id` to `(x, y)`
- `touchUp(id, x, y)` — lift finger `id` at `(x, y)`
- `usleep(microseconds)` — sleep in microseconds (fractions allowed; sliced so Stop exits immediately; max 60 s per call)
- `keyDown(keyType)` / `keyUp(keyType)` — press/release a hardware key:
  - `KEY_TYPE.HOME_BUTTON` (or `KEY_TYPE.MENU_BUTTON`)
  - `KEY_TYPE.VOLUME_UP_BUTTON`
  - `KEY_TYPE.VOLUME_DOWN_BUTTON`
  - `KEY_TYPE.POWER_BUTTON`

### Typing & clipboard
- `inputText(str)` → `true, how` | `false, reason` — ASCII strings are typed with the IOKit HID hardware keyboard (works in every app, including password fields); other text (Vietnamese, emoji, ...) is inserted by `TapCoreInput.dylib` in the foreground app
- `copyText(str)` → `true, app` | `false, reason` — put text on the iPhone clipboard (`UIPasteboard`) through `TapCoreInput.dylib` in the foreground app
  - Needs an app in the foreground (not the home screen). An app that was already open when TapCore was first installed must be relaunched once so it loads `TapCoreInput.dylib`.

### Screen, colors, OCR & image search
- `getColor(x, y)` → RGB integer `0xRRGGBB`
- `getColors({{x1,y1}, {x2,y2}, ...})` → `{rgb1, rgb2, ...}` (one screen capture)
- `findColors(colors, count, region, debug, rightToLeft, bottomToTop)` → `{{x, y}, ...}`
- `ocr({level = "fast", languages = {"en-US"}, correct = true, region = {x,y,w,h}, scale = 1, minTextHeight = 0})` → `{{text = "...", confidence = 0..1, rectangle = {topLeft, topRight, bottomLeft, bottomRight}}, ...}`
  - `level = "accurate"` (default) reads small or stylized text better but takes 2–4 s on iPhone X; `"fast"` takes about 0.1 s.
  - The screen lock is held only while copying the region (~10 ms), so other screen reads never wait for OCR.
- `findImage(fullPath, count, threshold, region, debug, method)` → `{{cx, cy}}` (best match only)

### System, apps & Photos
- `execute(cmd)` → run a shell command through `/var/jb/bin/sh` (rootless `PATH` preset), returns `stdout+stderr`
- `openURL(url)` → open a URL / deep link through `LSApplicationWorkspace` (falls back to `uiopen`)
- `appKill(bundleId)` → force-quit an app (e.g. `appKill("com.burbn.instagram")`)
- `rootDir()` → current Scripts folder (default `/var/jb/var/mobile/Library/TapCore/Scripts`)
- `saveToSystemAlbum(path)` *(aliases: `saveImageToAlbum`, `saveToAlbum`)* → save an image to Photos
- `clearSystemAlbum()` → delete every photo in the Photos library
- `print(...)` → print to the **Live Console** of the Web Studio and the TapCore app

### Bundled Lua libraries (no install needed)
- `local socket = require("socket")` — `gettime`, `bind`, `settimeout`, `accept`, `receive`, `send`, `close`
- `local json = require("json")` — `encode`, `decode`, `null`
