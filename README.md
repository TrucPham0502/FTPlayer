# FTPlayer SDK + Demo

## Cấu trúc test hiện tại — 2026-11-24

SDK có target unit `FTPlayerTests` chạy độc lập, không dùng video. Chạy bằng
`bash Scripts/test.sh unit` hoặc Test trong project SDK. Demo có XCUITest thực
trên Simulator với video qua URL: `bash Scripts/test.sh ui`. Các regression
playback trước đây được giữ ở `Demo/Tests/Playback` và cần URL đúng nguồn để
chạy, không đưa video vào Git hoặc bundle. [Hướng dẫn unit SDK](SDK/FTPlayerTests/README.md)
và [test video/UI Demo](Demo/Tests/README.md).
Hai project iOS riêng, clone từ nguồn FTPlayer được cung cấp:

- `SDK/FTPlayer.xcodeproj`: framework **FTPlayer**, chứa engine FTPlayer, audio, cache và Metal renderer.
- `Demo/FTPlayerDemo.xcodeproj`: app UIKit dùng SDK qua project reference.
- `FTPlayer.xcworkspace`: mở cả hai project và chạy demo.
- `SDK/Vendor/FFmpeg`: các XCFramework FFmpeg 9.x dùng thư viện static, được link vào framework SDK. Các file trong `SDK/VendorPatches` chỉ là lịch sử; build hiện tại dùng FFmpeg upstream nguyên bản, mọi workaround nằm trong SDK.
- [`SDK/Scripts/FFmpeg/ffmpeg-build-libs.sh`](SDK/Scripts/FFmpeg/ffmpeg-build-libs.sh): build 7 thư viện FFmpeg thành XCFramework iOS/Simulator/macOS; [cách chạy](SDK/Scripts/FFmpeg/README.md).
- `Scripts/build-sdk.sh`: đóng gói SDK thành `SDK/build/FTPlayer.xcframework` cho iPhone arm64 và Simulator arm64, không tạo hoặc đóng gói dSYM.

Không tham chiếu trở lại thư mục FTPlayer gốc. Không cần CocoaPods, WebRTC hoặc MQTT. Project Xcode đã được tạo sẵn; XcodeGen chỉ cần khi muốn tạo lại project từ `project.yml`.

## Tên project và API

SDK/module: `FTPlayer`; class: `FTPlayer`; demo: `FTPlayerDemo`; workspace: `FTPlayer.xcworkspace`. Các callback metadata dùng `FTPlayerMediaInfo`; diagnostics dùng `FTPlayerDiagnostic`. Biến môi trường của script dùng tiền tố `FTPLAYER_`.

Các type của SDK dùng prefix `FT`, ví dụ `FTFormatContext`, `FTDecoder`,
`FTVideoDecodingPolicy`, `FTPlayerDiagnostic` và `FTMediaRendererView`. App tích hợp dùng
`import FTPlayer` và cần build lại với tên API mới. FFmpeg/WebRTC giữ nguyên tên upstream.

Artifact build và log cũ được giữ nguyên để đối chiếu lịch sử. Kết quả mới nằm trong
`Validation/` và `build/` của project này.

## Bắt đầu từ Git

Repo gồm source SDK, hai project Xcode, shared scheme, test/fixture và các thư viện FFmpeg. Các binary FFmpeg dùng **Git LFS**; cần Git LFS trước khi clone hoặc chạy `git lfs pull` sau khi clone. Header và source vẫn được quản lý bằng Git thông thường.

```sh
git lfs install
# Sau khi clone repo, vào thư mục FTPlayer:
git lfs pull
open FTPlayer.xcworkspace
```

Demo không cần credential hoặc cấu hình API để build/chạy.

Build và test cần macOS, Xcode có iOS Simulator, Python 3 và Apple Silicon. XcodeGen chỉ cần để tạo lại project. Các file `.xcodeproj` hiện có giữ cấu hình signing đang dùng; nếu chạy Mac/iPhone trên máy khác, chọn bundle ID và Development Team của bạn. `Scripts/regenerate-projects.sh` tạo lại từ YAML và có thể thay cấu hình signing hiện tại bằng giá trị mẫu trong YAML.

`.gitignore` loại build, DerivedData, cấu hình cá nhân, token và thư mục `Validation/` chứa log/bằng chứng cục bộ. Các liên kết `Validation/...` bên dưới trỏ đến kết quả trên máy đã chạy; chúng không được clone cùng source. Chạy test để tạo kết quả mới trong `build/TestResults/`. Khi đẩy repo lên remote cần nơi lưu Git LFS cho các binary đi kèm.

## Chạy demo

1. Mở `FTPlayer.xcworkspace`, chọn scheme **FTPlayerDemo** và Simulator/iPhone.
2. Demo mở thẳng player. Dán URL, chọn file từ Files hoặc **Video mẫu** để phát clip local có tiếng, không cần mạng.
3. **Test Stream** mở danh mục video mẫu công khai. Player giữ các điều khiển seek, tốc độ, mute, cache, FPS và xuất log.

Có thể truyền `--play-sample`, `--play-url=<URL>` và `--mute` khi launch để kiểm tra player. Demo không còn màn hình/API danh sách camera, sự kiện hoặc bộ giải nguồn bên ngoài; không bundle token, serial hay GIS.

## Dùng SDK trong app khác

Target **FTPlayer** có Build Phase **Create XCFramework**, xuất gói phát triển vào `SDK/build/<CONFIGURATION>/FTPlayer.xcframework`, ví dụ `SDK/build/Debug/FTPlayer.xcframework`. Phase gom các framework iPhoneOS/Simulator đã build trong cùng configuration và build directory; khi mới build một nền tảng, output chỉ có nền tảng đó. Gói phát triển không ghi đè gói phát hành `SDK/build/FTPlayer.xcframework`. Phase chỉ thay gói của configuration hiện tại sau khi đóng gói thành công; `SDK/build/` đã được gitignore.

Khi dùng source, thêm `SDK/FTPlayer.xcodeproj` và link/embed target FTPlayer. Để build mới cả hai nền tảng Release và đóng gói không có dSYM, chạy:

```sh
./Scripts/build-sdk.sh
```

Script tạo gói tạm, kiểm tra import SDK thành công rồi mới chuyển đến output cuối.
SDK dùng `DEBUG_INFORMATION_FORMAT=dwarf`; script không sinh hoặc lấy dSYM cũ để đóng gói.
Script không ghi đè output đã tồn tại; có thể truyền đường dẫn mới, ví dụ
`./Scripts/build-sdk.sh build/FTPlayer-Release.xcframework`.

Kéo `SDK/build/FTPlayer.xcframework` vào app, chọn **Embed & Sign**. FFmpeg đã link trong SDK; app chỉ cần import FTPlayer, không phải thêm các FFmpeg framework.

Script đóng gói kiểm tra một consumer độc lập bằng cả module nhị phân và interface public/private trên iPhone và Simulator, dùng language mode mặc định của compiler. Không giới hạn danh sách phiên bản; `--languages` chuyển mode được yêu cầu cho compiler kiểm tra. Ví dụ kiểm tra thêm hai mode được toolchain hiện tại hỗ trợ:

```sh
python3 Scripts/check-sdk-import.py SDK/build/FTPlayer.xcframework --languages 5,6
```

`Apple Swift 6.1 effective-5.10` là compiler Swift 6.1 chạy ở language mode Swift 5; đặt `SWIFT_VERSION=5.0` không biến compiler thành Swift 5.0. `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` đã bật để xuất interface, nhưng không bảo đảm compiler cũ đọc được mọi interface do compiler mới sinh. Khi phát hành, dùng Xcode cũ nhất nằm trong phạm vi hỗ trợ để build SDK và kiểm tra lại bằng Xcode của bên nhận. Máy hiện tại chỉ kiểm chứng Xcode 16.3 / Swift 6.1.

`FTPlayerDeletegate` hiện là typealias kết hợp ba protocol observer, tránh lỗi Swift 6.1 làm mất class constraint khi đọc interface có alias module. Khai báo `class Observer: FTPlayerDeletegate` và gán `player.delegate` vẫn dùng như cũ, delegate vẫn là weak. Đây là thay đổi ABI so với protocol tổng hợp trước đó: phải build lại app/module phụ thuộc. Nếu app có `extension FTPlayerDeletegate`, chuyển extension đó sang protocol observer tương ứng; Swift không hỗ trợ extension trên protocol composition.

```swift
import UIKit
import FTPlayer

let renderer = FTMediaRendererView()
// Giữ strong reference đến cả player và renderer, thêm renderer vào layout của app.
let player = FTPlayer(contentURL: URL(string: "https://your-server/video.mp4"))
player.videoOutput = renderer
player.useCache = true // đặt trước khi mở video
player.replaceVideo() // chuẩn bị xong sẽ tự play
player.pause()
player.play()
player.seek(to: 10) { success in print(success) }
player.rate = 2
player.isMuted = true  // video và timeline tiếp tục chạy
player.volume = 0.5    // 0...1; giữ mức này khi unmute
player.isMuted = false
// Stop/Play cùng link giữ cache trong player này.
player.stop()
player.play()
// Khi đổi link: xoá cache cũ và mở video mới.
player.replaceVideo(with: URL(string: "https://your-server/another.mp4")!)
// Khi đóng màn hình: bỏ strong reference để player deinit và dọn cache.
```

Gọi API player/UI trên main thread. Đặt `player.delegate` theo kiểu `FTPlayerDeletegate` để nhận state, progress, buffering và error; tên được giữ như nguồn gốc. `useCache` mặc định false. Khi dùng cache, engine cache HTTP theo byte-range như nguồn gốc; cần server hỗ trợ Range. Đổi URL bằng `player.replaceVideo(with: newURL)` như Demo; cùng URL giữ cache, URL khác xoá cache cũ.

## Delegate state chuẩn bị và thông tin video

SDK **chỉ trả state chuẩn bị**, không trả phần trăm. API hiện tại:

```swift
func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState) {
    print(state.rawValue) // ví dụ connectingToSource, readingStreamInfo, end
    // App tự ánh xạ state sang %, tiêu đề hoặc UI riêng.
}

func player(_ player: FTPlayer, didUpdateMediaInfo info: FTPlayerMediaInfo) {
    print(info.videoCodec as Any, info.width as Any, info.framesPerSecond as Any)
    print(info.audioCodec as Any, info.audioSampleRate as Any, info.audioChannels as Any)
}
```

`player.preparationState` là state chuẩn bị hiện tại. Có **50 state** mô tả bước xử lý thực: kiểm tra URL, chọn cache, audio output, mở kết nối/nguồn, GET Range/HTTP header/byte đầu qua cache, nhận diện container, probe stream, đọc metadata, chọn track, mở codec, lấy thông số video/audio, tạo decoder/clock, dựng và trả media info, đọc packet, giải mã và xuất frame đầu. Callback chạy trên main queue; property khớp state được báo. Các bước không áp dụng bị bỏ qua: file local/warm cache không giả state GET, HLS native không giả callback header của custom HTTP cache.

`begin` bắt đầu mỗi lần mở; `end` chỉ sau khi renderer nhận frame video đầu (audio-only: decoder sẵn sàng). Pause khi mở video sẽ chờ Play để đến `end`. Lỗi khi mở trả `failed`; Stop trả `stopped` và hủy event cũ. Delegate được phép Stop/đổi URL trong callback; source generation ngăn state/metadata/frame cũ lọt sang phiên mới. Seek/rate/rebuffer sau `end` không khởi động lại luồng chuẩn bị.

`connectingToSource` bao quát mở IO URL. Với HTTP/HLS do FFmpeg mở, DNS/TCP/TLS/redirect/header nằm trong `avformat_open_input`; SDK không tạo các state con khi không quan sát được ranh giới thật. HTTP cache báo `requestingHTTPRange`, `httpHeadersReceived`, `receivingInitialData` theo request/response/body thực tế. HEAD dò kích thước có thể chạy song song; GET Content-Range vẫn xác định được kích thước nếu HEAD không hỗ trợ.

Demo tự quy định % trong `PreparationPresentation` ở `Demo/Sources/ViewController.swift`. Thanh cam hiển thị %, raw state, mô tả công việc; ô lịch sử giữ các bước đã nhận để xem lại. Đây là mốc UI có trọng số, không phải % byte hoặc ước lượng thời gian còn lại; `failed` giữ % cuối, `stopped` về 0. Bảng đủ 50 state, thông tin lấy từ URL và % **chỉ của Demo**: [Tests/PREPARATION_STATES.md](Tests/PREPARATION_STATES.md).

`mediaInfo` vẫn là snapshot nguồn: URL, container, duration (s), bitrate tổng/video/audio (bit/s), codec, width/height, FPS, sample rate (Hz), số kênh và số track. Trường không có dùng `nil`. Delegate nhận metadata trước `playerReadyToPlay`; thống kê backend thực nằm ở `videoDecodingStatistics`.

Demo hiển thị FPS ngay dưới video, lấy từ `videoStatisticsDelegate` (xem bên dưới) nên chỉ cập nhật khi số đo đổi. App tích hợp có thể đọc API public `player.videoFrameRateStatistics` trên main thread: `timelineFramesPerSecond` đo số frame xuất trên mỗi giây PTS video, `outputFramesPerSecond` đo trên mỗi giây thực, `sampleFrameCount` là số frame trong cửa sổ 2 giây gần nhất. Ví dụ nguồn 13 fps phát 2× có thể đo khoảng 13 / 26 fps nếu xuất đủ hình. FPS khai báo lấy riêng từ `mediaInfo.framesPerSecond`. Chỉ số PTS là cadence của hình được chọn xuất; bỏ hình có thể làm nó thấp hơn FPS mã hóa. Không phân tích ảnh lặp, không xác định AOV hay đo GPU scanout. Chưa đủ hai hình thì FPS PTS là `nil`; pause/stop/seek/đổi nguồn hoặc tốc độ xóa mẫu cũ. API hoạt động cả khi tắt diagnostics.

Demo bật thêm “Nhịp đổi nội dung (ước lượng)”. SDK mặc định tắt phép đo này; app bật `player.isVideoContentChangeMeasurementEnabled = true`, rồi đọc `player.videoContentChangeStatistics.estimatedChangesPerSecond` trên main thread. SDK thu nhỏ luma các frame output NV12/YUV 8-bit về 160×90, đếm lần khác biệt trung bình giữa hai ảnh vượt 0,05 trên thang 0–255, chia cho tối đa 4 giây PTS video gần nhất. `sampleDuration` cho biết thời lượng mẫu; chưa đủ 1 giây, không có frame trong 2 giây thực, định dạng không hỗ trợ hoặc đang tắt thì kết quả là `nil`. Reset cùng các phép đo FPS. Ảnh tĩnh có thể cho 0; OSD, ánh sáng, nhiễu nén và bỏ frame ảnh hưởng ước lượng. Đây là nhịp thay đổi nội dung theo ngưỡng, không phải FPS gốc camera hoặc bằng chứng chế độ AOV.

Muốn nhận thông báo thay vì tự poll, gán `player.videoStatisticsDelegate` (`FTPlayerVideoStatisticsDelegate`, giữ weak). `player(_:didChangeVideoFrameRate:)` gọi khi `timelineFramesPerSecond` đổi; `player(_:didChangeVideoContentChangeRate:)` gọi khi `estimatedChangesPerSecond` đổi và chỉ khi đã bật phép đo nhịp đổi. Callback chạy trên main khi đang phát, mỗi loại tối đa 1 lần mỗi 0,5 giây video (0,5/`rate` giây thực khi nhanh hơn 1×); giá trị `nil` nghĩa là chưa đủ mẫu (ví dụ ngay sau đổi tốc độ/seek). `upcomingTimelineFramesPerSecond` là FPS sắp tới: nhịp packet video đã demux trong 3 giây video ngay sau frame đang hiện (`FTPlayerSDKConfiguration.Playback.upcomingFrameRateWindow`), không bị ảnh hưởng bởi việc bỏ/lấy mẫu hình ở tốc độ cao; nil khi chưa đủ 3 giây packet hoặc ngay sau seek. Callback FPS gọi khi FPS đã hiện hoặc FPS sắp tới đổi. SDK **không tự đổi `rate`**: chế độ AOV thông minh do app quyết định, ví dụ:

```swift
func player(_ player: FTPlayer, didChangeVideoFrameRate statistics: FTVideoFrameRateStatistics) {
    guard smartEnabled, let fps = statistics.timelineFramesPerSecond else { return } // nil: giữ tốc độ
    let target: Float = fps <= threshold ? lowFrameRateRate : normalRate
    if player.rate != target { player.rate = target }
}
```

Đổi `rate` trong callback được phép; số đo bắt đầu lại nên callback kế tiếp có thể là `nil`. Ở ≥ 2× SDK bỏ frame non-reference, ở ≥ 4× chỉ chọn mẫu hình xuất: `timelineFramesPerSecond` khi đang tua nhanh thấp hơn FPS gốc và trễ; nên dùng `upcomingTimelineFramesPerSecond` để về tốc độ thường trước sự kiện. Khi FPS sắp tới đổi từ thấp sang thường, các frame đã giải mã vẫn thuộc đoạn thưa nên đổi `rate` không cần seek giải mã lại. Demo có nhóm “AOV thông minh” (bật/tắt, nguồn FPS/Nhịp đổi, ngưỡng, tốc độ khi thấp, tốc độ thường; mặc định tắt, 1, 16×, 1×) dùng chung số đo delegate với dòng FPS; tắt chế độ trả về tốc độ đang chọn. Khi pause/stop/kết thúc, Demo tự xóa số đo đang hiển thị vì không còn hình mới để delegate báo.

Toàn bộ logic chế độ này nằm trong một file `Demo/Sources/AOVSmartRateController.swift` (chỉ import `Foundation` và `FTPlayer`); app khác chỉ cần chép file này và link FTPlayer. Cách dùng (main thread): `attach(player, selectedRate:)` sau khi tạo player (controller làm `videoStatisticsDelegate`), chuyển `didChangeState` vào `playerDidChangeState(_:)`, seek của người dùng qua `seek(to:completion:)`, chọn tốc độ qua `selectRate(_:)`, đổi cấu hình qua `update { $0.isEnabled = true }`, cập nhật UI trong `onUpdate`.

Xác nhận state-only: Mac **227 pass**; Simulator iOS 18.4 **202 pass, 25 skip hardware**. Đã run Demo và đối chiếu log state/% trên cả hai nền tảng. [Báo cáo và log](Validation/PreparationStates/SUMMARY.md).

Migration: thay `didUpdatePreparationProgress` bằng `didChangePreparationState`; bỏ dùng `preparationProgress`, `preparationStage` và `FTPlayerPreparationStage`. Default implementation cho callback state giúp delegate không dùng tiến độ chuẩn bị vẫn biên dịch. Chạy `./Scripts/test.sh preparation` cho 24 ca state/metadata/UI.

## Mức âm thanh

SDK giữ mức nguồn: mono được nhân đôi sang stereo với gain 1 trên từng kênh, như AVFoundation; stereo và các phép downmix khác giữ cấu hình cũ. Bản trước dùng ma trận mặc định libswresample khiến mono→stereo giảm 3,01 dB mỗi kênh. `volume` vẫn trong 0...1, mute giữ volume đã chọn. Audio gốc thu nhỏ vẫn phát ở mức gốc.

Log có cấu hình resampler `dualMonoUnity` và `audioDecodedSamples`, `audioDecodedRMSDBFS`, `audioDecodedPeakDBFS`. Đây là mức PCM tích lũy đã decode trước mixer volume, gồm dữ liệu decode ahead và seek; không phải mức âm thanh đo tại loa. Đo ở decode thread, không xử lý/log trên realtime audio callback. Chạy `./Scripts/test.sh audio` cho 8 ca đo PCM + 2 ca mute/seek/rate; test tự tạo WAV, không dùng bản ghi camera riêng.

Xác nhận sau sửa audio: Mac **191 pass**; Simulator **178 pass, 13 skip hardware**. Đã đo lại clip camera thực tế; [kết quả đo, test trước/sau và log](Validation/AudioLevel/SUMMARY.md).

## Log phục vụ trace

Ghi log **mặc định tắt**, cả Debug và Release. App bật/tắt toàn SDK qua public API `FTPlayerDiagnostic.shared.isEnabled`; mặc định tập trung tại `FTPlayerSDKConfiguration.Diagnostics.enabledByDefault`.

Diagnostics che thông tin truy cập trong URL, Authorization/Cookie và các field token/key/serial/GIS nhận diện được trước khi ghi. Export cũng áp dụng lên notes và log lịch sử; file log gốc cũ không bị sửa. Đây không phải bộ dò mọi secret tùy ý: host app vẫn không nên gửi credential hoặc body API vào log.

- File JSONL trong `Documents/FTPlayerLogs`, tối đa 12 file × khoảng 8 MiB; tự xoay file và giữ phiên trước khi relaunch.
- Mỗi record có UTC timestamp, monotonic uptime, session, player ID ở các event player, thread, category và level.
- Timeline gồm host/định dạng nguồn đã che đường dẫn và thông tin truy cập, trạng thái, play/pause/stop/rate/seek, ready/EOF/finish/error, vòng đời app, memory warning và audio interruptions/routes.
- Giữ FFmpeg warning/error, native error code + stage, HTTP lỗi/Range không hợp lệ/retry, lỗi AudioUnit/VideoToolbox/Metal. Bỏ log verbose/info FFmpeg, từng request/response HTTP thành công, cache hit/chờ/đọc lại và các snapshot lặp.
- Khi bật, mỗi giây có một snapshot progress, buffer/threshold, cache/load control, audio/video queue, audio clock, muted/volume/mixer gain, video PTS, số frame gửi renderer và khoảng thời gian từ frame gần nhất. Đổi rate có thêm mẫu ngắn để đối chiếu rate thực tế.
- Khi tắt không tạo thư mục/file log mới, không dựng snapshot hoặc đo mức PCM phục vụ log. Lệnh tắt chờ lượt ghi đang chạy kết thúc, đóng file và hủy record đang chờ; bật lại tạo phần tiếp theo, giữ lịch sử. Có thể bật trong lúc video đang phát.
- Writer chạy serial queue, đồng bộ xuống file mỗi record. Các event chưa vào writer trước khi hệ điều hành kết thúc process vẫn có thể thiếu. Không log từng audio sample trên audio callback.
- **Xuất log** gộp tất cả file hiện còn giữ và mô tả lỗi vào một file `.txt`, kể cả khi đã tắt ghi. Xuất không tự bật ghi log. File xuất chứa URL và thông tin stream được FFmpeg ghi ra.

```swift
FTPlayerDiagnostic.shared.isEnabled = true
FTPlayerDiagnostic.shared.log("User tapped replay", category: "my-app")
FTPlayerDiagnostic.shared.flush()
FTPlayerDiagnostic.shared.isEnabled = false
let reportURL = try FTPlayerDiagnostic.shared.exportLogs(notes: "Seek tới 10s rồi bị đứng")
```

Có thể lấy thư mục log qua Files → FTPlayer Demo → FTPlayerLogs, hoặc Xcode Devices & Simulators → Download Container. Log ghi số frame gửi renderer; lỗi GPU được ghi riêng trong category engine.

## Kiểm tra

Các lệnh thường dùng:

| Lệnh | Phạm vi |
| --- | --- |
| `./Scripts/test.sh daily-startup` | Đo từng video trong manifest riêng: frame đầu, từng state và backend; xem Demo/Tests/Playback/README.md |
| `./Scripts/test.sh startup-log` | FFmpeg lọc đúng mức log khi mở file, vẫn giữ native error |
| `./Scripts/test.sh spam-seek` | 28 ca spam ±10s, 200 lệnh liên tiếp, rate 2×–16×, seek đầu/cuối và UI |
| `./Scripts/test.sh audio` | PCM mono/stereo, resample, mức tín hiệu và mute/seek/rate |
| `./Scripts/test.sh preparation` | Tiến độ tới frame đầu, metadata, lỗi/Stop/đổi nguồn và UI |
| `./Scripts/test.sh session-cache` | Stop/Play giữ cache, đổi URL/deinit dọn cache, test UI |
| `./Scripts/test.sh cache` | HTTP Range, cache, seek đầu/giữa/cuối, offline/recovery |
| `./Scripts/test.sh catalog-cache` | Toàn bộ Link test, bytes/timeline/seek/replay; báo riêng DASH thiếu demuxer |
| `./Scripts/test.sh catalog-controls` | Từng Link test: seek đầu/giữa/cuối, 16× trong cache, về 1× và Stop/Play; xem [phạm vi/kết quả](Demo/Tests/Playback/CATALOG_SEEK_16X_CACHE.md) |
| `./Scripts/test.sh catalog-round3` | 10 nguồn mới vòng 3: 10 ca playback/cache và 10 ca seek/16×/warm replay |
| `./Scripts/test.sh catalog-stress` | 5 nguồn nhãn Khó: discontinuity/quảng cáo, AES đổi key/IV, timestamp và gap A/V |
| `./Scripts/test.sh malformed-media` | 10 nguồn sai bitstream/metadata, cache mặc định/bật, seek 1×/4×/16× và báo lỗi; [nguồn/phạm vi](Demo/Tests/Playback/MALFORMED_MEDIA_LINKS.md) |
| `./Scripts/test.sh mux-16x` | Mux master bật cache, renderer thật, 16× liên tục trên Auto/FFmpeg/Hardware |
| `./Scripts/test.sh errors` | HTTP lỗi, mất mạng, timeout và callback lỗi |
| `./Scripts/test.sh local` | SDK và Demo với fixture/HTTP loopback |
| `./Scripts/test.sh backends-all` | FFmpeg/hardware, seek và rate 2×–16× |
| `./Scripts/test.sh full` | Toàn bộ local, Internet và backend |

Đã sửa log FFmpeg vượt ngưỡng khi mở MP4: cùng clip/cold cache, đoạn Demo 26% đo được **2.36s → 0.65s**. Bộ local sau sửa: Mac **229 pass**; Simulator **204 pass, 25 skip hardware**. [Bằng chứng trước/sau và log](Validation/Startup26/SUMMARY.md).

Xác nhận sau sửa spam seek: Mac **219 pass**; Simulator iOS 18.4 **194 pass, 25 skip hardware**. Bộ mới có 28 ca spam ±10s, kiểm tra trực tiếp lệnh cuối, FFmpeg/hardware và rate 2×–16×. [Bug, bằng chứng trước/sau và log](Validation/SpamSeek/SUMMARY.md).

Đợt xác nhận cache gần nhất (2026-10-22): Mac Designed for iPad **167 pass**; Simulator iOS 18.4 **156 pass, 11 skip hardware**. Đây là kết quả local đã ghi nhận; bộ Internet/backend đầy đủ có phạm vi riêng bên dưới.


Unit SDK ở [SDK/FTPlayerTests](SDK/FTPlayerTests/README.md), chạy `./Scripts/test.sh unit` không cần video. [Demo playback/UI](Demo/Tests/README.md) dùng video qua URL; `full` cần cấu hình đủ nguồn và thiết bị thích hợp cho từng nhóm.

Các smoke test playback ở `Demo/Tests/Playback/FTPlayerSmokeTests.swift`; log/diagnostics thuần ở SDK unit. Product → Test trong scheme `FTPlayerDemo` chạy XCUITest giao diện; scheme `FTPlayerPlayback` dành cho integration cần URL nguồn.

`Validation/` lưu kết quả build/test, mô tả thay đổi và hash nguồn gốc. Engine được clone từ nguồn gốc và đã sửa các lỗi tìm được qua regression test; xem `Validation/CHANGES.md`. Kiểm tra URL thực tế trên iPhone khi tái hiện lỗi hardware decoder.


## Bộ test định dạng, Internet và seek/rate

Xem [cấu trúc hiện tại](Demo/Tests/README.md) và [ma trận lịch sử](Tests/TEST_MATRIX.md). Unit ở `SDK/FTPlayerTests`; playback/UI ở `Demo/Tests`:

- Scheme **FTPlayerUnit**: 90 unit logic của SDK, không video/host Demo.
- Scheme **FTPlayerDemo** hoặc **FTPlayerDemoUI**: XCUITest app thật bằng URL public.
- Scheme **FTPlayerPlayback**: regression video/HTTP/cache; cần manifest URL đúng nguồn, không bundle video.
- Scheme **FTPlayerInternet**: URL Internet thật từ Apple, Mux, Test Videos, W3C và FFmpeg samples. Có ca DASH kiểm tra capability và từ chối đúng nếu binary không có demuxer.
- Bộ kết hợp seek/rate: MP4 H.264+AAC, MP4 HEVC, HLS H.264+AAC, HLS HEVC ở **2x/4x/8x/16x**, seek tiến, seek ngược rồi đổi ngay 1x, rapid seek + đổi rate và HTTP cache 8x.

```sh
./Scripts/test.sh unit
./Scripts/test.sh ui
./Scripts/test.sh playback-public
# Nhóm đầy đủ cần cấu hình URL nguồn và thiết bị phù hợp:
./Scripts/test.sh all
# Chọn Simulator khác:
FTPLAYER_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' ./Scripts/test.sh all
```

Script tạo `.xcresult`, log, CSV/Markdown và attachment JSON tại `build/TestResults/<timestamp>`. Attachment ghi số frame, source URL, states, lỗi, target seek, clock, PTS và tốc độ đo được; test không chỉ kiểm tra setter rate.

Demo có nút **Link test** với cùng catalog `Demo/Sources/SampleStreams.json`. Danh sách mở trong bảng dọc có thể cuộn, chia nhóm theo container; tên dài tự xuống dòng. Ô tìm kiếm lọc theo tên, codec (H.265/HEVC, H.264), container và URL. Chạm một dòng để đóng bảng và mở stream; nút × đóng bảng mà không đổi video. Chọn stream rồi thử thanh seek và rate; xuất log nếu gặp lỗi. Test tự động dùng renderer kiểm tra riêng, không thay nội dung đang phát trong khung video của demo.

Nhóm [10 nguồn sai bitstream/metadata](Demo/Tests/Playback/MALFORMED_MEDIA_LINKS.md) gồm chín URL mới có nhãn **Lỗi nguồn** và Custom IV đã có sẵn. Hai file trùng track ID/WebM hỏng được ghi rõ dùng kiểm tra báo lỗi; các clip keyframe hai frame dùng kiểm tra seek/EOF.

Catalog phân phối hiện gồm 15 URL MP4; các nhóm dưới đây là inventory lịch sử và cần URL opt-in. Trước cleanup catalog có 54 URL; có HEVC 1080p/4K, HEVC trong TS/fMP4, HDR/PQ, AES-128/SAMPLE-AES, audio riêng, WebM VP8/VP9, MOV HEVC/PCM và AVI MPEG-4. [5 nguồn nhãn Khó](Demo/Tests/Playback/DIFFICULT_PUBLIC_STREAMS.md) kiểm tra discontinuity, IV/key, timestamp và gap A/V bằng `./Scripts/test.sh catalog-stress`. Chạy 10 nguồn vòng 3 cùng kiểm tra cache/seek/16× bằng `./Scripts/test.sh catalog-round3`; xem [nguồn và kết quả vòng 3](Demo/Tests/Playback/PUBLIC_STREAM_EXPANSION_ROUND3.md). `catalog-more` giữ 10 nguồn của [vòng 2](Demo/Tests/Playback/PUBLIC_STREAM_EXPANSION_ROUND2.md), `catalog-extra` giữ 8 nguồn của [vòng đầu](Demo/Tests/Playback/PUBLIC_STREAM_EXPANSION.md).

Fixture local tại `Demo/Fixtures` được giữ trên máy và ignore; các target test hiện không dùng/bundle thư mục này. Playback regression tải nguồn URL đã cấu hình vào sandbox tạm và kiểm tra SHA-256. `Validation/Network/fixtures-manifest.json` ghi nguồn, SHA-256 và codec probe. Khi muốn tạo lại: đặt `FFMPEG_BIN` và `FFPROBE_BIN`, chạy `python3 Scripts/prepare-fixtures.py`. Đây là test data; không bundle các fixture vào SDK framework.

Nguồn công khai: [Apple Streaming Examples](https://developer.apple.com/streaming/examples/), [Mux HLS test streams](https://test-streams.mux.dev/), [Test Videos H.264](https://test-videos.co.uk/bigbuckbunny/mp4-h264), [Test Videos HEVC](https://test-videos.co.uk/bigbuckbunny/mp4-h265), [FFmpeg samples](https://samples.ffmpeg.org/FLV/) và [W3C trailer](https://media.w3.org/2010/05/bunny/trailer.mp4).


## Test decoder và rate/seek riêng biệt

```swift
player.videoDecodingPolicy = .ffmpeg // hoặc .automatic / .hardware; đặt trước replaceVideo()
player.replaceVideo()
// Khi đã decode: đọc player.videoDecodingStatistics.
```

`hardware` bắt buộc session VideoToolbox xác nhận hardware acceleration; nếu không có sẽ báo lỗi, không tự fallback. `automatic` ưu tiên hardware đã xác minh trên iOS 17 trở lên, nếu không xác minh được thì dùng FFmpeg; frame từ FFmpeg, hardware, VideoToolbox software và session chưa xác minh được thống kê riêng. API xác minh hardware có từ iOS 17 trong SDK Xcode đang dùng; iOS cũ vẫn dùng Auto/FFmpeg và không được tính hardware pass nếu không xác minh được.

Chạy `./Scripts/test.sh backends-all` cho 113 ca: MP4 H.264/HEVC, HLS H.264/HEVC, 2 backend, 2×/4×/8×/16× + seek, rapid seek/rate. Local còn chạy từng mức nguyên 2×…16× và pause/seek/resume/gần cuối. Chi tiết: `Tests/DECODE_BACKENDS.md`; kết quả thực chạy và các lỗi đã sửa: `Validation/DecodeBackends/SUMMARY.md`. Các ca hardware skip trên Simulator được ghi rõ; không coi software fallback là hardware pass.

## Chạy trực tiếp trên Mac Apple Silicon

Chọn scheme **FTPlayerDemo** và đích **My Mac (Designed for iPad)** rồi Run như Simulator. SDK dùng slice iOS arm64; chế độ này đã build/ký và Run được với cấu hình Signing hiện tại. Scheme Demo đã đặt executable rõ ràng là `FTPlayerDemo.app` cho Run/Profile. Các scheme Internet/DecodeBackends phục vụ test riêng; không cần chọn chúng để dùng demo.

Chạy riêng hardware trên Mac (cần Development Team hợp lệ):

```sh
FTPLAYER_TEST_DESTINATION='platform=macOS,arch=arm64,variant=Designed for iPad' \
FTPLAYER_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
FTPLAYER_TEST_BACKEND=hardware ./Scripts/test.sh backends-all
```

35 ca fixture + 20 ca URL công khai + 5 ca video PrivatePlayback riêng từ `FTPlayerPrivatePlaybackSource.json` trong Documents hoặc biến môi trường test `FTPLAYER_PRIVATE_PLAYBACK_URL`. Nếu không có URL riêng, 5 ca PrivatePlayback được skip rõ ràng. Kết quả thực chạy: `Validation/MacHardware/SUMMARY.md`. Hardware pass yêu cầu VideoToolbox xác nhận phần cứng, số frame hardware > 0 và không có FFmpeg/VT software/unverified fallback. Kết quả này áp dụng cho Mac đang chạy; cần kiểm tra riêng trên iPhone khi phát hành.

Hardware recovery 2026-10-22: đã sửa đứng hình HLS 60 fps ở 16×, đồng bộ bỏ frame trễ và phục hồi lỗi H264 bằng keyframe trên hardware. 55 ca hardware + 48 FFmpeg + 24 API/control/mute pass trên Mac; xem `Validation/MacHardware/SUMMARY.md`. URL PrivatePlayback cũ trả 500 đã được cấp lại qua API cho cùng clip; cấu hình test local dùng URL mới.


## Cache khi seek và mất mạng

Đặt `player.useCache = true` trước khi mở video; demo đã bật sẵn HTTP cache. Seek đầu/giữa/cuối đọc lại byte đã lưu trên máy, chỉ tải khoảng còn thiếu. Mất mạng vẫn phát/seek được vùng đã cache; đến phần thiếu thì buffering và tự tải/phát tiếp khi kết nối trở lại. Stop hủy chờ ngay. Cache giữ trong phiên player; Stop/Play cùng link giữ cache, đổi link/deinit xoá cache. Cache hỗ trợ HTTP file và HLS VOD: TS, fMP4, MP4 độc lập, media/master playlist, byte range, init map thay đổi và AES-128 identity. Master dùng variant đầu và audio DEFAULT/AUTOSELECT cùng group; timeline cache là phần có đủ video, audio, map và key. Tài nguyên dùng chung cơ chế cache theo URL + byte range, không phân nhánh theo link Apple/Mux. Live, DRM, GAP/DEFINE và external VIDEO group chưa thuộc phạm vi disk cache này; DASH chưa có demuxer trong binary hiện tại. Xem [phạm vi và regression](Demo/Tests/Playback/HLS_CACHE_COVERAGE.md).

Chạy lại 96 ca HTTP/cache bằng `./Scripts/test.sh cache`, hoặc nhóm playback bằng `./Scripts/test.sh playback` (số ca nêu ở đây là kết quả lịch sử). Test video nằm trong `Demo/Tests/Playback`.

### Thanh cache đã tải

Demo giữ thanh buffer hiện tại và thêm thanh **Cache đã tải** màu xanh ngọc ở trên thanh tua. Phần trăm là số byte thực sự lưu trên máy, gồm metadata. Các đoạn tô màu thể hiện khoảng thời gian có đủ packet video từ keyframe và audio đã chọn; khoảng chưa tải vẫn để trống. Không suy thời gian từ phần trăm byte vì video có bitrate thay đổi. SDK cung cấp `player.cachedTimeRanges`, `player.cacheProgress` và `player.downloadProgress`. `cacheProgress.cachedBytes` báo bytes đã lưu ngay cả khi chưa biết tổng; `totalBytes`/`fraction` là nil trong giai đoạn đó. Demo hiển thị bytes và trạng thái đang xác định tổng dung lượng, sau đó chuyển sang phần trăm. `downloadProgress` cũ vẫn bằng 0 khi chưa tính được tỷ lệ; cập nhật giao diện trong `didUpdateDownloadProgress` và `playerReadyToPlay` (cache có sẵn không phát sinh HTTP callback).

MP4 có bảng sample đầy đủ hỗ trợ timeline cache theo từng khoảng. Nếu định dạng không có index đầy đủ, phần trăm byte vẫn đúng, thanh thời gian chưa tô cho đến khi đủ file; HLS VOD tô các segment có đủ media và dependency đã tải trọn; master chỉ tô phần giao của video/audio. Live/DRM và DASH chưa hỗ trợ cache offline.

### Báo lỗi và thông tin thời gian

`player.currentTime` là vị trí hiện tại (giây), cùng timeline zero-based với `progress` và `seek`; `player.duration` là tổng thời lượng. Demo hiển thị hai nhãn Current time/Duration dạng giờ:phút:giây. Log lỗi và NSError.userInfo có currentTime/duration/rate/cacheProgress.

Cold open cache có giới hạn 30 giây và trả NSURLErrorTimedOut nếu thiếu dữ liệu quá hạn. Sau khi đã ready, mất mạng ở phần chưa cache vẫn buffering và tự phục hồi; dữ liệu có cache vẫn đọc được. HTTP 401/403/404/410/416 là lỗi dừng phát, giữ status gốc; 408/429/5xx được retry có backoff trong ngân sách mở video hoặc tiếp tục chờ khi đã phát. Lỗi fatal gửi một callback cho mỗi lần mở video; dùng replaceVideo() để thử lại. Chạy lại `./Scripts/test.sh errors`; bằng chứng tại Validation/ErrorHandling/SUMMARY.md.

### Cache chỉ dùng cho phiên hiện tại

- Pause, seek, Stop rồi Play lại **cùng link/cùng player** giữ dữ liệu đã tải. `stop()` đóng decoder/tải mạng, `play()` mở lại bằng cache của phiên; thanh cache và duration còn được giữ khi Stop.
- `player.replaceVideo(with: anotherURL)` xoá cache link cũ, tạo phiên cache mới. Demo sử dụng API này.
- Deinit player xoá video và index của phiên. Player mới luôn có phiên riêng, kể cả cùng URL. Không xoá cache của player khác còn đang dùng.
- Nếu app bị kill/crash không có deinit, lần dùng cache ở tiến trình mới sẽ dọn thư mục phiên cũ và cache persistent của bản trước. Không phục hồi cache qua lần mở app.

Chạy lại `./Scripts/test.sh session-cache`; bằng chứng tại Validation/SessionCache/SUMMARY.md. Đây là chính sách hiện tại, thay cho chính sách giữ cache lâu dài trong các báo cáo trước.


### Xcode Run trên My Mac báo thiếu AVPlayerView

Nếu dyld báo `_OBJC_CLASS_$_AVPlayerView` từ `libViewDebuggerSupport.dylib`, áp dụng workaround View Debugger được ghi nhận ở [Apple Developer Forums](https://developer.apple.com/forums/thread/766421): Edit Scheme → Run → Options → View Debugging, bỏ **Enable user interface debugging**. Các shared scheme chạy Demo đã tắt tùy chọn này (`viewDebuggingEnabled=No`), vẫn giữ LLDB/breakpoint. Muốn dùng UI hierarchy debugging trên Simulator có thể bật lại ở scheme; nếu tạo lại scheme bằng XcodeGen cần áp dụng lại tùy chọn. Đây là cấu hình launch của Xcode, không thay API SDK. Kết quả đối chiếu dependency và hai lần Run Mac: `Validation/ViewDebuggerLaunch/SUMMARY.md`.


### Regression đứng hình 16× và seek FFmpeg 9

SDK bắt kịp decoder chậm bằng random-access packet có thể hiển thị, giữ đầy đủ reorder window sau flush và bảo vệ preroll của seek. Không chọn keyframe có cờ DISCARD của MP4 edit list. Patch làm tròn DTS của HLS đã cập nhật cho dependency FFmpeg 9, kèm source/config/hash và công cụ rebuild.

Chạy `./Scripts/test.sh sustained-rate` (9 ca áp lực decoder + packet queue) và `./Scripts/test.sh hls-seek` (22 ca demux/spam seek/rate). Test source playback nằm trong `Demo/Tests/Playback`; media không bundle; clip camera riêng dùng manifest opt-in, hướng dẫn ở [SDK test README](Demo/Tests/Playback/README.md). [Báo cáo trước/sau, số liệu thiết bị thật và log](Validation/HighRateFreeze/SUMMARY.md).

### Tải trước theo tốc độ phát

HTTP cache tăng cửa sổ tải trước trên đĩa: **1× 8 MiB, 2× 16 MiB, 4× 32 MiB, 8×–16× mục tiêu 64 MiB**; mỗi Range tối đa 4 MiB. Giảm rate giữ các bytes đã tải. Request không có hoạt động mạng 10 giây sau ready tự nối lại từ bytes còn thiếu, kể cả chưa có reader chờ. Cold open giữ timeout mở nguồn. Cache vẫn chỉ tồn tại trong session: Stop/play cùng link giữ lại, đổi link/deinit xóa.

Chạy lại `./Scripts/test.sh adaptive-cache` (4 ca) hoặc `./Scripts/test.sh cache` (96 ca). Chi tiết policy, diagnostics và test source: [Demo playback](Demo/Tests/Playback/README.md).

Cửa sổ tải trước là mục tiêu: khi read head di chuyển, một Range đang tải có thể vượt mục tiêu dưới 4 MiB. Cache đã tải ở rate cao hoặc vùng seek khác vẫn được giữ trong session.

### Mã lỗi trong demo

Ngay dưới trạng thái phát có phần **Log mã lỗi**: domain/code gốc, thông báo, bước chuẩn bị, operation/stage, timeout, FFmpeg avCode và lỗi nguyên nhân nếu SDK cung cấp. Có thể chọn/sao chép nội dung. Cùng chi tiết được ghi vào file khi **Xuất log / Share**. Mở video hoặc thử phát lại sẽ xóa lỗi cũ trên màn hình; log file vẫn giữ lịch sử. Lỗi của player cũ không ghi đè player hiện tại.

### HTTPS cho HLS sau nâng FFmpeg 9

Đã bật native HTTPS/TLS bằng Apple Secure Transport trong libavformat, giữ HLS seek patch. Regression kiểm tra protocol nằm trong `Demo/Tests/Playback/FTPlayerHLSTests.swift`; script rebuild cùng SDK tại [rebuild-https-support.py](SDK/Scripts/FFmpeg/rebuild-https-support.py). Script `.sh` hiện đã bổ sung mặc định HTTPS/TLS/HLS cho mọi target. [Bằng chứng playlist gateway trước/sau](Validation/HLSGateway/SUMMARY.md).


### HLS VOD gồm MP4 độc lập / discontinuity

SDK chuẩn hóa timestamp các MP4 bắt đầu lại từ 0 thành timeline toàn playlist, sửa seek đầu/giữa/cuối và clock lùi khi 16×. Session cache lưu resource trên đĩa qua Range proxy; tải trước tăng theo rate, giữ Stop/replay, xóa khi đổi URL/deinit. Các dạng HLS khác tiếp tục dùng demuxer native.

Test cùng SDK: `./Scripts/test.sh hls-review` (12 ca opt-in, input riêng trong Documents). Mac Designed for iPad: 12/12 với 40 segment /21:05 và 12/12 với 83 segment /43:30; HLS regression 13/13. Không thay 21 archive FFmpeg do user tự build. Chi tiết: [test source và cách chạy](Demo/Tests/Playback/README.md), [bằng chứng trước/sau](Validation/HLSFullReview/SUMMARY.md).


Sửa cache HLS0% khi server trả HEAD403 nhưng GET206 hợp lệ: metadata fallback Range một byte; prefetch 1×8MiB đến16×64MiB. Đã kiểm tra gateway thật và label Demo trên Mac. Chi tiết: [log/test trước và sau sửa](Validation/HLSCacheProgress/SUMMARY.md).


### Điều khiển tải theo thời gian và dung lượng

Các giá trị tuning mặc định của toàn SDK được tập trung tại [FTPlayerSDKConfiguration.swift](SDK/Sources/API/Configuration/FTPlayerSDKConfiguration.swift): playback/rate/seek, load control, audio/video, network/cache/HLS, renderer và diagnostics. Đây là cấu hình lúc build, dùng `static let` bất biến; sửa file này rồi build lại SDK để đổi mặc định. Các API điều khiển và `player.loadControlConfiguration` vẫn ghi đè cấu hình cho từng player. Mã HTTP, mã lỗi, cấu trúc codec, hệ số màu chuẩn và phép đổi đơn vị giữ tại nơi sử dụng vì chúng là hằng số kỹ thuật.

Policy mới dùng `FTPlayerLoadControlConfiguration` theo quy tắc Media3/ExoPlayer: mặc định50giây media, điều chỉnh minimum theo rate và chặn bởi maximum, kết hợp byte-target theo selected tracks. Không áp dụng đề xuất10giây phát thực/16MiB. Bộ điều khiển demux dùng chung các định dạng; disk read-ahead dùng sample index của file hoặc timeline segment khi cache hỗ trợ. Cache cũ vẫn giữ trong session. Cấu hình trước open và cách chạy40 regression: [Demo playback](Demo/Tests/Playback/README.md). Báo cáo: [ExoLoadControl](Validation/ExoLoadControl/SUMMARY.md).
