# Render contract — frame graph, resources, bindings, shader ownership

Read with `Shaders/ShaderTypes.h` (binding indices, struct layouts, constants). All passes
run inside one `MTLCommandBuffer` per frame in the order below. Internal resolution
`R = round(native × renderScale)`; froxel grid 160×90×64. Reversed-Z depth. Linear HDR
everywhere until tonemap. Colour space: linear Rec.709 in, `bgra8Unorm_srgb` drawable
(`MTKView.colorPixelFormat = .bgra8Unorm_srgb`). MSL version Metal 3.1 (iOS 17).

## 1. Swift-side contracts (`BornlessRitual/Render`)

```swift
/// Per-frame immutable context handed to every pass.
struct FrameContext {
    let commandBuffer: MTLCommandBuffer
    let uniforms: FrameUniforms                 // also uploaded to `uniformBuffer` (triple-buffered ring)
    let uniformBuffer: MTLBuffer; let uniformOffset: Int
    let resources: RenderResources               // textures for the current sizes (see §2)
    let scene: SceneResources                    // buffers: vertices, indices, instances, materials, geometry ranges, lights, flames, SDF scene, accel structures
    let renderPath: RenderPath                   // .rt or .fallback
    let frameIndex: UInt32; let isWarmup: Bool; let historyValid: Bool
}
enum RenderPath: Int { case rt = 0, fallback = 1 }
protocol RenderPass: AnyObject {
    var name: String { get }
    /// Called once per (device, renderPath) and again on resize; build pipelines here (function constants: RENDER_PATH etc.).
    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws
    func encode(_ ctx: FrameContext)
}
final class RenderResources {           // owns every texture in TextureIndex (§2), created for (renderSize, outputSize); `swapHistory()` at frame end
    func texture(_ index: TextureIndex) -> MTLTexture
    func resize(renderSize: MTLSize, outputSize: MTLSize)
    func swapHistory()                  // current↔history for diffuse/specular/reflection/moments/depth/normal/froxel/HDR
    func resetHistory()                 // clears history + sets historyValid = false
}
final class Renderer: NSObject, MTKViewDelegate {
    init(view: MTKView, settings: SettingsModel, simulation: RitualSimulation, capture: CaptureHarness?)
    var renderPath: RenderPath { get }          // resolved from settings (.auto → .rt if device.supportsRaytracing && supportsFamily(.apple9) else .fallback)
    func setRenderPath(_ choice: RenderPathChoice)   // rebuilds passes; safe to call from the main thread between frames
    var camera: OrbitCamera
    func seek(toTick:)                           // sim.seek + resetHistory + schedules 16 warm-up frames
    var stats: FrameStats                        // fps, cpuMs, gpuMs, p1Low, thermal — published to the debug panel at 4 Hz
    func requestReadback(_ completion: @escaping (CGImage) -> Void)   // after the next presented frame (native res)
}
final class PipelineCache { func compute(_ fn: String, constants: MTLFunctionConstantValues?) throws -> MTLComputePipelineState; func render(_ desc: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState }
struct OrbitCamera { var target: SIMD3<Float>; var yaw, pitch, distance: Float; var fovY: Float = 50°; func viewMatrix() ; func projection(aspect:jitter:) (reversed-Z, infinite far not used: far 30); var forwardYawDegrees: Float; static func preset(_ p: CameraPreset) -> OrbitCamera; mutating func orbit(dx:dy:), pan(dx:dy:), zoom(scale:) }
final class SettingsModel: ObservableObject   // all sliders/toggles from ARCHITECTURE §8 as @Published; `applyLaunchConfig(CaptureConfig)`
```
Function constants (shared by all shaders, indices in `Common.h`): `0 kRenderPath (uint)`,
`1 kMetalFX (bool)`, `2 kDebugView (uint)`. Pipelines are built per render path.

## 2. Frame graph (order, encoder type, inputs → outputs)

| # | Pass (Swift file / .metal) | Type | Inputs → outputs |
|---|---|---|---|
| 0 | `SceneUpdate` (Render/Scene/SceneUpdater.swift) | CPU + blit | sim state → instances (sorcerer procedural pose, sigil/daemon params), lights (flames with flicker), ring history entry for this tick, flames, SDF scene; RT: refit sorcerer primitive AS, rebuild instance AS |
| 1 | `ProceduralTexturePass` (once at startup; `ProceduralTextures.metal`) | compute | seed → albedo/normal atlases (7 layers, 1024², mipmapped by blit), blue noise 128², chalk mask 2048² (circle + name letters rasterised as SDF text? use simple stroked glyph paths from `SigilPath`/Hebrew letter strokes table) |
| 2 | `GBufferPass` (`GBuffer.metal`) | render | instances → albedo, normal+rough, motion, emissive+metallic, depth. Vertex: jittered VP, prev VP for motion. Fragment: samples atlases (triplanar for stone), chalk decal on floor, wax/skin flags to albedo.a |
| 3 | `DirectLightingPass` (`Lighting.metal` + `RT.h` / `SDF.h`) | compute | G-buffer, lights, blue noise → DirectDiffuse, DirectSpecular (noisy, 1 shadow ray per pixel: pick light by importance (radiance/d²) with a hash-driven CDF, sample a point on the sphere/ring, trace visibility; RT: `intersector<triangle_data, instancing>` any-hit; fallback: SDF cone-march soft shadow), plus unshadowed ambient term × `ambient` |
| 4 | `ReflectionPass` (`Reflection.metal`) | compute | glossy pixels (MATERIAL_FLAG_GLOSSY: floor, altar top): 1 GGX-sampled ray; RT: closest-hit → reconstruct hit vertex (GeometryRange + Vertex buffer) → material → shade with the 2 brightest lights (no secondary shadow); miss → chamber ambient; fallback: SDF sphere-march (64 steps, 8 m) → material id → same shading. Output rgb + hit distance |
| 5 | `DenoisePass` (`Denoise.metal`) | compute | temporal reprojection (motion vectors, depth/normal rejection, history length, moments/variance) for diffuse, specular, reflection; then 3 à-trous iterations (5×5, edge-stopping on depth, normal, luminance variance). Warm-up frames accumulate but never reproject with motion (camera static) |
| 6 | `SSSPass` (`SSS.metal`) | compute | denoised diffuse on SSS pixels → separable Burley-profile blur in screen space (radius from `sssRadiusMm` and depth), wax translucency: adds flame-through-wax term for pixels within 0.06 m below a lit flame (uses FlameData) |
| 7 | `FroxelPass` (`Froxel.metal`) | compute ×4 | (a) density: procedural incense plume from censer (buoyant column, curl noise advected by time), sigil smoke (∝ sigilErupt), daemon condensation smoke (∝ manifest·(1−manifest)), global haze 0.02 × smokeDensity; (b) lighting: per froxel, all lights, HG phase g=0.55, visibility: RT 1 shadow ray per froxel per frame (jittered), fallback SDF march (16 steps); (c) temporal blend with history (reprojected by prev VP, blend 0.92, rejected outside frustum); (d) front-to-back integration along Z → FroxelScatter (rgb, transmittance) |
| 8 | `CompositePass` (`Composite.metal`) | compute | albedo × (diffuse+SSS) + specular + reflection×F + emissive → apply froxel (colour × T + S) → HDRColor; also clears Heat |
| 9 | `FlamePass` (`Flame.metal`) | render (blend add) | FlameData → camera-facing quads ray-marching a procedural flame density (teardrop + flicker noise), blackbody emission (Planck → linear RGB via CIE fit) tinted by elemental colour, depth-tested; writes Heat |
| 10 | `SigilPass` (`Sigil.metal`) | compute + render | (a) ember kernel over grid (RING_HISTORY_TICKS × EMBERS_PER_TICK_MAX): for spawn tick s in [tick−300, tick], ember index i live iff `Hash.unit(seed, s, i, 7) < rate(s)/EMBERS_PER_TICK_MAX·(1/120)`; closed form position (ARCHITECTURE §6), appends `EmberInstance` (atomic counter) and indirect draw args; (b) draw filament rune rings (SigilFilamentVertex line strips, rotated per ring by RingHistory[tick].angle, expanded to quads, glow falloff, additive) and embers (instanced quads, additive, soft depth); writes Heat |
| 11 | `DaemonPass` (`Daemon.metal`) | render (full-screen bounded by boundsMin/Max, blend) | ray-march the daemon SDF (leonine: head with mane as noise-displaced spheres, torso, forelimbs; parameters from DaemonParams; condensation: density = smoothstep(threshold(manifest), noise)) with emissive fire shading (palette by density gradient, blackbody-ish) and smoke absorption; depth-test vs G-buffer depth; writes Heat |
| 12 | `UpscalePass` (`Upscale.swift`, `TAA.metal`) | MetalFX or compute | MetalFX temporal (color HDRColor, depth, motion; jitter from uniforms; reset when !historyValid) → Upscaled; fallback custom TAA-upsample (5-tap Catmull-Rom history, YCoCg clamp) when `MTLFXTemporalScalerDescriptor.supportsDevice` is false |
| 13 | `PostPass` (`Post.metal`) | compute ×3 | bloom (threshold, 5-level downsample/upsample, tent), heat shimmer (Heat upsampled → gradient-noise UV offset), exposure (EV) + ACES fitted tonemap + blue-noise dither → Output (bgra8Unorm_srgb) ; blit Output → drawable |
| 14 | `Readback` (capture) | blit | Output → shared MTLBuffer → CGImage → PNG (background queue) |

Every pass reads uniforms from `BufferIndexFrameUniforms` at `uniformOffset`. Compute
threadgroups 8×8 (16×16 for post). All textures are `.private` except readback.

## 3. Motion vectors & jitter
Halton(2,3) 16-sample jitter in pixels applied to the projection (`jitter` in NDC = 2·px/R).
Motion = (prevUV − curUV) × R in pixels (MetalFX `motionVectorScaleX/Y = 1` when vectors
are in render-resolution pixels; use the convention "motion points from current to previous").
Animated instances write motion from `prevModel`. Embers/flames/daemon: motion 0 (they are
composited after upscale input? NO — they render into HDRColor before upscale, so they get
temporal treatment; they are jittered consistently and this is acceptable).

## 4. Fallback SDF scene (`SDF.h`)
`sdScene(p) -> (distance, materialIndex)`: room (inverted box), floor plane, altar box (rounded),
candle cylinders + stands, sorcerer = 7 capsules (torso, head, 2 upper arms, 2 forearms, hood
sphere) updated per tick, censer sphere. Soft shadow: sphere-tracing toward the light with
penumbra estimate `min(1, k·h/t)` (k from light radius / distance, i.e. a physically-motivated
cone); reflections: sphere march 64 steps, 8 m max. Everything mirrors the triangle scene.

## 5. RT scene (`RT.h`, `Render/Scene/AccelerationStructures.swift`)
One primitive AS per mesh (static meshes built once; sorcerer refit each tick via
`MTLAccelerationStructureCommandEncoder.refit` with the updated vertex buffer);
one instance AS rebuilt every frame (cheap). `useResources` on all primitive AS in every
compute encoder that traces. Shadow rays: `accept_any_intersection(true)`, `min_distance`
1 mm offset along the normal. Shader: `#include <metal_raytracing>`, `using namespace metal::raytracing;`.
Emissive flame proxies are not in the AS (MATERIAL_FLAG_NO_SHADOW instances are excluded).

## 6. Shader files and owners
`Common.h` (hash_u32 bit-identical to Swift, blackbody, GGX/Smith/Fresnel, HG phase, curl noise,
value/simplex noise, Halton, reversed-Z helpers, function constant indices),
`SDF.h`, `RT.h`, `GBuffer.metal`, `Lighting.metal`, `Reflection.metal`, `Denoise.metal`,
`SSS.metal`, `Froxel.metal`, `Composite.metal`, `Flame.metal`, `Sigil.metal`, `Daemon.metal`,
`TAA.metal`, `Post.metal`, `ProceduralTextures.metal`. Every kernel name is prefixed by its
pass (`lighting_direct`, `froxel_density`, …). All .metal files must pass `Tools/metal-lint`.

## 7. Threading & timing
`MTKView` with `preferredFramesPerSecond = 60`, `isPaused = false`, `enableSetNeedsDisplay = false`.
`draw(in:)` → sim advance (§ARCHITECTURE 5) → passes → present. Triple-buffered uniforms
and instance buffers guarded by a `DispatchSemaphore(3)`. GPU time from
`commandBuffer.gpuStartTime/gpuEndTime`; CPU time measured around encoding. Thermal from
`ProcessInfo.processInfo.thermalState` polled each second. Capture runs on the same loop;
PNG encoding on a background queue with backpressure (clip mode uses a bounded queue).
