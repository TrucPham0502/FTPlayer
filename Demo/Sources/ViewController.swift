import UIKit
import FTPlayer

// UI policy belongs to the Demo, never to the SDK. These are weighted milestones,
// not elapsed time, bytes downloaded, or an estimate of time remaining.
struct PreparationPresentation {
    let percent: Int?
    let title: String
    let detail: String
    static func forState(_ state: FTPlayerPreparationState) -> PreparationPresentation {
        switch state {
        case .idle: return PreparationPresentation(percent: 0, title: "Chưa mở video", detail: "Chưa có yêu cầu mở nguồn.")
        case .begin: return PreparationPresentation(percent: 0, title: "Bắt đầu", detail: "Bắt đầu phiên chuẩn bị video mới.")
        case .validatingSource: return PreparationPresentation(percent: 2, title: "Kiểm tra URL", detail: "Kiểm tra nguồn đầu vào trước khi mở.")
        case .sourceValidated: return PreparationPresentation(percent: 4, title: "Đã nhận URL", detail: "URL đầu vào đã được chấp nhận; chưa có nghĩa máy chủ đã phản hồi.")
        case .preparingCache: return PreparationPresentation(percent: 6, title: "Chuẩn bị cache", detail: "Tạo hoặc dùng lại session cache cho URL hiện tại.")
        case .cachePrepared: return PreparationPresentation(percent: 8, title: "Cache sẵn sàng", detail: "Đã chọn session cache; các byte đã tải được giữ khi Stop/Play cùng URL.")
        case .configuringAudioOutput: return PreparationPresentation(percent: 10, title: "Khởi tạo đầu ra âm thanh", detail: "Đăng ký AVAudioSession và chuẩn bị AudioUnit, volume/mute.")
        case .audioOutputConfigured: return PreparationPresentation(percent: 12, title: "Đầu ra âm thanh đã cấu hình", detail: "Đã chạy bước cấu hình audio output; codec của nguồn sẽ mở sau.")
        case .allocatingFormatContext: return PreparationPresentation(percent: 14, title: "Tạo FFmpeg format context", detail: "Cấp phát context để mở URL, demux và quản lý track.")
        case .formatContextAllocated: return PreparationPresentation(percent: 16, title: "Format context đã tạo", detail: "Đã cấp phát context và chuẩn bị cấu hình timeout/interrupt.")
        case .connectingToSource: return PreparationPresentation(percent: 18, title: "Mở kết nối tới URL", detail: "Bắt đầu mở nguồn. Với HTTP/HLS native, FFmpeg thực hiện DNS, TCP, TLS nếu HTTPS, redirect và đọc header trong bước này; file local không mở mạng.")
        case .requestingHTTPRange: return PreparationPresentation(percent: 20, title: "Gửi HTTP GET Range", detail: "HTTP cache yêu cầu vùng byte còn thiếu bằng GET với header Range; HEAD dò Content-Length có thể chạy song song.")
        case .httpHeadersReceived: return PreparationPresentation(percent: 23, title: "Đã nhận HTTP header", detail: "Đã nhận phản hồi GET thành công. Cache đọc status, Content-Range/Content-Length để biết kích thước và khả năng đọc theo vùng.")
        case .receivingInitialData: return PreparationPresentation(percent: 26, title: "Đã nhận dữ liệu đầu tiên", detail: "Đã nhận body GET đầu tiên của worker cache; ghi byte vào cache để FFmpeg đọc.")
        case .sourceOpened: return PreparationPresentation(percent: 30, title: "Đã mở nguồn và nhận diện container", detail: "avformat_open_input hoàn tất: đã mở IO và nhận diện định dạng như MP4, MPEG-TS hoặc HLS. Đây chưa phải tải toàn bộ video.")
        case .readingStreamInfo: return PreparationPresentation(percent: 34, title: "Dò thông tin stream", detail: "avformat_find_stream_info đọc header/packet cần thiết để dò track, codec, timebase, kích thước, FPS, duration, bitrate, sample rate và số kênh khi nguồn có khai báo.")
        case .streamInfoRead: return PreparationPresentation(percent: 40, title: "Đã dò thông tin stream", detail: "FFmpeg đã hoàn tất probe; một số trường có thể không có với live hoặc nguồn thiếu metadata.")
        case .readingMetadata: return PreparationPresentation(percent: 42, title: "Đọc metadata của container", detail: "Chuyển metadata dạng key/value do container cung cấp sang dữ liệu của SDK.")
        case .metadataRead: return PreparationPresentation(percent: 45, title: "Đã đọc metadata", detail: "Đã lấy các tag metadata hiện có; không đảm bảo nguồn có mọi tag.")
        case .selectingTracks: return PreparationPresentation(percent: 48, title: "Liệt kê và chọn track", detail: "Duyệt stream video/audio, bỏ qua loại track không dùng và ảnh bìa.")
        case .tracksSelected: return PreparationPresentation(percent: 50, title: "Đã liệt kê track", detail: "Đã xác định danh sách track video/audio để mở codec.")
        case .openingVideoCodec: return PreparationPresentation(percent: 52, title: "Mở codec video", detail: "Đọc codec parameters, tạo AVCodecContext và avcodec_open2 cho track video phù hợp.")
        case .videoCodecOpened: return PreparationPresentation(percent: 54, title: "Codec video đã mở", detail: "Đã chọn track video và lấy width/height, FPS, timebase, tỉ lệ ảnh.")
        case .readingVideoParameters: return PreparationPresentation(percent: 56, title: "Đọc thông số video", detail: "Lấy width/height, FPS, timebase và tỉ lệ ảnh từ stream/codec của track video đã mở.")
        case .videoParametersRead: return PreparationPresentation(percent: 58, title: "Đã đọc thông số video", detail: "Đã lấy kích thước, tốc độ khung hình và timebase hiện có của video.")
        case .openingAudioCodec: return PreparationPresentation(percent: 60, title: "Mở codec âm thanh", detail: "Đọc codec parameters và mở decoder audio cho track phù hợp.")
        case .audioCodecOpened: return PreparationPresentation(percent: 62, title: "Codec âm thanh đã mở", detail: "Đã chọn track audio, codec, sample rate, số kênh và timebase.")
        case .readingAudioParameters: return PreparationPresentation(percent: 64, title: "Đọc thông số âm thanh", detail: "Lấy codec context và timebase; sample rate, channel layout/số kênh có trong codec parameters của track audio.")
        case .audioParametersRead: return PreparationPresentation(percent: 66, title: "Đã đọc thông số âm thanh", detail: "Đã xác định track audio và thông số để tạo resampler/PCM.")
        case .indexingCache: return PreparationPresentation(percent: 68, title: "Lập chỉ mục thời gian/byte", detail: "Chụp index packet/keyframe hiện có để ánh xạ byte cache sang khoảng thời gian video.")
        case .cacheIndexed: return PreparationPresentation(percent: 69, title: "Đã chụp chỉ mục", detail: "Đã tính các khoảng cache có thể xác định; nguồn thiếu index có thể chưa có khoảng thời gian.")
        case .creatingVideoDecoder: return PreparationPresentation(percent: 70, title: "Tạo bộ giải mã video", detail: "Tạo frame queue/pool và kiểm tra VideoToolbox khi yêu cầu hardware; FFmpeg dùng software decode.")
        case .videoDecoderCreated: return PreparationPresentation(percent: 72, title: "Bộ giải mã video sẵn sàng", detail: "Đã tạo decoder theo policy. Số frame/backend thực tế được thống kê riêng.")
        case .creatingAudioDecoder: return PreparationPresentation(percent: 74, title: "Tạo bộ giải mã âm thanh", detail: "Tạo audio frame queue, resampler và cấu hình PCM theo audio output.")
        case .audioDecoderCreated: return PreparationPresentation(percent: 76, title: "Bộ giải mã âm thanh đã tạo", detail: "Đã tạo audio decoder/resampler cho nguồn có audio.")
        case .creatingClock: return PreparationPresentation(percent: 78, title: "Tạo đồng hồ phát", detail: "Chọn audio master clock nếu có audio; nếu không dùng system clock.")
        case .clockCreated: return PreparationPresentation(percent: 80, title: "Đồng hồ phát đã tạo", detail: "Đã thiết lập clock ban đầu để đồng bộ phát.")
        case .readingMediaInfo: return PreparationPresentation(percent: 81, title: "Lấy thông tin tổng hợp của nguồn", detail: "Đọc container name, duration, bitrate tổng/video/audio, codec, width/height, FPS, sample rate, số kênh và số track; thiếu thông tin giữ nil.")
        case .mediaInfoRead: return PreparationPresentation(percent: 82, title: "Đã lấy snapshot thông tin nguồn", detail: "Đã dựng FTPlayerMediaInfo từ các stream được chọn; chuẩn bị trả qua delegate.")
        case .publishingMediaInfo: return PreparationPresentation(percent: 84, title: "Chuẩn bị thông tin video", detail: "Chuẩn bị snapshot container, duration, bitrate, codec, kích thước, FPS và audio cho delegate.")
        case .mediaInfoPublished: return PreparationPresentation(percent: 86, title: "Đã trả thông tin video", detail: "Delegate đã nhận FTPlayerMediaInfo; giá trị nguồn không biết giữ nil.")
        case .readyToDecode: return PreparationPresentation(percent: 88, title: "Sẵn sàng đọc/giải mã", detail: "Decoder đã mở. Với video, vẫn cần packet, frame và xuất hình; audio-only hoàn tất tại đây.")
        case .readingPackets: return PreparationPresentation(percent: 90, title: "Đọc các packet đầu tiên", detail: "Demux đọc packet nén từ file, cache hoặc mạng; HLS có thể cần tải segment.")
        case .firstPacketRead: return PreparationPresentation(percent: 92, title: "Đã đọc packet đầu tiên", detail: "Đã nhận packet nén đầu tiên của phiên; chưa có nghĩa đã giải mã được hình.")
        case .decodingFirstFrame: return PreparationPresentation(percent: 94, title: "Giải mã frame video đầu tiên", detail: "Đã chuyển packet video đầu tiên tới decoder; codec có B-frame có thể cần thêm packet.")
        case .firstFrameDecoded: return PreparationPresentation(percent: 96, title: "Đã giải mã frame đầu tiên", detail: "Decoder đã tạo frame video đầu tiên; có thể đang sắp xếp thứ tự hiển thị hoặc chờ clock.")
        case .waitingForFirstFrame: return PreparationPresentation(percent: 98, title: "Chờ xuất frame đầu tiên", detail: "Đợi renderer nhận pixel buffer. Nếu đang Pause, bước hoàn tất đợi Play.")
        case .end: return PreparationPresentation(percent: 100, title: "Hoàn tất chuẩn bị", detail: "Đã xuất frame video đầu tiên; audio-only đã mở decoder sẵn sàng phát.")
        case .stopped: return PreparationPresentation(percent: 0, title: "Đã dừng", detail: "Đã hủy các state đang chờ của phiên. Stop vẫn giữ cache của URL hiện tại.")
        case .failed: return PreparationPresentation(percent: nil, title: "Chuẩn bị thất bại", detail: "Xem lỗi cụ thể và log. Demo giữ % của bước cuối đã nhận; không tự tăng tới 100%.")
        @unknown default:
            return PreparationPresentation(percent: nil, title: "Đang chuẩn bị video", detail: "SDK đang xử lý trạng thái: \(state.rawValue). Demo giữ phần trăm của bước gần nhất.")
        }
    }
}

// Keep the original domain/code and both native and FFmpeg causes visible.
// Only selected diagnostic fields are included; arbitrary userInfo may contain credentials.
enum DemoErrorPresentation {
    static func details(_ error: Error) -> String {
        var lines: [String] = [], visited = Set<ObjectIdentifier>()
        func append(_ error: NSError, label: String, depth: Int) {
            guard depth < 8, visited.count < 16, visited.insert(ObjectIdentifier(error)).inserted else { return }
            lines.append("\(label): \(error.domain) (\(error.code))")
            lines.append("Message: \(error.localizedDescription)")
            if error.domain == "StreamingLoader", (400...599).contains(error.code) {
                lines.append("HTTP: \(error.code)")
            }
            for key in ["operation", "stage", "avCode", "timeoutSeconds", "currentTime", "duration", "rate", "cacheProgress"] {
                if let text = error.userInfo[key] as? String { lines.append("\(key): \(text)") }
                else if let number = error.userInfo[key] as? NSNumber { lines.append("\(key): \(number)") }
            }
            for (key, name) in [(NSUnderlyingErrorKey, "Underlying"), ("ffmpegError", "FFmpeg")] {
                if let cause = error.userInfo[key] as? NSError { append(cause, label: name, depth: depth + 1) }
            }
        }
        append(error as NSError, label: "Error", depth: 0)
        return lines.joined(separator: "\n")
    }
}

struct DemoTestStream: Decodable {
    let id: String
    let title: String
    let url: URL
    let container: String
    let videoCodec: String
}

final class TestStreamPickerViewController: UITableViewController, UISearchResultsUpdating {
    let streams: [DemoTestStream]
    var onSelect: ((DemoTestStream) -> Void)?
    let search = UISearchController(searchResultsController: nil)
    private var sections: [(title: String, streams: [DemoTestStream])] = []
    private var finishing = false

    init(streams: [DemoTestStream]) {
        self.streams = streams
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Link test (\(streams.count))"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closePicker))
        navigationItem.rightBarButtonItem = close
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = "Tìm tên, H.265, HLS, 4K…"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.keyboardDismissMode = .onDrag
        updateSearchResults(for: search)
    }

    func updateSearchResults(for searchController: UISearchController) {
        func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        let tokens = folded(searchController.searchBar.text ?? "").split(whereSeparator: { $0.isWhitespace })
        let filtered = streams.filter { stream in
            let aliases = stream.videoCodec == "hevc" ? "h265 h.265" : stream.videoCodec == "h264" ? "h.264" : ""
            let text = folded("\(stream.title) \(stream.container) \(stream.videoCodec) \(stream.url.absoluteString) \(aliases)")
            return tokens.allSatisfy { text.contains($0) }
        }
        let groups = Dictionary(grouping: filtered) { $0.container.hasPrefix("HLS") ? "HLS" : $0.container }
        let order = ["HLS", "MP4", "WebM", "Matroska", "QuickTime MOV", "FLV", "DASH"]
        sections = groups.keys.sorted {
            let lhs = order.firstIndex(of: $0) ?? order.count, rhs = order.firstIndex(of: $1) ?? order.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }.map { ($0, groups[$0] ?? []) }
        if filtered.isEmpty {
            let empty = UILabel()
            empty.text = "Không tìm thấy link phù hợp"
            empty.textAlignment = .center
            empty.numberOfLines = 0
            empty.textColor = .secondaryLabel
            tableView.backgroundView = empty
        } else { tableView.backgroundView = nil }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].streams.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "\(sections[section].title) (\(sections[section].streams.count))"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "stream") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "stream")
        let stream = sections[indexPath.section].streams[indexPath.row]
        cell.textLabel?.text = stream.title
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.text = "\(stream.container) • \(stream.url.host ?? stream.url.lastPathComponent)"
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let stream = sections[indexPath.section].streams[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        let selected = onSelect
        finish { selected?(stream) }
    }
    private func finish(completion: (() -> Void)? = nil) {
        guard !finishing else { return }
        finishing = true
        // Dismiss the whole sheet even while its search controller is active.
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        (presenter ?? self).dismiss(animated: true, completion: completion)
    }
    @objc private func closePicker() { finish() }
}

final class ViewController: UIViewController, UIDocumentPickerDelegate, FTPlayerDeletegate {
    private let renderer = FTMediaRendererView()
    private let frameRateLabel = UILabel()
    private let urlField = UITextField()
    private let notesField = UITextField()
    private let status = UILabel()
    private let errorLogView = UITextView()
    private let progressLabel = UILabel()
    private let preparationLabel = UILabel()
    private let preparationBar = UIProgressView(progressViewStyle: .default)
    private let preparationHistoryView = UITextView()
    private(set) var preparationHistory: [FTPlayerPreparationState] = []
    private var preparationPercent = 0
    private let mediaInfoLabel = UILabel()
    private let slider = UISlider()
    private let cacheProgress = CacheDownloadProgressView()
    private let cacheProgressLabel = UILabel()
    private let buffer = UIProgressView(progressViewStyle: .default)
    private let rateSelector = UISegmentedControl(items: ["0.5×", "1×", "2×", "4×", "8×", "16×"])
    private let decoderSelector = UISegmentedControl(items: ["Auto", "FFmpeg", "Hardware"])
    private let cacheSwitch = UISwitch()
    /// AOV smart playback; also the player's statistics delegate, whose values the FPS label shows.
    private let aov = AOVSmartRateController()
    private let aovSwitch = UISwitch()
    private let aovSource = UISegmentedControl(items: ["FPS", "Nhịp đổi"])
    private let aovThresholdField = UITextField()
    private let aovLowRateField = UITextField()
    private let aovNormalRateField = UITextField()
    private let aovStatusLabel = UILabel()
    private let muteButton = UIButton(type: .system)
    private var muted = false
    private let playButton = UIButton(type: .system)
    private(set) var player: FTPlayer?
    private var localURL: URL?
    private var scrubbing = false

    let initialURL: URL?
    private let sourceLifetime: AnyObject?
    init(initialURL: URL? = nil, sourceLifetime: AnyObject? = nil) {
        self.initialURL = initialURL; self.sourceLifetime = sourceLifetime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if parent == nil {
            player?.delegate = nil; player?.stop(); player = nil
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chi tiết video"
        progressLabel.numberOfLines = 0
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        let title = UILabel()
        title.text = "FTPlayer SDK Demo"
        title.font = .boldSystemFont(ofSize: 24)
        frameRateLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        frameRateLabel.numberOfLines = 0
        frameRateLabel.textColor = .systemTeal
        updateFrameRateLabel()
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Dán URL video: https://... / rtsp://..."
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.text = UserDefaults.standard.string(forKey: "lastVideoURL") ?? ""
        notesField.borderStyle = .roundedRect
        notesField.placeholder = "Mô tả lỗi / các bước tái hiện trước khi xuất log"
        status.text = "Nhập URL hoặc chọn video trong Files"
        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 14)
        errorLogView.isEditable = false
        errorLogView.isSelectable = true
        errorLogView.isHidden = true
        errorLogView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        errorLogView.textColor = .systemRed
        errorLogView.backgroundColor = .secondarySystemBackground
        let errorHeight = errorLogView.heightAnchor.constraint(equalToConstant: 180)
        errorHeight.priority = .defaultHigh
        errorHeight.isActive = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        progressLabel.text = "0.0 / 0.0 s"
        preparationLabel.text = "Chuẩn bị video: 0% • Chưa mở video"
        preparationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        preparationLabel.numberOfLines = 0
        preparationBar.progressTintColor = .systemOrange
        preparationHistoryView.isEditable = false
        preparationHistoryView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preparationHistoryView.backgroundColor = .secondarySystemBackground
        preparationHistoryView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        preparationHistoryView.text = "Chi tiết chuẩn bị sẽ hiển thị ở đây. % do demo tự quy định."
        mediaInfoLabel.text = "Thông tin video: chưa có"
        mediaInfoLabel.numberOfLines = 0
        mediaInfoLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        mediaInfoLabel.textColor = .secondaryLabel
        cacheProgressLabel.text = "Cache đã tải: 0.0%"
        cacheProgressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cacheProgressLabel.numberOfLines = 0
        cacheProgressLabel.textColor = .secondaryLabel
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        playButton.setTitle("Play / Pause", for: .normal)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        muted = CommandLine.arguments.contains("--mute")
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        updateMuteButton()
        rateSelector.selectedSegmentIndex = 1
        rateSelector.addTarget(self, action: #selector(rateChanged(_:)), for: .valueChanged)
        decoderSelector.selectedSegmentIndex = 0
        if CommandLine.arguments.contains("--decode=ffmpeg") { decoderSelector.selectedSegmentIndex = 1 }
        if CommandLine.arguments.contains("--decode=hardware") { decoderSelector.selectedSegmentIndex = 2 }
        let hint = UILabel()
        hint.text = "Gặp lỗi: giữ nguyên app → ghi mô tả → Xuất log. Nếu app crash, mở lại rồi Xuất log. Log nằm trong Files → FTPlayer Demo → FTPlayerLogs."
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        let cacheLabel = UILabel()
        cacheLabel.text = "HTTP cache (áp dụng khi mở video)"
        cacheLabel.font = .systemFont(ofSize: 13)
        cacheSwitch.isOn = true
        let testStreamsButton = button("Link test", #selector(chooseTestStream))
        let openRow = row([button("Mở URL", #selector(openURL)), button("Chọn file", #selector(chooseFile)), button("Video mẫu", #selector(openSample)), testStreamsButton])
        let controls = row([button("−10s", #selector(backward)), playButton, button("+10s", #selector(forward))])
        let audioControls = row([muteButton, button("Stop", #selector(stop))])
        let aovControls = makeAOVControls()
        let stack = UIStackView(arrangedSubviews: [title, renderer, frameRateLabel, aovControls, urlField, openRow, row([cacheLabel, cacheSwitch]), status, errorLogView, preparationLabel, preparationBar, preparationHistoryView, mediaInfoLabel, progressLabel, buffer, cacheProgressLabel, cacheProgress, slider, controls, audioControls, rateSelector, decoderSelector, notesField, button("Xuất log / Share", #selector(exportLogs)), hint])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            renderer.heightAnchor.constraint(equalTo: renderer.widthAnchor, multiplier: 9.0 / 16.0)
        ])
        if let initialURL {
            urlField.text = initialURL.absoluteString
            DispatchQueue.main.async { [weak self] in self?.load(initialURL) }
        } else if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--play-url=") }) {
            urlField.text = String(argument.dropFirst("--play-url=".count))
            DispatchQueue.main.async { [weak self] in self?.openURL() }
        } else if CommandLine.arguments.contains("--play-sample") {
            DispatchQueue.main.async { [weak self] in self?.openSample() }
        }
    }

    private func load(_ url: URL) {
        view.endEditing(true)
        let next = player ?? FTPlayer(contentURL: url)
        next.isVideoContentChangeMeasurementEnabled = true
        next.isMuted = muted
        next.useCache = cacheSwitch.isOn
        next.rate = [Float(0.5), 1, 2, 4, 8, 16][rateSelector.selectedSegmentIndex]
        next.videoDecodingPolicy = [FTVideoDecodingPolicy.automatic, .ffmpeg, .hardware][decoderSelector.selectedSegmentIndex]
        next.delegate = self
        aov.attach(next, selectedRate: selectedRate)
        next.videoOutput = renderer
        player = next
        slider.value = 0
        buffer.progress = 0
        cacheProgress.update(fraction: 0, ranges: [], duration: 0)
        cacheProgressLabel.text = "Cache đã tải: 0.0%"
        clearPlaybackError()
        status.text = "Đang mở video..."
        preparationBar.progress = 0
        preparationPercent = 0
        preparationHistory.removeAll()
        preparationHistoryView.text = ""
        preparationLabel.text = "Chuẩn bị video: 0% • Bắt đầu"
        mediaInfoLabel.text = "Thông tin video: đang đọc..."
        updateTimeLabel(next)
        next.replaceVideo(with: url)
        updateFrameRateLabel()
    }
    @objc private func openURL() {
        let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "rtsp", "rtmp", "file"].contains(scheme) else {
            status.text = "URL không hợp lệ"; return
        }
        UserDefaults.standard.set(text, forKey: "lastVideoURL")
        load(url)
    }
    @objc private func chooseTestStream() {
        guard let url = Bundle.main.url(forResource: "SampleStreams", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let streams = try? JSONDecoder().decode([DemoTestStream].self, from: data) else {
            status.text = "Không đọc được danh sách link test"; return
        }
        presentTestStreams(streams)
    }
    func presentTestStreams(_ streams: [DemoTestStream]) {
        guard presentedViewController == nil else { return }
        view.endEditing(true)
        let picker = TestStreamPickerViewController(streams: streams)
        picker.onSelect = { [weak self] stream in
            self?.urlField.text = stream.url.absoluteString
            self?.openURL()
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 640, height: 680)
        present(navigation, animated: true)
    }
    @objc private func openSample() {
        guard let file = Bundle.main.url(forResource: "SampleStreams", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let streams = try? JSONDecoder().decode([DemoTestStream].self, from: data),
              let url = streams.first(where: { $0.id == "mp4-h264" })?.url else {
            status.text = "Không tìm thấy link video mẫu"; return
        }
        urlField.text = url.absoluteString
        load(url)
    }
    @objc private func chooseFile() {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.movie", "public.video", "public.audiovisual-content"], in: .import)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Keep an imported copy so playback and seeks remain valid after the picker closes.
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Videos")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: copy)
            localURL = copy
            load(copy)
        } catch { showError(error) }
    }
    @objc private func togglePlay() {
        guard let player else { openURL(); return }
        if player.state == .none || player.state == .failed { player.replaceVideo() }
        else if player.state == .playing || player.state == .buffering { player.pause() }
        else { player.play() }
    }
    @objc private func toggleMute() {
        muted.toggle()
        player?.isMuted = muted
        updateMuteButton()
    }
    private func updateMuteButton() {
        muteButton.setTitle(muted ? " Unmute" : " Mute", for: .normal)
        muteButton.setImage(UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
        muteButton.accessibilityLabel = muted ? "Bật âm thanh" : "Tắt âm thanh"
        muteButton.accessibilityValue = muted ? "Đang tắt tiếng" : "Đang bật tiếng"
    }
    @objc private func stop() {
        player?.stop()
        if let player { updateCacheProgress(player); updateTimeLabel(player); updatePreparation(player) }
        FTPlayerDiagnostic.shared.flush()
    }
    @objc private func backward() { if let p = player { aov.seek(to: max(0, p.progress - 10)) } }
    @objc private func forward() { if let p = player { aov.seek(to: min(p.duration, p.progress + 10)) } }
    @objc private func scrubStart() { scrubbing = true }
    @objc private func scrubEnd() {
        scrubbing = false
        guard let p = player, p.duration > 0, p.duration.isFinite else { return }
        aov.seek(to: Double(slider.value) * p.duration)
    }
    @objc private func rateChanged(_ sender: UISegmentedControl) {
        aov.selectRate(selectedRate)
        showAOVPolicyValues()
    }
    @objc private func exportLogs() {
        view.endEditing(true)
        do {
            FTPlayerDiagnostic.shared.log("User exported report; notes=\(notesField.text ?? "")")
            let url = try FTPlayerDiagnostic.shared.exportLogs(notes: notesField.text ?? "")
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        } catch { showError(error) }
    }
    static func mediaTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else { return "--:--" }
        let tenths = Int((seconds * 10).rounded())
        let whole = tenths / 10
        return String(format: "%02d:%02d:%02d.%d", whole / 3600, (whole / 60) % 60, whole % 60, tenths % 10)
    }
    private func updateTimeLabel(_ player: FTPlayer) {
        progressLabel.text = "Current time: \(Self.mediaTime(player.currentTime)) • Duration: \(Self.mediaTime(player.duration))\n" + decodeLabel(player)
    }
    private func decodeLabel(_ player: FTPlayer) -> String {
        let s = player.videoDecodingStatistics
        return "HW \(s.hardwareFrames) / FF \(s.ffmpegFrames) / VT-SW \(s.videoToolboxSoftwareFrames)"
    }
    private func clearPlaybackError() {
        errorLogView.text = ""
        errorLogView.isHidden = true
    }
    private func showError(_ error: Error) {
        let native = error as NSError
        let details = DemoErrorPresentation.details(error)
        let lastStep = preparationHistory.last(where: { $0 != .failed })?.rawValue ?? "idle"
        let context = "Preparation: \(lastStep) • \(preparationPercent)%"
        status.text = "Lỗi: \(native.domain) (\(native.code))\n\(native.localizedDescription)"
        errorLogView.text = "Log mã lỗi • \(ISO8601DateFormatter().string(from: Date()))\n\(context)\n\(details)"
        errorLogView.isHidden = false
        errorLogView.setContentOffset(.zero, animated: false)
        FTPlayerDiagnostic.shared.log("Demo error code: \(context)\n\(details)", category: "demo-error")
    }
    private func button(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }
    private func row(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = 8; row.distribution = .equalSpacing; row.alignment = .center
        return row
    }
    private var selectedRate: Float { [Float(0.5), 1, 2, 4, 8, 16][rateSelector.selectedSegmentIndex] }
    private func makeAOVControls() -> UIStackView {
        let title = UILabel()
        title.text = "AOV thông minh"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        aovSwitch.isOn = aov.policy.isEnabled
        aovSwitch.addTarget(self, action: #selector(aovToggled), for: .valueChanged)
        aovSource.selectedSegmentIndex = aov.policy.source.rawValue
        aovSource.addTarget(self, action: #selector(aovSourceChanged), for: .valueChanged)
        let done = UIToolbar(); done.sizeToFit()
        done.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                      UIBarButtonItem(title: "Xong", style: .done, target: self, action: #selector(endAOVEditing))]
        func field(_ field: UITextField, caption: String) -> UIStackView {
            field.borderStyle = .roundedRect
            field.keyboardType = .decimalPad
            field.inputAccessoryView = done
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            field.addTarget(self, action: #selector(aovFieldChanged(_:)), for: .editingDidEnd)
            let label = UILabel()
            label.text = caption
            label.font = .systemFont(ofSize: 12)
            return row([label, field])
        }
        let fields = UIStackView(arrangedSubviews: [field(aovThresholdField, caption: "Ngưỡng ≤"),
                                                    field(aovLowRateField, caption: "Khi thấp ×"),
                                                    field(aovNormalRateField, caption: "Thường ×")])
        fields.distribution = .equalSpacing
        aovStatusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        aovStatusLabel.numberOfLines = 0
        aovStatusLabel.textColor = .secondaryLabel
        showAOVPolicyValues()
        aovStatusLabel.text = aov.statusText
        aov.onUpdate = { [weak self] in
            guard let self else { return }
            self.updateFrameRateLabel()
            self.aovStatusLabel.text = self.aov.statusText
        }
        let group = UIStackView(arrangedSubviews: [row([title, aovSource, aovSwitch]), fields, aovStatusLabel])
        group.axis = .vertical
        group.spacing = 6
        return group
    }
    private func showAOVPolicyValues() {
        aovThresholdField.text = String(format: "%g", aov.policy.threshold)
        aovLowRateField.text = String(format: "%g", aov.policy.lowRate)
        aovNormalRateField.text = String(format: "%g", aov.policy.normalRate)
    }
    @objc private func endAOVEditing() { view.endEditing(true) }
    @objc private func aovToggled() {
        let isOn = aovSwitch.isOn
        aov.update { $0.isEnabled = isOn }
    }
    @objc private func aovSourceChanged() {
        let source = AOVSmartRatePolicy.Source(rawValue: aovSource.selectedSegmentIndex) ?? .frameRate
        aov.update { $0.source = source }
    }
    @objc private func aovFieldChanged(_ sender: UITextField) {
        let text = sender.text
        switch sender {
        case aovThresholdField: AOVSmartRatePolicy.threshold(from: text).map { value in aov.update { $0.threshold = value } }
        case aovLowRateField: AOVSmartRatePolicy.rate(from: text).map { value in aov.update { $0.lowRate = value } }
        default: AOVSmartRatePolicy.rate(from: text).map { value in aov.update { $0.normalRate = value } }
        }
        showAOVPolicyValues() // Invalid input falls back to the last valid value.
    }
    private func updateFrameRateLabel() {
        let measured = aov.latestFrameRate
        let timeline = measured?.timelineFramesPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        let upcoming = measured?.upcomingTimelineFramesPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        let output = String(format: "%.1f", measured?.outputFramesPerSecond ?? 0)
        let nominal = player?.mediaInfo?.framesPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        let content = aov.latestContentChangeRate?.estimatedChangesPerSecond.map { String(format: "~%.2f", $0) } ?? "—"
        frameRateLabel.text = "FPS video (PTS): \(timeline) • Sắp tới: \(upcoming) • Xuất hình: \(output) fps\nFPS khai báo: \(nominal) • Đo trong 2 giây gần nhất\nNhịp đổi nội dung (ước lượng): \(content) lần/s\nĐo trong tối đa 4 giây video"
    }
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) {
        guard player === self.player else { return }
        aov.playerDidChangeState(state)
        guard player.state != .failed else { return }
        status.text = "Trạng thái: \(state) • \(player.rate)×"
    }
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {
        guard player === self.player else { return }
        updateTimeLabel(player)
        if !scrubbing && player.duration > 0 { slider.value = Float(progress / player.duration) }
    }
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) {
        guard player === self.player else { return }
        buffer.progress = Float(progress)
    }
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double) {
        guard player === self.player else { return }
        updateCacheProgress(player)
    }
    private func updateCacheProgress(_ player: FTPlayer) {
        let progress = player.cacheProgress
        let fraction = progress.fraction ?? 0
        if let value = progress.fraction {
            cacheProgressLabel.text = String(format: "Cache đã tải: %.1f%%", value * 100)
        } else if progress.cachedBytes > 0 {
            let bytes = ByteCountFormatter.string(fromByteCount: progress.cachedBytes, countStyle: .file)
            cacheProgressLabel.text = "Đã cache: \(bytes) • đang xác định tổng dung lượng"
        } else { cacheProgressLabel.text = "Cache đã tải: 0.0%" }
        let ranges = player.cachedTimeRanges
        cacheProgress.update(fraction: fraction, ranges: ranges, duration: player.duration)
        cacheProgress.accessibilityValue = cacheProgressLabel.text
        FTPlayerDiagnostic.shared.log("cache display fraction=\(fraction) storedBytes=\(progress.cachedBytes) totalBytes=\(progress.totalBytes.map(String.init) ?? "unknown") duration=\(player.duration) ranges=\(ranges.map { "[\($0.start),\($0.end)]" }.joined(separator: ","))", category: "demo")
    }
    func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState) {
        guard player === self.player else { return }
        updatePreparation(player, state: state)
    }
    private func updatePreparation(_ player: FTPlayer, state: FTPlayerPreparationState? = nil) {
        let state = state ?? player.preparationState
        let presentation = PreparationPresentation.forState(state)
        if state == .begin && preparationHistory.last != .begin {
            clearPlaybackError()
            preparationHistory.removeAll()
            preparationHistoryView.text = ""
            preparationPercent = 0
        }
        if let percent = presentation.percent { preparationPercent = percent }
        preparationBar.progress = Float(preparationPercent) / 100
        preparationLabel.text = "Chuẩn bị video: \(preparationPercent)% • \(state.rawValue)\n\(presentation.title)\n\(presentation.detail)"
        if preparationHistory.last != state {
            preparationHistory.append(state)
            preparationHistoryView.text += "\(preparationPercent)% • \(state.rawValue): \(presentation.title)\n\(presentation.detail)\n\n"
            preparationHistoryView.scrollRangeToVisible(NSRange(location: preparationHistoryView.text.utf16.count, length: 0))
            FTPlayerDiagnostic.shared.log("Preparation UI state=\(state.rawValue) demoPercent=\(preparationPercent) detail=\(presentation.detail)", category: "demo")
        }
    }
    func player(_ player: FTPlayer, didUpdateMediaInfo info: FTPlayerMediaInfo) {
        guard player === self.player else { return }
        func bitrate(_ value: Int64?) -> String { value.map { String(format: "%.0f kb/s", Double($0) / 1000) } ?? "không rõ" }
        let duration = info.duration.map(Self.mediaTime) ?? "không rõ / live"
        let video = info.videoCodec.map { codec in
            "Video: \(codec.uppercased()) • \(info.width.map(String.init) ?? "?")×\(info.height.map(String.init) ?? "?") • \(info.framesPerSecond.map { String(format: "%.2f fps", $0) } ?? "FPS không rõ") • \(bitrate(info.videoBitrate))"
        } ?? "Video: không có"
        let audio = info.audioCodec.map { codec in
            "Audio: \(codec.uppercased()) • \(info.audioSampleRate.map { "\($0) Hz" } ?? "sample rate không rõ") • \(info.audioChannels.map { "\($0) kênh" } ?? "số kênh không rõ") • \(bitrate(info.audioBitrate))"
        } ?? "Audio: không có"
        mediaInfoLabel.text = "Thông tin video\nĐịnh dạng: \(info.formatName)\nThời lượng: \(duration) • Bitrate tổng: \(bitrate(info.bitrate))\n\(video)\n\(audio)\nTrack: \(info.videoTrackCount) video / \(info.audioTrackCount) audio"
    }
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) {
        guard player === self.player else { return }
        updateTimeLabel(player)
        updateCacheProgress(player) // Warm cache has no download callbacks.
        slider.isEnabled = duration > 0 && duration.isFinite && duration < Double(Float.greatestFiniteMagnitude)
    }
    func playerDidFinish(_ player: FTPlayer) {
        guard player === self.player, player.state != .failed else { return }; status.text = "Đã phát xong"
    }
    func player(_ player: FTPlayer, didFail error: Error) {
        guard player === self.player else { return }; updateTimeLabel(player); showError(error)
    }
    func playerBufferingStart(_ player: FTPlayer) {
        guard player === self.player, player.state != .failed else { return }; status.text = "Đang buffering..."
    }
    func playerBufferingEnd(_ player: FTPlayer) {
        guard player === self.player, player.state != .failed else { return }; status.text = "Trạng thái: \(player.state)"
    }
    deinit { player?.delegate = nil; player?.stop() }
}

/// Separate from decode buffering and the seek slider. Colored spans use media time;
/// the label reports total downloaded bytes, including metadata.
final class CacheDownloadProgressView: UIView {
    private(set) var fraction: Double = 0
    private(set) var ranges: [FTPlayerCachedTimeRange] = []
    private var duration: Double = 0
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 6) }
    func update(fraction: Double, ranges: [FTPlayerCachedTimeRange], duration: Double) {
        self.fraction = min(1, max(0, fraction))
        self.ranges = ranges
        self.duration = duration
        isAccessibilityElement = true
        accessibilityLabel = "Cache video đã tải"
        accessibilityValue = String(format: "%.1f%%", self.fraction * 100)
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        let track = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2)
        UIColor.systemGray4.setFill(); track.fill()
        guard duration > 0, duration.isFinite else { return }
        track.addClip()
        UIColor.systemTeal.setFill()
        for range in ranges {
            let start = min(1, max(0, range.start / duration))
            let end = min(1, max(start, range.end / duration))
            UIBezierPath(rect: CGRect(x: bounds.width * start, y: 0, width: bounds.width * (end - start), height: bounds.height)).fill()
        }
    }
}
