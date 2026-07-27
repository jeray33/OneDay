import SwiftUI
import UIKit

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
    var onZoomChanged: (Bool) -> Void = { _ in }
    var caption: String? = nil
    var captionColor: Color = .black
    var onEditCaption: (() -> Void)? = nil

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

        // The zooming view fills the scroll view bounds (this is what made zoom
        // robust before the border existed). The white card is centered inside it
        // and scales as a whole, so border + caption scale proportionally.
        let container = context.coordinator.container
        scrollView.addSubview(container)

        let card = context.coordinator.card
        card.backgroundColor = UIColor(cardColor)
        container.addSubview(card)

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
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
        return scrollView
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.apply(self)
        context.coordinator.relayout(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChanged: onZoomChanged, onEditCaption: onEditCaption) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let container = UIView()
        let card = UIView()
        let imageView = UIImageView()
        let captionLabel = UILabel()
        var displaySize: CGSize = .zero
        var sideBorder: CGFloat = 8
        var topBorder: CGFloat = 8
        var captionHeight: CGFloat = 0
        var caption: String? = nil
        var captionColor: Color = .black
        let onZoomChanged: (Bool) -> Void
        let onEditCaption: (() -> Void)?
        private var wasZoomed = false
        private var isZoomInteractionActive = false

        init(onZoomChanged: @escaping (Bool) -> Void, onEditCaption: (() -> Void)?) {
            self.onZoomChanged = onZoomChanged
            self.onEditCaption = onEditCaption
        }

        func apply(_ view: ZoomableImageView) {
            displaySize = view.displaySize
            sideBorder = view.sideBorder
            topBorder = view.topBorder
            captionHeight = view.captionHeight
            caption = view.caption
            captionColor = view.captionColor
            card.backgroundColor = UIColor(view.cardColor)
            captionLabel.text = view.caption
            captionLabel.textColor = UIColor(view.captionColor)
            captionLabel.isHidden = view.caption?.isEmpty ?? true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        /// Container fills the viewport; the white card is centered inside it.
        /// While zoomed we only keep the card centered and never touch the
        /// container frame / contentSize, so we don't fight the zoom.
        func relayout(_ scrollView: UIScrollView) {
            let size = scrollView.bounds.size
            guard size.width > 0, size.height > 0, displaySize.width > 0 else { return }
            let zoomVisualActive = isZoomInteractionActive
                || scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            let activeSideBorder: CGFloat = zoomVisualActive ? 0 : sideBorder
            let activeTopBorder: CGFloat = zoomVisualActive ? 0 : topBorder
            let activeCaptionHeight: CGFloat = zoomVisualActive ? 0 : captionHeight

            if abs(scrollView.zoomScale - 1) < 0.001 {
                container.frame = CGRect(origin: .zero, size: size)
                scrollView.contentSize = size
            }
            card.bounds = CGRect(origin: .zero, size: displaySize)
            card.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)

            let imageH = displaySize.height - activeTopBorder - activeCaptionHeight
            imageView.frame = CGRect(x: activeSideBorder, y: activeTopBorder,
                                     width: displaySize.width - activeSideBorder * 2,
                                     height: max(imageH, 0))

            let hasCaption = !(caption?.isEmpty ?? true) && !zoomVisualActive
            captionLabel.isHidden = !hasCaption
            if hasCaption {
                captionLabel.frame = CGRect(
                    x: activeSideBorder,
                    y: displaySize.height - activeCaptionHeight,
                    width: displaySize.width - activeSideBorder * 2,
                    height: activeCaptionHeight
                )
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            relayout(scrollView)
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                onZoomChanged(zoomed)
            }
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isZoomInteractionActive = true
            relayout(scrollView)
            if !wasZoomed {
                wasZoomed = true
                onZoomChanged(true)
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZoomInteractionActive = false
            relayout(scrollView)
            let zoomed = scale > scrollView.minimumZoomScale + 0.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                onZoomChanged(zoomed)
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
                let point = gesture.location(in: container)
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