import AVFoundation
import CoreGraphics

/// Browses independently of playback and makes one seek to the released position after its artwork is available.
@MainActor
final class RoomVideoScanner {
    struct Preview {
        let image: CGImage
        let time: Double
        let fraction: Double
        let loading: Bool

        var timestamp: String {
            let tenths = max(0, Int((time * 10).rounded()))
            let seconds = tenths / 10
            return seconds >= 3600 ? String(format: "%d:%02d:%02d.%d", seconds / 3600, seconds / 60 % 60, seconds % 60, tenths % 10)
                                   : String(format: "%d:%02d.%d", seconds / 60, seconds % 60, tenths % 10)
        }
    }

    private struct Frame {
        let image: CGImage
        let time: Double
        let range: Range<Double>?
        func covers(_ position: Double) -> Bool { time == position || range?.contains(position) == true }
    }

    private let frameRange: @MainActor (AVPlayerItem, Double) -> Range<Double>?
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
    private var coldRelease: (rate: Float, position: Double, uptime: TimeInterval)?
    private var releaseDeadline: Task<Void, Never>?
    private var bounds: ClosedRange<Double> = 0...0
    private var duration = 0.0
    private var target = 0.0
    private var displayedTime: Double?
    private var recentFrames: [Frame] = []
    private var previousDirection = 0.0
    private var requestID = 0
    private var requestedTime: Double?
    private var generation = 0
    var busy: Bool { item != nil }

    init(canPreview: @escaping @MainActor (AVPlayerItem) -> Bool, image: @escaping @MainActor (AVPlayerItem, Double) async -> CGImage?,
         frameRange: @escaping @MainActor (AVPlayerItem, Double) -> Range<Double>? = { _, _ in nil }) {
        self.frameRange = frameRange
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
        let direction = next > target ? 1.0 : -1.0
        let reversed = previousDirection != 0 && previousDirection != direction
        previousDirection = direction
        target = next
        if let frame = recentFrames.last(where: { $0.covers(next) }) {
            cancelRequest()
            show(frame, at: next)
            return
        }
        if let frame = recentFrames.last, displayedTime != nil {
            // The destination and clock follow the finger even when a new sheet is still loading.
            present?(Preview(image: frame.image, time: next, fraction: next / duration, loading: true))
        }
        if reversed { cancelRequest() }
        requestFrame()
    }

    private func requestFrame() {
        guard worker == nil else { return }
        let id = requestID
        worker = Task { [weak self] in await self?.showFrames(id: id) }
    }

    private func cancelRequest() {
        requestID &+= 1
        worker?.cancel()
        worker = nil
        requestedTime = nil
    }

    private func show(_ frame: Frame, at time: Double) {
        displayedTime = time
        present?(Preview(image: frame.image, time: time, fraction: time / duration, loading: false))
    }

    private func showFrames(id: Int) async {
        while requestID == id, !Task.isCancelled {
            guard let item, player?.currentItem === item, monitor?.events.isEmpty == true else { stop(); return }
            let time = target
            requestedTime = time
            let bitmap = await image(item, time)
            guard requestID == id, !Task.isCancelled else { return }
            guard player?.currentItem === item, presentationActive?() == true else { stop(); return }
            guard let bitmap else {
                if target != time { continue }
                failedItem = item
                retryAfter = .now + .seconds(30)
                stop()
                return
            }
            let frame = Frame(image: bitmap, time: time, range: frameRange(item, time))
            if recentFrames.count == 2 { recentFrames.removeFirst() }
            recentFrames.append(frame)
            if frame.covers(target) {
                show(frame, at: target)
            } else {
                // A coalesced lookup can finish after the finger has passed that tile. Fetch the latest target next.
                if displayedTime == nil, coldRelease == nil {
                    present?(Preview(image: bitmap, time: target, fraction: target / duration, loading: true))
                }
                continue
            }
            if coldRelease != nil {
                releaseDeadline?.cancel()
                try? await Task.sleep(for: .milliseconds(90))
                guard requestID == id else { return }
                commit()
                return
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard requestID == id else { return }
            if displayedTime == target { worker = nil; requestedTime = nil; return }
        }
    }

    func finish() {
        guard busy, coldRelease == nil else { return }
        if displayedTime == target { commit(); return }
        guard previousDirection != 0, let player else { stop(); return }
        coldRelease = (player.rate, player.currentTime().seconds, ProcessInfo.processInfo.systemUptime)
        let wait: Duration = displayedTime == nil ? .milliseconds(550) : .milliseconds(1200)
        let visit = generation
        releaseDeadline = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, generation == visit else { return }
            stop()
        }
        if requestedTime != target { cancelRequest() }
        requestFrame()
    }

    func cancelPendingRelease() {
        if coldRelease != nil { stop() }
    }

    private func commit() {
        guard let selected = item, let player, player.currentItem === selected, let time = displayedTime, time == target,
              monitor?.events.isEmpty == true, presentationActive?() == true else { stop(); return }
        if let released = coldRelease {
            let elapsed = ProcessInfo.processInfo.systemUptime - released.uptime
            let advanced = player.currentTime().seconds - released.position
            guard player.rate == released.rate, advanced >= -0.35, advanced <= Double(released.rate) * elapsed + 0.65 else {
                stop()
                return
            }
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
        cancelRequest()
        recentFrames.removeAll(keepingCapacity: true)
        previousDirection = 0
        present?(nil)
        present = nil
        item = nil
        player = nil
        monitor = nil
        displayedTime = nil
    }
}

/// Finger movement is fine at low velocity. A sustained hold gathers speed after its first second.
enum RoomScrubMotion {
    static func seconds(forPoints points: Double, velocity: Double) -> Double {
        let phase = min(1, max(0, (abs(velocity) - 200) / 1600))
        let acceleration = phase * phase * (3 - 2 * phase)
        return points * (0.0125 + 0.1375 * acceleration)
    }

    static func holdSpeed(after elapsed: Double) -> Double {
        let accelerating = max(0, elapsed - 1.25)
        return min(60, 2 + 1.75 * accelerating * accelerating)
    }
}

/// The card can slide inwards at either edge, but both pointers stay on the selected timeline coordinate.
struct RoomScrubPlacement {
    let card: CGRect
    let destination: CGPoint

    init(screen: CGRect, measuredTrack: CGRect?, fraction: Double, controlsVisible: Bool) {
        let track = measuredTrack ?? CGRect(x: screen.minX + screen.width / 24, y: screen.minY + screen.height * 0.843,
                                             width: screen.width * 11 / 12, height: 0)
        let x = track.minX + CGFloat(min(1, max(0, fraction))) * track.width
        destination = CGPoint(x: x, y: track.midY)
        let width = min(272, track.width * 0.25)
        let height = width * 9 / 16 + 36
        let left = max(screen.minX, track.minX - 18)
        let right = min(screen.maxX, track.maxX + 18)
        let cardX = min(right - width, max(left, x - width / 2))
        var bottom = screen.minY + screen.height * (controlsVisible ? 0.72 : 0.82)
        if controlsVisible, measuredTrack != nil {
            bottom = min(screen.minY + 0.74 * screen.height, max(screen.minY + 0.70 * screen.height, track.midY - 0.12 * screen.height))
        }
        card = CGRect(x: cardX, y: max(screen.minY, bottom - height), width: width, height: height)
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
            scanner.move(by: RoomScrubMotion.seconds(forPoints: Double(x - lastX), velocity: Double(velocityX)))
            lastX = x
        case .ended, .cancelled, .failed:
            guard activeGesture === pan else { return }
            if state == .ended {
                scanner.move(by: RoomScrubMotion.seconds(forPoints: Double(x - lastX), velocity: Double(velocityX)))
                scanner.finish()
            } else { scanner.stop() }
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
                    let speed = RoomScrubMotion.holdSpeed(after: now - start)
                    scanner.move(by: direction * speed * min(0.25, now - previous))
                    previous = now
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
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
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pointer = UIImageView(image: UIImage(systemName: "arrowtriangle.down.fill"))
    private let cursor = UIView()

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
        spinner.hidesWhenStopped = true
        spinner.color = .white
        addSubview(spinner)
        let accent = UIColor(red: 0.41, green: 0.92, blue: 1, alpha: 1)
        pointer.tintColor = accent
        pointer.contentMode = .scaleAspectFit
        pointer.accessibilityIdentifier = "scrub-preview-pointer"
        cursor.accessibilityIdentifier = "scrub-preview-cursor"
        cursor.backgroundColor = accent
        cursor.layer.cornerRadius = 3
        cursor.layer.borderWidth = 1
        cursor.layer.borderColor = UIColor.black.cgColor
        for marker in [pointer as UIView, cursor] {
            marker.isUserInteractionEnabled = false
            marker.isHidden = true
            marker.layer.shadowColor = UIColor.black.cgColor
            marker.layer.shadowOpacity = 0.9
            marker.layer.shadowRadius = 2
            marker.layer.shadowOffset = CGSize(width: 0, height: 1)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        for marker in [pointer as UIView, cursor] {
            marker.removeFromSuperview()
            superview?.addSubview(marker)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - 36)
        clock.frame = CGRect(x: 2, y: picture.frame.maxY, width: bounds.width - 4, height: 32)
        spinner.center = picture.center
    }

    func show(_ preview: RoomVideoScanner.Preview, in controller: AVPlayerViewController, controlsVisible: Bool) {
        guard let parent = superview else { return }
        let screen = controller.view.bounds
        guard screen.width > 0, screen.height > 0 else { return }
        let track = controlsVisible ? focusedTrack(in: controller) : nil
        let placement = RoomScrubPlacement(screen: screen, measuredTrack: track, fraction: preview.fraction, controlsVisible: controlsVisible)
        frame = parent.convert(placement.card, from: controller.view).integral
        let point = parent.convert(placement.destination, from: controller.view)
        pointer.bounds.size = CGSize(width: 19, height: 11)
        pointer.center = CGPoint(x: point.x, y: frame.maxY + pointer.bounds.midY)
        cursor.bounds.size = CGSize(width: 7, height: 24)
        cursor.center = point
        pointer.isHidden = false
        cursor.isHidden = !controlsVisible
        if isHidden {
            setNeedsLayout()
            layoutIfNeeded()
        }
        picture.isHidden = preview.loading
        if preview.loading { spinner.startAnimating() }
        else {
            spinner.stopAnimating()
            if picture.image?.cgImage !== preview.image { picture.image = UIImage(cgImage: preview.image) }
        }
        clock.text = preview.timestamp
        parent.bringSubviewToFront(cursor)
        parent.bringSubviewToFront(pointer)
        parent.bringSubviewToFront(self)
        isHidden = false
    }

    private func focusedTrack(in controller: AVPlayerViewController) -> CGRect? {
        guard let focused = UIFocusSystem.focusSystem(for: controller)?.focusedItem as? UIView,
              focused.accessibilityTraits.contains(.adjustable), focused.isDescendant(of: controller.view) else { return nil }
        let screen = controller.view.bounds
        let track = controller.view.convert(focused.bounds, from: focused)
        guard track.width > screen.width * 0.45, track.height < screen.height * 0.16,
              screen.contains(track), (screen.minY + 0.75 * screen.height ... screen.minY + 0.95 * screen.height).contains(track.midY)
        else { return nil }
        return track
    }

    func hide() {
        isHidden = true
        pointer.isHidden = true
        cursor.isHidden = true
        spinner.stopAnimating()
        picture.image = nil
        clock.text = nil
    }
}
#endif
