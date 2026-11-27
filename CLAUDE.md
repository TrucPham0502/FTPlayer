# CLAUDE.md — TPPlayer (FTPlayer SDK + Demo)

## Đo/chạy playback trên My Mac (Designed for iPad)

Đã thử và KHÔNG dùng được trên My Mac (Designed for iPad):
- Unit test có host app Demo (scheme `FTPlayerPlayback` cũ, đã xoá): app bị kill trước khi kết nối
  (`Test crashed with signal kill before establishing connection`), kể cả khi ký bằng Team.
- Unit test SDK không host (`FTPlayerUnit`): "Unit tests without a host app are not supported on My Mac".
- UI test (scheme `FTPlayerDemoUI` cũ, đã xoá): "UI tests are not supported on My Mac (Designed for iPad)".
- `open` file `.app` tự build (kể cả bọc kiểu `Wrapper/` + `WrappedBundle` + `BundleMetadata.plist`):
  macOS báo "damaged" hoặc process treo ở `_dyld_start`.

Cách chạy được: để Xcode Run app Demo, điều khiển Xcode bằng AppleScript.

1. Viết code đo tạm (probe) vào app Demo, ví dụ gọi từ `AppDelegate.didFinishLaunching` trên background queue.
   Thao tác với FTPlayer qua `DispatchQueue.main.sync`. Code app Debug có thể dùng `@testable import FTPlayer`.
   Ghi kết quả ra file trong Documents của app (sandbox), ví dụ `zzprobe.txt`, và in dòng `... done` khi xong.
2. (Tuỳ chọn) Build trước để bắt lỗi compile:
   ```bash
   DEST='platform=macOS,arch=arm64,variant=Designed for iPad,id=00008132-001979623421801C'
   xcodebuild build -workspace FTPlayer.xcworkspace -scheme FTPlayerDemo -configuration Debug \
     -destination "$DEST" -allowProvisioningUpdates DEVELOPMENT_TEAM=34DKQGSTRU FTPLAYER_CREATE_XCFRAMEWORK=NO
   ```
   Truyền `DEVELOPMENT_TEAM` qua dòng lệnh thay vì sửa `project.pbxproj`.
3. Run trên My Mac bằng Xcode. Cần bật System Settings → Privacy & Security → Automation → Xcode cho Terminal.
   Chạy lệnh nền vì lệnh chờ tới khi Xcode kết thúc lần Run:
   ```bash
   osascript -e 'tell application "Xcode"
   set d to workspace document "FTPlayer.xcworkspace"
   set active run destination of d to (first run destination of d whose name is "My Mac (Designed for iPad)")
   set r to run d
   repeat 600 times
   if completed of r then exit repeat
   delay 1
   end repeat
   return (status of r as text)
   end tell'
   ```
   Scheme đang active trong Xcode phải là `FTPlayerDemo`. Đổi bằng `set active scheme of d to scheme "FTPlayerDemo"`.
4. Theo dõi kết quả (Monitor/until-loop): `pgrep -x FTPlayerDemo`, rồi
   `find ~/Library/Containers -maxdepth 6 -name zzprobe.txt -mmin -15`. Chờ tới khi file có dòng `done`.
   Container của app iPad trên Mac có tên là UUID (vd `~/Library/Containers/90570100-…/Data/Documents/`),
   không phải `com.ftplayer.demo`, nên phải dùng `find`.
5. Dừng app: `osascript -e 'tell application "Xcode" to stop workspace document "FTPlayer.xcworkspace"'`.
   Sau đó gỡ probe tạm: `git checkout -- Demo/Sources/AppDelegate.swift` cùng các file probe khác.

Probe mẫu (1 fps H.264 tạo bằng AVAssetWriter, phát ở 16×/4×/1×, đo tốc độ, rebuffer và frame bị giữ):
xem `testZZProbe1fpsHighRate` trong lịch sử phiên điều tra lỗi tốc độ 16× (2026-11-26).

## Simulator
- Unit test SDK (từ `SDK/`): `xcodebuild test -project FTPlayer.xcodeproj -scheme FTPlayerUnit -destination 'id=<simulator id>'`,
  hoặc `./Scripts/test.sh [-only-testing:FTPlayerTests/<Class>/<test>]`. Demo không còn target test.
