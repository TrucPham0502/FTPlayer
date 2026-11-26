import XCTest
@testable import FTPlayer
@testable import FTPlayerDemo

final class FTPlayerDemoTests: XCTestCase {
    override func setUp() {
        FTPlayerDiagnostic.shared.log("BEGIN \(name)", category: "test")
    }
    override func tearDown() {
        FTPlayerDiagnostic.shared.log("END \(name) failures=\(testRun?.failureCount ?? 0)", category: "test")
        FTPlayerDiagnostic.shared.flush()
    }
    func testBundledCatalogOnlyPublishesApprovedPublicMP4Sources() throws {
        let approvedHosts: Set<String> = ["test-videos.co.uk", "media.w3.org", "dl.photoprism.app", "dev.gentoo.org", "raw.githubusercontent.com"]
        var catalogs: [[DemoTestStream]] = []
        for bundle in [Bundle.main, Bundle(for: PlaybackTestCase.self)] {
            let file = try XCTUnwrap(bundle.url(forResource: "SampleStreams", withExtension: "json"))
            let rows = try JSONDecoder().decode([DemoTestStream].self, from: Data(contentsOf: file))
            XCTAssertEqual(rows.count, 15, "Publish only the approved public MP4 catalog")
            for row in rows {
                XCTAssertEqual(row.url.pathExtension.lowercased(), "mp4")
                XCTAssertTrue(approvedHosts.contains(row.url.host ?? ""), "Unapproved source host in bundled catalog")
                XCTAssertNil(row.url.user); XCTAssertNil(row.url.password)
            }
            catalogs.append(rows)
        }
        XCTAssertEqual(catalogs[0].map(\.id), catalogs[1].map(\.id))
    }

    func testResolvedRecordingURLPlaysHLSWithoutMetadataAPI() throws {
        let root = try RemoteFixtureStore.root()
        let media = try FixtureHTTPServer(root: root); defer { media.stop() }
        let source = media.url("hls-ts/index.m3u8")
        let payload = try JSONSerialization.data(withJSONObject: [["id": "resolved-recording", "title": "Captured recording", "url": source.absoluteString,
            "container": "HLS", "videoCodec": "h264", "duration": 0]])
        let streams = try JSONDecoder().decode([DemoTestStream].self, from: payload)
        let savedURL = UserDefaults.standard.string(forKey: "lastVideoURL")
        let detail = ViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        defer {
            detail.player?.delegate = nil; detail.player?.stop(); detail.dismiss(animated: false); window.isHidden = true
            UserDefaults.standard.set(savedURL, forKey: "lastVideoURL")
        }
        detail.loadViewIfNeeded(); detail.presentTestStreams(streams)
        func waitFor(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(10)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        XCTAssertTrue(waitFor { (detail.presentedViewController as? UINavigationController)?.topViewController is TestStreamPickerViewController })
        let picker = try XCTUnwrap((detail.presentedViewController as? UINavigationController)?.topViewController as? TestStreamPickerViewController)
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(waitFor { (detail.player?.videoFrameRateStatistics.sampleFrameCount ?? 0) >= 10 })
        let player = try XCTUnwrap(detail.player)
        XCTAssertEqual(player.duration, 30, accuracy: 0.2)
        var completed: Bool?
        player.seek(to: 12) { completed = $0 }
        XCTAssertTrue(waitFor { completed == true && player.currentTime > 12.2 && player.videoFrameRateStatistics.sampleFrameCount >= 10 })
        XCTAssertEqual(completed, true)
    }

    func testBackFromResolvedRecordingReleasesPlayerAndKeepsRoot() throws {
        let root = try RemoteFixtureStore.root()
        let list = UIViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        nav.pushViewController(detail, animated: false)
        func waitFor(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(8)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        XCTAssertTrue(waitFor { (detail.player?.videoFrameRateStatistics.sampleFrameCount ?? 0) >= 10 })
        XCTAssertTrue(waitFor { nav.transitionCoordinator == nil })
        XCTAssertTrue(nav.popViewController(animated: false) === detail)
        // Original contract keeps the detail controller alive in the test, but
        // requires it to clear/release the player after returning to the list.
        XCTAssertTrue(waitFor { detail.player == nil }, "Original Back contract: detail.player must be cleared; parentNil=\(detail.parent == nil)")
        XCTAssertNil(detail.player)
        XCTAssertTrue(nav.topViewController === list)
    }

    func testDemoStartsWithPlayerAndDoesNotBundleCredentials() throws {
        let app = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let navigation = try XCTUnwrap(app.window?.rootViewController as? UINavigationController)
        XCTAssertTrue(navigation.viewControllers.first is ViewController)
        XCTAssertFalse(Bundle.main.paths(forResourcesOfType: "plist", inDirectory: nil).contains {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains("credentials")
        }, "Demo must not bundle any credential plist")
    }

    func testDemoControlsRateSeekMuteStopReopenAndShare() throws {
        let diagnostics = FTPlayerDiagnostic.shared
        let loggingWasEnabled = diagnostics.isEnabled
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = loggingWasEnabled }
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let nav = UINavigationController(rootViewController: detail)
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = nav; window.makeKeyAndVisible()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        detail.loadViewIfNeeded()
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 10) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(detail.view)
        func tap(_ selector: String) throws {
            let button = try XCTUnwrap(views.compactMap { $0 as? UIButton }.first { button in
                button.actions(forTarget: detail, forControlEvent: .touchUpInside)?.contains(selector) == true
            }, "Missing control: \(selector)")
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertTrue(pumpUntil { (detail.player?.progress ?? 0) > 0.2 })
        let player = try XCTUnwrap(detail.player)
        let rates = try XCTUnwrap(views.compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 6 })
        let requestedRates: [(Int, Float)] = [(2, 2), (3, 4), (4, 8), (5, 16), (1, 1)]
        for (index, rate) in requestedRates {
            rates.selectedSegmentIndex = index; rates.sendActions(for: .valueChanged); XCTAssertEqual(player.rate, rate)
        }
        try tap("forward"); XCTAssertTrue(pumpUntil { player.progress >= 9.9 })
        try tap("togglePlay"); XCTAssertEqual(player.state, .suspend)
        let slider = try XCTUnwrap(views.compactMap { $0 as? UISlider }.first)
        slider.sendActions(for: .touchDown); slider.value = 0.5; slider.sendActions(for: .touchUpInside)
        XCTAssertTrue(pumpUntil { abs(player.progress - 15) < 0.2 })
        XCTAssertEqual(player.state, .suspend)
        try tap("toggleMute"); XCTAssertTrue(player.isMuted)
        try tap("togglePlay"); XCTAssertTrue(pumpUntil { player.progress > 15.2 })
        try tap("toggleMute"); XCTAssertFalse(player.isMuted)
        try tap("stop"); XCTAssertEqual(player.state, .none)
        try tap("togglePlay"); XCTAssertTrue(pumpUntil { player.progress > 0.2 && player.state == .playing })
        let notes = try XCTUnwrap(views.compactMap { $0 as? UITextField }.first { $0.placeholder?.contains("Mô tả lỗi") == true })
        notes.text = "review-ui-rate-seek-mute-stop-reopen"
        try tap("exportLogs")
        XCTAssertTrue(pumpUntil { detail.presentedViewController is UIActivityViewController })
        detail.dismiss(animated: false)
        let report = try String(contentsOf: FTPlayerDiagnostic.shared.exportLogs(notes: "review-ui-confirmed"))
        XCTAssertTrue(report.contains("review-ui-rate-seek-mute-stop-reopen"))
        XCTAssertTrue(report.contains("seek completed")); XCTAssertTrue(report.contains("audio muted=true"))
    }
    func testDemoImportsFileAndPlaysCopiedVideo() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        let picker = UIDocumentPickerViewController(documentTypes: ["public.movie"], in: .import)
        detail.documentPicker(picker, didPickDocumentsAt: [root.appendingPathComponent("sample.mp4")])
        let end = Date().addingTimeInterval(10)
        while (detail.player?.progress ?? 0) < 0.2 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertGreaterThan(detail.player?.progress ?? 0, 0.2)
        XCTAssertEqual(detail.player?.duration, 30)
    }

    func testTestStreamPickerOpensSearchableVerticalCatalogAndCancels() throws {
        let detail = ViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        defer { detail.dismiss(animated: false); window.isHidden = true }
        detail.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func waitFor(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(4)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        let button = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "testStreams.open" } as? UIButton)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(waitFor { (detail.presentedViewController as? UINavigationController)?.topViewController is TestStreamPickerViewController })
        let navigation = try XCTUnwrap(detail.presentedViewController as? UINavigationController)
        let picker = try XCTUnwrap(navigation.topViewController as? TestStreamPickerViewController)
        XCTAssertEqual(navigation.modalPresentationStyle, .formSheet)
        XCTAssertEqual(picker.streams.count, 15, "The published catalog contains only approved MP4 sources")
        func rowCount() -> Int { (0..<picker.tableView.numberOfSections).reduce(0) { $0 + picker.tableView.numberOfRows(inSection: $1) } }
        XCTAssertEqual(rowCount(), picker.streams.count)
        let shown = Date().addingTimeInterval(10)
        while navigation.transitionCoordinator != nil && Date() < shown { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot); attachment.name = "test-stream-picker-vertical-catalog"; attachment.lifetime = .keepAlways; add(attachment)
        picker.search.searchBar.text = "H.265"; picker.updateSearchResults(for: picker.search)
        let expected = Set(picker.streams.filter { $0.videoCodec == "hevc" }.map { "testStreams.\($0.id)" })
        var actual = Set<String>()
        for section in 0..<picker.tableView.numberOfSections {
            for row in 0..<picker.tableView.numberOfRows(inSection: section) {
                let cell = picker.tableView(picker.tableView, cellForRowAt: IndexPath(row: row, section: section))
                actual.insert(try XCTUnwrap(cell.accessibilityIdentifier))
                XCTAssertEqual(cell.textLabel?.numberOfLines, 0)
            }
        }
        XCTAssertFalse(expected.isEmpty); XCTAssertEqual(actual, expected)
        picker.search.searchBar.text = "Lỗi nguồn"; picker.updateSearchResults(for: picker.search)
        let malformed = picker.streams.filter { $0.id.hasPrefix("malformed-") }
        XCTAssertEqual(malformed.count, 7, "Only malformed MP4 samples are published")
        XCTAssertEqual(Set(malformed.map(\.url)).count, 7)
        XCTAssertGreaterThanOrEqual(rowCount(), malformed.count)
        let shownMalformed = (0..<picker.tableView.numberOfSections).flatMap { section in
            (0..<picker.tableView.numberOfRows(inSection: section)).compactMap { row in
                picker.tableView(picker.tableView, cellForRowAt: IndexPath(row: row, section: section)).accessibilityIdentifier
            }
        }
        // Search uses tokens, so an existing title such as "nguồn segment lỗi"
        // also matches. Every newly added source must still be selectable.
        XCTAssertTrue(Set(malformed.map { "testStreams.\($0.id)" }).isSubset(of: Set(shownMalformed)))
        picker.search.searchBar.text = "no-such-stream-123"; picker.updateSearchResults(for: picker.search)
        XCTAssertEqual(rowCount(), 0); XCTAssertNotNil(picker.tableView.backgroundView)
        picker.search.isActive = true
        XCTAssertTrue(waitFor { picker.search.isActive && picker.search.transitionCoordinator == nil })
        let close = try XCTUnwrap(picker.navigationItem.rightBarButtonItem)
        _ = (close.target as? NSObject)?.perform(try XCTUnwrap(close.action))
        XCTAssertTrue(waitFor { detail.presentedViewController == nil })
        XCTAssertNil(detail.player, "Closing the list must not choose a stream")
    }

    func testTestStreamPickerLastRowIsHittableAndOpensSelectedVideo() throws {
        let root = try RemoteFixtureStore.root()
        let selectedURL = root.appendingPathComponent("sample.mp4")
        let streams = (0..<30).map { index in
            DemoTestStream(id: "fixture-\(index)", title: "Nguồn thử \(index) · tên dài để kiểm tra xuống dòng và vùng bấm" + (index == 29 ? " · đích-cuối" : ""),
                url: index == 29 ? selectedURL : root.appendingPathComponent("faststart.mp4"), container: "MP4", videoCodec: "h264")
        }
        XCTAssertGreaterThan(streams.count, 20, "Exercise the large catalog that broke the Mac action sheet")
        let savedURL = UserDefaults.standard.string(forKey: "lastVideoURL")
        let detail = ViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        defer {
            detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true
            UserDefaults.standard.set(savedURL, forKey: "lastVideoURL")
        }
        detail.loadViewIfNeeded(); detail.presentTestStreams(streams)
        let navigation = try XCTUnwrap(detail.presentedViewController as? UINavigationController)
        let picker = try XCTUnwrap(navigation.topViewController as? TestStreamPickerViewController)
        let last = IndexPath(row: 29, section: 0)
        // Presentation begins on the next run-loop turn. Wait for the actual
        // cell hit, not a coordinator that may still be nil before animation.
        let shown = Date().addingTimeInterval(10)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            picker.tableView.scrollToRow(at: last, at: .bottom, animated: false)
            window.layoutIfNeeded()
            if let cell = picker.tableView.cellForRow(at: last), let cellWindow = cell.window {
                let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: cellWindow)
                let hit = cellWindow.hitTest(point, with: nil)
                if hit === cell || hit?.isDescendant(of: cell) == true { break }
            }
        } while Date() < shown
        let cell = try XCTUnwrap(picker.tableView.cellForRow(at: last))
        let cellWindow = try XCTUnwrap(cell.window)
        let point = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: cellWindow)
        let hit = cellWindow.hitTest(point, with: nil)
        let diagnostic = XCTAttachment(string: "cell=\(cell.frame) table=\(picker.tableView.frame) offset=\(picker.tableView.contentOffset) size=\(picker.tableView.contentSize) windowPoint=\(point) hit=\(String(describing: hit)) coordinator=\(String(describing: picker.transitionCoordinator))")
        diagnostic.name = "test-stream-last-row-hit"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        let screenshot = UIGraphicsImageRenderer(bounds: cellWindow.bounds).image { _ in cellWindow.drawHierarchy(in: cellWindow.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot); attachment.name = "test-stream-picker-last-row"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(hit === cell || hit?.isDescendant(of: cell) == true, "The last row must receive pointer/touch hits")
        XCTAssertGreaterThanOrEqual(cell.bounds.height, 44)
        picker.search.isActive = true
        let searching = Date().addingTimeInterval(4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        while (picker.search.isBeingPresented || picker.search.transitionCoordinator != nil) && Date() < searching { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(picker.search.isActive)
        // Use a title-only token: numeric fixture IDs can also occur in the
        // Simulator's UUID path, which is intentionally searchable by URL.
        picker.search.searchBar.text = "đích-cuối"; picker.updateSearchResults(for: picker.search)
        XCTAssertEqual(picker.tableView.numberOfRows(inSection: 0), 1)
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        let end = Date().addingTimeInterval(10)
        while (detail.presentedViewController != nil || (detail.player?.progress ?? 0) < 0.2) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNil(detail.presentedViewController)
        XCTAssertEqual(detail.player?.mediaInfo?.sourceURL, selectedURL)
        XCTAssertGreaterThan(detail.player?.progress ?? 0, 0.2)
    }

    func testHLSCacheLabelIncreasesWhenHEADIsForbidden() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root, mp4HEADStatus: 403); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("independent-hls.m3u8"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "cache.progress.label" })
        let bar = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? CacheDownloadProgressView }.first)
        let end = Date().addingTimeInterval(10)
        while bar.fraction <= 0 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let player = try XCTUnwrap(detail.player)
        player.pause()
        // Freeze upstream bytes before comparing the asynchronous main-queue UI
        // callback with the live property; an active download can advance both.
        server.setNetworkMode(.stall,dropExistingConnections:true)
        let settled = Date().addingTimeInterval(5)
        while abs(bar.fraction-player.downloadProgress) > 0.000001 && Date() < settled { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertGreaterThan(player.downloadProgress,0)
        XCTAssertGreaterThan(bar.fraction,0)
        XCTAssertEqual(bar.fraction,player.downloadProgress,accuracy:0.001)
        XCTAssertEqual(label.text,String(format:"Cache đã tải: %.1f%%",bar.fraction*100))
        XCTAssertNotEqual(label.text,"Cache đã tải: 0.0%")
        FTPlayerDiagnostic.shared.log("HEAD403 Demo cache label=\(label.text ?? "") bytesFraction=\(bar.fraction)",category:"test")
        let image = UIGraphicsImageRenderer(size: CGSize(width: max(label.bounds.width,bar.bounds.width)+32,height: 70)).image { context in
            context.cgContext.setFillColor(UIColor.systemBackground.cgColor); context.cgContext.fill(CGRect(x:0,y:0,width:max(label.bounds.width,bar.bounds.width)+32,height:70))
            context.cgContext.translateBy(x:16,y:12); label.layer.render(in:context.cgContext)
            context.cgContext.translateBy(x:0,y:32); bar.layer.render(in:context.cgContext)
        }
        let attachment = XCTAttachment(image:image); attachment.name="HLS-HEAD403-cache-label"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testHLSUnknownTotalShowsStoredBytesInsteadOfZeroPercent() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("hls-unknown-total/index.m3u8"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "cache.progress.label" })
        let end = Date().addingTimeInterval(10)
        while !(label.text?.contains("đang xác định") ?? false) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let progress = try XCTUnwrap(detail.player).cacheProgress
        XCTAssertGreaterThan(progress.cachedBytes, 0)
        XCTAssertNil(progress.totalBytes)
        XCTAssertNil(progress.fraction)
        XCTAssertTrue(label.text?.contains("Đã cache:") == true)
        XCTAssertTrue(label.text?.contains("đang xác định") == true)
        XCTAssertFalse(label.text?.contains("0.0%") == true)
        let attachment = XCTAttachment(string: label.text ?? ""); attachment.name = "unknown-total-cache-label"; attachment.lifetime = .keepAlways; add(attachment)
        detail.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: CGSize(width: label.bounds.width + 32, height: label.bounds.height + 24)).image { context in
            UIColor.systemBackground.setFill(); context.fill(CGRect(origin: .zero, size: CGSize(width: label.bounds.width + 32, height: label.bounds.height + 24)))
            context.cgContext.translateBy(x: 16, y: 12); label.layer.render(in: context.cgContext)
        }
        let screenshot = XCTAttachment(image: image); screenshot.name = "unknown-total-cache-label-image"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testCacheDownloadHasSeparateBarFromDecodeBufferAndSeek() throws {
        let detail = ViewController(); detail.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(detail.view)
        XCTAssertNotNil(views.first { $0.accessibilityIdentifier == "cache.progress" }, "Missing separate downloaded-cache bar")
        XCTAssertNotNil(views.first { $0.accessibilityIdentifier == "cache.progress.label" }, "Cache needs its own label")
        XCTAssertEqual(views.compactMap { $0 as? UISlider }.count, 1, "Playback seek slider was replaced")
        XCTAssertEqual(views.compactMap { $0 as? UIProgressView }.count, 2, "Preparation and decode buffer each need their own bar")
        XCTAssertNotNil(views.first { $0.accessibilityIdentifier == "playback.buffer" } as? UIProgressView)
        XCTAssertNotNil(views.first { $0.accessibilityIdentifier == "preparation.progress" } as? UIProgressView)
    }

    func testPlaybackBufferBarIsFullAfter16xPlaybackAndReplay() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("human-detect-h264.mp4"))
        detail.loadViewIfNeeded()
        detail.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        detail.view.layoutIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(detail.view)
        let decoder = try XCTUnwrap(views.compactMap { $0 as? UISegmentedControl }.first { $0.titleForSegment(at: 0) == "Auto" })
        decoder.selectedSegmentIndex = 1
        let bar = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "playback.buffer" } as? UIProgressView)
        let label = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "playback.time" } as? UILabel)
        let readyDeadline = Date().addingTimeInterval(10)
        while (detail.player?.duration ?? 0) <= 0 && Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let player = try XCTUnwrap(detail.player)
        XCTAssertGreaterThan(player.duration, 0)
        player.backgroundMode = .continuing
        player.rate = 16
        for pass in 0..<2 {
            if pass == 1 {
                player.seek(to: 0)
                XCTAssertEqual(player.bufferProgress, 0, "Replay retained the previous full buffer endpoint")
                player.play()
                // Deliver the seek's reset before sampling the new interval.
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            var samples: [Float] = []
            let deadline = Date().addingTimeInterval(15)
            while player.state != .finished && player.state != .failed && Date() < deadline {
                samples.append(bar.progress)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            samples.append(bar.progress)
            XCTAssertEqual(player.state, .finished)
            XCTAssertEqual(bar.progress, 1, "Visible buffer bar left a gap after playback")
            XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "Visible buffer bar moved backward at 16x")
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: bar.bounds.width + 32, height: 90)).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: bar.bounds.width + 32, height: 90))
            context.cgContext.translateBy(x: 16, y: 12)
            label.layer.render(in: context.cgContext)
            context.cgContext.translateBy(x: 0, y: 52)
            bar.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "playback-buffer-full-after-16x"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCacheBarPreservesSparseRangesAndDoesNotFollowDecodeBuffer() throws {
        let detail = ViewController(); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        let root = try RemoteFixtureStore.root()
        let picker = UIDocumentPickerViewController(documentTypes: ["public.movie"], in: .import)
        detail.documentPicker(picker, didPickDocumentsAt: [root.appendingPathComponent("sample.mp4")])
        let end = Date().addingTimeInterval(10)
        while (detail.player?.duration ?? 0) <= 0 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let player = try XCTUnwrap(detail.player)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(detail.view)
        let bar = try XCTUnwrap(views.compactMap { $0 as? CacheDownloadProgressView }.first)
        let ranges: [FTPlayerCachedTimeRange] = [.init(start: 0, end: 2), .init(start: 8, end: 10)]
        bar.update(fraction: 0.4, ranges: ranges, duration: 10)
        XCTAssertEqual(bar.ranges, ranges); XCTAssertEqual(bar.fraction, 0.4)
        XCTAssertEqual(bar.accessibilityValue, "40.0%")
        let preparation = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "preparation.progress" } as? UIProgressView)
        let preparationBefore = preparation.progress
        detail.player(player, didUpdateBufferProgress: 0.9)
        XCTAssertEqual((views.first { $0.accessibilityIdentifier == "playback.buffer" } as? UIProgressView)?.progress, 0.9)
        XCTAssertEqual(preparation.progress, preparationBefore, "Decode buffering changed startup progress")
        XCTAssertEqual(bar.ranges, ranges); XCTAssertEqual(bar.fraction, 0.4)
        // Snapshot a standalone view; its frame cannot be resized by the detail's stack.
        let drawing = CacheDownloadProgressView(frame: CGRect(x: 0, y: 0, width: 100, height: 6))
        drawing.update(fraction: 0.4, ranges: ranges, duration: 10)
        drawing.layer.displayIfNeeded()
        let image = UIGraphicsImageRenderer(size: drawing.bounds.size).image { drawing.layer.render(in: $0.cgContext) }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        func pixel(_ fraction: Double) -> [UInt8] {
            let offset = ((cgImage.height / 2) * cgImage.width + Int(Double(cgImage.width) * fraction)) * 4
            return Array(pixels[offset..<(offset + 4)])
        }
        XCTAssertEqual(pixel(0.1), pixel(0.9), "Both cached islands must be colored")
        XCTAssertNotEqual(pixel(0.1), pixel(0.5), "Uncached middle was painted as downloaded")
        let attachment = XCTAttachment(image: image); attachment.name = "sparse-cache-head-tail-middle-gap"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func playbackErrorLog(_ detail: ViewController) throws -> UITextView {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "playback.errorLog" } as? UITextView)
    }
    func testErrorDemoShowsTimeoutDomainCodeAndNestedFFmpegInExportedLog() throws {
        let diagnostics = FTPlayerDiagnostic.shared
        let loggingWasEnabled = diagnostics.isEnabled
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = loggingWasEnabled }
        let detail = try detailForErrorChecks(); defer { detail.player?.delegate = nil; detail.player?.stop() }
        let player = try XCTUnwrap(detail.player)
        let ffmpeg = NSError(domain: "FTPlayer.FFmpeg", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out", "avCode": -60, "stage": 1])
        let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "Socket timed out"])
        let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [NSLocalizedDescriptionKey: "Video open timed out after 30.0 seconds", "operation": "open", "timeoutSeconds": 30, "stage": 1, "avCode": -60, "ffmpegError": ffmpeg, NSUnderlyingErrorKey: cause])
        player.errorHandler(error: error)
        let end = Date().addingTimeInterval(2)
        while player.state != .failed && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let log = try playbackErrorLog(detail), text = log.text ?? ""
        XCTAssertFalse(log.isHidden); XCTAssertTrue(log.isSelectable); XCTAssertFalse(log.isEditable)
        for value in ["NSURLErrorDomain", "-1001", "open", "timeoutSeconds: 30", "stage: 1", "avCode: -60", "FTPlayer.FFmpeg", "NSPOSIXErrorDomain"] { XCTAssertTrue(text.contains(value), "Missing error detail: \(value)") }
        XCTAssertTrue(try errorStatusLabel(detail).text?.contains("-1001") ?? false)
        let exported = try FTPlayerDiagnostic.shared.exportLogs(notes: "demo-error-code-regression")
        defer { try? FileManager.default.removeItem(at: exported) }
        let report = try String(contentsOf: exported)
        XCTAssertTrue(report.contains("Demo error code:")); XCTAssertTrue(report.contains("avCode: -60"))
        let attachment = XCTAttachment(string: text); attachment.name = "Demo-timeout-domain-code-and-causes"; attachment.lifetime = .keepAlways; add(attachment)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = detail; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        detail.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let image = UIGraphicsImageRenderer(bounds: log.bounds).image { context in
            log.layer.render(in: context.cgContext)
        }
        let screenshot = XCTAttachment(image: image); screenshot.name = "Demo-error-code-view"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testErrorDemoShowsRealHTTP403Code() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("status/403")); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        let end = Date().addingTimeInterval(10)
        while detail.player?.state != .failed && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let log = try playbackErrorLog(detail), text = log.text ?? ""
        XCTAssertFalse(log.isHidden); XCTAssertTrue(text.contains("StreamingLoader")); XCTAssertTrue(text.contains("403")); XCTAssertTrue(text.contains("HTTP: 403"))
    }
    func testErrorDemoClearsVisibleErrorOnNewPlaybackAttempt() throws {
        let detail = try detailForErrorChecks(); defer { detail.player?.delegate = nil; detail.player?.stop() }
        let player = try XCTUnwrap(detail.player)
        detail.player(player, didFail: NSError(domain: NSURLErrorDomain, code: -1001))
        let log = try playbackErrorLog(detail); XCTAssertFalse(log.isHidden); XCTAssertTrue(log.text.contains("-1001"))
        let root = try RemoteFixtureStore.root()
        detail.documentPicker(UIDocumentPickerViewController(documentTypes: ["public.movie"], in: .import), didPickDocumentsAt: [root.appendingPathComponent("sample.mp4")])
        XCTAssertTrue(log.isHidden); XCTAssertEqual(log.text, "")
        let stale = FTPlayer(contentURL: nil)
        detail.player(stale, didFail: NSError(domain: "stale-error", code: 500))
        XCTAssertTrue(log.isHidden); XCTAssertEqual(log.text, "")
    }

    private func errorStatusLabel(_ detail: ViewController) throws -> UILabel {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UILabel }.first {
            let text = $0.text ?? ""; return ["Trạng thái:", "Lỗi:", "Đang buffering", "Đã phát xong"].contains { text.hasPrefix($0) }
        })
    }
    private func detailForErrorChecks() throws -> ViewController {
        let detail = ViewController(); detail.loadViewIfNeeded()
        let root = try RemoteFixtureStore.root()
        detail.documentPicker(UIDocumentPickerViewController(documentTypes: ["public.movie"], in: .import), didPickDocumentsAt: [root.appendingPathComponent("sample.mp4")])
        let end = Date().addingTimeInterval(10)
        while (detail.player?.progress ?? 0) < 0.2 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return detail
    }
    func testErrorDemoIgnoresStalePlayerErrorFinishAndBuffering() throws {
        let detail = try detailForErrorChecks(); defer { detail.player?.delegate = nil; detail.player?.stop() }
        let label = try errorStatusLabel(detail), before = label.text
        let stale = FTPlayer(contentURL: nil)
        detail.player(stale, didFail: NSError(domain: "stale", code: 403)); XCTAssertEqual(label.text, before)
        detail.playerDidFinish(stale); XCTAssertEqual(label.text, before)
        detail.playerBufferingStart(stale); XCTAssertEqual(label.text, before)
        detail.playerBufferingEnd(stale); XCTAssertEqual(label.text, before)
    }
    func testErrorDemoKeepsFatalMessageAfterBufferAndFinishCallbacks() throws {
        let detail = try detailForErrorChecks(); defer { detail.player?.delegate = nil; detail.player?.stop() }
        let player = try XCTUnwrap(detail.player)
        player.errorHandler(error: NSError(domain: "error-test", code: 403, userInfo: [NSLocalizedDescriptionKey: "HTTP 403"]))
        let end = Date().addingTimeInterval(1)
        while !(try errorStatusLabel(detail).text?.contains("HTTP 403") ?? false) && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let label = try errorStatusLabel(detail); XCTAssertTrue(label.text?.contains("HTTP 403") ?? false)
        detail.playerBufferingEnd(player); detail.playerBufferingStart(player); detail.playerDidFinish(player)
        XCTAssertTrue(label.text?.contains("HTTP 403") ?? false, "Late buffering/finish erased the actionable error")
    }
    func testErrorDemoShowsCurrentTimeAndDuration() throws {
        let detail = try detailForErrorChecks(); defer { detail.player?.delegate = nil; detail.player?.stop() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let text = descendants(detail.view).compactMap { ($0 as? UILabel)?.text }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Current time:")); XCTAssertTrue(text.contains("Duration:"))
    }

    func testErrorTimeFormattingHandlesCarryHoursAndUnknownDuration() {
        XCTAssertEqual(ViewController.mediaTime(59.98), "00:01:00.0")
        XCTAssertEqual(ViewController.mediaTime(3601.2), "01:00:01.2")
        XCTAssertEqual(ViewController.mediaTime(0), "00:00:00.0")
        XCTAssertEqual(ViewController.mediaTime(.infinity), "--:--")
        XCTAssertEqual(ViewController.mediaTime(Double(Float.greatestFiniteMagnitude)), "--:--")
    }

    func testSessionDemoSwitchDeletesCacheButStopKeepsIt() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func until(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(12)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func tap(_ selector: String) throws {
            let button = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UIButton }.first {
                $0.actions(forTarget: detail, forControlEvent: .touchUpInside)?.contains(selector) == true
            }); button.sendActions(for: .touchUpInside)
        }
        XCTAssertTrue(until { (detail.player?.duration ?? 0) > 0 && detail.player?.downloadProgress == 1 })
        let previous = try XCTUnwrap(detail.player), previousDirectory = try XCTUnwrap(previous.cacheSession).directory
        let field = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UITextField }.first { $0.placeholder?.contains("Dán URL") == true })
        let secondURL = server.url("photoprism-tsu-hevc.mp4")
        field.text = secondURL.absoluteString; try tap("openURL")
        XCTAssertTrue(until { detail.player?.contentURL == secondURL && (detail.player?.duration ?? 0) > 0 && detail.player?.downloadProgress == 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousDirectory.path), "Switch only cleans after deinit; old player is intentionally retained here")
        let current = try XCTUnwrap(detail.player), directory = try XCTUnwrap(current.cacheSession).directory
        XCTAssertNotEqual(directory, previousDirectory); XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try tap("stop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Stop removed session cache")
        let label = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "cache.progress.label" })
        XCTAssertEqual(label.text, "Cache đã tải: 100.0%")
        let requestCount = server.requests.count
        try tap("togglePlay")
        XCTAssertTrue(until { current.currentTime > 0.2 && current.downloadProgress == 1 })
        XCTAssertEqual(server.requests.count, requestCount, "Demo Stop/Play re-downloaded cached video")
        XCTAssertEqual(current.cacheSession?.directory, directory)
        FTPlayerDiagnostic.shared.log("SESSION CHECK Demo switchDeleted=\(!FileManager.default.fileExists(atPath: previousDirectory.path)) stopPlayRequestsBefore=\(requestCount) after=\(server.requests.count) retained=\(directory.path)", category: "test")
    }

    func testAOVSmartRatePolicyChoosesRateFromThreshold() {
        var policy = AOVSmartRatePolicy()
        XCTAssertFalse(policy.isEnabled)
        XCTAssertEqual(policy.threshold, 1); XCTAssertEqual(policy.lowRate, 16); XCTAssertEqual(policy.normalRate, 1)
        XCTAssertNil(policy.rate(for: 0.5), "A disabled policy never changes rate")
        policy.isEnabled = true
        XCTAssertEqual(policy.rate(for: 1), 16, "Equal to the threshold is low")
        XCTAssertEqual(policy.rate(for: 0.4), 16)
        // Real AOV recordings measure 0.999...1.003 fps; compare the value shown (one decimal), not the raw jitter.
        XCTAssertEqual(policy.rate(for: 1.0028), 16, "Displayed as 1.0, so it is low")
        XCTAssertEqual(policy.rate(for: 0.9989), 16)
        XCTAssertEqual(policy.rate(for: 1.04), 16)
        XCTAssertEqual(policy.rate(for: 1.06), 1, "Displayed as 1.1, above the threshold")
        XCTAssertNil(policy.rate(for: nil), "An unknown measurement keeps the current rate")
        policy.threshold = 5; policy.lowRate = 8; policy.normalRate = 2
        XCTAssertEqual(policy.rate(for: 4), 8); XCTAssertEqual(policy.rate(for: 24), 2)
        XCTAssertEqual(AOVSmartRatePolicy.threshold(from: "0,5"), 0.5)
        XCTAssertEqual(AOVSmartRatePolicy.threshold(from: " 0 "), 0)
        XCTAssertNil(AOVSmartRatePolicy.threshold(from: "-1")); XCTAssertNil(AOVSmartRatePolicy.threshold(from: "abc"))
        XCTAssertEqual(AOVSmartRatePolicy.rate(from: "16"), 16); XCTAssertEqual(AOVSmartRatePolicy.rate(from: "0.25"), 0.25)
        XCTAssertNil(AOVSmartRatePolicy.rate(from: "20")); XCTAssertNil(AOVSmartRatePolicy.rate(from: "0.1"))
        XCTAssertNil(AOVSmartRatePolicy.rate(from: nil))
    }

    /// Records the frames FTPlayer outputs and forwards them to the Demo renderer.
    final class OutputSpy: FTPlayerVideoOutput {
        weak var next: (any FTPlayerVideoOutput)?
        var frames: [(wall: TimeInterval, pts: TimeInterval)] = []
        func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) {
            frames.append((ProcessInfo.processInfo.systemUptime, presentationTime))
            next?.player(player, didOutput: pixelBuffer, presentationTime: presentationTime)
        }
    }

    func testAOVSmartRatePolicyRedecodesOnlyWhenLeavingFrameDropRates() {
        // FTPlayer drops non-reference pictures from 2× up; those frames must be decoded again at a slower rate.
        XCTAssertTrue(AOVSmartRatePolicy.needsRedecode(from: 15, to: 1))
        XCTAssertTrue(AOVSmartRatePolicy.needsRedecode(from: 2, to: 1.5))
        XCTAssertFalse(AOVSmartRatePolicy.needsRedecode(from: 15, to: 8), "Still dropping frames at 8×")
        XCTAssertFalse(AOVSmartRatePolicy.needsRedecode(from: 1, to: 15))
        XCTAssertFalse(AOVSmartRatePolicy.needsRedecode(from: 1.5, to: 1))
    }

    /// The SDK reports the cadence of the packets ahead; an event seen there lowers the rate before it is decoded.
    func testAOVUsesUpcomingFrameRateAndLowersBeforeTheEvent() {
        var policy = AOVSmartRatePolicy(); policy.isEnabled = true
        XCTAssertTrue(policy.isFirstSeenAhead(previous: 1, current: 13))
        XCTAssertTrue(policy.isFirstSeenAhead(previous: 1.04, current: 1.3), "Compared as displayed, like the rate")
        XCTAssertFalse(policy.isFirstSeenAhead(previous: nil, current: 13), "Not measured ahead, e.g. a seek into an event")
        XCTAssertFalse(policy.isFirstSeenAhead(previous: 13, current: 13))
        XCTAssertFalse(policy.isFirstSeenAhead(previous: 13, current: 1))
        XCTAssertFalse(policy.isFirstSeenAhead(previous: 1, current: nil))
        let player = FTPlayer(contentURL: nil)
        let controller = AOVSmartRateController()
        controller.attach(player, selectedRate: 1)
        controller.update { $0.isEnabled = true }
        func report(timeline: Double?, upcoming: Double?) {
            controller.player(player, didChangeVideoFrameRate: FTVideoFrameRateStatistics(
                timelineFramesPerSecond: timeline, outputFramesPerSecond: 0, sampleFrameCount: 0,
                upcomingTimelineFramesPerSecond: upcoming))
        }
        report(timeline: 1, upcoming: nil)
        XCTAssertEqual(player.rate, 16, "Without packets ahead the displayed frames decide")
        report(timeline: 1, upcoming: 1)
        XCTAssertEqual(player.rate, 16)
        report(timeline: 1, upcoming: 13)
        XCTAssertEqual(player.rate, 1, "An event in the packets ahead lowers the rate before it is shown")
        XCTAssertEqual(controller.measurement, 13)
        report(timeline: 13, upcoming: 1)
        XCTAssertEqual(player.rate, 16, "1 fps ahead boosts again right after the event")
    }

    /// After AOV returns from a frame-dropping rate, playback must show every source frame again at once,
    /// not the sparse pictures already decoded for the high rate (seen as a stutter on real AOV recordings).
    func testAOVReturnToNormalRateShowsFullFrameRateImmediately() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: UIView>(_ id: String, as type: T.Type) throws -> T {
            try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == id } as? T, "Missing \(id)")
        }
        func enter(_ field: UITextField, _ text: String) { field.text = text; field.sendActions(for: .editingDidEnd) }
        let enabled = try find("aov.enabled", as: UISwitch.self)
        let threshold = try find("aov.threshold", as: UITextField.self)
        XCTAssertTrue(pumpUntil { detail.player?.state == .playing })
        let player = try XCTUnwrap(detail.player)
        let spy = OutputSpy(); spy.next = player.videoOutput; player.videoOutput = spy
        // sample.mp4 is 24 fps for 30 s: threshold 30 boosts to 8× (≈ 3.7 s of wall time), threshold 5 restores 1×.
        enter(threshold, "30"); enter(try find("aov.lowRate", as: UITextField.self), "8")
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil { player.rate == 8 })
        XCTAssertTrue(pumpUntil({ player.progress > 8 }, timeout: 4), "Let 8× fill the frame queue")
        enter(threshold, "5")
        XCTAssertEqual(player.rate, 1)
        let switched = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pumpUntil({ ProcessInfo.processInfo.systemUptime - switched > 1.5 }, timeout: 3))
        let after = spy.frames.filter { $0.wall > switched }
        XCTAssertGreaterThan(after.count, 10, "Playback did not resume after the switch")
        let gaps = zip(after, after.dropFirst()).map { $1.pts - $0.pts }
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 2.0 / 24 + 0.005,
                                 "Frames sampled for 8× played at 1×: gaps \(gaps.map { String(format: "%.3f", $0) })")
        XCTAssertFalse(after.contains { $0.pts < after[0].pts - 0.001 }, "Playback moved backwards")
    }

    func testAOVSmartModeDemoAppliesAndRestoresRate() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: UIView>(_ id: String, as type: T.Type) throws -> T {
            try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == id } as? T, "Missing \(id)")
        }
        let enabled = try find("aov.enabled", as: UISwitch.self)
        let source = try find("aov.source", as: UISegmentedControl.self)
        let threshold = try find("aov.threshold", as: UITextField.self)
        let lowRate = try find("aov.lowRate", as: UITextField.self)
        let normalRate = try find("aov.normalRate", as: UITextField.self)
        let status = try find("aov.status", as: UILabel.self)
        func enter(_ field: UITextField, _ text: String) { field.text = text; field.sendActions(for: .editingDidEnd) }
        XCTAssertFalse(enabled.isOn)
        XCTAssertEqual(source.selectedSegmentIndex, 0)
        XCTAssertEqual(threshold.text, "1"); XCTAssertEqual(lowRate.text, "16"); XCTAssertEqual(normalRate.text, "1")
        XCTAssertTrue(status.text?.contains("tắt") ?? false)
        let rates = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 6 })
        rates.selectedSegmentIndex = 2; rates.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil { detail.player?.state == .playing && (detail.player?.progress ?? 0) > 0.5 })
        let player = try XCTUnwrap(detail.player)
        XCTAssertEqual(player.rate, 2)
        // sample.mp4 is 24 fps: a threshold above it is "low", below it is "normal".
        enter(threshold, "30"); enter(lowRate, "4"); enter(normalRate, "1")
        XCTAssertEqual(player.rate, 2, "Settings do not change rate while the mode is off")
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil { player.rate == 4 }, "Low measurement did not boost rate")
        XCTAssertTrue(pumpUntil { status.text?.contains("tăng tốc 4×") ?? false })
        enter(threshold, "abc")
        XCTAssertEqual(threshold.text, "30", "Invalid input keeps the previous value")
        enter(lowRate, "20")
        XCTAssertEqual(lowRate.text, "4")
        enter(threshold, "5")
        XCTAssertTrue(pumpUntil { player.rate == 1 }, "Normal measurement did not restore the normal rate")
        XCTAssertTrue(pumpUntil { status.text?.contains("tốc độ thường 1×") ?? false })
        enabled.isOn = false; enabled.sendActions(for: .valueChanged)
        XCTAssertEqual(player.rate, 2, "Turning the mode off restores the selected rate")
        XCTAssertTrue(status.text?.contains("tắt") ?? false)
    }

    func testFPSLabelAndAOVShareDelegateMeasurementAndClearOnStop() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: UIView>(_ id: String, as type: T.Type) throws -> T {
            try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == id } as? T, "Missing \(id)")
        }
        func number(after marker: String, in text: String?) -> Double? {
            guard let text, let range = text.range(of: marker) else { return nil }
            return Double(text[range.upperBound...].prefix { $0.isNumber || $0 == "." })
        }
        let label = try find("playback.fps", as: UILabel.self)
        let status = try find("aov.status", as: UILabel.self)
        let enabled = try find("aov.enabled", as: UISwitch.self)
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        // Default policy: threshold 1, normal 1×; sample.mp4 (24 fps) stays at 1× so measurements are not reset.
        XCTAssertTrue(pumpUntil { status.text?.contains("tốc độ thường 1×") ?? false })
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.13))
            let aov = try XCTUnwrap(number(after: "(FPS ", in: status.text))
            // AOV uses the upcoming FPS, or the shown FPS until the upcoming one is known.
            let shown = try XCTUnwrap(number(after: "Sắp tới: ", in: label.text) ?? number(after: "FPS video (PTS): ", in: label.text))
            XCTAssertEqual(shown, (aov * 10).rounded() / 10, accuracy: 0.001, "FPS label and AOV must use the same delegate value")
        }
        detail.player?.stop()
        XCTAssertTrue(pumpUntil({ label.text?.contains("FPS video (PTS): —") ?? false }, timeout: 2))
        XCTAssertTrue(pumpUntil({ status.text?.contains("chờ số đo") ?? false }, timeout: 2), "Stopped playback clears the AOV measurement")
    }

    /// Runs AOV smart mode on a real AOV recording. The URL is private, so it is passed at run time:
    /// `TEST_RUNNER_AOV_TEST_URL=<m3u8> TEST_RUNNER_AOV_TEST_SEEK=<seconds before a 1 fps section> xcodebuild test ...`
    func testAOVSmartModeBoostsSteadilyOnRecordedAOVVideo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["AOV_TEST_URL"], let url = URL(string: text) else {
            throw XCTSkip("Set TEST_RUNNER_AOV_TEST_URL to an AOV recording")
        }
        let seek = environment["AOV_TEST_SEEK"].flatMap(Double.init) ?? 185
        let detail = ViewController(initialURL: url)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let enabled = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "aov.enabled" } as? UISwitch)
        XCTAssertTrue(pumpUntil({ detail.player?.state == .playing }, timeout: 30), "Recording did not start")
        let player = try XCTUnwrap(detail.player)
        let spy = OutputSpy(); spy.next = player.videoOutput; player.videoOutput = spy
        player.seek(to: seek)
        // Defaults chosen by the product owner: threshold 1 fps, 16× when low, 1× otherwise.
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil({ player.rate == 16 }, timeout: 10), "1 fps section did not boost to 16×")
        let boosted = player.progress
        var flips = 0, last = player.rate
        let stable = Date().addingTimeInterval(5)
        while Date() < stable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if player.rate != last { flips += 1; last = player.rate }
        }
        XCTAssertEqual(flips, 0, "Timestamp jitter around 1 fps must not toggle the rate")
        XCTAssertGreaterThan(player.progress - boosted, 30, "16× should cover over 30 s of video in 5 s")
        XCTAssertTrue(pumpUntil({ player.rate == 1 }, timeout: 30), "Normal-FPS section did not restore 1×")
        // The event continues at the source cadence; frames sampled for 16× must not be replayed at 1×.
        // The rate drops a few seconds before the event, so start from its first dense frame.
        let switched = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pumpUntil({ ProcessInfo.processInfo.systemUptime - switched > 6 }, timeout: 7))
        let after = spy.frames.filter { $0.wall > switched }
        let start = try XCTUnwrap(zip(after, after.dropFirst()).first { $1.pts - $0.pts < 0.3 }?.0, "No event frames after returning to 1×")
        let event = after.filter { $0.pts >= start.pts && $0.pts <= start.pts + 1 }
        let gaps = zip(event, event.dropFirst()).map { $1.pts - $0.pts }
        XCTAssertGreaterThan(event.count, 5, "Too few frames in the first second of the event")
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.16,
                                 "Stutter after returning to 1×: gaps \(gaps.map { String(format: "%.3f", $0) })")
    }

    /// Real AOV recording (private URL, passed at run time):
    /// `TEST_RUNNER_AOV_TEST_URL=<m3u8> TEST_RUNNER_AOV_TEST_EVENTS=<first event start>,<last event start>`.
    /// From 16× in 1 fps sections, smart mode must lower the rate before each event is shown, with no seek:
    /// every event frame plays, no frame repeats or goes back, and it does not buffer at the switch.
    func testAOVSmartModeLowersRateBeforeEventOnRecordedAOVVideo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["AOV_TEST_URL"], let url = URL(string: text),
              let events = environment["AOV_TEST_EVENTS"]?.split(separator: ",").compactMap({ Double($0) }), !events.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_AOV_TEST_URL and TEST_RUNNER_AOV_TEST_EVENTS")
        }
        let detail = ViewController(initialURL: url)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        var states: [(wall: TimeInterval, state: FTPlayerState, position: TimeInterval, rate: Float)] = []
        func pumpUntil(_ condition: () -> Bool, timeout: Double) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if let state = detail.player?.state, states.last?.state != state {
                    states.append((ProcessInfo.processInfo.systemUptime, state, detail.player?.progress ?? 0, detail.player?.rate ?? 0))
                }
            }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let enabled = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "aov.enabled" } as? UISwitch)
        XCTAssertTrue(pumpUntil({ detail.player?.state == .playing && (detail.player?.duration ?? 0) > events.max()! }, timeout: 30))
        let player = try XCTUnwrap(detail.player)
        let spy = OutputSpy(); spy.next = player.videoOutput; player.videoOutput = spy
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        // Plays continuously from before the first event to the end of the last one; checks every return to 1×.
        player.seek(to: events[0] - 40)
        var checked = 0
        while player.progress < events.max()! {
            guard pumpUntil({ player.rate == 16 }, timeout: 30) else { XCTFail("No 16× at \(player.progress) s"); break }
            guard pumpUntil({ player.rate == 1 || player.state == .finished }, timeout: 30), player.rate == 1 else { break }
            let switched = ProcessInfo.processInfo.systemUptime, switchedAt = player.progress
            _ = pumpUntil({ player.rate != 1 }, timeout: 30)
            let after = spy.frames.filter { $0.wall > switched }
            guard let start = zip(after, after.dropFirst()).first(where: { $1.pts - $0.pts < 0.3 })?.0 else {
                XCTFail("Dropped to 1× at \(switchedAt) s without an event"); continue
            }
            checked += 1
            let event = String(format: "%.1f", start.pts)
            XCTAssertLessThan(switchedAt, start.pts - 1, "Rate dropped at \(switchedAt) s, not before the event at \(event) s")
            let eventFrames = after.filter { $0.pts >= start.pts && $0.pts <= start.pts + 3 }
            let gaps = zip(eventFrames, eventFrames.dropFirst()).map { $1.pts - $0.pts }
            XCTAssertGreaterThan(eventFrames.count, 30, "Event \(event): frames are missing")
            XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.16, "Event \(event) gaps \(gaps.map { String(format: "%.2f", $0) })")
            XCTAssertFalse(zip(after, after.dropFirst()).contains { $1.pts <= $0.pts }, "Event \(event): a frame repeated or went back (seek)")
            let buffering = states.filter { $0.wall > switched && $0.state == .buffering }
            XCTAssertTrue(buffering.isEmpty, "Event \(event): buffering at \(buffering.map { String(format: "%.1f s %g× (+%.2f s)", $0.position, $0.rate, $0.wall - switched) })")
        }
        XCTAssertGreaterThanOrEqual(checked, events.count, "Not every event was reached")
    }

    /// With AOV on, the rate bar picks the rate for normal sections; low sections keep the AOV low rate.
    func testAOVRateBarSetsNormalRateAndKeepsLowRate() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: UIView>(_ id: String, as type: T.Type) throws -> T {
            try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == id } as? T, "Missing \(id)")
        }
        func enter(_ field: UITextField, _ text: String) { field.text = text; field.sendActions(for: .editingDidEnd) }
        let enabled = try find("aov.enabled", as: UISwitch.self)
        let threshold = try find("aov.threshold", as: UITextField.self)
        let normalRate = try find("aov.normalRate", as: UITextField.self)
        let rates = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 6 })
        func pick(_ index: Int) { rates.selectedSegmentIndex = index; rates.sendActions(for: .valueChanged) }
        XCTAssertTrue(pumpUntil { detail.player?.state == .playing })
        let player = try XCTUnwrap(detail.player)
        // sample.mp4 is 24 fps: threshold 30 is a low section, threshold 5 a normal one.
        enter(threshold, "30"); enter(try find("aov.lowRate", as: UITextField.self), "4")
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil { player.rate == 4 })
        pick(2)
        XCTAssertEqual(player.rate, 4, "A low section keeps the AOV low rate when the user picks a rate")
        XCTAssertEqual(normalRate.text, "2", "The picked rate becomes the normal-section rate")
        XCTAssertTrue(pumpUntil({ player.rate != 4 }, timeout: 1) == false, "Rate left 4× in a low section")
        enter(threshold, "5")
        XCTAssertEqual(player.rate, 2, "A normal section plays at the rate the user picked")
        pick(1)
        XCTAssertEqual(player.rate, 1); XCTAssertEqual(normalRate.text, "1")
        enabled.isOn = false; enabled.sendActions(for: .valueChanged)
        XCTAssertEqual(player.rate, 1)
        pick(3)
        XCTAssertEqual(player.rate, 4, "With AOV off the rate bar sets the rate directly")
        XCTAssertEqual(normalRate.text, "1", "With AOV off the rate bar leaves the AOV setting alone")
    }

    /// A user seek lands on an unmeasured position: AOV plays it at the normal rate until it is measured,
    /// so a seek from a boosted section into an event does not skip the event at the low-FPS rate.
    func testAOVUserSeekPlaysNormalRateUntilMeasured() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func pumpUntil(_ condition: () -> Bool, timeout: Double = 8) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: UIView>(_ id: String, as type: T.Type) throws -> T {
            try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == id } as? T, "Missing \(id)")
        }
        func enter(_ field: UITextField, _ text: String) { field.text = text; field.sendActions(for: .editingDidEnd) }
        let enabled = try find("aov.enabled", as: UISwitch.self)
        let status = try find("aov.status", as: UILabel.self)
        let slider = try XCTUnwrap(descendants(detail.view).first { $0 is UISlider } as? UISlider)
        XCTAssertTrue(pumpUntil { detail.player?.state == .playing })
        let player = try XCTUnwrap(detail.player)
        enter(try find("aov.threshold", as: UITextField.self), "30"); enter(try find("aov.lowRate", as: UITextField.self), "4")
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        XCTAssertTrue(pumpUntil { player.rate == 4 })
        for seek in [{ slider.value = 0.2; slider.sendActions(for: .touchDown); slider.sendActions(for: .touchUpInside) },
                     { _ = try? self.tapButton("−10s", in: detail.view) }, { _ = try? self.tapButton("+10s", in: detail.view) }] as [() -> Void] {
            XCTAssertTrue(pumpUntil { player.rate == 4 }, "Not boosted before the seek")
            seek()
            XCTAssertEqual(player.rate, 1, "An unmeasured position after a user seek plays at the normal rate")
            XCTAssertTrue(status.text?.contains("chờ số đo") ?? false, "Status still shows the old measurement: \(status.text ?? "")")
            XCTAssertTrue(pumpUntil({ player.rate == 4 }, timeout: 3), "Measured low section did not boost again")
        }
    }

    private func tapButton(_ title: String, in root: UIView) throws {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(root).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == title }, "Missing \(title)")
        button.sendActions(for: .touchUpInside)
    }

    /// Seek and rate-bar cases on a real AOV recording (private URL, passed at run time):
    /// `TEST_RUNNER_AOV_TEST_URL=<m3u8> TEST_RUNNER_AOV_TEST_LOW=<1 fps position>,<1 fps position>`
    /// `TEST_RUNNER_AOV_TEST_EVENTS=<event start>,<event start>` (each event lasting over 10 s, after both low positions
    /// except the second low one, which lies between the events).
    func testAOVSeeksAndRateBarOnRecordedAOVVideo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["AOV_TEST_URL"], let url = URL(string: text),
              let low = environment["AOV_TEST_LOW"]?.split(separator: ",").compactMap({ Double($0) }), low.count == 2,
              let events = environment["AOV_TEST_EVENTS"]?.split(separator: ",").compactMap({ Double($0) }), events.count == 2 else {
            throw XCTSkip("Set TEST_RUNNER_AOV_TEST_URL, TEST_RUNNER_AOV_TEST_LOW and TEST_RUNNER_AOV_TEST_EVENTS")
        }
        let detail = ViewController(initialURL: url)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let enabled = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "aov.enabled" } as? UISwitch)
        let normalRate = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "aov.normalRate" } as? UITextField)
        let slider = try XCTUnwrap(descendants(detail.view).first { $0 is UISlider } as? UISlider)
        let rates = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? UISegmentedControl }.first { $0.numberOfSegments == 6 })
        var start = Date()
        var trace: [(wall: Double, pos: Double, rate: Float)] = []
        /// Pumps until `done` or the timeout, recording position and rate every 50 ms of wall time.
        func watch(_ timeout: Double, until done: () -> Bool = { false }) -> Bool {
            start = Date(); trace = []
            let end = start.addingTimeInterval(timeout)
            while !done() && Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if let p = detail.player { trace.append((Date().timeIntervalSince(start), p.progress, p.rate)) }
            }
            return done()
        }
        func log(_ name: String) {
            var changes: [String] = []; var last: Float = -1
            for s in trace where s.rate != last { changes.append(String(format: "%.2fs@%.1f→%g×", s.wall, s.pos, s.rate)); last = s.rate }
            print("AOVSEEK \(name): \(changes.joined(separator: " ")) end=\(String(format: "%.1f", trace.last?.pos ?? -1))")
        }
        func seek(_ time: Double) {
            slider.value = Float(time / (detail.player?.duration ?? 1))
            slider.sendActions(for: .touchDown); slider.sendActions(for: .touchUpInside)
        }
        func pick(_ index: Int) { rates.selectedSegmentIndex = index; rates.sendActions(for: .valueChanged) }
        XCTAssertTrue(watch(30) { detail.player?.state == .playing && (detail.player?.duration ?? 0) > events[1] }, "Recording did not start")
        let player = try XCTUnwrap(detail.player)
        enabled.isOn = true; enabled.sendActions(for: .valueChanged)
        func inEvent(_ event: Double) -> (Double) -> Bool { { $0 >= event - 0.5 && $0 <= event + 10 } }

        seek(low[0])
        XCTAssertTrue(watch(10) { player.rate == 16 }, "Low section did not boost to 16×"); log("start low")

        // 1. 16× in a 1 fps section → seek into an event: the event must play at the normal rate from its start.
        seek(events[0]); _ = watch(4); log("low→event")
        let skipped = trace.filter { inEvent(events[0])($0.pos) && $0.rate == 16 }
        XCTAssertTrue(skipped.isEmpty, "Event played at 16× up to \(skipped.last?.pos ?? 0) s")
        XCTAssertEqual(player.rate, 1); XCTAssertLessThan(player.progress, events[0] + 8, "Event skipped")

        // 2. Event → another event: stays at the normal rate.
        seek(events[1]); _ = watch(3); log("event→event")
        XCTAssertFalse(trace.contains { inEvent(events[1])($0.pos) && $0.rate != 1 }, "Event left 1× after a seek")

        // 3. Rate bar in an event: the event plays at the picked rate at once.
        pick(2)
        XCTAssertEqual(player.rate, 2); XCTAssertEqual(normalRate.text, "2")
        _ = watch(1.5); log("event bar 2×")
        XCTAssertFalse(trace.contains { $0.rate != 2 }, "Picked rate did not hold in the event")

        // 4. Normal FPS → seek into a 1 fps section: boosts to 16×.
        seek(low[1])
        XCTAssertTrue(watch(5) { player.rate == 16 }, "1 fps section after a seek did not boost to 16×"); log("event→low")

        // 5. 16× → seek to another 1 fps section (slider and +10 s button): back to 16×.
        seek(low[0])
        XCTAssertTrue(watch(5) { player.rate == 16 && player.progress < low[0] + 30 }, "No 16× after low→low seek"); log("low→low")
        try tapButton("+10s", in: detail.view)
        XCTAssertTrue(watch(5) { player.rate == 16 && player.progress < events[0] }, "No 16× after +10 s"); log("low +10s")

        // 6. Rate bar at 16× in a 1 fps section: keeps 16×; the next event plays at the picked rate.
        pick(3)
        XCTAssertEqual(normalRate.text, "4")
        _ = watch(1); log("low bar 4×")
        XCTAssertFalse(trace.contains { $0.rate != 16 }, "1 fps section left 16× after the rate bar changed")
        XCTAssertTrue(watch(30) { player.rate == 4 && inEvent(events[0])(player.progress) }, "Event did not play at the picked 4×")
        log("reach event")
        XCTAssertTrue(watch(15) { player.rate == 16 && player.progress > events[0] + 10 }, "1 fps after the event did not boost")
        log("after event")
    }

    func testContentChangeDemoShowsEstimateAndClearsItWhenStopped() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "playback.fps" } as? UILabel)
        XCTAssertTrue(label.text?.contains("Nhịp đổi nội dung (ước lượng): — lần/s") ?? false)
        let end = Date().addingTimeInterval(12)
        while !(label.text?.contains("ước lượng): ~") ?? false) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(label.text?.contains("ước lượng): ~") ?? false)
        XCTAssertTrue(label.text?.contains("FPS video (PTS)") ?? false)
        XCTAssertTrue(label.text?.contains("4 giây video") ?? false)
        XCTAssertEqual(detail.player?.isVideoContentChangeMeasurementEnabled, true)
        detail.player?.stop()
        let stopped = Date().addingTimeInterval(2)
        while !(label.text?.contains("ước lượng): — lần/s") ?? false) && Date() < stopped {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(label.text?.contains("ước lượng): — lần/s") ?? false)
    }

    func testPreparationDemoShowsPercentageAndMediaInfoFromSDK() throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible()
        detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "preparation.label" } as? UILabel)
        let bar = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "preparation.progress" } as? UIProgressView)
        let info = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "media.info" } as? UILabel)
        XCTAssertTrue(label.text?.contains("0%") ?? false); XCTAssertEqual(bar.progress, 0)
        let end = Date().addingTimeInterval(12)
        while detail.player?.preparationState != .end && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(bar.progress, 1); XCTAssertTrue(label.text?.contains("100%") ?? false)
        XCTAssertTrue(label.text?.contains("Hoàn tất chuẩn bị") ?? false)
        XCTAssertTrue(info.text?.contains("H264") ?? false); XCTAssertTrue(info.text?.contains("640×360") ?? false)
        XCTAssertTrue(info.text?.contains("AAC") ?? false); XCTAssertTrue(info.text?.contains("24.00 fps") ?? false)
        XCTAssertTrue(info.text?.contains("Hz") ?? false); XCTAssertNotNil(detail.player?.mediaInfo)
        let stale = FTPlayer(contentURL: nil), text = label.text
        detail.player(stale, didChangePreparationState: .connectingToSource); XCTAssertEqual(label.text, text)
        if let metadata = detail.player?.mediaInfo {
            let old = info.text; detail.player(stale, didUpdateMediaInfo: metadata); XCTAssertEqual(info.text, old)
        }
        detail.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: detail.view.bounds).image { _ in detail.view.drawHierarchy(in: detail.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Preparation-and-media-info"; attachment.lifetime = .keepAlways; add(attachment)
        FTPlayerDiagnostic.shared.log("PREPARATION UI CHECK \(label.text ?? "") info=\(info.text ?? "")", category: "test")
    }
    func testPreparationDemoFailureKeepsPartialProgress() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("missing.mp4")); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        let end = Date().addingTimeInterval(10)
        while detail.player?.state != .failed && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "preparation.label" } as? UILabel)
        let bar = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "preparation.progress" } as? UIProgressView)
        XCTAssertLessThan(bar.progress, 1); XCTAssertTrue(label.text?.contains("Chuẩn bị thất bại") ?? false)
        XCTAssertNil(detail.player?.mediaInfo)
    }

    func testPreparationDemoMapsAllStatesWithDescriptionsAndNoSDKPercent() {
        let states = FTPlayerPreparationState.allCases
        for state in states {
            let presentation = PreparationPresentation.forState(state)
            XCTAssertFalse(presentation.title.isEmpty); XCTAssertGreaterThan(presentation.detail.count, 20)
            if let percent = presentation.percent { XCTAssertTrue((0...100).contains(percent)) }
        }
        XCTAssertEqual(PreparationPresentation.forState(.end).percent, 100)
        XCTAssertNil(PreparationPresentation.forState(.failed).percent)
        let percentages = states.filter { ![.idle, .begin, .stopped, .failed].contains($0) }.compactMap { PreparationPresentation.forState($0).percent }
        XCTAssertEqual(Set(percentages).count, percentages.count)
        XCTAssertTrue(zip(percentages, percentages.dropFirst()).allSatisfy { $0 < $1 })
    }
    func testPreparationDemoHistoryIncludesConnectionMetadataDecodeAndEnd() throws {
        let root = try RemoteFixtureStore.root()
        let server = try FixtureHTTPServer(root: root); defer { server.stop() }
        let detail = ViewController(initialURL: server.url("sample.mp4")); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop() }
        let end = Date().addingTimeInterval(12)
        while detail.player?.preparationState != .end && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(detail.preparationHistory.first, .begin); XCTAssertEqual(detail.preparationHistory.last, .end)
        for state in [FTPlayerPreparationState.requestingHTTPRange, .httpHeadersReceived, .receivingInitialData, .readingStreamInfo, .videoCodecOpened, .audioCodecOpened, .firstFrameDecoded] {
            XCTAssertTrue(detail.preparationHistory.contains(state), "Demo history missing \(state)")
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let history = try XCTUnwrap(descendants(detail.view).first { $0.accessibilityIdentifier == "preparation.history" } as? UITextView)
        XCTAssertTrue(history.text.contains("Content-Range")); XCTAssertTrue(history.text.contains("GET")); XCTAssertTrue(history.text.contains("100% • end"))
    }

    private func spamDetail(_ deltas: [Double]) throws {
        let root = try RemoteFixtureStore.root()
        let detail = ViewController(initialURL: root.appendingPathComponent("sample.mp4"))
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = UINavigationController(rootViewController: detail); window.makeKeyAndVisible(); detail.loadViewIfNeeded()
        defer { detail.player?.delegate = nil; detail.player?.stop(); window.isHidden = true }
        func until(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(12)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        XCTAssertTrue(until { (detail.player?.currentTime ?? 0) > 0.2 })
        let player = try XCTUnwrap(detail.player); player.pause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(detail.view).compactMap { $0 as? UIButton }
        let forward = try XCTUnwrap(buttons.first { $0.actions(forTarget: detail, forControlEvent: .touchUpInside)?.contains("forward") == true })
        let backward = try XCTUnwrap(buttons.first { $0.actions(forTarget: detail, forControlEvent: .touchUpInside)?.contains("backward") == true })
        var expected = player.currentTime
        for delta in deltas {
            expected = min(max(0, expected + delta), player.duration - 0.05)
            (delta > 0 ? forward : backward).sendActions(for: .touchUpInside)
        }
        // No corrective seek after the button burst. The latest UI intent must win.
        XCTAssertTrue(until { player.decoder?.seeking == false })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(player.currentTime, expected, accuracy: 0.5, "Rapid ±10s taps used stale progress instead of pending target")
        player.play()
        XCTAssertTrue(until { player.currentTime > expected + 0.1 || player.state == .finished })
        FTPlayerDiagnostic.shared.log("SPAM SEEK UI CHECK clicks=\(deltas.count) expected=\(expected) current=\(player.currentTime)", category: "test")
    }
    func testSpamSeekDemoDoubleForwardAccumulatesTwentySeconds() throws { try spamDetail([10, 10]) }
    func testSpamSeekDemoMixedButtonsAccumulatePendingTarget() throws { try spamDetail([10, 10, 10, -10, -10, 10]) }

}
