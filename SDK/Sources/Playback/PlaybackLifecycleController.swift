import UIKit

enum FTPlayerBackgroundMode {
    case nothing
    case autoPlayAndPause
    case continuing
}

protocol PlaybackLifecycleDelegate: AnyObject {
    var state: FTPlayerState { get }
    func play()
    func pause()
}

/// Main-thread owner of app lifecycle and audio interruption policy.
final class PlaybackLifecycleController: NSObject {
    weak var delegate: (any PlaybackLifecycleDelegate)?
    var backgroundMode: FTPlayerBackgroundMode = .autoPlayAndPause
    private var autoResume = false
    private var lastForeground: TimeInterval?
    private var revision = 0
    private var observing = false

    func configure(audio: any PlaybackAudioOutput) {
        revision += 1
        let token = revision
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(background),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        audio.setEventHandlers(interruption: { [weak self] type, _ in
            self?.onMain(token: token) { owner in
                guard type == .begin,
                      Date.timeIntervalSinceReferenceDate - (owner.lastForeground ?? 0) > FTPlayerSDKConfiguration.Playback.foregroundResumeDebounce else { return }
                owner.pauseIfPlaying()
            }
        }, routeChange: { [weak self] reason in
            self?.onMain(token: token) { owner in
                if reason == .oldDeviceUnavailable { owner.pauseIfPlaying() }
            }
        })
    }
    private func onMain(token: Int, _ body: @escaping (PlaybackLifecycleController) -> Void) {
        let action = { [weak self] in
            guard let self, self.revision == token else { return }
            body(self)
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
    func didPause() { autoResume = false }
    func didStop() { autoResume = false; revision += 1 }
    private func pauseIfPlaying() {
        if delegate?.state == .playing || delegate?.state == .buffering { delegate?.pause() }
    }
    @objc private func background() {
        let action = { [weak self] in
            guard let self, self.backgroundMode == .autoPlayAndPause,
                  self.delegate?.state == .playing || self.delegate?.state == .buffering else { return }
            self.delegate?.pause()
            self.autoResume = true
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
    @objc private func foreground() {
        let action = { [weak self] in
            guard let self, self.backgroundMode == .autoPlayAndPause,
                  self.delegate?.state == .suspend, self.autoResume else { return }
            self.autoResume = false
            self.lastForeground = Date.timeIntervalSinceReferenceDate
            self.delegate?.play()
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
