import UIKit
import CoreVideo

public protocol FTRendererViewDelegate: AnyObject {
    func rendererView(_ view: FTMediaRendererView, readyToPlay size: CGSize)
    func rendererView(_ view: FTMediaRendererView, currentSecond time: Double)
}
/// Video-only view backed by the SDK Metal renderer.
public final class FTMediaRendererView: UIView {
    private let metalRenderer = MetalVideoRenderer()
    public weak var delegate: FTRendererViewDelegate?
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        backgroundColor = .black
        addSubview(metalRenderer)
        metalRenderer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metalRenderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalRenderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalRenderer.topAnchor.constraint(equalTo: topAnchor),
            metalRenderer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    public func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) { metalRenderer.renderPixelBuffer(pb) }
    public func didChangeVideoSize(_ size: CGSize) { delegate?.rendererView(self, readyToPlay: size) }
    public func didUpdateCurrentTime(_ sec: Double) { delegate?.rendererView(self, currentSecond: sec) }
    deinit { metalRenderer.flush() }
}

// Optional SDK view utility. The player itself knows only FTPlayerVideoOutput.
extension FTMediaRendererView: FTPlayerVideoOutput {
    public func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer,
                       presentationTime: TimeInterval) {
        didRenderFrame(pixelBuffer, time: Int64(presentationTime * 1_000_000))
    }
}
