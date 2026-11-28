import AVFoundation
import CoreGraphics

/// Browses frames independently of playback. Releasing selects the last picture actually shown.
@MainActor
final class RoomVideoScanner {
    struct Preview {
        let image: CGImage
        let time: Double
        let fraction: Double
    }

    private let canPreview: @MainActor (AVPlayerItem) -> Bool
    private let image: @MainActor (AVPlayerItem, Double) async -> CGImage?
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private weak var failedItem: AVPlayerItem?
    private var retryAfter = ContinuousClock.now
    private var monitor: AVPlayerInterstitialEventMonitor?
    private var worker: Task<Void, Never>?
    private var present: ((Preview?) -> Void)?
    private var presentationActive: (() -> Bool)?
    private var coldRelease: (rate: Float, position: Double)?
    private var releaseDeadline: Task<Void, Never>?
    private var bounds: ClosedRange<Double> = 0...0
    private var duration = 0.0
    private var target = 0.0
    private var displayedTime: Double?
    private var generation = 0
    var busy: Bool { item != nil }

    init(canPreview: @escaping @MainActor (AVPlayerItem) -> Bool, image: @escaping @MainActor (AVPlayerItem, Double) async -> CGImage?) {
        self.canPreview = canPreview
        self.image = image
    }

    private func seekBounds(_ player: AVPlayer) -> ClosedRange<Double>? {
        guard let item = player.currentItem, item.status == .readyToPlay, item.duration.isNumeric,
              player.rate == 0 || abs(player.rate - player.defaultRate) < 0.01 else { return nil }
        let now = player.currentTime().seconds
        guard let range = item.seekableTimeRanges.map(\.timeRangeValue).first(where: {
            $0.start.seconds <= now && now <= $0.end.seconds
        }) else { return nil }
        var end = min(item.duration.seconds, range.end.seconds)
        if item.forwardPlaybackEndTime.isNumeric { end = min(end, item.forwardPlaybackEndTime.seconds) }
        // The media ends immediately after its final picture.
        let last = end - 1.0 / 30.0
        return last > range.start.seconds ? range.start.seconds...last : nil
    }

    func canBegin(on player: AVPlayer) -> Bool {
        guard !busy, let item = player.currentItem, failedItem !== item || ContinuousClock.now >= retryAfter,
              canPreview(item) else { return false }
        return seekBounds(player) != nil
    }

    @discardableResult
    func begin(on player: AVPlayer, presentationActive: @escaping () -> Bool = { true }, present: @escaping (Preview?) -> Void) -> Bool {
        guard canBegin(on: player), let bounds = seekBounds(player), let item = player.currentItem else { return false }
        let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: player)
        guard monitor.events.isEmpty else { return false }
        self.monitor = monitor
        self.bounds = bounds
        self.item = item
        self.player = player
        self.present = present
        self.presentationActive = presentationActive
        duration = item.duration.seconds
        target = min(bounds.upperBound, max(bounds.lowerBound, player.currentTime().seconds))
        return true
    }

    func move(by seconds: Double) {
        guard busy, coldRelease == nil, seconds.isFinite else { return }
        let next = min(bounds.upperBound, max(bounds.lowerBound, target + seconds))
        guard next != target else { return }
        target = next
        if worker == nil {
            let visit = generation
            worker = Task { [weak self] in await self?.showFrames(visit: visit) }
        }
    }

    private func showFrames(visit: Int) async {
        while generation == visit, !Task.isCancelled {
            guard let item, player?.currentItem === item, monitor?.events.isEmpty == true else { stop(); return }
            let time = target
            let frame = await image(item, time)
            guard generation == visit, !Task.isCancelled else { return }
            guard player?.currentItem === item, presentationActive?() == true else { stop(); return }
            if coldRelease != nil, target != time { continue }
            guard let frame else {
                failedItem = item
                retryAfter = .now + .seconds(30)
                stop()
                return
            }
            // Keep the timestamp and position tied to the decoded image even on a slow connection.
            displayedTime = time
            present?(Preview(image: frame, time: time, fraction: time / duration))
            if coldRelease != nil {
                releaseDeadline?.cancel()
                // A short swipe can finish before its first sheet arrives. Show the selection before landing on it.
                try? await Task.sleep(for: .milliseconds(110))
                guard generation == visit else { return }
                commit()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard generation == visit else { return }
            if target == time { worker = nil; return }
        }
    }

    func finish() {
        guard busy, coldRelease == nil else { return }
        if displayedTime != nil { commit(); return }
        guard worker != nil, let player else { stop(); return }
        coldRelease = (player.rate, player.currentTime().seconds)
        let visit = generation
        releaseDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard let self, generation == visit else { return }
            stop()
        }
    }

    func cancelPendingRelease() {
        if coldRelease != nil { stop() }
    }

    private func commit() {
        guard let selected = item, let player, player.currentItem === selected, let time = displayedTime,
              monitor?.events.isEmpty == true, presentationActive?() == true else { stop(); return }
        if let released = coldRelease,
           player.rate != released.rate || abs(player.currentTime().seconds - released.position) > 2 {
            stop()
            return
        }
        stop()
        selected.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    func stop() {
        generation &+= 1
        releaseDeadline?.cancel()
        releaseDeadline = nil
        coldRelease = nil
        presentationActive = nil
        worker?.cancel()
        worker = nil
        present?(nil)
        present = nil
        item = nil
        player = nil
        monitor = nil
        displayedTime = nil
    }
}

#if os(tvOS)
import AVKit
import UIKit

@MainActor
final class RoomScanGestures: NSObject, UIGestureRecognizerDelegate {
    private let scanner: RoomVideoScanner
    private let canScanPlayback: () -> Bool
    private weak var controller: AVPlayerViewController?
    var enabled = false { didSet { if !enabled { cancel() } } }
    var transportBarVisible: Bool?
    private var ownsScan = false
    private weak var activeGesture: UIGestureRecognizer?
    private let inset = RoomScrubPreview()
    private var holdUpdates: Task<Void, Never>?
    private var direction = 0.0
    private var touchMayScan = false
    private var pressMayScan = false
    private var lastX: CGFloat = 0
    private let otherPresses = UITapGestureRecognizer()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))

    init(scanner: RoomVideoScanner, canScanPlayback: @escaping () -> Bool) {
        self.scanner = scanner
        self.canScanPlayback = canScanPlayback
    }

    func install(on controller: AVPlayerViewController) {
        self.controller = controller
        controller.contentOverlayView?.addSubview(inset)
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.allowedPressTypes = []
        hold.allowedTouchTypes = []
        hold.allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        hold.minimumPressDuration = 0.45
        // Observe the next navigation press only to cancel a pending cold selection. This recognizer rejects every press.
        otherPresses.allowedTouchTypes = []
        otherPresses.allowedPressTypes = [UIPress.PressType.menu, .select, .playPause, .upArrow, .downArrow].map { NSNumber(value: $0.rawValue) }
        for gesture in [pan as UIGestureRecognizer, hold, otherPresses] {
            gesture.delegate = self
            controller.view.addGestureRecognizer(gesture)
        }
    }

    func cancel() {
        holdUpdates?.cancel()
        holdUpdates = nil
        if ownsScan { scanner.stop() }
        ownsScan = false
        inset.hide()
        activeGesture = nil
    }

    private var available: Bool {
        guard enabled, canScanPlayback(), let controller, controller.presentedViewController == nil, !controller.requiresLinearPlayback,
              let player = controller.player, player.currentItem?.interstitialTimeRanges.isEmpty == true else { return false }
        return scanner.canBegin(on: player)
    }

    private var focusedOnVideo: Bool {
        guard let controller else { return false }
        guard let focused = UIFocusSystem.focusSystem(for: controller)?.focusedItem else { return true }
        guard var view = focused as? UIView, view.isDescendant(of: controller.view) else { return false }
        if let shelf = controller.customOverlayViewController?.viewIfLoaded, view.isDescendant(of: shelf) { return false }
        while view !== controller.view {
            let traits = view.accessibilityTraits
            if view is UIButton || view is UITableViewCell || view is UICollectionViewCell || view is UITextField ||
                view is UISegmentedControl || traits.contains(.button) || traits.contains(.link) ||
                (view as? UIControl)?.showsMenuAsPrimaryAction == true { return false }
            if traits.contains(.adjustable) { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan else { return false }
        scanner.cancelPendingRelease()
        touchMayScan = available && focusedOnVideo
        return touchMayScan
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        scanner.cancelPendingRelease()
        guard gestureRecognizer === hold else { return false }
        direction = press.type == .leftArrow ? -1 : 1
        pressMayScan = available && focusedOnVideo
        return pressMayScan
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard available else { return false }
        if gestureRecognizer === hold { return pressMayScan }
        let speed = pan.velocity(in: pan.view)
        return touchMayScan && abs(speed.x) > 1.4 * abs(speed.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan { return touchMayScan && other is UIPanGestureRecognizer }
        guard gestureRecognizer === hold else { return false }
        return pressMayScan && !Set(hold.allowedPressTypes).isDisjoint(with: other.allowedPressTypes)
    }

    private func begin(on player: AVPlayer) -> Bool {
        guard inset.superview != nil else { return false }
        return scanner.begin(on: player, presentationActive: { [weak self] in
            guard let self, let controller else { return false }
            return enabled && canScanPlayback() && controller.presentedViewController == nil && controller.viewIfLoaded?.window != nil
        }) { [weak self] preview in
            guard let self, let controller else { return }
            if let preview { inset.show(preview, in: controller, controlsVisible: transportBarVisible ?? (controller.player?.timeControlStatus == .paused)) } else { inset.hide() }
        }
    }

    @objc private func panned() {
        handlePan(pan.state, translationX: pan.translation(in: pan.view).x, velocityX: pan.velocity(in: pan.view).x)
    }

    func handlePan(_ state: UIGestureRecognizer.State, translationX x: CGFloat, velocityX: CGFloat) {
        guard let player = controller?.player else { return }
        switch state {
        case .began:
            guard available, begin(on: player) else { return }
            ownsScan = true
            activeGesture = pan
            lastX = 0
            fallthrough
        case .changed:
            guard activeGesture === pan else { return }
            let secondsPerPoint = 0.055 + 0.25 * min(1, abs(velocityX) / 1800)
            scanner.move(by: Double((x - lastX) * secondsPerPoint))
            lastX = x
        case .ended, .cancelled, .failed:
            guard activeGesture === pan else { return }
            if state == .ended { scanner.finish() } else { scanner.stop() }
            activeGesture = nil
        default: break
        }
    }

    @objc private func held() {
        guard let player = controller?.player else { return }
        switch hold.state {
        case .began:
            guard available, begin(on: player) else { return }
            ownsScan = true
            activeGesture = hold
            let start = ProcessInfo.processInfo.systemUptime
            let direction = self.direction
            holdUpdates = Task { [weak self] in
                var previous = start
                while let self, scanner.busy, !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let speed: Double = now - start > 2 ? 50 : 20
                    scanner.move(by: direction * speed * min(0.25, now - previous))
                    previous = now
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        case .ended, .cancelled, .failed:
            guard activeGesture === hold else { return }
            activeGesture = nil
            holdUpdates?.cancel()
            holdUpdates = nil
            if hold.state == .ended { scanner.finish() } else { scanner.stop() }
        default: break
        }
    }
}

/// A nonfocusable picture and timestamp above AVKit’s transport controls.
@MainActor
private final class RoomScrubPreview: UIView {
    private let picture = UIImageView()
    private let clock = UILabel()

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "scrub-preview"
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = .black
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        layer.borderWidth = 2
        clipsToBounds = true
        picture.accessibilityIdentifier = "scrub-preview-image"
        picture.isAccessibilityElement = true
        picture.accessibilityLabel = "Video preview"
        picture.contentMode = .scaleAspectFit
        clock.accessibilityIdentifier = "scrub-preview-time"
        clock.textAlignment = .center
        clock.textColor = .white
        clock.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        addSubview(picture)
        addSubview(clock)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - 36)
        clock.frame = CGRect(x: 2, y: picture.frame.maxY, width: bounds.width - 4, height: 32)
    }

    func show(_ preview: RoomVideoScanner.Preview, in controller: AVPlayerViewController, controlsVisible: Bool) {
        guard let parent = superview else { return }
        let screen = controller.view.bounds
        guard screen.width > 0, screen.height > 0 else { return }
        // AVKit’s timeline spans the playback window, including letterboxed video. Only its horizontal safe margins apply.
        let edges = controller.view.safeAreaInsets
        let left = screen.minX + max(edges.left, screen.width * 0.04)
        let right = screen.maxX - max(edges.right, screen.width * 0.04)
        let width = min(272, (right - left) * 0.25)
        let height = width * 9 / 16 + 36
        let fraction = CGFloat(min(1, max(0, preview.fraction)))
        let x = min(right - width, max(left, left + fraction * (right - left) - width / 2))
        var bottom = screen.minY + screen.height * (controlsVisible ? 0.72 : 0.82)
        if controlsVisible, let focused = UIFocusSystem.focusSystem(for: controller)?.focusedItem as? UIView,
           focused.accessibilityTraits.contains(.adjustable), focused.isDescendant(of: controller.view) {
            let track = controller.view.convert(focused.bounds, from: focused)
            if track.width > screen.width * 0.45, track.height < screen.height * 0.16,
               (screen.minY + 0.75 * screen.height ... screen.minY + 0.95 * screen.height).contains(track.midY) {
                // Keep the entire row of transport actions under the preview clear, including at right-hand targets.
                bottom = min(screen.minY + 0.74 * screen.height, max(screen.minY + 0.70 * screen.height, track.midY - 0.12 * screen.height))
            }
        }
        let windowFrame = CGRect(x: x, y: max(screen.minY, bottom - height), width: width, height: height)
        frame = parent.convert(windowFrame, from: controller.view).integral
        if isHidden {
            setNeedsLayout()
            layoutIfNeeded()
        }
        picture.image = UIImage(cgImage: preview.image)
        let value = max(0, Int(preview.time))
        clock.text = value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                                   : String(format: "%d:%02d", value / 60, value % 60)
        parent.bringSubviewToFront(self)
        isHidden = false
    }

    func hide() {
        isHidden = true
        picture.image = nil
        clock.text = nil
    }
}
#endif
