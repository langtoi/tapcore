<p align="center"><img src="docs/icon-512.png" width="128" alt="TapCore"></p>

# TapCore

AutoTouch-compatible Lua automation runtime for jailbroken **rootless iOS 15–16** (Dopamine/Procursus). It does not hook SpringBoard.

- Touch, swipe, hardware keys and typing through IOKit HID
- Pixel colors, color patterns, template image search, Apple Vision OCR
- Runs `sv.lua` unmodified for the BAS client (port `3000`)
- Web Studio and the **TapCore** app to manage scripts, capture/crop screenshots, run OCR and record touches

## Install with Sileo

1. Open Sileo → **Sources** → **+**
2. Add the source `https://langtoi.github.io/tapcore/`
3. Search for **TapCore** → **Get**

Or open https://langtoi.github.io/tapcore/ on the iPhone and tap the add-source button.

After installing:
- The **TapCore** app appears on the Home Screen.
- Web Studio: `http://<iphone-ip>:8080` (switches to `8088` when `8080` is busy).
- Lua scripts live in `/var/jb/var/mobile/Library/AutoTouch/Scripts/`.
- An older `ghost-atd` / GhostStudio install is removed automatically.

## Documentation

- [API.md](API.md): REST API on port 8080, `sv.lua` API on port 3000, native Lua functions.
- [HANDOFF.md](HANDOFF.md): architecture, install paths, build and technical notes.

## Build & release (developers)

Releases are built by GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml)):

1. Change the code and push to `main` (editing on github.com works too).
2. A macOS runner builds the `.deb`, refreshes the Sileo repo in `docs/` and commits it back as `Release TapCore x.y.z`.
3. GitHub Pages publishes it; Sileo offers the update on the next refresh.

If `VERSION` was not bumped, the workflow increases the patch number itself. Run `git pull` afterwards to get the release commit. The workflow can also be started by hand from the **Actions** tab (**Build & publish** → **Run workflow**).

Building locally is still possible from the repo root, in Linux/WSL with Theos (`/opt/theos`, iPhoneOS16.5 SDK) and `dpkg-dev`:

```bash
bash build.sh             # build + .deb in build/
bash tools/make_repo.sh   # refresh the Sileo repo in docs/
```

> Ports 8080 and 3000 have no authentication and the daemon runs as root: use TapCore on a trusted LAN only.
