import SwiftUI
import UIKit
import Photos

/// A UIScrollView that reports back when it needs to re-layout its content,
/// so centering stays correct once the view actually receives its size.
final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// The white card size (image + borders + caption strip) at zoom scale 1.
    let displaySize: CGSize
    var sideBorder: CGFloat = 8
    var topBorder: CGFloat = 8
    /// Thickness of the bottom border strip (tall for Polaroid).
    var captionHeight: CGFloat = 0
    var cardColor: Color = .white
    var cornerRadius: CGFloat = 0
    var onZoomChanged: (Bool) -> Void = { _ in }
    var caption: String? = nil
    var captionColor: Color = .black
    var onEditCaption: (() -> Void)? = nil
    var livePhotoAsset: PHAsset? = nil
    var isSelected = false
    var livePhotoVisitID: UUID? = nil
    var allowsLivePlayback = false
    var interactionRecoveryID: UUID?

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        // The whole white card (image + border + caption) is the zooming view,
        // so pinch/double-tap scales it as one unit and the border grows
        // proportionally with the photo. Centering is handled with contentInset.
        let card = context.coordinator.card
        card.backgroundColor = UIColor(cardColor)
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = cornerRadius > 0
        scrollView.addSubview(card)

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        let innerRadius = max(cornerRadius - sideBorder, 0)
        imageView.layer.cornerRadius = innerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.layer.masksToBounds = innerRadius > 0
        card.addSubview(imageView)

        let captionLabel = context.coordinator.captionLabel
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.serif)
            .map { $0.withSize(12) }
        captionLabel.font = descriptor.map { UIFont(descriptor: $0, size: 12) }
            ?? UIFont.systemFont(ofSize: 12, weight: .regular)
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.8
        captionLabel.isUserInteractionEnabled = true
        let captionTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCaptionTap(_:)))
        captionLabel.addGestureRecognizer(captionTap)
        card.addSubview(captionLabel)

        scrollView.onLayout = { [weak scrollView] in
            guard let scrollView else { return }
            context.coordinator.relayout(scrollView)
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.apply(self)
        context.coordinator.lastRecoveryID = interactionRecoveryID
        return scrollView
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.apply(self)
        context.coordinator.recoverInteraction(
            uiView, id: interactionRecoveryID, selected: isSelected
        )
        context.coordinator.relayout(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChanged: onZoomChanged, onEditCaption: onEditCaption) }

    static func dismantleUIView(_ uiView: ZoomScrollView, coordinator: Coordinator) {
        uiView.onLayout = nil
        coordinator.livePlayer?.reset()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let card = UIView()
        let imageView = UIImageView()
        let captionLabel = UILabel()
        private(set) var livePlayer: LivePhotoPlayerController?
        var displaySize: CGSize = .zero
        var sideBorder: CGFloat = 8
        var topBorder: CGFloat = 8
        var captionHeight: CGFloat = 0
        var cornerRadius: CGFloat = 0
        var caption: String? = nil
        var captionColor: Color = .black
        let onZoomChanged: (Bool) -> Void
        let onEditCaption: (() -> Void)?
        private var wasZoomed = false
        private var isSelected = false
        private var isRecoveringInteraction = false
        var lastRecoveryID: UUID?

        func recoverInteraction(_ scrollView: UIScrollView, id: UUID?, selected: Bool) {
            guard id != lastRecoveryID else { return }
            lastRecoveryID = id
            // Cancel native pan/pinch/deceleration without discarding the user's
            // actual zoom level. Only the selected page may update parent state.
            isRecoveringInteraction = true
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            for gesture in [scrollView.panGestureRecognizer, scrollView.pinchGestureRecognizer].compactMap({ $0 }) {
                let enabled = gesture.isEnabled
                gesture.isEnabled = false
                gesture.isEnabled = enabled
            }
            relayout(scrollView)
            isRecoveringInteraction = false
            guard selected else { return }
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView, self.lastRecoveryID == id,
                      self.isSelected else { return }
                let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                self.wasZoomed = zoomed
                self.livePlayer?.setZoomed(zoomed)
                self.onZoomChanged(zoomed)
            }
        }

        init(onZoomChanged: @escaping (Bool) -> Void, onEditCaption: (() -> Void)?) {
            self.onZoomChanged = onZoomChanged
            self.onEditCaption = onEditCaption
        }

        func apply(_ view: ZoomableImageView) {
            isSelected = view.isSelected
            displaySize = view.displaySize
            sideBorder = view.sideBorder
            topBorder = view.topBorder
            captionHeight = view.captionHeight
            cornerRadius = view.cornerRadius
            caption = view.caption
            captionColor = view.captionColor
            card.backgroundColor = UIColor(view.cardColor)
            card.layer.cornerRadius = view.cornerRadius
            card.layer.masksToBounds = view.cornerRadius > 0
            let innerRadius = max(view.cornerRadius - view.sideBorder, 0)
            imageView.layer.cornerRadius = innerRadius
            imageView.layer.masksToBounds = innerRadius > 0
            captionLabel.text = view.caption
            captionLabel.textColor = UIColor(view.captionColor)
            captionLabel.isHidden = view.caption?.isEmpty ?? true
            if view.livePhotoAsset != nil, livePlayer == nil {
                let player = LivePhotoPlayerController()
                card.insertSubview(player.liveView, aboveSubview: imageView)
                card.insertSubview(player.badge, aboveSubview: player.liveView)
                livePlayer = player
            }
            livePlayer?.liveView.layer.cornerRadius = innerRadius
            livePlayer?.liveView.layer.cornerCurve = .continuous
            livePlayer?.update(
                asset: view.livePhotoAsset,
                selected: view.isSelected,
                visitID: view.livePhotoVisitID,
                permitted: view.allowsLivePlayback,
                targetSize: CGSize(
                    width: max(1, displaySize.width - sideBorder * 2) * imageView.traitCollection.displayScale,
                    height: max(1, displaySize.height - topBorder - captionHeight) * imageView.traitCollection.displayScale
                )
            )
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { card }

        /// Lays the card out at its rest (scale 1) geometry and keeps it
        /// centered. While zoomed the scroll view owns the card's transform, so
        /// we only re-center and never rewrite the card frame.
        func relayout(_ scrollView: UIScrollView) {
            let size = scrollView.bounds.size
            guard size.width > 0, size.height > 0, displaySize.width > 0 else { return }

            if abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001 {
                card.frame = CGRect(origin: .zero, size: displaySize)
                scrollView.contentSize = displaySize

                let imageH = displaySize.height - topBorder - captionHeight
                imageView.frame = CGRect(x: sideBorder, y: topBorder,
                                         width: displaySize.width - sideBorder * 2,
                                         height: max(imageH, 0))
                if let livePlayer {
                    livePlayer.liveView.frame = imageView.frame
                    let badgeSize = livePlayer.badge.sizeThatFits(imageView.bounds.size)
                    livePlayer.badge.frame = CGRect(
                        x: imageView.frame.minX + 8, y: imageView.frame.minY + 8,
                        width: min(badgeSize.width, max(0, imageView.bounds.width - 16)),
                        height: badgeSize.height
                    )
                }

                let hasCaption = !(caption?.isEmpty ?? true)
                captionLabel.isHidden = !hasCaption
                if hasCaption {
                    captionLabel.frame = CGRect(
                        x: sideBorder,
                        y: displaySize.height - captionHeight,
                        width: displaySize.width - sideBorder * 2,
                        height: captionHeight
                    )
                }
            }
            centerContent(scrollView)
        }

        /// Centers the card while it is smaller than the viewport (scale 1), and
        /// lets it pan freely once zoomed larger.
        private func centerContent(_ scrollView: UIScrollView) {
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX,
                                                   bottom: offsetY, right: offsetX)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            guard !isRecoveringInteraction else { return }
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            livePlayer?.setZoomed(zoomed)
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                if isSelected { onZoomChanged(zoomed) }
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            centerContent(scrollView)
            guard !isRecoveringInteraction else { return }
            let zoomed = scale > scrollView.minimumZoomScale + 0.01
            livePlayer?.setZoomed(zoomed)
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                if isSelected { onZoomChanged(zoomed) }
            }
        }

        @objc func handleCaptionTap(_ gesture: UITapGestureRecognizer) {
            onEditCaption?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: card)
                let targetScale: CGFloat = 2.5
                let w = scrollView.bounds.width / targetScale
                let h = scrollView.bounds.height / targetScale
                scrollView.zoom(to: CGRect(x: point.x - w / 2,
                                           y: point.y - h / 2,
                                           width: w, height: h),
                                animated: true)
            }
        }
    }
}
