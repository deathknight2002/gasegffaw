//
//  FroxelPass.swift
//  Bornless Ritual — volumetric smoke pass (RENDER_CONTRACT §2 row 7 "FroxelPass",
//  §1 `RenderPass`, §5 "useResources on all primitive AS in every compute encoder that
//  traces"; Shaders/Froxel.metal `froxel_density` / `froxel_lighting` /
//  `froxel_temporal` / `froxel_integrate`).
//
//  Role: one compute encoder with four serial dispatches over the 160×90×64 froxel
//  grid (8×8×1 threadgroups, `dispatchThreads`):
//    1. froxel_density   → FroxelLighting.a (density)
//    2. froxel_lighting  FroxelLighting.a → FroxelScatter (un-blended in-scatter; the
//                        scatter volume doubles as scratch until step 4 rewrites it)
//    3. froxel_temporal  FroxelScatter + FroxelHistory → FroxelLighting (rgb, a = σ_t)
//    4. froxel_integrate FroxelLighting → FroxelScatter (rgb S, a T per slice) — one
//                        thread per (x, y) column
//  RenderResources.swapHistory() exchanges FroxelLighting ↔ FroxelHistory at frame end
//  (the pair is in `RenderResources.historyPairs`), so the next frame's history is this
//  frame's blended lighting.
//
//  FroxelMatrices: FrameUniforms carries no inverse of the un-jittered view-projection
//  and FroxelParams has no matrix, so the pass uploads a small triple-buffered block
//  (`FroxelMatrices`, layout identical to the struct in Froxel.metal) at buffer index
//  20 — the first index above the ShaderTypes.h `BufferIndex` enum (recorded in the
//  caveats). Its `temporal.x` is the effective history blend: min(historyBlend,
//  n / (n + 1)) with n = frames since the last history reset, so the 16 warm-up frames
//  form an exact running mean before the 0.92 exponential window takes over (bit-
//  deterministic for a given reset point), and 0 on the frame after a reset.
//
//  Parameters come from SceneUpdater's `FroxelParams` slot (another job); the kernels
//  substitute the documented defaults when the block still reads as zeros, and this
//  pass reads `historyBlend` from the same slot on the CPU (falling back to 0.92).
//

import Foundation
import Metal
import simd
import os

// MARK: - FroxelMatrices

/// Per-frame matrices and temporal weights for Froxel.metal (mirror of its
/// `FroxelMatrices`: two column-major float4x4 followed by one float4, 144 bytes,
/// 16-byte aligned — `MemoryLayout<FroxelMatrices>.size` must equal 144).
struct FroxelMatrices {
    /// Un-jittered reversed-Z NDC → world (froxel centres must not follow the TAA jitter).
    var invUnjitteredViewProjection: float4x4
    /// World → un-jittered NDC (kept alongside for kernels that project).
    var unjitteredViewProjection: float4x4
    /// x: effective history blend, y: frames accumulated since reset, z: historyValid (0/1), w: unused.
    var temporal: SIMD4<Float>
}

// MARK: - FroxelPass

/// Density → lighting → temporal → integration over the froxel volume.
final class FroxelPass: RenderPass {

    // MARK: Configuration

    let name = "Froxel"

    /// Buffer index of `FroxelMatrices` (`BufferIndexFroxelMatrices` in Froxel.metal).
    static let matricesBufferIndex = 20
    /// Grid dimensions (RENDER_CONTRACT §2: 160×90×64).
    static let gridSize = RenderResources.froxelSize
    /// History blend used when FroxelParams has not been written (ShaderTypes.h: 0.92).
    static let defaultHistoryBlend: Float = 0.92
    /// Threadgroup shape for the volume and column dispatches.
    static let threadgroup = MTLSize(width: 8, height: 8, depth: 1)

    // MARK: State

    private let pipelines: PipelineCache
    private var densityPipeline: MTLComputePipelineState?
    private var lightingPipeline: MTLComputePipelineState?
    private var temporalPipeline: MTLComputePipelineState?
    private var integratePipeline: MTLComputePipelineState?
    private var matricesBuffer: MTLBuffer?
    private let matricesSlotStride: Int
    private var framesAccumulated = 0
    private var loggedMissingAS = false
    private var loggedNotBuilt = false
    private let log = Logger(subsystem: "BornlessRitual", category: "FroxelPass")

    // MARK: Init

    /// Creates the pass; pipelines and the matrices ring are built in `build`.
    init(pipelines: PipelineCache) {
        self.pipelines = pipelines
        let bytes = MemoryLayout<FroxelMatrices>.stride
        self.matricesSlotStride = (bytes + SceneResources.slotAlignment - 1) / SceneResources.slotAlignment * SceneResources.slotAlignment
    }

    // MARK: RenderPass

    func build(device: MTLDevice, library: MTLLibrary, resources: RenderResources, renderPath: RenderPath) throws {
        densityPipeline = try pipelines.compute("froxel_density")
        lightingPipeline = try pipelines.compute("froxel_lighting")
        temporalPipeline = try pipelines.compute("froxel_temporal")
        integratePipeline = try pipelines.compute("froxel_integrate")
        if matricesBuffer == nil {
            guard let buffer = device.makeBuffer(length: matricesSlotStride * SceneResources.inflightSlots, options: .storageModeShared) else {
                throw RenderResourceError.bufferCreationFailed("FroxelPass matrices")
            }
            buffer.label = "FroxelPass matrices"
            memset(buffer.contents(), 0, buffer.length)
            matricesBuffer = buffer
        }
        // A rebuild (path switch / resize) always follows a history reset.
        framesAccumulated = 0
        loggedMissingAS = false
        loggedNotBuilt = false
    }

    func encode(_ ctx: FrameContext) {
        guard let density = densityPipeline, let lighting = lightingPipeline,
              let temporal = temporalPipeline, let integrate = integratePipeline,
              let matricesBuffer = matricesBuffer else {
            if !loggedNotBuilt {
                log.error("FroxelPass.encode called before build succeeded")
                loggedNotBuilt = true
            }
            return
        }
        let scene = ctx.scene
        let resources = ctx.resources

        // The RT lighting kernel dereferences the instance AS; skip the pass until it exists
        // (Composite treats an untouched scatter volume as "no fog").
        var accelerationStructure: MTLAccelerationStructure?
        if ctx.renderPath == .rt {
            guard let instanceAS = scene.instanceAS else {
                if !loggedMissingAS {
                    log.warning("RT path active but no instance acceleration structure is available; skipping froxels")
                    loggedMissingAS = true
                }
                return
            }
            accelerationStructure = instanceAS
        }

        let matricesOffset = uploadMatrices(ctx: ctx, into: matricesBuffer)

        guard let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            log.error("Could not create the froxel compute encoder")
            return
        }
        encoder.label = "Froxel (\(ctx.renderPath.displayName))"

        // Bindings shared by all four kernels.
        encoder.setBuffer(ctx.uniformBuffer, offset: ctx.uniformOffset, index: BufferIndex.frameUniforms.rawValue)
        encoder.setBuffer(scene.buffer(for: .froxelParams), offset: scene.offset(for: .froxelParams), index: BufferIndex.froxelParams.rawValue)
        encoder.setBuffer(scene.buffer(for: .sigilParams), offset: scene.offset(for: .sigilParams), index: BufferIndex.sigilParams.rawValue)
        encoder.setBuffer(scene.buffer(for: .daemonParams), offset: scene.offset(for: .daemonParams), index: BufferIndex.daemonParams.rawValue)
        encoder.setBuffer(scene.buffer(for: .lights), offset: scene.offset(for: .lights), index: BufferIndex.lights.rawValue)
        encoder.setBuffer(matricesBuffer, offset: matricesOffset, index: FroxelPass.matricesBufferIndex)
        if let instanceAS = accelerationStructure {
            encoder.setAccelerationStructure(instanceAS, bufferIndex: BufferIndex.accel.rawValue)
            for primitiveAS in scene.primitiveAS {
                encoder.useResource(primitiveAS, usage: .read)
            }
        } else {
            encoder.setBuffer(scene.buffer(for: .sdfScene), offset: scene.offset(for: .sdfScene), index: BufferIndex.sdfScene.rawValue)
        }
        encoder.setTexture(resources.texture(.blueNoise), index: TextureIndex.blueNoise.rawValue)
        encoder.setTexture(resources.texture(.froxelLighting), index: TextureIndex.froxelLighting.rawValue)
        encoder.setTexture(resources.texture(.froxelScatter), index: TextureIndex.froxelScatter.rawValue)
        encoder.setTexture(resources.texture(.froxelHistory), index: TextureIndex.froxelHistory.rawValue)

        let volumeGrid = MTLSize(width: FroxelPass.gridSize.width, height: FroxelPass.gridSize.height, depth: FroxelPass.gridSize.depth)
        let columnGrid = MTLSize(width: FroxelPass.gridSize.width, height: FroxelPass.gridSize.height, depth: 1)

        // 1. Density → FroxelLighting.a.
        encoder.setComputePipelineState(density)
        encoder.dispatchThreads(volumeGrid, threadsPerThreadgroup: FroxelPass.threadgroup)

        // 2. Lighting: FroxelLighting.a → FroxelScatter (scratch). Serial dispatches in
        //    one encoder observe the previous dispatch's writes.
        encoder.setComputePipelineState(lighting)
        encoder.dispatchThreads(volumeGrid, threadsPerThreadgroup: FroxelPass.threadgroup)

        // 3. Temporal: FroxelScatter + FroxelHistory → FroxelLighting.
        encoder.setComputePipelineState(temporal)
        encoder.dispatchThreads(volumeGrid, threadsPerThreadgroup: FroxelPass.threadgroup)

        // 4. Integration: FroxelLighting → FroxelScatter, one thread per column.
        encoder.setComputePipelineState(integrate)
        encoder.dispatchThreads(columnGrid, threadsPerThreadgroup: FroxelPass.threadgroup)

        encoder.endEncoding()
    }

    // MARK: - Helpers

    /// Writes this frame's `FroxelMatrices` into the scene slot's ring entry and returns
    /// its byte offset. Also advances the temporal bookkeeping.
    private func uploadMatrices(ctx: FrameContext, into buffer: MTLBuffer) -> Int {
        if !ctx.historyValid {
            framesAccumulated = 0
        }
        let configuredBlend = configuredHistoryBlend(scene: ctx.scene)
        let runningMean = Float(framesAccumulated) / Float(framesAccumulated + 1)
        let effectiveBlend: Float = ctx.historyValid ? min(configuredBlend, runningMean) : 0
        framesAccumulated = min(framesAccumulated + 1, 1_000_000)

        let unjittered = ctx.uniforms.unjitteredViewProjection
        let matrices = FroxelMatrices(invUnjitteredViewProjection: unjittered.inverse,
                                      unjitteredViewProjection: unjittered,
                                      temporal: SIMD4<Float>(effectiveBlend, Float(framesAccumulated), ctx.historyValid ? 1 : 0, 0))

        let slotOffset = (ctx.scene.slot % SceneResources.inflightSlots) * matricesSlotStride
        let destination = buffer.contents().advanced(by: slotOffset)
        withUnsafeBytes(of: matrices) { raw in
            if let source = raw.baseAddress {
                destination.copyMemory(from: source, byteCount: MemoryLayout<FroxelMatrices>.size)
            }
        }
        return slotOffset
    }

    /// `FroxelParams.historyBlend` from the scene's current slot (shared storage written
    /// by SceneUpdater earlier this frame), or the default when the block is unwritten.
    private func configuredHistoryBlend(scene: SceneResources) -> Float {
        let base = scene.buffer(for: .froxelParams).contents().advanced(by: scene.offset(for: .froxelParams))
        let params = base.load(as: FroxelParams.self)
        if params.farZ > 0 && params.historyBlend > 0 {
            return min(max(params.historyBlend, 0), 1)
        }
        return FroxelPass.defaultHistoryBlend
    }
}
