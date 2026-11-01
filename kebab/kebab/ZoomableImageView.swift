//
//  ZoomableImageView.swift
//  kebab
//

import SwiftUI
import UIKit

/// What the swipe-down-to-dismiss drag reports up to the viewer, so it can
/// fade its own black background and chrome in step with the image.
enum DismissDragEvent {
    /// 0 at rest → 1 fully faded, while the finger is down.
    case changed(CGFloat)
    /// Released short of the threshold; the image is springing back.
    case cancelled
    /// Released past the threshold; the image is leaving over `duration`.
    case committed(duration: TimeInterval)
    /// The image is gone; the viewer should close without its own animation.
    case finished
}

/// One page of the full-screen viewer: a UIScrollView that zooms its image
/// (pinch 1–3×, double-tap 2×) and owns the swipe-down dismiss pan. Both live
/// in UIKit on purpose — a SwiftUI DragGesture on top fights the zoom
/// scroll view and the TabView pager, while UIKit recognizers can be gated
/// on zoom state and ordered against the scroll views' own pans.
struct ZoomableImageView: UIViewRepresentable {

    let image: UIImage
    /// False once the pager moves away; the page snaps back to 1×.
    let isCurrent: Bool
    var onDismissDrag: (DismissDragEvent) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let scrollView = ZoomingScrollView()
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.image = image
        container.addSubview(scrollView)

        context.coordinator.attach(scrollView: scrollView, container: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismissDrag = onDismissDrag
        guard let scrollView = context.coordinator.scrollView else { return }
        scrollView.image = image
        if !isCurrent, scrollView.zoomScale != scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismissDrag: onDismissDrag)
    }

    // MARK: - Dismiss pan

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismissDrag: (DismissDragEvent) -> Void

        private(set) weak var scrollView: ZoomingScrollView?
        private weak var container: UIView?

        /// Vertical travel that commits a dismiss on release.
        private let threshold: CGFloat = 120
        /// Downward release speed that commits regardless of travel.
        private let flickVelocity: CGFloat = 800
        /// Scale the image reaches at the threshold (and holds past it).
        private let minimumScale: CGFloat = 0.85

        init(onDismissDrag: @escaping (DismissDragEvent) -> Void) {
            self.onDismissDrag = onDismissDrag
        }

        func attach(scrollView: ZoomingScrollView, container: UIView) {
            self.scrollView = scrollView
            self.container = container
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            scrollView.addGestureRecognizer(pan)
        }

        // Begins only at 1× and only for a mostly-vertical start, so zoomed
        // drags pan the image and horizontal drags page.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scrollView, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
            let velocity = pan.velocity(in: container)
            return abs(velocity.y) > abs(velocity.x)
        }

        // Every scroll-view pan above or at this page (the zoom scroll view
        // and the TabView's pager) waits for this recognizer to decide. It
        // decides at the movement threshold: horizontal or zoomed → fail
        // instantly and the scroll views proceed as normal; vertical at 1× →
        // begin, and the pager never steals the drag mid-dismiss.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let scrollView, let container else { return }
            let translation = pan.translation(in: container)

            switch pan.state {
            case .changed:
                let offset = resisted(translation, height: container.bounds.height)
                scrollView.transform = transform(for: offset)
                onDismissDrag(.changed(progress(for: offset.y)))

            case .ended, .cancelled, .failed:
                let velocity = pan.velocity(in: container)
                let commits = pan.state == .ended
                    && translation.y > 0
                    && (translation.y > threshold || velocity.y > flickVelocity)
                if commits {
                    commit(from: resisted(translation, height: container.bounds.height), velocity: velocity)
                } else {
                    springBack()
                }

            default:
                break
            }
        }

        private func commit(from offset: CGPoint, velocity: CGPoint) {
            guard let scrollView, let container else { return }
            scrollView.isUserInteractionEnabled = false
            let duration: TimeInterval = 0.25
            onDismissDrag(.committed(duration: duration))

            let animations: () -> Void
            if UIAccessibility.isReduceMotionEnabled {
                // Reduce Motion: the image fades where it is, no fling.
                animations = { scrollView.alpha = 0 }
            } else {
                // Continue along the release direction until fully off-screen.
                // A slow release past the threshold falls back to the drag's
                // own direction; either way it always leaves downward.
                var direction = hypot(velocity.x, velocity.y) > 200 ? velocity : offset
                direction.y = max(direction.y, 1)
                let length = hypot(direction.x, direction.y)
                let distance = container.bounds.height * 1.2
                let end = CGPoint(
                    x: offset.x + direction.x / length * distance,
                    y: offset.y + direction.y / length * distance
                )
                animations = { scrollView.transform = self.transform(for: end) }
            }

            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut], animations: animations) { _ in
                self.onDismissDrag(.finished)
            }
        }

        private func springBack() {
            guard let scrollView else { return }
            onDismissDrag(.cancelled)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                scrollView.transform = .identity
            }
        }

        /// Follows the finger in both axes; upward travel rubber-bands.
        private func resisted(_ translation: CGPoint, height: CGFloat) -> CGPoint {
            guard translation.y < 0, height > 0 else { return translation }
            let pulled = -translation.y
            let band = (1 - 1 / (pulled * 0.55 / height + 1)) * height
            return CGPoint(x: translation.x, y: -band)
        }

        private func transform(for offset: CGPoint) -> CGAffineTransform {
            let travel = min(1, max(0, offset.y) / threshold)
            let scale = 1 - (1 - minimumScale) * travel
            return CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
        }

        /// Background and chrome fade over twice the threshold, so they are
        /// still visibly there when a release would commit.
        private func progress(for offsetY: CGFloat) -> CGFloat {
            min(1, max(0, offsetY) / (threshold * 2))
        }
    }
}

// MARK: - Zooming scroll view

/// Aspect-fit image at 1×, zooming to 3× with content centred by insets
/// whenever it's smaller than the bounds.
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private var fittedBoundsSize: CGSize = .zero

    private let doubleTapScale: CGFloat = 2

    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            refit()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 3
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBoundsSize {
            refit()
        }
    }

    /// Back to 1× with the image sized to fit the current bounds.
    private func refit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        fittedBoundsSize = bounds.size
        zoomScale = minimumZoomScale

        guard let size = image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = .zero
            contentSize = .zero
            return
        }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centreContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private func centreContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets {
            contentInset = insets
        }
    }

    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = tap.location(in: imageView)
        let width = bounds.width / doubleTapScale
        let height = bounds.height / doubleTapScale
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreContent()
    }
}
