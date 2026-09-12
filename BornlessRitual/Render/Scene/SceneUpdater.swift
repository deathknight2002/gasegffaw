//
//  SceneUpdater.swift
//  Bornless Ritual — per-frame scene update, frame-graph row 0 (RENDER_CONTRACT §2 row 0
//  "SceneUpdate: sim state → instances (sorcerer procedural pose, sigil/daemon params),
//  lights (flames with flicker), ring history entry for this tick, flames, SDF scene;
//  RT: refit sorcerer primitive AS, rebuild instance AS"; §4 fallback SDF mirror;
//  §5 RT scene; Renderer.swift `SceneUpdating`; ARCHITECTURE §2 layout, §3 stages,
//  §5 "pure functions of (tick, seed, sim state)", §6 determinism).
//
//  Role: `SceneUpdater` owns the built scene (SceneBuilder), the sorcerer model, the
//  sigil filament geometry and the acceleration structures, and on every frame writes
//  the current slot of every triple-buffered scene buffer from `(tick, state, settings)`:
//    • sorcerer vertices (cloth + skin) rebuilt from the pose and rewritten into their
//      dynamic regions; instances = static list + the two sorcerer instances;
//    • lights: 4 quarter flames (LIGHT_TYPE_SPHERE r 0.012, elemental colour ×
//      blackbody(T) × intensity × flicker, ignition ramp from CandleState.intensity),
//      2 altar candles (always lit, candleWarmthK), the sigil ring light (LIGHT_TYPE_RING,
//      ring 0 radius, intensity ∝ sigilErupt × (0.6 + 0.4·spinEnergy/2)), the daemon
//      glow (∝ manifestT) and one LIGHT_TYPE_AMBIENT entry;
//    • FlameData for every lit candle; RingHistory entry for this tick (gaps between
//      rendered ticks are interpolated; seeks are back-filled by re-simulation);
//    • SigilParams, DaemonParams, FroxelParams, PostParams;
//    • the SDF mirror (static primitives + 7 sorcerer capsules from the pose);
//    • RT path: primitive AS built lazily, sorcerer AS refit, instance AS rebuilt.
//
//  Radiometric convention (LightShading.h): `radiance × intensity` is the radiant
//  intensity; the shader applies the blackbody tint when `temperatureK > 0`, so flame
//  radiance here is the elemental colour normalised so that colour × blackbody has unit
//  luminance. The ambient entry is NOT pre-scaled by the slider — `ambient_radiance`
//  multiplies the sum of ambient entries by `FrameUniforms.ambient`.
//
//  Flicker: 1 + 0.12·fbm(t·3.1 + i) from a seed-keyed 1-D value-noise fbm (`FlickerNoise`),
//  a pure function of (tick, seed, candle index).
//

import Foundation
import Metal
import simd
import RitualCore
import os

// MARK: - Deterministic flicker noise

/// Seed-keyed 1-D value noise / fbm for flame flicker (pure function of its inputs).
enum FlickerNoise {
    /// 1-D value noise in [−1, 1] at `x` (Hermite interpolation of hashed lattice values).
    static func value(_ x: Float, seed: UInt64, channel: UInt32, octave: UInt32) -> Float {
        let cell = floor(x)
        let fraction = x - cell
        let index = UInt32(truncatingIfNeeded: Int(cell))
        let a = Float(Hash.unit(seed, index, channel, 0x11CE_0000 &+ octave))
        let b = Float(Hash.unit(seed, index &+ 1, channel, 0x11CE_0000 &+ octave))
        let t = fraction * fraction * (3 - 2 * fraction)
        return (a + (b - a) * t) * 2 - 1
    }

    /// Three-octave fbm of `value`, normalised to [−1, 1].
    static func fbm(_ x: Float, seed: UInt64, channel: UInt32) -> Float {
        var sum: Float = 0
        var amplitude: Float = 0.5
        var norm: Float = 0
        var frequency: Float = 1
        for octave in 0..<3 {
            sum += amplitude * value(x * frequency + Float(octave) * 17.31, seed: seed, channel: channel, octave: UInt32(octave))
            norm += amplitude
            frequency *= 2.03
            amplitude *= 0.5
        }
        return norm > 0 ? sum / norm : 0
    }

    /// Flame flicker multiplier `1 + 0.12·fbm(t·3.1 + i)` for candle `index` at ritual time `time`.
    static func flicker(time: Float, index: Int, seed: UInt64) -> Float {
        1 + 0.12 * fbm(time * 3.1 + Float(index) * 7.37, seed: seed, channel: UInt32(max(index, 0)))
    }

    /// Maps a flicker multiplier (0.88…1.12) to the 0…1 `FlameData.flicker` range.
    static func normalised(_ flicker: Float) -> Float {
        ScalarMath.clamp((flicker - 0.88) / 0.24, 0, 1)
    }
}

// MARK: - SceneUpdater

/// Frame-graph row 0: fills the scene buffers for the current tick.
final class SceneUpdater: SceneUpdating {

    // MARK: Tunables (linear radiometric units, see the header)

    /// Radiant intensity of a quarter flame at flameIntensity 1, fully lit.
    static let quarterFlameIntensity: Float = 2.4
    /// Radiant intensity of an altar candle at flameIntensity 1.
    static let altarFlameIntensity: Float = 1.8
    /// Quarter flame light radius (m).
    static let quarterFlameRadius: Float = 0.012
    /// Altar flame light radius (m).
    static let altarFlameRadius: Float = 0.010
    /// Peak radiant intensity of the sigil ring light.
    static let sigilLightIntensity: Float = 8.0
    /// Peak radiant intensity of the daemon glow.
    static let daemonLightIntensity: Float = 14.0
    /// Ambient entry radiance (before the `ambient` slider, applied in-shader).
    static let ambientLightRadiance = SIMD3<Float>(0.030, 0.027, 0.024)
    /// Candle flame height / width (m).
    static let flameHeight: Float = 0.035
    static let flameWidth: Float = 0.014
    /// Sigil filament colours and width (SigilParams).
    static let sigilCoreColor = SIMD3<Float>(1.0, 0.92, 0.75)
    static let sigilEdgeColor = SIMD3<Float>(1.0, 0.45, 0.10)
    static let sigilFilamentWidth: Float = 0.006
    /// Froxel volume parameters (RENDER_CONTRACT §2 row 7).
    static let froxelNearZ: Float = 0.1
    static let froxelAnisotropy: Float = 0.55
    static let froxelAmbientScatter: Float = 0.02
    static let froxelHistoryBlend: Float = 0.92
    static let froxelExtinctionScale: Float = 1.0
    static let froxelWindDirection = SIMD3<Float>(0.35, 0.05, -0.2)
    static let froxelWindSpeed: Float = 0.06
    /// Post parameters.
    static let bloomThreshold: Float = 1.0
    static let vignette: Float = 0.25
    static let shimmerPixelsAtFullStrength: Float = 8.0
    /// Daemon animation.
    static let daemonBreathHz: Float = 0.12
    static let daemonHeadYawAmplitude: Float = 0.35
    static let daemonHeadYawHz: Float = 0.045

    // MARK: State

    /// Device (for the acceleration structures).
    let device: MTLDevice
    /// Simulation / render seed.
    let seed: UInt64
    /// The daemon whose name, sigil and palette the scene shows.
    let daemon: DaemonProfile
    /// Meshes, static instances and static SDF primitives.
    let built: BuiltScene
    /// Device capabilities (mirrors the Renderer's render-path resolution).
    let capabilities: CapabilityProbe
    /// Native output size for `PostParams.outputSize`; set by the integrator (0 = unknown,
    /// PostPass should then fall back to `FrameUniforms.outputSize`).
    var outputSize = SIMD2<Float>(0, 0)
    /// Pose used for the most recent frame (debug panel).
    private(set) var lastPose = SorcererPose.rest
    /// Lights written for the most recent frame.
    private(set) var lastLightCount = 0

    private let acceleration: AccelerationStructures?
    private var accelerationBuildFailed = false
    private let noShadowMaterials: Set<UInt32>
    private var lastRingTick: Int?
    private var lastRingEntries: [RingHistoryEntry] = []
    private let log = Logger(subsystem: "BornlessRitual", category: "SceneUpdater")

    // MARK: Init

    /// Builds the scene into `scene` and prepares the per-frame machinery.
    ///
    /// - Parameters:
    ///   - device: The Metal device.
    ///   - scene: Freshly created scene buffers (meshes and materials are written here).
    ///   - seed: Simulation seed (melted candle rims, flicker).
    ///   - daemon: Daemon profile (default: the owner's).
    /// - Throws: `SceneResourceError` when a scene capacity is exceeded.
    init(device: MTLDevice, scene: SceneResources, seed: UInt64, daemon: DaemonProfile = .owner) throws {
        self.device = device
        self.seed = seed
        self.daemon = daemon
        self.built = try SceneBuilder.build(into: scene, seed: seed)
        self.capabilities = CapabilityProbe(device: device)
        self.acceleration = device.supportsRaytracing ? AccelerationStructures(device: device) : nil
        self.noShadowMaterials = Set(MaterialIndex.allCases
            .filter { ($0.data.flags & MaterialFlags.noShadow) != 0 }
            .map { $0.rawValue })
        let radii = SigilDynamics.ringRadii.map { Float($0) }
        let filaments = SigilFilaments.build(daemon: daemon, center: SceneLayout.sigilCenter, radii: radii)
        let written = scene.writeSigilFilaments(filaments)
        log.info("Scene built: \(self.built.meshNames.joined(separator: ", "), privacy: .public); \(written) filament vertices")
    }

    // MARK: - SceneUpdating

    func update(tick: Int, state: RitualState, camera: OrbitCamera, settings: RenderSettings,
                resources: SceneResources, commandBuffer: MTLCommandBuffer) {
        let time = Float(tick) / Float(SIM_TICK_RATE)
        let sigilErupt = UniformBuilder.sigilErupt(state: state, tick: tick)
        let manifest = Float(ScalarMath.clamp(state.manifestT, 0, 1))

        // Sorcerer: rebuild vertices for this tick into the current slot.
        let sorcerer = built.sorcerer.vertices(tick: tick, state: state)
        resources.rewriteVertices(of: built.sorcererClothRegion, vertices: sorcerer.cloth)
        resources.rewriteVertices(of: built.sorcererSkinRegion, vertices: sorcerer.skin)
        lastPose = sorcerer.pose

        // Instances: static ones (model = prevModel) + the sorcerer (world-space vertices, identity model).
        var instances = built.staticInstances
        instances.append(SceneBuilder.makeInstance(geometryIndex: built.sorcererClothRegion.geometryIndex(for: resources.slot),
                                                   material: .cloth, model: .identity))
        instances.append(SceneBuilder.makeInstance(geometryIndex: built.sorcererSkinRegion.geometryIndex(for: resources.slot),
                                                   material: .skin, model: .identity))
        resources.writeInstances(instances)

        // Lights and flames.
        let lighting = buildLightsAndFlames(time: time, state: state, settings: settings, sigilErupt: sigilErupt, manifest: manifest)
        lastLightCount = resources.writeLights(lighting.lights)
        resources.writeFlames(lighting.flames)

        // Ring history for this tick (and any skipped ticks since the last frame).
        writeRingHistory(tick: tick, state: state, resources: resources)

        // Parameter blocks.
        resources.writeSigilParams(makeSigilParams(tick: tick, state: state, settings: settings, sigilErupt: sigilErupt,
                                                   filamentVertexCount: resources.sigilFilamentVertexCount))
        resources.writeDaemonParams(makeDaemonParams(time: time, manifest: manifest, settings: settings))
        resources.writeFroxelParams(makeFroxelParams(state: state, settings: settings, sigilErupt: sigilErupt, manifest: manifest))
        resources.writePostParams(makePostParams(time: time, settings: settings))

        // Fallback SDF mirror: static primitives + the sorcerer's capsules.
        var primitives = built.staticSDFPrimitives
        primitives.append(contentsOf: built.sorcerer.sdfPrimitives(pose: sorcerer.pose))
        resources.writeSDFScene(primitives: primitives)

        // RT scene.
        updateAccelerationStructures(instances: instances, settings: settings, resources: resources, commandBuffer: commandBuffer)
    }

    func didSeek(toTick tick: Int, simulation: RitualSimulation, resources: SceneResources) {
        backfillRingHistory(toTick: tick, simulation: simulation, resources: resources)
    }

    // MARK: - Lights and flames

    /// Lights (≤ MAX_LIGHTS) and flames for the frame.
    private func buildLightsAndFlames(time: Float, state: RitualState, settings: RenderSettings,
                                      sigilErupt: Float, manifest: Float) -> (lights: [LightData], flames: [FlameData]) {
        var lights: [LightData] = []
        var flames: [FlameData] = []
        let flameScale = max(settings.flameIntensity, 0)

        // Quarter candles (East, South, West, North).
        for (index, quarter) in Quarter.allCases.enumerated() {
            guard let candle = state.candles[quarter], candle.lit, candle.intensity > 0 else { continue }
            let element = quarter.element
            let flicker = FlickerNoise.flicker(time: time, index: index, seed: seed)
            let ramp = ScalarMath.smoothstep(0, 1, Float(ScalarMath.clamp(candle.intensity, 0, 1)))
            let temperature = element.flameTemperatureKelvin
            let radiance = SceneUpdater.normalisedRadiance(color: element.flameColorSIMD, temperatureK: temperature)
            let origin = quarter.flamePositionSIMD
            lights.append(SceneUpdater.makeLight(position: origin + SIMD3<Float>(0, 0.55 * SceneUpdater.flameHeight, 0),
                                                 radius: SceneUpdater.quarterFlameRadius,
                                                 radiance: radiance,
                                                 intensity: SceneUpdater.quarterFlameIntensity * flameScale * ramp * flicker,
                                                 type: UInt32(LIGHT_TYPE_SPHERE), ringRadius: 0, temperatureK: temperature))
            flames.append(SceneUpdater.makeFlame(position: origin,
                                                 height: SceneUpdater.flameHeight * (0.85 + 0.15 * flicker) * (0.5 + 0.5 * ramp),
                                                 color: element.flameColorSIMD,
                                                 intensity: ScalarMath.clamp(ramp * flicker, 0, 1),
                                                 temperatureK: temperature,
                                                 flicker: FlickerNoise.normalised(flicker),
                                                 width: SceneUpdater.flameWidth))
        }

        // Altar candles: always lit, warm (candle warmth slider).
        let altarTemperature = settings.candleWarmthKelvin
        let altarRadiance = SceneUpdater.normalisedRadiance(color: SIMD3<Float>(1, 1, 1), temperatureK: altarTemperature)
        for index in 0..<SceneLayout.altarCandlePositions.count {
            let flicker = FlickerNoise.flicker(time: time, index: Quarter.allCases.count + index, seed: seed)
            let origin = SceneLayout.altarFlameOrigin(index)
            lights.append(SceneUpdater.makeLight(position: origin + SIMD3<Float>(0, 0.55 * SceneUpdater.flameHeight, 0),
                                                 radius: SceneUpdater.altarFlameRadius,
                                                 radiance: altarRadiance,
                                                 intensity: SceneUpdater.altarFlameIntensity * flameScale * flicker,
                                                 type: UInt32(LIGHT_TYPE_SPHERE), ringRadius: 0, temperatureK: altarTemperature))
            flames.append(SceneUpdater.makeFlame(position: origin,
                                                 height: SceneUpdater.flameHeight * 0.9 * (0.85 + 0.15 * flicker),
                                                 color: SIMD3<Float>(1, 1, 1),
                                                 intensity: ScalarMath.clamp(flicker, 0, 1),
                                                 temperatureK: altarTemperature,
                                                 flicker: FlickerNoise.normalised(flicker),
                                                 width: SceneUpdater.flameWidth * 0.85))
        }

        // Sigil ring light (ring 0), once the sigil has erupted.
        if sigilErupt > 0 {
            let spin = Float(ScalarMath.clamp(state.spinEnergy / 2, 0, 1))
            let intensity = SceneUpdater.sigilLightIntensity * flameScale * sigilErupt * (0.6 + 0.4 * spin)
            lights.append(SceneUpdater.makeLight(position: SceneLayout.sigilCenter,
                                                 radius: SceneUpdater.sigilFilamentWidth,
                                                 radiance: SceneUpdater.sigilCoreColor,
                                                 intensity: intensity,
                                                 type: UInt32(LIGHT_TYPE_RING),
                                                 ringRadius: Float(SigilDynamics.ringRadii[0]),
                                                 temperatureK: 0))
        }

        // Daemon glow while (and after) it condenses.
        if manifest > 0 {
            let breath = 0.5 + 0.5 * sin(2 * Float.pi * SceneUpdater.daemonBreathHz * time)
            let palette = daemon.paletteSIMD
            lights.append(SceneUpdater.makeLight(position: SceneLayout.daemonCenter + SIMD3<Float>(0, 0.45 * manifest, 0),
                                                 radius: 0.30 + 0.25 * manifest,
                                                 radiance: palette.mid,
                                                 intensity: SceneUpdater.daemonLightIntensity * manifest * (0.9 + 0.1 * breath),
                                                 type: UInt32(LIGHT_TYPE_DAEMON), ringRadius: 0, temperatureK: 0))
        }

        // Ambient (slider applied in-shader; the kindled ring adds a little warmth).
        let kindle = Float(ScalarMath.clamp(state.ringKindle, 0, 1))
        lights.append(SceneUpdater.makeLight(position: SIMD3<Float>(0, 1, 0), radius: 0,
                                             radiance: SceneUpdater.ambientLightRadiance * (1 + 0.6 * kindle),
                                             intensity: 1,
                                             type: UInt32(LIGHT_TYPE_AMBIENT), ringRadius: 0, temperatureK: 0))

        return (Array(lights.prefix(Int(MAX_LIGHTS))), flames)
    }

    /// Elemental colour scaled so that colour × blackbody(T) has unit luminance (the
    /// shader applies the blackbody tint itself when `temperatureK > 0`).
    static func normalisedRadiance(color: SIMD3<Float>, temperatureK: Float) -> SIMD3<Float> {
        let tint = temperatureK > 0 ? color * BlackbodyColor.rgb(temperatureK) : color
        let luminance = simd_dot(tint, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        return color / max(luminance, 1e-3)
    }

    /// Fills one `LightData`.
    static func makeLight(position: SIMD3<Float>, radius: Float, radiance: SIMD3<Float>, intensity: Float,
                          type: UInt32, ringRadius: Float, temperatureK: Float) -> LightData {
        var light = LightData()
        light.position = position
        light.radius = radius
        light.radiance = simd_max(radiance, SIMD3<Float>(0, 0, 0))
        light.intensity = max(intensity, 0)
        light.type = type
        light.ringRadius = ringRadius
        light.temperatureK = max(temperatureK, 0)
        light.flags = 0
        return light
    }

    /// Fills one `FlameData`.
    static func makeFlame(position: SIMD3<Float>, height: Float, color: SIMD3<Float>, intensity: Float,
                          temperatureK: Float, flicker: Float, width: Float) -> FlameData {
        var flame = FlameData()
        flame.position = position
        flame.height = max(height, 0)
        flame.color = color
        flame.intensity = ScalarMath.clamp(intensity, 0, 1)
        flame.temperatureK = max(temperatureK, 0)
        flame.flicker = ScalarMath.clamp(flicker, 0, 1)
        flame.width = max(width, 0)
        flame.flags = 0
        return flame
    }

    // MARK: - Ring history

    /// `RingHistoryEntry` per ring from the sigil dynamics.
    static func ringEntries(from sigil: SigilDynamics) -> [RingHistoryEntry] {
        var entries: [RingHistoryEntry] = []
        entries.reserveCapacity(Int(RING_COUNT))
        for ring in sigil.rings.prefix(Int(RING_COUNT)) {
            var entry = RingHistoryEntry()
            entry.angle = Float(ring.angle)
            entry.omega = Float(ring.omega)
            entry.radius = Float(ring.radius)
            entry.energy = Float(ring.kineticEnergy)
            entries.append(entry)
        }
        while entries.count < Int(RING_COUNT) {
            entries.append(RingHistoryEntry())
        }
        return entries
    }

    /// Writes this tick's entry; ticks skipped since the previous frame (the renderer
    /// may advance several ticks per frame) are filled by interpolating ω and energy and
    /// integrating the angle with the mean ω, so the ember kernel never sees holes.
    private func writeRingHistory(tick: Int, state: RitualState, resources: SceneResources) {
        let current = SceneUpdater.ringEntries(from: state.sigil)
        let span = Int(RING_HISTORY_TICKS)
        if let last = lastRingTick, lastRingEntries.count == current.count, tick > last + 1, tick - last < span {
            let dt = 1 / Float(SIM_TICK_RATE)
            for t in (last + 1)..<tick {
                let fraction = Float(t - last) / Float(tick - last)
                var entries: [RingHistoryEntry] = []
                entries.reserveCapacity(current.count)
                for ring in 0..<current.count {
                    let previous = lastRingEntries[ring]
                    let next = current[ring]
                    var entry = RingHistoryEntry()
                    entry.omega = ScalarMath.lerp(previous.omega, next.omega, fraction)
                    entry.energy = ScalarMath.lerp(previous.energy, next.energy, fraction)
                    entry.radius = next.radius
                    let meanOmega = 0.5 * (previous.omega + entry.omega)
                    entry.angle = SceneUpdater.wrapAngle(previous.angle + meanOmega * dt * Float(t - last))
                    entries.append(entry)
                }
                resources.writeRingHistory(tick: t, entries: entries)
            }
        }
        if lastRingTick != tick {
            resources.writeRingHistory(tick: tick, entries: current)
        }
        lastRingTick = tick
        lastRingEntries = current
    }

    /// After a seek: re-simulates the last RING_HISTORY_TICKS ticks from the nearest
    /// keyframe so the ring buffer holds exact entries for every tick the ember kernel can
    /// look back to, leaving the simulation at `tick` (deterministic replay).
    private func backfillRingHistory(toTick tick: Int, simulation: RitualSimulation, resources: SceneResources) {
        lastRingTick = nil
        lastRingEntries = []
        let start = max(tick - (Int(RING_HISTORY_TICKS) - 1), 0)
        simulation.seek(toTick: start)
        resources.writeRingHistory(tick: simulation.tick, entries: SceneUpdater.ringEntries(from: simulation.state.sigil))
        var guardCount = Int(RING_HISTORY_TICKS) + 1
        while simulation.tick < tick && guardCount > 0 {
            simulation.step()
            resources.writeRingHistory(tick: simulation.tick, entries: SceneUpdater.ringEntries(from: simulation.state.sigil))
            guardCount -= 1
        }
        if simulation.tick != tick {
            // Never expected (the loop steps exactly to `tick`); restore the requested position regardless.
            simulation.seek(toTick: tick)
        }
        lastRingTick = simulation.tick
        lastRingEntries = SceneUpdater.ringEntries(from: simulation.state.sigil)
    }

    /// Wraps an angle into [0, 2π).
    static func wrapAngle(_ radians: Float) -> Float {
        let twoPi = 2 * Float.pi
        var wrapped = radians.truncatingRemainder(dividingBy: twoPi)
        if wrapped < 0 { wrapped += twoPi }
        if wrapped >= twoPi { wrapped -= twoPi }
        return wrapped
    }

    // MARK: - Parameter blocks

    private func makeSigilParams(tick: Int, state: RitualState, settings: RenderSettings, sigilErupt: Float,
                                 filamentVertexCount: Int) -> SigilParams {
        var params = SigilParams()
        params.center = SceneLayout.sigilCenter
        params.erupt = sigilErupt
        params.coreColor = SceneUpdater.sigilCoreColor
        params.filamentWidth = SceneUpdater.sigilFilamentWidth
        params.edgeColor = SceneUpdater.sigilEdgeColor
        params.sparkRate = Float(state.sigil.sparkRate) * sigilErupt
        params.currentTick = UInt32(clamping: max(tick, 0))
        params.ringCount = UInt32(min(state.sigil.rings.count, Int(RING_COUNT)))
        params.filamentVertexCount = UInt32(clamping: max(filamentVertexCount, 0))
        params.gravity = Float(EmberModel.standardGravity) * max(settings.gravity, 0)
        params.dragK = Float(EmberModel.dragK)
        params.emberScale = max(settings.emberCount, 0)
        params.lifetime = Float(EmberModel.lifetime)
        params.padding = 0
        return params
    }

    private func makeDaemonParams(time: Float, manifest: Float, settings: RenderSettings) -> DaemonParams {
        let palette = daemon.paletteSIMD
        var params = DaemonParams()
        params.center = SceneLayout.daemonCenter
        params.manifest = manifest
        params.paletteCore = palette.core
        params.height = SceneLayout.daemonHeight
        params.paletteMid = palette.mid
        params.breath = 0.5 + 0.5 * sin(2 * Float.pi * SceneUpdater.daemonBreathHz * time)
        params.paletteEdge = palette.edge
        // Slow, unhurried head turn: ±0.35 rad, a two-tone drift so it never looks periodic.
        params.headYaw = SceneUpdater.daemonHeadYawAmplitude
            * (0.7 * sin(2 * Float.pi * SceneUpdater.daemonHeadYawHz * time + 1.3)
               + 0.3 * sin(2 * Float.pi * SceneUpdater.daemonHeadYawHz * 0.37 * time + 4.1))
        params.boundsMin = SceneLayout.daemonCenter + SIMD3<Float>(-1.1, -1.2, -1.1)
        params.boundsMax = SceneLayout.daemonCenter + SIMD3<Float>(1.1, 1.35, 1.1)
        params.time = time
        params.emissiveScale = max(settings.flameIntensity, 0)
        params.form = UInt32(DaemonForm.allCases.firstIndex(of: daemon.form) ?? 0)
        params.motion = UInt32(DaemonMotion.allCases.firstIndex(of: daemon.motion) ?? 0)
        params.presence = UInt32(DaemonPresence.allCases.firstIndex(of: daemon.presence) ?? 0)
        params.padding = 0
        return params
    }

    private func makeFroxelParams(state: RitualState, settings: RenderSettings, sigilErupt: Float, manifest: Float) -> FroxelParams {
        var params = FroxelParams()
        params.gridSize = SIMD3<UInt32>(UInt32(FROXEL_X), UInt32(FROXEL_Y), UInt32(FROXEL_Z))
        params.nearZ = SceneUpdater.froxelNearZ
        params.farZ = max(settings.froxelFarZ, SceneUpdater.froxelNearZ + 1)
        params.densityScale = max(settings.smokeDensity, 0)
        params.anisotropy = SceneUpdater.froxelAnisotropy
        params.ambientScatter = SceneUpdater.froxelAmbientScatter
        params.windDirection = SceneUpdater.froxelWindDirection.safeNormalized(fallback: SIMD3<Float>(1, 0, 0))
        params.windSpeed = SceneUpdater.froxelWindSpeed
        params.censerPosition = SceneLayout.censerSmokeOrigin
        params.historyBlend = SceneUpdater.froxelHistoryBlend
        params.extinctionScale = SceneUpdater.froxelExtinctionScale
        let spin = Float(ScalarMath.clamp(state.spinEnergy / 2, 0, 1))
        params.sigilSmoke = sigilErupt * (0.5 + 0.5 * spin)
        params.daemonSmoke = 4 * manifest * (1 - manifest)
        params.padding = 0
        return params
    }

    private func makePostParams(time: Float, settings: RenderSettings) -> PostParams {
        var params = PostParams()
        params.exposureEV = settings.exposureEV
        params.bloomIntensity = max(settings.bloomIntensity, 0)
        params.bloomThreshold = SceneUpdater.bloomThreshold
        params.shimmerStrength = SceneUpdater.shimmerPixelsAtFullStrength * ScalarMath.clamp(settings.heatShimmer, 0, 1)
        params.outputSize = outputSize
        params.time = time
        params.vignette = SceneUpdater.vignette
        // The frame index is assigned by the Renderer after this update; PostPass should
        // dither with `FrameUniforms.frameIndex`.
        params.frameIndex = 0
        return params
    }

    // MARK: - Acceleration structures

    private func updateAccelerationStructures(instances: [InstanceData], settings: RenderSettings,
                                              resources: SceneResources, commandBuffer: MTLCommandBuffer) {
        guard let acceleration = acceleration, capabilities.resolve(settings.renderPathChoice) == .rt else {
            resources.instanceAS = nil
            return
        }
        if !acceleration.isBuilt {
            guard !accelerationBuildFailed else {
                resources.instanceAS = nil
                return
            }
            do {
                try acceleration.buildPrimitives(scene: resources, commandBuffer: commandBuffer)
                log.info("Built \(acceleration.primitiveStructures.count) primitive acceleration structures")
            } catch {
                accelerationBuildFailed = true
                resources.instanceAS = nil
                log.error("Acceleration structure build failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        acceleration.refitDynamic(scene: resources, commandBuffer: commandBuffer)
        acceleration.rebuildInstances(instances: instances, noShadowMaterials: noShadowMaterials,
                                      scene: resources, commandBuffer: commandBuffer)
    }

    // MARK: - Debug

    /// One-line summary for the debug panel.
    var description: String {
        "lights \(lastLightCount), ring history tick \(lastRingTick.map { String($0) } ?? "-"), AS \(acceleration?.isBuilt == true ? "built" : "none")"
    }
}
