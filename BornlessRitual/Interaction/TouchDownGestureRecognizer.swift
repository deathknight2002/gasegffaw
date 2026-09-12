//
//  TouchDownGestureRecognizer.swift
//  Bornless Ritual — zero-latency touch lifecycle recogniser for `GestureController`
//  (docs/CRITIC.md "Interaction feel: tap latency (input → visible response ≤ 2 frames)";
//  job contract "inputs applied on touch-begin callbacks for lowest latency").
//
//  Role: a continuous `UIGestureRecognizer` subclass that enters `.began` on the first
//  touch-down and `.ended` when the last finger lifts (`.cancelled` on system
//  cancellation). Unlike `UITapGestureRecognizer` (fires on touch-up) and
//  `UILongPressGestureRecognizer` (fires after `minimumPressDuration`), it reports the
//  touch the moment it lands, so rhythm taps, chant holds and the first trace point are
//  stamped at the current simulation tick without waiting for a timer or a lift. It never
//  cancels touches in the view and recognises alongside every other recogniser.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Continuous recogniser: `.began` on the first touch, `.ended` when all touches lift.
final class TouchDownGestureRecognizer: UIGestureRecognizer {
    /// Touches currently down on the view.
    private var activeTouches = Set<UITouch>()
    /// First touch of the sequence; its location drives tap / hold / trace handling.
    private(set) var primaryTouch: UITouch?

    /// Creates the recogniser targeting `action` on `target`.
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// Number of fingers currently down.
    var activeTouchCount: Int {
        activeTouches.count
    }

    /// Location of the primary touch in `view` (the centroid when the primary is unknown).
    func primaryLocation(in view: UIView?) -> CGPoint {
        if let touch = primaryTouch {
            return touch.location(in: view)
        }
        return location(in: view)
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        activeTouches.formUnion(touches)
        if primaryTouch == nil {
            primaryTouch = touches.first
        }
        switch state {
        case .possible:
            state = .began
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        activeTouches.subtract(touches)
        guard state == .began || state == .changed else { return }
        state = activeTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        activeTouches.subtract(touches)
        guard state == .began || state == .changed else { return }
        if activeTouches.isEmpty {
            state = .cancelled
        }
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        primaryTouch = nil
    }
}
