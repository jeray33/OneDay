import Photos
import PhotosUI
import UIKit

/// Owned by the zoom coordinator, so SwiftUI refreshes never recreate playback.
final class LivePhotoPlayerController: NSObject, PHLivePhotoViewDelegate {
    let liveView = PHLivePhotoView()
    let badge = UIButton(type: .system)
    private var policy = LivePhotoPlaybackPolicy()
    private var asset: PHAsset?
    private var permitted = false
    private var zoomed = false
    private var loading = false
    private var failed = false
    private var manualAfterLoad = false
    private var requestTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var requestToken: UUID?
    private var targetSize: CGSize = .zero

    override init() {
        super.init()
        liveView.delegate = self
        liveView.contentMode = .scaleAspectFit
        liveView.clipsToBounds = true
        liveView.isHidden = true
        liveView.isMuted = true
        liveView.playbackGestureRecognizer.addTarget(self, action: #selector(playbackGesture(_:)))
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = PreviewMediaBadgeStyle.backgroundColor
        config.background.backgroundColor = PreviewMediaBadgeStyle.backgroundColor
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 6)
        config.imagePadding = 2
        config.image = UIImage(systemName: "livephoto")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: PreviewMediaBadgeStyle.symbolSize, weight: .regular)
        config.title = "实况"
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 11, weight: .regular)
            return attributes
        }
        badge.configuration = config
        badge.accessibilityLabel = "实况照片"
        badge.addTarget(self, action: #selector(replay), for: .touchUpInside)
    }

    func update(asset: PHAsset?, selected: Bool, visitID: UUID?, permitted: Bool, targetSize: CGSize) {
        if self.asset?.localIdentifier != asset?.localIdentifier {
            reset()
            self.asset = asset
        }
        policy.select(selected, visitID: visitID)
        self.permitted = permitted && selected
        self.targetSize = targetSize
        if !selected {
            cancelRequest()
            failed = false
            liveView.stopPlayback()
            liveView.livePhoto = nil
            liveView.isHidden = true
        } else if asset != nil, liveView.livePhoto == nil, !loading, !failed {
            load()
        }
        reconcile()
    }

    func setZoomed(_ zoomed: Bool) {
        self.zoomed = zoomed
        reconcile()
    }

    private var canPlay: Bool { permitted && !zoomed }

    private func reconcile() {
        badge.isHidden = asset == nil || !canPlay
        badge.configuration?.showsActivityIndicator = loading
        badge.accessibilityHint = failed ? "实况加载失败，轻点重试" : "轻点有声重播，或长按照片播放"
        badge.configuration?.title = failed ? "实况 · 重试" : "实况"
        badge.superview?.superview?.setNeedsLayout()
        liveView.isHidden = !canPlay || liveView.livePhoto == nil
        liveView.playbackGestureRecognizer.isEnabled = canPlay && liveView.livePhoto != nil
        guard canPlay else {
            autoplayTask?.cancel()
            autoplayTask = nil
            manualAfterLoad = false
            liveView.stopPlayback()
            return
        }
        guard liveView.livePhoto != nil else { return }
        if manualAfterLoad {
            manualAfterLoad = false
            play(.manual)
        } else if !policy.hasPlayed, autoplayTask == nil {
            // Also debounce programmatic page changes and the last frames of paging.
            autoplayTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self else { return }
                self.autoplayTask = nil
                self.play(.automatic)
            }
        }
    }

    private func load() {
        guard let asset, policy.isSelected else { return }
        loading = true
        failed = false
        let token = UUID()
        requestToken = token
        let size = targetSize
        requestTask = Task { [weak self] in
            for await photo in ImageLoader.shared.livePhotoStream(asset: asset, targetSize: size) {
                guard !Task.isCancelled, let self, self.requestToken == token else { return }
                self.liveView.livePhoto = photo
                self.liveView.isHidden = false
            }
            guard !Task.isCancelled, let self, self.requestToken == token else { return }
            self.loading = false
            self.failed = self.liveView.livePhoto == nil
            self.requestTask = nil
            self.reconcile()
        }
        reconcile()
    }

    private func cancelRequest() {
        requestToken = nil
        requestTask?.cancel()
        requestTask = nil
        loading = false
        manualAfterLoad = false
    }

    func reset() {
        cancelRequest()
        autoplayTask?.cancel()
        autoplayTask = nil
        liveView.stopPlayback()
        liveView.livePhoto = nil
        liveView.isHidden = true
        policy.select(false)
        permitted = false
        failed = false
        badge.isHidden = true
    }

    private func play(_ source: LivePhotoPlaybackPolicy.Source) {
        guard policy.begin(source, ready: liveView.livePhoto != nil, permitted: canPlay) else { return }
        autoplayTask?.cancel()
        autoplayTask = nil
        liveView.stopPlayback()
        liveView.isMuted = source.isMuted
        liveView.startPlayback(with: .full)
    }

    @objc private func replay() {
        guard canPlay else { return }
        if liveView.livePhoto == nil {
            manualAfterLoad = true
            if !loading { load() }
        } else {
            play(.manual)
        }
    }

    @objc private func playbackGesture(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began, canPlay {
            autoplayTask?.cancel()
            autoplayTask = nil
            // Native playback owns the gesture; only record its source and audio.
            _ = policy.begin(.manual, ready: liveView.livePhoto != nil, permitted: canPlay)
            liveView.isMuted = false
        }
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView,
                       canBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) -> Bool {
        canPlay
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView,
                       willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        let state = livePhotoView.playbackGestureRecognizer.state
        if state == .began || state == .changed {
            _ = policy.begin(.manual, ready: true, permitted: canPlay)
            livePhotoView.isMuted = false
        }
    }
}
