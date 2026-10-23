import AVFoundation
import Observation
import Photos
import UIKit

/// A preview session owns exactly one player. Animation copies and neighbor pages
/// receive only a poster, never an independently playing AVPlayer.
@MainActor @Observable
final class PreviewVideoPlayer {
    private(set) var player: AVPlayer?
    private(set) var contentVersion: String?
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var downloadProgress: Double?
    private(set) var isLoading = false
    private(set) var isReady = false
    private(set) var isBuffering = false
    private(set) var isSeekable = false
    private(set) var errorMessage: String?
    private var policy = VideoPlaybackPolicy()
    private var hasReachedEnd = false
    var isPlaying: Bool { policy.isPlaying }
    var isScrubbing: Bool { policy.isScrubbing }
    var canSeek: Bool { isReady && isSeekable && duration > 0 && policy.isPermitted }
    var canPlay: Bool { isReady && errorMessage == nil && policy.isPermitted }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: (time: Double, resume: Bool, revision: UInt)?
    @ObservationIgnored private var savedPositions: [String: Double] = [:]

    func load(asset: PHAsset?, version: String?) async {
        if contentVersion == version, player != nil, errorMessage == nil { return }
        replaceCurrentItem()
        guard let asset, let version else { return }
        contentVersion = version
        duration = VideoPlaybackPolicy.validDuration(asset.duration)
        position = VideoPlaybackPolicy.clampedTime(savedPositions[version] ?? 0, duration: duration)
        isLoading = true
        let request = loadID
        do {
            for try await event in ImageLoader.shared.videoStream(for: asset) {
                guard !Task.isCancelled, loadID == request else { return }
                switch event {
                case .progress(let value):
                    if value.isFinite { downloadProgress = min(max(value, 0), 1) }
                case .ready(let item):
                    install(item)
                }
            }
        } catch is CancellationError {
            if loadID == request {
                if Task.isCancelled { isLoading = false }
                else { fail("视频加载已中断，请重试。") }
            }
        } catch {
            guard !Task.isCancelled, loadID == request else { return }
            fail("无法加载此视频，请检查网络后重试。")
        }
        if Task.isCancelled, loadID == request {
            replaceCurrentItem()
        }
    }

    func permit(_ permitted: Bool) {
        policy.permit(permitted)
        if !permitted { player?.pause() }
    }

    func togglePlayback() {
        guard canPlay, !isScrubbing else { return }
        if isPlaying {
            pause()
        } else if hasReachedEnd || (duration > 0 && position >= duration - min(0.05, duration * 0.01)) {
            requestSeek(to: 0, resume: true)
        } else {
            startPlayback()
        }
    }

    func pause() {
        policy.pause()
        player?.pause()
        isBuffering = false
    }

    @discardableResult
    func beginScrubbing() -> Bool {
        guard canSeek, policy.beginScrubbing(ready: isReady) else { return false }
        player?.pause()
        isBuffering = false
        return true
    }

    func scrub(to time: Double) {
        guard policy.isScrubbing else { return }
        position = VideoPlaybackPolicy.clampedTime(time, duration: duration)
        requestSeek(to: position, resume: false)
    }

    func endScrubbing(cancelled: Bool = false) {
        guard policy.isScrubbing else { return }
        let resume = policy.endScrubbing()
        if cancelled { pause() }
        requestSeek(to: position, resume: resume && !cancelled)
    }

    /// VoiceOver adjustments are discrete seeks, not touch-tracking sessions.
    func adjustPosition(to time: Double) {
        guard canSeek else { return }
        beginScrubbing()
        scrub(to: time)
        endScrubbing()
    }

    func close() {
        replaceCurrentItem()
        savedPositions.removeAll()
        policy.permit(false)
    }

    private func startPlayback() {
        guard policy.play(ready: isReady && errorMessage == nil) else { return }
        // Match the app's rewind sound session instead of changing global audio
        // categories on every pause or interfering with other audio engines.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            player?.play()
        } catch {
            fail("无法开始播放，请重试。")
        }
    }

    private func install(_ item: AVPlayerItem) {
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = false
        self.player = player
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in self?.refresh(item) }
            },
            item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in self?.refresh(item) }
            },
            item.observe(\.seekableTimeRanges, options: [.new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in self?.refresh(item) }
            },
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player === player else { return }
                    self.isBuffering = self.isPlaying && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        ]
        let request = loadID
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == request,
                      !self.isScrubbing, !self.isSeeking, !self.hasReachedEnd else { return }
                self.position = VideoPlaybackPolicy.clampedTime(time.seconds, duration: self.duration)
            }
        }
        observe(.AVPlayerItemDidPlayToEndTime, object: item) { owner in
            owner.pause()
            owner.hasReachedEnd = true
            owner.position = owner.duration
        }
        observe(.AVPlayerItemFailedToPlayToEndTime, object: item) { owner in
            owner.fail("视频播放失败，请重试。")
        }
        observe(AVAudioSession.interruptionNotification) { owner in
            owner.pause()
        }
        observe(AVAudioSession.routeChangeNotification, matching: { notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            return reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        }) { owner in
            // Route changes never resume playback automatically.
            owner.pause()
        }
        observe(UIApplication.willResignActiveNotification) { owner in
            owner.pause()
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject? = nil,
                         matching predicate: @escaping @Sendable (Notification) -> Bool = { _ in true },
                         action: @escaping @MainActor (PreviewVideoPlayer) -> Void) {
        let request = loadID
        notifications.append(NotificationCenter.default.addObserver(
            forName: name, object: object, queue: .main
        ) { [weak self] notification in
            guard predicate(notification) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loadID == request else { return }
                action(self)
            }
        })
    }

    private func refresh(_ item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            let firstReady = !isReady
            isReady = true
            isLoading = false
            let actualDuration = VideoPlaybackPolicy.validDuration(item.duration.seconds)
            if actualDuration > 0 { duration = actualDuration }
            isSeekable = !item.seekableTimeRanges.isEmpty
            if firstReady, position > 0 { requestSeek(to: position, resume: false) }
        case .failed:
            fail("无法播放此视频，请重试。")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        pause()
        isLoading = false
        isReady = false
        errorMessage = message
    }

    /// Only one native seek is in flight; new drag positions replace the pending
    /// target. A stale completion cannot resume a paused or replaced player.
    private func requestSeek(to time: Double, resume: Bool) {
        guard isReady else { return }
        pendingSeek = (VideoPlaybackPolicy.clampedTime(time, duration: duration), resume, policy.revision)
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !isSeeking, let target = pendingSeek, let player else { return }
        pendingSeek = nil
        isSeeking = true
        let request = seekID
        player.seek(to: CMTime(seconds: target.time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.player != nil, self.seekID == request else { return }
                self.isSeeking = false
                if self.pendingSeek != nil {
                    self.performPendingSeek()
                } else if finished {
                    let atEnd = self.duration > 0
                        && target.time >= self.duration - min(0.001, self.duration * 0.001)
                    self.hasReachedEnd = atEnd
                    if !self.isScrubbing { self.position = atEnd ? self.duration : target.time }
                    if atEnd, self.policy.canResumeSeek(revision: target.revision) {
                        self.pause()
                    } else if target.resume, self.policy.canResumeSeek(revision: target.revision) {
                        self.startPlayback()
                    }
                }
            }
        }
    }

    private func replaceCurrentItem() {
        if let contentVersion { savedPositions[contentVersion] = position }
        loadID = UUID()
        seekID = UUID()
        pause()
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
        contentVersion = nil
        pendingSeek = nil
        isSeeking = false
        duration = 0
        position = 0
        downloadProgress = nil
        isLoading = false
        isReady = false
        isSeekable = false
        errorMessage = nil
        hasReachedEnd = false
    }
}

/// The AVPlayerLayer stays inside the zoomable card. No system player chrome,
/// fullscreen controller, or picture-in-picture controller is created.
final class PreviewVideoSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var readiness: NSKeyValueObservation?

    func display(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        readiness = nil
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        isHidden = true
        guard player != nil else { return }
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isHidden = !self.playerLayer.isReadyForDisplay
            }
        }
    }
}
