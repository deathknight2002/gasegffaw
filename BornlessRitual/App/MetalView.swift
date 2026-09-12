//
//  MetalView.swift
//  Bornless Ritual — SwiftUI wrapper of the MTKView (RENDER_CONTRACT §7: MTKView with
//  preferredFramesPerSecond 60, isPaused false, enableSetNeedsDisplay false; the
//  foundation's output-format decision: `colorPixelFormat = .bgra8Unorm` with the sRGB
//  transfer applied in the tonemap kernel, `framebufferOnly = false` for the readback
//  blit; depth `.invalid` because the passes own their depth textures).
//
//  Role: creates the MTKView, constructs the `Renderer` (which configures the view and
//  becomes its delegate), attaches the `GestureController` from Interaction/ and hands
//  the renderer to `RendererHost`. The coordinator retains the renderer and the gesture
//  controller for the lifetime of the view.
//
//  Also installs `Renderer.sceneUpdater` (Render/Scene/SceneUpdater.swift, frame-graph
//  row 0: `init(device:scene:seed:daemon:) throws`); a failure there is reported to the
//  host and the app keeps running (black frames) so the panel can show the error.
//
//  Assumption about Interaction/GestureController.swift (another job):
//  `final class GestureController: NSObject` with
//  `init(renderer: Renderer, simulation: RitualSimulation, settings: SettingsModel)` and
//  `func attach(to view: UIView)`.
//

import SwiftUI
import UIKit
import Metal
import MetalKit
import RitualCore

/// Full-screen Metal view driven by `Renderer`.
@MainActor
struct MetalView: UIViewRepresentable {
    /// Owner of the renderer reference and UI snapshots.
    let host: RendererHost

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: CGRect.zero, device: MTLCreateSystemDefaultDevice())
        // The Renderer applies the same configuration in its initialiser; setting it here
        // keeps the view well-formed even if the renderer fails to construct.
        view.colorPixelFormat = RenderResources.outputPixelFormat
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.backgroundColor = UIColor.black
        view.isMultipleTouchEnabled = true
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.coordinator.start(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Nothing to push: the renderer reads `RenderSettingsStore` every frame and the
        // host forwards UI actions directly.
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.stop()
    }

    // MARK: Coordinator

    /// Retains the renderer and gesture controller; reports to the host.
    @MainActor
    final class Coordinator {
        /// The host that receives the renderer.
        let host: RendererHost
        /// The renderer (the MTKView's delegate), once created.
        private(set) var renderer: Renderer?
        /// Gesture recognisers attached to the MTKView.
        private(set) var gestures: GestureController?

        /// Creates the coordinator for `host`.
        init(host: RendererHost) {
            self.host = host
        }

        /// Creates the renderer for `view` and attaches gestures; failures go to the host.
        func start(view: MTKView) {
            guard renderer == nil else { return }
            do {
                let renderer = try Renderer(view: view, settings: host.settings, simulation: host.simulation, capture: nil)
                self.renderer = renderer
                do {
                    let updater = try SceneUpdater(device: renderer.device, scene: renderer.scene,
                                                   seed: host.launchConfig.seed, daemon: host.profile)
                    renderer.sceneUpdater = updater
                } catch {
                    host.sceneUpdaterFailed(error)
                }
                let gestures = GestureController(renderer: renderer, simulation: host.simulation, settings: host.settings)
                gestures.attach(to: view)
                self.gestures = gestures
                host.rendererDidStart(renderer)
            } catch {
                host.rendererFailed(error)
            }
        }

        /// Releases the renderer and gesture controller.
        func stop() {
            host.rendererDidStop()
            gestures = nil
            renderer = nil
        }
    }
}
