import Foundation
import QuartzCore

final class FTVSyncDriver: NSObject {

    var onTick: ((TimeInterval) -> Void)?

    private var _displayLink: CADisplayLink?
    private var _thread: Thread?
    private var _runLoop: CFRunLoop?
    private var _isSuspended = false

    #if DEBUG
    private var _tickCount = 0
    private var _fpsWindowStart: TimeInterval = 0
    private var _fpsWindowTicks = 0
    #endif

    // MARK: - Public Interface

    func start() {
        guard _thread == nil else { return }
        let t = Thread { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self._tick(_:)))
            link.add(to: .current, forMode: .common)
            link.isPaused = self._isSuspended
            self._displayLink = link
            self._runLoop = CFRunLoopGetCurrent()
            RunLoop.current.run()
        }
        t.name = "com.fli.vsync-display"
        t.qualityOfService = .userInteractive
        _thread = t
        t.start()
    }

    func suspend() {
        _isSuspended = true
        _displayLink?.isPaused = true
    }

    func resume() {
        _isSuspended = false
        _displayLink?.isPaused = false
    }

    func stop() {
        guard let thread = _thread else { return }
        if Thread.current == thread {
            _invalidate()
        } else {
            perform(#selector(_invalidate), on: thread, with: nil, waitUntilDone: true)
        }
        _thread = nil
        _runLoop = nil
        _displayLink = nil
    }

    // MARK: - Private

    @objc private func _invalidate() {
        _displayLink?.invalidate()
        _displayLink = nil
        if let rl = _runLoop {
            CFRunLoopStop(rl)
        }
    }

    @objc private func _tick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        onTick?(target)
    }
}
