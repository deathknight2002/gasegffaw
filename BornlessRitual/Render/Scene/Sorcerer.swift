//
//  Sorcerer.swift
//  Bornless Ritual — the sorcerer's procedural body: hooded robe, sleeves, head and
//  hands rebuilt every tick from a pose (ARCHITECTURE §2 "Sorcerer: stands at
//  (0, 0, 0.75) facing −Z … hooded robe; hands and face use the SSS skin material;
//  face is inside the hood's shadow", §5 "sorcerer animation … pure functions of
//  (tick, seed, sim state)"; RENDER_CONTRACT §2 row 0 "instances (sorcerer procedural
//  pose)", §4 "sorcerer = 7 capsules … updated per tick", §5 "sorcerer refit each tick").
//
//  Role: `SorcererModel.pose(tick:state:)` maps the ritual state to arm / torso / head
//  angles (chanting sway 0.3 Hz, arms rising through the quarter stages, spread at the
//  climax, still and open at manifestation, breathing), and the mesh builders turn a
//  pose into two vertex arrays with a fixed topology: the cloth mesh (robe with
//  low-frequency folds, hood as a partially swept cap leaving the face cavity open,
//  sleeves) and the skin mesh (head, palms, five finger capsules per hand). Vertices are
//  emitted directly in world space, so the sorcerer instances use an identity model
//  matrix and the RT path refits their primitive acceleration structures in place.
//

import Foundation
import simd
import RitualCore

// MARK: - Pose

/// Per-arm animation targets (left = .x, right = .y where a pair is used).
struct SorcererPose: Equatable {
    /// Chest scale from breathing (≈ 0.99 … 1.01).
    var breathingScale: Float = 1
    /// Torso lean about +X in radians (positive = toward −Z, the altar).
    var torsoLean: Float = 0
    /// Torso sway about +Z in radians.
    var torsoSway: Float = 0
    /// Arm raise angle (0 = hanging, π/2 = forward, π = straight up) — left, right.
    var raise = SIMD2<Float>(0.3, 0.3)
    /// Lateral spread of the upper arm in radians — left, right.
    var spread = SIMD2<Float>(0.15, 0.15)
    /// Elbow bend in radians — left, right.
    var bend = SIMD2<Float>(0.6, 0.6)
    /// Finger curl toward the palm in radians (0 = open).
    var fingerCurl: Float = 0.4
    /// Head pitch (positive = looking up).
    var headPitch: Float = 0
    /// Cloth-fold phase (radians) so folds drift with the chant.
    var foldPhase: Float = 0

    /// The rest pose used to register the topology.
    static let rest = SorcererPose()
}

/// Stage-driven arm targets before the chant sway is layered on.
private struct ArmTarget {
    var raise: Float
    var spread: Float
    var bend: Float
    var swayAmplitude: Float
    var fingerCurl: Float
    var headPitch: Float

    /// Component-wise linear blend.
    static func mix(_ a: ArmTarget, _ b: ArmTarget, _ t: Float) -> ArmTarget {
        ArmTarget(raise: ScalarMath.lerp(a.raise, b.raise, t),
                  spread: ScalarMath.lerp(a.spread, b.spread, t),
                  bend: ScalarMath.lerp(a.bend, b.bend, t),
                  swayAmplitude: ScalarMath.lerp(a.swayAmplitude, b.swayAmplitude, t),
                  fingerCurl: ScalarMath.lerp(a.fingerCurl, b.fingerCurl, t),
                  headPitch: ScalarMath.lerp(a.headPitch, b.headPitch, t))
    }
}

// MARK: - Tube rings (surface-of-revolution rows in arbitrary frames)

/// One ring of a tube: a circle (or arc) of `radius` around `center` in the plane
/// spanned by `e1`, `e2` with `e1 × e2 = axis` (right-handed).
private struct TubeRing {
    var center: SIMD3<Float>
    var axis: SIMD3<Float>
    var e1: SIMD3<Float>
    var e2: SIMD3<Float>
    var radius: Float
    var v: Float
    /// Angular range in radians (a full ring spans 0 … 2π).
    var phiStart: Float = 0
    var phiEnd: Float = 2 * Float.pi
    /// Optional radius multiplier by angle φ.
    var modulation: ((Float) -> Float)? = nil
}

// MARK: - SorcererModel

/// Builds and animates the sorcerer's meshes and SDF proxies.
final class SorcererModel {

    // MARK: Layout constants

    /// Feet position (ARCHITECTURE §2).
    static let origin = SIMD3<Float>(0, 0, 0.75)
    /// Overall height in metres.
    static let height: Float = 1.80
    /// Head centre above the feet.
    static let headHeight: Float = 1.66
    /// Shoulder joints (local, before the torso transform): (±x, y, z).
    static let shoulderOffset = SIMD3<Float>(0.21, 1.47, 0.0)
    /// Torso pivot for lean / sway.
    static let hipPivot = SIMD3<Float>(0, 0.90, 0)
    /// Upper-arm and forearm lengths.
    static let upperArmLength: Float = 0.30
    static let forearmLength: Float = 0.27

    /// Tube resolutions (fixed: they define the registered topology).
    static let robeSegments = 40
    static let hoodSegments = 32
    static let sleeveSegments = 16
    static let headSegments = 20
    static let palmSegments = 12
    static let fingerSegments = 8

    // MARK: Cache

    private var cachedTick: Int?
    private var cachedCloth: [Vertex] = []
    private var cachedSkin: [Vertex] = []
    private var cachedPose = SorcererPose.rest

    /// Creates the model.
    init() {}

    // MARK: - Pose

    /// Deterministic pose for the simulation tick and state (ARCHITECTURE §5).
    static func pose(tick: Int, state: RitualState) -> SorcererPose {
        let time = Float(tick) / Float(SIM_TICK_RATE)
        let progress = Float(ScalarMath.clamp(state.stageProgress, 0, 1))
        var target = stageTarget(state.stage, progress: progress)

        // Blend from the previous stage's final pose over 1.2 s after a stage change.
        if let previous = RitualStage(rawValue: state.stage.rawValue - 1) {
            let sinceStart = Float(max(tick - state.stageStartTick, 0)) / Float(SIM_TICK_RATE)
            let weight = ScalarMath.smoothstep(0, 1.2, sinceStart)
            target = ArmTarget.mix(stageTarget(previous, progress: 1), target, weight)
        }

        // Chant sway at 0.3 Hz (stronger while the oath is being held).
        let swayPhase = 2 * Float.pi * 0.3 * time
        let holdBoost: Float = state.holding ? 1.35 : 1.0
        let sway = target.swayAmplitude * holdBoost
        let breathing = 1 + 0.012 * sin(2 * Float.pi * 0.2 * time)

        var pose = SorcererPose()
        pose.breathingScale = breathing
        pose.torsoSway = 0.035 * sway * sin(swayPhase)
        pose.torsoLean = 0.03 * sway * sin(swayPhase * 0.5 + 1.0) + 0.02
        let raiseWobble = 0.06 * sway * sin(swayPhase + 0.4)
        pose.raise = SIMD2<Float>(target.raise - 0.04 + raiseWobble, target.raise + 0.02 - raiseWobble * 0.7)
        pose.spread = SIMD2<Float>(target.spread, target.spread + 0.04)
        pose.bend = SIMD2<Float>(target.bend + 0.05 * sway * sin(swayPhase * 0.5), target.bend)
        pose.fingerCurl = target.fingerCurl
        pose.headPitch = target.headPitch + 0.02 * sway * sin(swayPhase * 0.5 + 2.0)
        pose.foldPhase = 0.35 * sway * sin(swayPhase * 0.5)
        return pose
    }

    /// Arm targets per stage (angles in radians).
    private static func stageTarget(_ stage: RitualStage, progress: Float) -> ArmTarget {
        let eased = ScalarMath.smoothstep(0, 1, progress)
        switch stage {
        case .oath:
            return ArmTarget(raise: 0.45 + 0.25 * eased, spread: 0.15, bend: 0.95, swayAmplitude: 1.0, fingerCurl: 0.45, headPitch: -0.15)
        case .air, .fire, .water, .earth:
            return ArmTarget(raise: 0.55 + 1.25 * eased, spread: 0.45, bend: 0.35, swayAmplitude: 0.5, fingerCurl: 0.3, headPitch: 0.05 + 0.15 * eased)
        case .spirit:
            return ArmTarget(raise: 2.0, spread: 0.75, bend: 0.25, swayAmplitude: 1.2, fingerCurl: 0.25, headPitch: 0.35)
        case .sigilSpin:
            return ArmTarget(raise: 1.35, spread: 1.25, bend: 0.2, swayAmplitude: 0.6, fingerCurl: 0.2, headPitch: 0.3)
        case .manifestation:
            return ArmTarget(raise: 1.15, spread: 0.85, bend: 0.12, swayAmplitude: 0.0, fingerCurl: 0.05, headPitch: 0.25)
        }
    }

    // MARK: - Per-tick vertices

    /// Cloth and skin vertex arrays for `tick` (cached while the tick is unchanged).
    func vertices(tick: Int, state: RitualState) -> (cloth: [Vertex], skin: [Vertex], pose: SorcererPose) {
        if cachedTick == tick, !cachedCloth.isEmpty {
            return (cachedCloth, cachedSkin, cachedPose)
        }
        let pose = SorcererModel.pose(tick: tick, state: state)
        cachedCloth = clothMesh(pose: pose, buildIndices: false).vertices
        cachedSkin = skinMesh(pose: pose, buildIndices: false).vertices
        cachedPose = pose
        cachedTick = tick
        return (cachedCloth, cachedSkin, cachedPose)
    }

    // MARK: - Skeleton

    /// World-space joints and frames of one arm.
    struct ArmChain {
        var shoulder: SIMD3<Float>
        var elbow: SIMD3<Float>
        var wrist: SIMD3<Float>
        var upperDirection: SIMD3<Float>
        var forearmDirection: SIMD3<Float>
        /// Lateral axis (away from the body).
        var side: SIMD3<Float>
        /// Palm-facing direction.
        var palmNormal: SIMD3<Float>
    }

    /// Torso rotation at height `y` (lean/sway fade in above the hips).
    private static func torsoRotation(_ pose: SorcererPose, y: Float) -> simd_quatf {
        let weight = ScalarMath.smoothstep(0.85, 1.55, y)
        let sway = simd_quatf(angle: pose.torsoSway * weight, axis: SIMD3<Float>(0, 0, 1))
        let lean = simd_quatf(angle: pose.torsoLean * weight, axis: SIMD3<Float>(1, 0, 0))
        return sway * lean
    }

    /// Applies the torso transform to a local point (feet at the origin).
    private static func torsoPoint(_ pose: SorcererPose, _ local: SIMD3<Float>) -> SIMD3<Float> {
        let rotation = torsoRotation(pose, y: local.y)
        return origin + hipPivot + rotation.act(local - hipPivot)
    }

    /// Arm chain for side `s` (+1 right at +X, −1 left).
    static func armChain(_ pose: SorcererPose, side s: Float) -> ArmChain {
        let index = s > 0 ? 1 : 0
        let raise = pose.raise[index]
        let spread = pose.spread[index]
        let bend = pose.bend[index]

        let shoulderLocal = SIMD3<Float>(s * shoulderOffset.x, shoulderOffset.y, shoulderOffset.z)
        let girdle = torsoRotation(pose, y: shoulderLocal.y)
        let shoulder = torsoPoint(pose, shoulderLocal)

        // Hanging arm rotated forward by `raise` (about +X) then outward by `spread` (about +Z).
        let raiseRotation = simd_quatf(angle: raise, axis: SIMD3<Float>(1, 0, 0))
        let bendRotation = simd_quatf(angle: raise + bend, axis: SIMD3<Float>(1, 0, 0))
        let spreadRotation = simd_quatf(angle: s * spread, axis: SIMD3<Float>(0, 0, 1))
        let hanging = SIMD3<Float>(0, -1, 0)
        let upperDirection = simd_normalize(girdle.act(spreadRotation.act(raiseRotation.act(hanging))))
        let forearmDirection = simd_normalize(girdle.act(spreadRotation.act(bendRotation.act(hanging))))
        let side = simd_normalize(girdle.act(spreadRotation.act(SIMD3<Float>(s, 0, 0))))

        let elbow = shoulder + upperDirection * upperArmLength
        let wrist = elbow + forearmDirection * forearmLength
        let palmNormal = simd_normalize(simd_cross(forearmDirection, side))
        return ArmChain(shoulder: shoulder, elbow: elbow, wrist: wrist,
                        upperDirection: upperDirection, forearmDirection: forearmDirection,
                        side: side, palmNormal: palmNormal)
    }

    // MARK: - Cloth mesh

    /// Robe, hood and sleeves. Topology is independent of the pose.
    func clothMesh(pose: SorcererPose, buildIndices: Bool) -> MeshData {
        var mesh = MeshData()
        appendRobe(pose: pose, into: &mesh, buildIndices: buildIndices)
        appendHood(pose: pose, into: &mesh, buildIndices: buildIndices)
        for s: Float in [-1, 1] {
            appendSleeve(pose: pose, side: s, into: &mesh, buildIndices: buildIndices)
        }
        return mesh
    }

    /// Robe profile rows: (height, radius). The chest rows breathe; the hem is wide.
    private static let robeProfile: [(Float, Float)] = [
        (0.015, 0.0), (0.02, 0.44), (0.18, 0.425), (0.34, 0.40), (0.52, 0.375), (0.70, 0.345),
        (0.88, 0.31), (1.04, 0.275), (1.18, 0.255), (1.30, 0.245), (1.42, 0.24), (1.50, 0.215),
        (1.56, 0.13), (1.61, 0.095),
    ]

    private func appendRobe(pose: SorcererPose, into mesh: inout MeshData, buildIndices: Bool) {
        var rings: [TubeRing] = []
        let profile = SorcererModel.robeProfile
        let foldPhase = pose.foldPhase
        for (k, row) in profile.enumerated() {
            let y = row.0
            var radius = row.1
            // Breathing scales the chest rows.
            let chest = ScalarMath.smoothstep(0.95, 1.2, y) * (1 - ScalarMath.smoothstep(1.45, 1.6, y))
            radius *= 1 + (pose.breathingScale - 1) * chest
            let rotation = SorcererModel.torsoRotation(pose, y: y)
            let center = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, y, 0))
            let axis = rotation.act(SIMD3<Float>(0, 1, 0))
            let e1 = rotation.act(SIMD3<Float>(0, 0, 1))
            let e2 = rotation.act(SIMD3<Float>(1, 0, 0))
            let v = Float(k) / Float(profile.count - 1)
            // Folds: loose toward the hem, elliptical cross-section (wider in X), a
            // raised shoulder line near the top.
            let foldAmplitude = 0.09 * (1 - ScalarMath.smoothstep(0.2, 1.5, y))
            let shoulderLine = ScalarMath.smoothstep(1.40, 1.50, y) * (1 - ScalarMath.smoothstep(1.52, 1.58, y))
            let ring = TubeRing(center: center, axis: axis, e1: e1, e2: e2, radius: radius, v: v,
                                modulation: { phi in
                                    let sinPhi = sin(phi)
                                    let ellipse: Float = 0.82 + 0.18 * sinPhi * sinPhi
                                    let folds = foldAmplitude * (0.5 * sin(7 * phi + 0.8 * y + foldPhase)
                                                                 + 0.3 * sin(11 * phi - 1.3 * y + 2.1 - foldPhase)
                                                                 + 0.2 * sin(3 * phi + 2.2 * y + 0.5 * foldPhase))
                                    let shoulders = 0.14 * shoulderLine * sinPhi * sinPhi
                                    return ellipse * (1 + folds) + shoulders
                                })
            rings.append(ring)
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.robeSegments, closed: true,
                                 uRepeat: 4, into: &mesh, buildIndices: buildIndices)
    }

    /// Hood rows: (height above the feet, radius, half-opening angle in front, forward offset).
    private static let hoodProfile: [(Float, Float, Float, Float)] = [
        (1.535, 0.205, 1.15, 0.0), (1.60, 0.195, 1.10, 0.0), (1.66, 0.19, 1.05, 0.0), (1.72, 0.18, 0.95, -0.005),
        (1.78, 0.16, 0.80, -0.012), (1.83, 0.128, 0.55, -0.022), (1.87, 0.082, 0.30, -0.042),
        (1.895, 0.032, 0.12, -0.058), (1.905, 0.0, 0.0, -0.064),
    ]

    private func appendHood(pose: SorcererPose, into mesh: inout MeshData, buildIndices: Bool) {
        var rings: [TubeRing] = []
        let profile = SorcererModel.hoodProfile
        let rotation = SorcererModel.torsoRotation(pose, y: 1.55)
        let axis = rotation.act(SIMD3<Float>(0, 1, 0))
        let e1 = rotation.act(SIMD3<Float>(0, 0, 1))
        let e2 = rotation.act(SIMD3<Float>(1, 0, 0))
        for (k, row) in profile.enumerated() {
            let center = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, row.0, row.3))
            let halfOpen = row.2
            let v = Float(k) / Float(profile.count - 1)
            // φ = 0 is the back (+Z); the front (φ = ±π) is left open for the face.
            let ring = TubeRing(center: center, axis: axis, e1: e1, e2: e2, radius: row.1, v: v,
                                phiStart: -Float.pi + halfOpen, phiEnd: Float.pi - halfOpen,
                                modulation: { phi in 1 + 0.03 * sin(5 * phi + 1.7) })
            rings.append(ring)
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.hoodSegments, closed: false,
                                 uRepeat: 2, into: &mesh, buildIndices: buildIndices)
    }

    private func appendSleeve(pose: SorcererPose, side s: Float, into mesh: inout MeshData, buildIndices: Bool) {
        let arm = SorcererModel.armChain(pose, side: s)
        // Upper arm.
        let upperRadii: [Float] = [0.080, 0.074, 0.067, 0.062]
        var rings: [TubeRing] = []
        for (k, radius) in upperRadii.enumerated() {
            let t = Float(k) / Float(upperRadii.count - 1)
            let center = arm.shoulder + arm.upperDirection * (SorcererModel.upperArmLength * t)
            rings.append(SorcererModel.ring(center: center, axis: arm.upperDirection, reference: arm.side,
                                            radius: radius, v: t * 0.5, modulation: { phi in 1 + 0.04 * sin(4 * phi) }))
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.sleeveSegments, closed: true,
                                 uRepeat: 1, into: &mesh, buildIndices: buildIndices)
        // Forearm with a flared cuff.
        let forearmRadii: [(Float, Float)] = [(0.0, 0.064), (0.35, 0.058), (0.7, 0.056), (0.92, 0.072), (1.0, 0.085)]
        rings.removeAll()
        for (t, radius) in forearmRadii {
            let center = arm.elbow + arm.forearmDirection * (SorcererModel.forearmLength * t)
            rings.append(SorcererModel.ring(center: center, axis: arm.forearmDirection, reference: arm.side,
                                            radius: radius, v: 0.5 + t * 0.5, modulation: { phi in 1 + 0.04 * sin(5 * phi + 1) }))
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.sleeveSegments, closed: true,
                                 uRepeat: 1, into: &mesh, buildIndices: buildIndices)
    }

    // MARK: - Skin mesh

    /// Head, palms and fingers. Topology is independent of the pose.
    func skinMesh(pose: SorcererPose, buildIndices: Bool) -> MeshData {
        var mesh = MeshData()
        appendHead(pose: pose, into: &mesh, buildIndices: buildIndices)
        for s: Float in [-1, 1] {
            appendHand(pose: pose, side: s, into: &mesh, buildIndices: buildIndices)
        }
        return mesh
    }

    private func appendHead(pose: SorcererPose, into mesh: inout MeshData, buildIndices: Bool) {
        let rotation = SorcererModel.torsoRotation(pose, y: SorcererModel.headHeight)
        let pitch = simd_quatf(angle: -pose.headPitch, axis: SIMD3<Float>(1, 0, 0))
        let headRotation = rotation * pitch
        let axis = headRotation.act(SIMD3<Float>(0, 1, 0))
        let e1 = headRotation.act(SIMD3<Float>(0, 0, 1))
        let e2 = headRotation.act(SIMD3<Float>(1, 0, 0))
        let headCenter = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, SorcererModel.headHeight, 0))
        let ringCount = 12
        var rings: [TubeRing] = []
        for k in 0...ringCount {
            let t = Float(k) / Float(ringCount)
            let theta = Float.pi * t
            let radius = 0.10 * sin(theta)
            let center = headCenter + axis * (-0.115 * cos(theta))
            // Slightly flattened face side (φ = π is the front) and a chin.
            rings.append(TubeRing(center: center, axis: axis, e1: e1, e2: e2, radius: radius, v: t,
                                  modulation: { phi in 1 - 0.06 * max(-cos(phi), 0) }))
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.headSegments, closed: true,
                                 uRepeat: 2, into: &mesh, buildIndices: buildIndices)
    }

    private func appendHand(pose: SorcererPose, side s: Float, into mesh: inout MeshData, buildIndices: Bool) {
        let arm = SorcererModel.armChain(pose, side: s)
        let forward = arm.forearmDirection
        let side = arm.side
        let palm = arm.palmNormal
        let curl = pose.fingerCurl

        // Palm: flattened tube along the forearm direction.
        let palmRows: [(Float, Float)] = [(-0.012, 0.0), (-0.005, 0.55), (0.02, 0.95), (0.05, 1.0), (0.08, 0.95), (0.095, 0.6), (0.102, 0.0)]
        var rings: [TubeRing] = []
        for (k, row) in palmRows.enumerated() {
            let center = arm.wrist + forward * row.0
            let scale = row.1
            let v = Float(k) / Float(palmRows.count - 1)
            rings.append(TubeRing(center: center, axis: forward, e1: side, e2: palm, radius: 0.042 * scale, v: v,
                                  modulation: { phi in
                                      let c = cos(phi), sn = sin(phi)
                                      // Ellipse: 0.042 across, 0.015 thick.
                                      let inv = sqrt((c * c) / (0.042 * 0.042) + (sn * sn) / (0.015 * 0.015))
                                      return inv > 1e-6 ? (1 / inv) / 0.042 : 1
                                  }))
        }
        SorcererModel.appendTube(rings: rings, segments: SorcererModel.palmSegments, closed: true,
                                 uRepeat: 1, into: &mesh, buildIndices: buildIndices)

        // Four fingers fanning from the palm end (medial → lateral), curling toward the palm.
        let fingerOffsets: [Float] = [-0.030, -0.010, 0.010, 0.030]
        let fingerLengths: [Float] = [0.066, 0.074, 0.070, 0.056]
        let curlRotation = simd_quatf(angle: curl, axis: side)
        for i in 0..<4 {
            let base = arm.wrist + forward * 0.088 + side * fingerOffsets[i] - palm * 0.002
            let fan = simd_normalize(forward + side * (fingerOffsets[i] * 2.2))
            let direction = simd_normalize(curlRotation.act(fan))
            SorcererModel.appendCapsule(base: base, axis: direction, length: fingerLengths[i], radius: 0.0085,
                                        reference: side, segments: SorcererModel.fingerSegments,
                                        into: &mesh, buildIndices: buildIndices)
        }
        // Thumb from the medial edge of the palm.
        let thumbBase = arm.wrist + forward * 0.035 - side * 0.038
        let thumbDirection = simd_normalize(-side * 0.75 + forward * 0.6 + palm * (0.15 + 0.5 * curl))
        SorcererModel.appendCapsule(base: thumbBase, axis: thumbDirection, length: 0.052, radius: 0.0105,
                                    reference: forward, segments: SorcererModel.fingerSegments,
                                    into: &mesh, buildIndices: buildIndices)
    }

    // MARK: - SDF proxies (RENDER_CONTRACT §4: 7 capsules)

    /// Torso, head, hood sphere and the four arm capsules for the fallback SDF scene.
    func sdfPrimitives(pose: SorcererPose) -> [SDFPrimitive] {
        var primitives: [SDFPrimitive] = []
        let torsoBottom = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, 0.22, 0))
        let torsoTop = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, 1.50, 0))
        primitives.append(SDFPrimitives.capsule(from: torsoBottom, to: torsoTop, radius: 0.30, material: .cloth))
        let headCenter = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, SorcererModel.headHeight, 0))
        primitives.append(SDFPrimitives.capsule(from: headCenter - SIMD3<Float>(0, 0.02, 0), to: headCenter + SIMD3<Float>(0, 0.02, 0), radius: 0.10, material: .skin))
        let hoodCenter = SorcererModel.torsoPoint(pose, SIMD3<Float>(0, 1.70, -0.01))
        primitives.append(SDFPrimitives.sphere(center: hoodCenter, radius: 0.19, material: .cloth))
        for s: Float in [-1, 1] {
            let arm = SorcererModel.armChain(pose, side: s)
            primitives.append(SDFPrimitives.capsule(from: arm.shoulder, to: arm.elbow, radius: 0.07, material: .cloth))
            primitives.append(SDFPrimitives.capsule(from: arm.elbow, to: arm.wrist, radius: 0.06, material: .cloth))
        }
        return primitives
    }

    // MARK: - Tube generation

    /// Ring with a frame derived from `axis` and a reference direction for `e1`.
    private static func ring(center: SIMD3<Float>, axis: SIMD3<Float>, reference: SIMD3<Float>, radius: Float, v: Float,
                             modulation: ((Float) -> Float)?) -> TubeRing {
        let unitAxis = axis.safeNormalized(fallback: SIMD3<Float>(0, 1, 0))
        var e1 = reference - unitAxis * simd_dot(reference, unitAxis)
        if simd_length_squared(e1) < 1e-10 {
            e1 = MeshBuilder.anyPerpendicular(to: unitAxis)
        }
        e1 = simd_normalize(e1)
        let e2 = simd_cross(unitAxis, e1)
        return TubeRing(center: center, axis: unitAxis, e1: e1, e2: e2, radius: radius, v: v, modulation: modulation)
    }

    /// Capsule of `radius` from `base` along `axis` for `length` (hemispherical ends).
    private static func appendCapsule(base: SIMD3<Float>, axis: SIMD3<Float>, length: Float, radius: Float,
                                      reference: SIMD3<Float>, segments: Int,
                                      into mesh: inout MeshData, buildIndices: Bool) {
        let unitAxis = axis.safeNormalized(fallback: SIMD3<Float>(0, 1, 0))
        var rings: [TubeRing] = []
        let capSteps = 3
        let total = length + 2 * radius
        rings.append(ring(center: base - unitAxis * radius, axis: unitAxis, reference: reference, radius: 0, v: 0, modulation: nil))
        for k in 1...capSteps {
            let theta = Float.pi * 0.5 * Float(k) / Float(capSteps)
            let along = -radius * cos(theta)
            rings.append(ring(center: base + unitAxis * along, axis: unitAxis, reference: reference,
                              radius: radius * sin(theta), v: (along + radius) / total, modulation: nil))
        }
        for k in 1...capSteps {
            let theta = Float.pi * 0.5 * Float(k) / Float(capSteps)
            let along = length + radius * sin(theta)
            rings.append(ring(center: base + unitAxis * along, axis: unitAxis, reference: reference,
                              radius: radius * cos(theta), v: (along + radius) / total, modulation: nil))
        }
        appendTube(rings: rings, segments: segments, closed: true, uRepeat: 1, into: &mesh, buildIndices: buildIndices)
    }

    /// Stitches `rings` into a tube. Rings with radius 0 become poles (fans). All rings
    /// share `segments`, so the topology depends only on `rings.count`, `segments` and
    /// `closed`. Winding: right-handed frames ⇒ quads (a, b, c, d) face outward.
    private static func appendTube(rings: [TubeRing], segments: Int, closed: Bool, uRepeat: Float,
                                   into mesh: inout MeshData, buildIndices: Bool) {
        let ringCount = rings.count
        guard ringCount >= 2, segments >= 3 else { return }
        let columns = closed ? segments : segments + 1
        let base = mesh.vertices.count

        // Radius slope along the path for the normals.
        var slopes: [Float] = []
        slopes.reserveCapacity(ringCount)
        for k in 0..<ringCount {
            let previous = rings[max(k - 1, 0)]
            let next = rings[min(k + 1, ringCount - 1)]
            let distance = simd_length(next.center - previous.center)
            slopes.append(distance > 1e-6 ? (next.radius - previous.radius) / distance : 0)
        }

        for k in 0..<ringCount {
            let ring = rings[k]
            let isPole = ring.radius <= 1e-6
            let sweep = ring.phiEnd - ring.phiStart
            for c in 0..<columns {
                let fraction = Float(c) / Float(segments)
                let phi = ring.phiStart + fraction * sweep
                let cosPhi = cos(phi), sinPhi = sin(phi)
                let radial = ring.e1 * cosPhi + ring.e2 * sinPhi
                var radius = ring.radius
                if let modulation = ring.modulation, !isPole {
                    radius = max(radius * modulation(phi), 1e-4)
                }
                let position = ring.center + radial * radius
                let normal: SIMD3<Float>
                if isPole {
                    normal = k == 0 ? -ring.axis : ring.axis
                } else {
                    normal = simd_normalize(radial - ring.axis * slopes[k])
                }
                let uDirection = -ring.e1 * sinPhi + ring.e2 * cosPhi
                let tangent = MeshBuilder.tangent(alongU: uDirection, normal: normal, vDirection: ring.axis)
                let uv = SIMD2<Float>(fraction * uRepeat, ring.v)
                mesh.vertices.append(MeshData.makeVertex(position: position, normal: normal, tangent: tangent, uv: uv))
            }
        }

        guard buildIndices else { return }
        for k in 0..<(ringCount - 1) {
            let lowerPole = rings[k].radius <= 1e-6
            let upperPole = rings[k + 1].radius <= 1e-6
            for c in 0..<segments {
                let cNext = closed ? (c + 1) % segments : c + 1
                let a = base + k * columns + c
                let b = base + k * columns + cNext
                let cc = base + (k + 1) * columns + cNext
                let d = base + (k + 1) * columns + c
                if lowerPole && upperPole {
                    continue
                } else if lowerPole {
                    mesh.addTriangle(a, cc, d)
                } else if upperPole {
                    mesh.addTriangle(a, b, cc)
                } else {
                    mesh.addQuad(a, b, cc, d)
                }
            }
        }
    }
}
