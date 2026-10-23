import SwiftUI
import UIKit

struct PreviewVideoControls: View {
    static let height: CGFloat = 44
    let playback: PreviewVideoPlayer
    var onRetry: () -> Void

    var body: some View {
        Group {
            if let error = playback.errorMessage {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试", action: onRetry)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
            } else if playback.isLoading {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                VideoProgressTrack(playback: playback)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
    }
}

struct PreviewVideoPlaybackIcon: View {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.black.opacity(0.28), in: Circle())
            .opacity(!isPlaying || isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: isPlaying) {
                isVisible = true
                guard isPlaying else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    isVisible = false
                }
            }
    }
}

private struct VideoProgressTrack: UIViewRepresentable {
    let playback: PreviewVideoPlayer

    func makeUIView(context: Context) -> VideoTrackingControl {
        VideoTrackingControl()
    }

    func updateUIView(_ control: VideoTrackingControl, context: Context) {
        control.duration = playback.duration
        control.isEnabled = playback.canSeek
        control.alpha = playback.canSeek ? 1 : 0.35
        control.onBegin = { playback.beginScrubbing() }
        control.onChange = { playback.scrub(to: $0) }
        control.onEnd = { [weak control] cancelled in
            playback.endScrubbing(cancelled: cancelled)
            control?.position = playback.position
        }
        control.onAdjust = { playback.adjustPosition(to: $0) }
        if !playback.isScrubbing { control.cancelInteraction() }
        control.position = playback.position
        control.accessibilityValue = "\(VideoPlaybackPolicy.timeLabel(playback.position))，共 \(VideoPlaybackPolicy.timeLabel(playback.duration))"
        control.accessibilityHint = playback.isBuffering ? "正在缓冲；上下轻扫调整进度" : "上下轻扫调整进度"
    }
}

/// No thumb or outer capsule. A 44-point hit region surrounds the thin track.
private final class VideoTrackingControl: UIControl {
    var duration: Double = 0
    var position: Double = 0 { didSet { setNeedsLayout() } }
    var onBegin: () -> Bool = { false }
    var onChange: (Double) -> Void = { _ in }
    var onEnd: (Bool) -> Void = { _ in }
    var onAdjust: (Double) -> Void = { _ in }
    private let track = UIVisualEffectView()
    private let fill = UIView()
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "视频进度"
        accessibilityTraits = .adjustable
        track.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        track.effect = glass
        track.cornerConfiguration = .capsule()
        track.contentView.cornerConfiguration = .capsule()
        track.contentView.clipsToBounds = true
        fill.backgroundColor = UIColor.label.withAlphaComponent(0.5)
        track.contentView.addSubview(fill)
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: PreviewVideoControls.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height: CGFloat = isDragging ? 8 : 3
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        let progress = VideoPlaybackPolicy.progress(position: position, duration: duration)
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * progress, height: height)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, onBegin() else { return false }
        isDragging = true
        updateTrackAppearance()
        updatePosition(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isDragging, isEnabled else { return false }
        updatePosition(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard isDragging else { return }
        if let touch { updatePosition(touch) }
        finish(cancelled: touch == nil)
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        cancelInteraction()
    }

    func cancelInteraction() {
        guard isDragging else { return }
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        isDragging = false
        updateTrackAppearance()
        onEnd(cancelled)
    }

    private func updatePosition(_ touch: UITouch) {
        position = VideoPlaybackPolicy.scrubbedTime(
            x: touch.location(in: self).x, width: bounds.width, duration: duration
        )
        onChange(position)
    }

    private func updateTrackAppearance() {
        setNeedsLayout()
        if UIAccessibility.isReduceMotionEnabled {
            layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.16, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.layoutIfNeeded()
            }
        }
    }

    override func accessibilityIncrement() {
        guard isEnabled else { return }
        onAdjust(VideoPlaybackPolicy.clampedTime(position + 5, duration: duration))
    }

    override func accessibilityDecrement() {
        guard isEnabled else { return }
        onAdjust(VideoPlaybackPolicy.clampedTime(position - 5, duration: duration))
    }
}
