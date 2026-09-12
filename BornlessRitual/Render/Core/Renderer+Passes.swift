//
//  Renderer+Passes.swift
//  Bornless Ritual — frame-graph assembly (RENDER_CONTRACT §2).
//
//  Role: `assemblePasses()` returns the ordered pass list the Renderer builds and
//  encodes every frame. The integrator fills it in once the pass classes exist; until
//  then the list is empty and the Renderer still clears, updates the scene, uploads
//  uniforms and presents (a black frame), so the app runs end to end.
//
//  Intended order (RENDER_CONTRACT §2, row numbers):
//    0  SceneUpdate            — not a pass: `Renderer.sceneUpdater` (Render/Scene/SceneUpdater.swift)
//    1  ProceduralTexturePass  — Render/Passes/ProceduralTexturePass.swift (runs once, then no-op)
//    2  GBufferPass            — Render/Passes/GBufferPass.swift
//    3  DirectLightingPass     — Render/Passes/DirectLightingPass.swift
//    4  ReflectionPass         — Render/Passes/ReflectionPass.swift
//    5  DenoisePass            — Render/Passes/DenoisePass.swift
//    6  SSSPass                — Render/Passes/SSSPass.swift
//    7  FroxelPass             — Render/Passes/FroxelPass.swift
//    8  CompositePass          — Render/Passes/CompositePass.swift
//    9  FlamePass              — Render/Passes/FlamePass.swift
//   10  SigilPass              — Render/Passes/SigilPass.swift
//   11  DaemonPass             — Render/Passes/DaemonPass.swift
//   12  UpscalePass            — Render/Passes/Upscale.swift (MetalFX or TAA fallback)
//   13  PostPass               — Render/Passes/PostPass.swift (writes TextureIndexOutput)
//   14  Readback               — not a pass: handled by `Renderer.requestReadback`
//
//  Each pass receives `pipelines` (PipelineCache, variant already set for the current
//  render path / MetalFX / debug view) and `capabilities` through its initialiser if it
//  needs them; `build(device:library:resources:renderPath:)` is called by the Renderer.
//

import Foundation
import Metal

extension Renderer {
    /// The ordered frame graph for the current render path. Empty until the passes are
    /// integrated (see the header for the intended order).
    func assemblePasses() -> [RenderPass] {
        // Example once the passes exist:
        // return [
        //     ProceduralTexturePass(pipelines: pipelines),
        //     GBufferPass(pipelines: pipelines),
        //     DirectLightingPass(pipelines: pipelines),
        //     ReflectionPass(pipelines: pipelines),
        //     DenoisePass(pipelines: pipelines),
        //     SSSPass(pipelines: pipelines),
        //     FroxelPass(pipelines: pipelines),
        //     CompositePass(pipelines: pipelines),
        //     FlamePass(pipelines: pipelines),
        //     SigilPass(pipelines: pipelines),
        //     DaemonPass(pipelines: pipelines),
        //     UpscalePass(pipelines: pipelines, capabilities: capabilities),
        //     PostPass(pipelines: pipelines),
        // ]
        return []
    }
}
