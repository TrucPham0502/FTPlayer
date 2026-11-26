# Build FFmpeg nguyên bản cho FTPlayer

Script chỉ configure, compile, install và đóng gói source FFmpeg upstream do chủ project cung cấp. Các tùy chọn cấu hình trong `.sh` phải là tùy chọn chuẩn của FFmpeg; không chứa thuật toán hoặc logic xử lý của SDK/player. Không sửa source/header/Makefile/configure, không tạo `patched-source`, không áp patch hoặc tạo receipt patch. Sửa lỗi playback và workaround nằm trong source SDK. Quy tắc: [AGENTS.md](../../../AGENTS.md).

Chủ project tự chọn source, tự build và cập nhật dependency. Script không tải FFmpeg, không chọn phiên bản khác và không chép binary vào `SDK/Vendor/FFmpeg`.

## Chạy trong source FFmpeg gốc

Dùng checkout FFmpeg upstream sạch, có `configure` và `libavcodec/`, chưa configure trong source tree. Chép script vào đó rồi chạy:

```sh
bash ./ffmpeg-build-libs.sh
```

Hoặc chạy script từ repo FTPlayer:

```sh
BUILD_ROOT="$PWD/build/ffmpeg-libs" JOBS=8 \
  bash SDK/Scripts/FFmpeg/ffmpeg-build-libs.sh /path/to/FFmpeg
```

Script build trực tiếp source được truyền vào, giữ các thư mục build riêng cho từng target. Thư mục build cũ được dọn bằng target `make distclean SRC_LINK=src` của FFmpeg trước configure, bao gồm link `src` do configure sinh ra; giữ nguyên `BUILD_ROOT` và bố cục output. Output mặc định: `<FFmpeg-source>/build-libs/xcframeworks/`. Có thể đặt `BUILD_ROOT`, `JOBS`, `MIN_IOS_VERSION` và `MIN_MACOS_VERSION`; script không tự đổi bố cục đường dẫn build.

## Cấu hình chuẩn và output

Yêu cầu macOS, Xcode với iOS/Simulator/macOS SDK và các công cụ `xcrun`, `xcodebuild`, `make`, `lipo`, `ar`, `sysctl`, `cmp`. Không còn yêu cầu Python, patch hoặc shasum. NASM là tùy chọn cho macOS x86_64; nếu thiếu thì dùng cờ chuẩn `--disable-x86asm`.

Giữ các cờ chuẩn: static/PIC, GPL, VideoToolbox, network, SecureTransport, HLS demuxer và protocol HTTP/HTTPS/TCP/TLS/crypto. Tắt chương trình ffmpeg/ffprobe, tài liệu, debug và autodetect thư viện trên máy host. Script kiểm tra cấu hình HTTPS/TLS/HLS trước compile và kiểm tra library/header/architecture khi build. CoreVideo/Metal dùng SDK Apple.

Bảy thư viện `libavcodec`, `libavdevice`, `libavfilter`, `libavformat`, `libavutil`, `libswresample`, `libswscale` được đóng gói thành XCFramework với:

- iOS arm64, mặc định iOS13.0.
- iOS Simulator arm64, mặc định iOS13.0.
- macOS universal arm64+x86_64, mặc định macOS11.0.

Framework/XCFramework, modulemap, Info.plist và các file do configure/make sinh ra là output build bình thường. Script không tạo source sửa riêng hay metadata patch.

## Đóng gói lại thư viện có sẵn

```sh
BUILD_ROOT="$PWD/build/ffmpeg-libs" \
  bash SDK/Scripts/FFmpeg/ffmpeg-build-libs.sh --package-only /path/to/FFmpeg
```

Giữ đủ output trong `ios`, `ios-simulator-arm64`, `macos-arm64`, `macos-x86_64` của cùng `BUILD_ROOT`. Chế độ này chỉ đóng gói archive có sẵn, không compile hoặc kiểm chứng source của archive. Khi chuyển từ output đã patch sang FFmpeg thuần, chủ project cần chạy full build từ source upstream sạch; `--package-only` không thay nội dung archive cũ.

`--prepare-only` đã bỏ vì không còn bước chuẩn bị patch. Để đóng gói FTPlayer SDK sau khi cập nhật dependency, dùng `Scripts/build-sdk.sh /path/to/new/FTPlayer.xcframework`.
