//
//  GestureController.swift
//  Bornless Ritual — touch input → `RitualInput` and camera control (ARCHITECTURE §3
//  mini-games: hold to chant, face a quarter and trace, rhythm taps, flick to spin; §2
//  "Facing a quarter" via the camera's forward yaw; §5 inputs stamped with the current
//  120 Hz tick; RENDER_CONTRACT §1 `OrbitCamera.orbit/pan/zoom`; docs/CRITIC.md
//  "Interaction feel": tap latency ≤ 2 frames, gesture response for trace, flick, orbit,
//  pinch, pan).
//
//  Role: owns the gesture recognisers attached to the MTKView and translates them into
//  simulation inputs and camera moves. Every input is applied on the touch-down callback
//  (`TouchDownGestureRecognizer`) or the pan's `.changed`/`.ended`, stamped with
//  `renderer.currentTick`, so it is consumed by the very next simulated tick.
//
//  Recognisers (all allowed simultaneously):
//    • press  — TouchDownGestureRecognizer: oath → holdBegin/holdEnd; spirit → tap;
//               quarter stage while facing → first tracePoint at touch-down and traceEnd
//               on lift; also decides how the 1-finger drag behaves (trace / flick / orbit).
//    • drag   — 1-finger UIPanGestureRecognizer: trace points (quarter stage, facing),
//               flick on release (sigil spin / manifestation when the drag started on the
//               sigil: velocity in points/s ÷ 300 rotated into the ring's tangential
//               frame, ring = nearest ring under the finger), otherwise orbit yaw/pitch.
//    • pan    — 2-finger UIPanGestureRecognizer: moves the orbit target.
//    • pinch  — UIPinchGestureRecognizer: zoom.
//  After every orbit the camera's forward yaw is pushed as `.cameraYaw` when it moved
//  by more than 1° (the Renderer also feeds it per frame; duplicates are harmless).
//
//  The controller also owns the feedback layer (haptics + narration) through a
//  `RitualFeedbackMonitor`, started in `attach(to:)`, because MetalView creates only
//  this object and nothing else in the app drives `HapticsEngine` / `Narration`.
//
//  Main-actor: UIKit callbacks and the MTKView draw loop share the main thread, so the
//  simulation and `renderer.camera` are only touched between frames.
//

import Foundation
import UIKit
import simd
import RitualCore

/// Translates touches into ritual inputs and camera moves.
@MainActor
final class GestureController: NSObject, UIGestureRecognizerDelegate {

    // MARK: Tuning

    /// Orbit yaw / pitch change per point of 1-finger drag (radians).
    static let orbitRadiansPerPoint: Float = 0.005
    /// Yaw change (degrees) that triggers a `.cameraYaw` input.
    static let yawPushThresholdDegrees: Float = 1.0
    /// Flicks with a smaller tangential speed (normalised units/s) are ignored.
    static let minimumFlickSpeed: Double = 0.05

    // MARK: Collaborators

    /// The renderer (camera owner, tick source).
    let renderer: Renderer
    /// The simulation that consumes the inputs.
    let simulation: RitualSimulation
    /// Settings (autopilot gate for the yaw feed, haptics / narration toggles).
    let settings: SettingsModel
    /// Haptic feedback (driven by the feedback monitor).
    let haptics: HapticsEngine
    /// Spoken narration (driven by the feedback monitor).
    let narration: Narration
    /// Diffs the simulation state per display frame and dispatches events.
    let feedback: RitualFeedbackMonitor

    // MARK: Recognisers

    private(set) weak var view: UIView?
    private(set) var pressRecognizer: TouchDownGestureRecognizer?
    private(set) var dragRecognizer: UIPanGestureRecognizer?
    private(set) var twoFingerPanRecognizer: UIPanGestureRecognizer?
    private(set) var pinchRecognizer: UIPinchGestureRecognizer?

    // MARK: Gesture state

    /// What the 1-finger drag does for the current touch sequence (decided at touch-down).
    enum DragMode: Equatable {
        case orbit
        case trace
        case flick
    }

    private var dragMode: DragMode = .orbit
    private var lastDragTranslation = CGPoint.zero
    private var lastPanTranslation = CGPoint.zero
    private var holdActive = false
    private var traceActive = false
    private var lastYawPushed: Float?

    // MARK: Init

    /// Creates the controller.
    ///
    /// - Parameters:
    ///   - renderer: Camera owner and tick source.
    ///   - simulation: The ritual simulation (render-thread owned; touched between frames).
    ///   - settings: The settings model.
    ///   - text: Ritual text for the narration (loaded from the main bundle by default).
    init(renderer: Renderer, simulation: RitualSimulation, settings: SettingsModel,
         text: RitualTextProvider = RitualTextProvider(bundle: Bundle.main)) {
        self.renderer = renderer
        self.simulation = simulation
        self.settings = settings
        self.haptics = HapticsEngine(settingsStore: settings.renderSettingsStore)
        self.narration = Narration(text: text)
        self.feedback = RitualFeedbackMonitor(renderer: renderer, simulation: simulation, settings: settings,
                                              haptics: haptics, narration: narration)
        super.init()
    }

    // MARK: Attach / detach

    /// Installs the recognisers on `view` and starts the feedback monitor.
    func attach(to view: UIView) {
        detach()
        self.view = view
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true

        let press = TouchDownGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.delegate = self
        view.addGestureRecognizer(press)
        pressRecognizer = press

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        view.addGestureRecognizer(drag)
        dragRecognizer = drag

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        view.addGestureRecognizer(pan)
        twoFingerPanRecognizer = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        if haptics.isEnabled {
            haptics.prepare()
        }
        feedback.start()
    }

    /// Removes the recognisers and stops the feedback monitor.
    func detach() {
        feedback.stop()
        narration.stop()
        if let view = view {
            for recognizer in [pressRecognizer, dragRecognizer, twoFingerPanRecognizer, pinchRecognizer].compactMap({ $0 }) {
                view.removeGestureRecognizer(recognizer)
            }
        }
        pressRecognizer = nil
        dragRecognizer = nil
        twoFingerPanRecognizer = nil
        pinchRecognizer = nil
        view = nil
        holdActive = false
        traceActive = false
    }

    // MARK: Helpers

    /// A picker for the current camera and view size.
    private func makePicker(in view: UIView) -> SigilPicker {
        let size = view.bounds.size
        return SigilPicker(camera: renderer.camera,
                           viewSize: SIMD2<Float>(Float(size.width), Float(size.height)))
    }

    /// View point → normalised [0, 1]² (x right, y down), clamped.
    static func normalisedPoint(_ point: CGPoint, in bounds: CGRect) -> RVec2 {
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        let x = width > 0 ? Double(point.x) / width : 0
        let y = height > 0 ? Double(point.y) / height : 0
        return RVec2(ScalarMath.clamp(x, 0, 1), ScalarMath.clamp(y, 0, 1))
    }

    /// Applies an input stamped with the current tick.
    private func apply(_ kind: InputKind) {
        simulation.apply(RitualInput(tick: renderer.currentTick, kind: kind))
    }

    /// Whether the current stage is a quarter stage whose gate is currently satisfied.
    private var isTracingAllowed: Bool {
        let state = simulation.state
        return state.stage.quarter != nil && state.facingQuarter
    }

    /// Decides what a 1-finger drag starting at `point` does.
    func resolveDragMode(forTouchAt point: CGPoint, in view: UIView) -> DragMode {
        let stage = simulation.state.stage
        if isTracingAllowed {
            return .trace
        }
        if stage == .sigilSpin || stage == .manifestation {
            let picker = makePicker(in: view)
            if picker.planeHit(at: SIMD2<Float>(Float(point.x), Float(point.y)))?.onSigil == true {
                return .flick
            }
        }
        return .orbit
    }

    /// Pushes `.cameraYaw` when the camera's forward yaw moved by more than 1°.
    func pushCameraYawIfNeeded() {
        guard !settings.autopilotEnabled else { return }
        let yaw = renderer.camera.forwardYawDegrees
        if let last = lastYawPushed, abs(Float.wrapDegrees180(yaw - last)) <= GestureController.yawPushThresholdDegrees {
            return
        }
        apply(.cameraYaw(Double(yaw)))
        lastYawPushed = yaw
    }

    // MARK: Press (touch-down / lift)

    @objc private func handlePress(_ recognizer: TouchDownGestureRecognizer) {
        guard let view = view else { return }
        switch recognizer.state {
        case .began:
            let point = recognizer.primaryLocation(in: view)
            dragMode = resolveDragMode(forTouchAt: point, in: view)
            lastDragTranslation = .zero
            switch simulation.state.stage {
            case .oath:
                holdActive = true
                apply(.holdBegin)
            case .spirit:
                apply(.tap)
            case .air, .fire, .water, .earth:
                if dragMode == .trace {
                    traceActive = true
                    apply(.tracePoint(GestureController.normalisedPoint(point, in: view.bounds)))
                }
            case .sigilSpin, .manifestation:
                break
            }
        case .ended, .cancelled, .failed:
            if holdActive {
                holdActive = false
                apply(.holdEnd)
            }
            if traceActive {
                traceActive = false
                apply(.traceEnd)
            }
        default:
            break
        }
    }

    // MARK: 1-finger drag (trace / flick / orbit)

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let view = view else { return }
        switch recognizer.state {
        case .began:
            lastDragTranslation = .zero
            if pressRecognizer?.activeTouchCount == 0 {
                // The press recogniser did not see this sequence; decide now.
                dragMode = resolveDragMode(forTouchAt: recognizer.location(in: view), in: view)
            }
        case .changed:
            let translation = recognizer.translation(in: view)
            let delta = CGPoint(x: translation.x - lastDragTranslation.x, y: translation.y - lastDragTranslation.y)
            lastDragTranslation = translation
            switch dragMode {
            case .trace:
                guard traceActive || isTracingAllowed else { return }
                traceActive = true
                apply(.tracePoint(GestureController.normalisedPoint(recognizer.location(in: view), in: view.bounds)))
            case .orbit:
                let scale = GestureController.orbitRadiansPerPoint
                renderer.camera.orbit(dx: -Float(delta.x) * scale, dy: Float(delta.y) * scale)
                pushCameraYawIfNeeded()
            case .flick:
                break
            }
        case .ended:
            if dragMode == .flick {
                let velocity = recognizer.velocity(in: view)
                let location = recognizer.location(in: view)
                let picker = makePicker(in: view)
                let flick = picker.flickInput(swipe: SIMD2<Float>(Float(velocity.x), Float(velocity.y)),
                                              at: SIMD2<Float>(Float(location.x), Float(location.y)))
                if abs(flick.velocity.x) >= GestureController.minimumFlickSpeed {
                    apply(.flick(velocity: flick.velocity, ring: flick.ring))
                }
            }
        default:
            break
        }
    }

    // MARK: 2-finger pan (orbit target)

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = view else { return }
        switch recognizer.state {
        case .began:
            lastPanTranslation = .zero
        case .changed:
            let translation = recognizer.translation(in: view)
            let delta = CGPoint(x: translation.x - lastPanTranslation.x, y: translation.y - lastPanTranslation.y)
            lastPanTranslation = translation
            let metresPerPoint = makePicker(in: view).metresPerPointAtTarget
            // Dragging right moves the scene right, i.e. the target left; dragging down
            // moves the scene down, i.e. the target up.
            renderer.camera.pan(dx: -Float(delta.x) * metresPerPoint, dy: Float(delta.y) * metresPerPoint)
        default:
            break
        }
    }

    // MARK: Pinch (zoom)

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            renderer.camera.zoom(scale: Float(recognizer.scale))
            recognizer.scale = 1
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Every recogniser may run alongside every other one (the press recogniser never
    /// consumes touches; pinch and 2-finger pan combine naturally).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
