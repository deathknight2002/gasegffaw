//
//  Renderer+Passes.swift
//  Bornless Ritual — frame-graph assembly (RENDER_CONTRACT §2).
//
//  Role: `assemblePasses()` returns the ordered pass list the Renderer builds
//  (`rebuildPasses`) and encodes every frame, in the contract's row order:
//
//    0  SceneUpdate            — not a pass: `Renderer.sceneUpdater` (Render/Scene/SceneUpdater.swift),
//                                run by `draw(in:)` before the uniforms are built (row 0)
//    1  ProceduralTexturePass  — Render/Scene/ProceduralTexturePass.swift (generates once; a
//                                single persistent instance survives pass rebuilds so a
//                                resize / path switch / debug-view change never regenerates)
//    2  GBufferPass            — Render/Passes/GBufferPass.swift
//    3  DirectLightingPass     — Render/Passes/DirectLightingPass.swift
//    4  ReflectionPass         — Render/Passes/ReflectionPass.swift
//    5  DenoisePass            — Render/Passes/DenoisePass.swift
//    6  SSSPass                — Render/Passes/SSSPass.swift
//    7  FroxelPass             — Render/Passes/FroxelPass.swift
//    8  CompositePass          — Render/Passes/CompositePass.swift (writes HDRColor, clears Heat)
//    9  FlamePass              — Render/Passes/FlamePass.swift
//   10  SigilPass              — Render/Passes/SigilPass.swift
//   11  DaemonPass             — Render/Passes/DaemonPass.swift
//   12  UpscalePass            — Render/Passes/UpscalePass.swift (MetalFX when the variant asks
//                                for it and the device supports it, else TAA.metal)
//   13  PostPass               — Render/Passes/PostPass.swift (writes TextureIndexOutput, which
//                                `Renderer.encodeFinalBlits` copies into the drawable)
//   14  Readback               — not a pass: `Renderer.requestReadback`
//
//  Acceleration structures (RENDER_CONTRACT §5) are owned by the SceneUpdater
//  (Render/Scene/AccelerationStructures.swift) and are only built / refit / rebuilt
//  when the resolved render path is `.rt`; the tracing passes (rows 3, 4, 7) skip their
//  dispatch while `scene.instanceAS` is nil.
//
//  Every pass receives `pipelines` (PipelineCache, whose `variant` the Renderer sets for
//  the current render path / MetalFX / debug view before `build`) and, where needed,
//  `capabilities` and the daemon profile; `build(device:library:resources:renderPath:)`
//  is called by the Renderer once per variant and again on resize.
//

import Foundation
import Metal
import RitualCore

extension Renderer {
    /// The ordered frame graph for the current render path (RENDER_CONTRACT §2 rows 1–13).
    func assemblePasses() -> [RenderPass] {
        let proceduralTextures = persistentProceduralTexturePass()
        return [
            proceduralTextures,
            GBufferPass(pipelines: pipelines),
            DirectLightingPass(pipelines: pipelines),
            ReflectionPass(pipelines: pipelines),
            DenoisePass(pipelines: pipelines),
            SSSPass(pipelines: pipelines),
            FroxelPass(pipelines: pipelines),
            CompositePass(pipelines: pipelines),
            FlamePass(pipelines: pipelines),
            SigilPass(pipelines: pipelines, daemon: daemonProfile),
            DaemonPass(pipelines: pipelines),
            UpscalePass(pipelines: pipelines, capabilities: capabilities),
            PostPass(pipelines: pipelines),
        ]
    }

    /// The one `ProceduralTexturePass` of this renderer. It is created on the first
    /// assembly and reused by every later rebuild, so its generated atlases, blue noise
    /// and chalk mask (all static, seed-keyed) are encoded exactly once per seed.
    private func persistentProceduralTexturePass() -> ProceduralTexturePass {
        if let existing = proceduralTexturePass {
            return existing
        }
        let pass = ProceduralTexturePass(pipelines: pipelines, daemon: daemonProfile)
        proceduralTexturePass = pass
        return pass
    }
}
