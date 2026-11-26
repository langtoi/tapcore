<p align="center"><img src="docs/icon-512.png" width="128" alt="TapCore"></p>

# TapCore

Runtime tự động hoá Lua tương thích AutoTouch cho iPhone jailbreak **rootless iOS 15–16** (Dopamine/Procursus). Không hook SpringBoard.

- Chạm, vuốt, phím cứng, gõ chữ bằng IOKit HID
- Đọc màu, tìm màu, tìm ảnh, OCR bằng Apple Vision
- Chạy `sv.lua` nguyên văn cho client BAS (cổng `3000`)
- Web Studio và app **TapCore** để quản lý script, chụp/cắt ảnh, OCR, ghi thao tác chạm

## Cài đặt qua Sileo

1. Mở Sileo → **Sources** → **+**
2. Thêm nguồn: `https://langtoi.github.io/tapcore/`
3. Tìm **TapCore** → **Get**

Hoặc mở trang https://langtoi.github.io/tapcore/ trên iPhone và bấm nút thêm nguồn.

Sau khi cài:
- App **TapCore** có trên màn hình chính.
- Web Studio: `http://<IP iPhone>:8080` (tự chuyển sang `8088` nếu `8080` bận).
- Script Lua đặt trong `/var/jb/var/mobile/Library/AutoTouch/Scripts/`.

## Tài liệu

- [API.md](API.md): REST API cổng 8080, API `sv.lua` cổng 3000, danh sách hàm Lua.
- [HANDOFF.md](HANDOFF.md): kiến trúc, đường dẫn, build, các lưu ý kỹ thuật.

## Build & phát hành (dành cho dev)

Cần Windows + WSL Ubuntu có Theos (`/opt/theos`, SDK iPhoneOS16.5) và `dpkg-dev`.

```bash
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/build.sh'          # build + .deb
wsl bash -lc 'bash /mnt/d/CHUNG_CHUNG/AUTO/tapcore/tools/make_repo.sh' # cập nhật repo Sileo trong docs/
git add -A && git commit -m "TapCore x.y.z" && git push                # GitHub Pages phát hành
```

Tăng số trong `VERSION` trước mỗi lần phát hành để Sileo nhận bản cập nhật.

> Cổng 8080 và 3000 không có mật khẩu và daemon chạy quyền root: chỉ dùng trong mạng LAN tin cậy.
