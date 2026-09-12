//
//  SceneBuilder.swift
//  Bornless Ritual — procedural chamber geometry and static instances
//  (ARCHITECTURE §2 units/axes/scene layout; RENDER_CONTRACT §2 row 0 instances,
//  §4 fallback SDF mirror, §5 one primitive AS per mesh; ShaderTypes.h `Vertex`,
//  `InstanceData`, `SDFPrimitive`).
//
//  Role: builds every mesh once into `SceneResources` (chamber walls + ceiling with
//  corner pilasters and a ceiling beam, floor, altar body + polished top, quarter
//  candles with iron stands and wicks, altar candles with holders, censer) and
//  registers the sorcerer's two dynamic regions LAST so SceneUpdater can rewrite
//  their vertices per tick. Produces the static `InstanceData` list (model = prevModel)
//  and the static half of the SDF scene; the dynamic half comes from `SorcererModel`.
//
//  Culling notes (for GBufferPass, which honours `MeshRegion.cullMode`): the chamber is
//  an inward-facing box registered with `.back` culling so that camera presets outside
//  the 6 m room (front, profile, threequarter, low are beyond the walls) look through
//  the near wall; pilasters omit their wall-flush faces and the beam its ceiling-flush
//  face for the same reason. The sorcerer's cloth is `.none` (the hood interior is
//  visible through the face opening).
//

import Foundation
import Metal
import simd
import RitualCore

// MARK: - Layout constants

/// Scene layout (ARCHITECTURE §2), in metres.
enum SceneLayout {
    /// Chamber interior half extents (6 × 4 × 6 m).
    static let chamberHalfExtents = SIMD3<Float>(3, 2, 3)
    /// Chamber centre (floor at y = 0).
    static let chamberCenter = SIMD3<Float>(0, 2, 0)
    /// Altar block size (X, Y, Z).
    static let altarSize = SIMD3<Float>(1.0, 0.85, 0.5)
    /// Altar floor position.
    static let altarPosition = SIMD3<Float>(0, 0, -2.4)
    /// Height of the polished top slab.
    static let altarTopThickness: Float = 0.05
    /// Altar candle bases.
    static let altarCandlePositions: [SIMD3<Float>] = [SIMD3<Float>(-0.35, 0.85, -2.4), SIMD3<Float>(0.35, 0.85, -2.4)]
    /// Censer base position (bowl sits on the altar).
    static let censerPosition = SIMD3<Float>(0, 0.85, -2.3)
    /// Smoke emission point above the censer (FroxelParams.censerPosition).
    static let censerSmokeOrigin = SIMD3<Float>(0, 0.9, -2.3)
    /// Quarter candle wax radius / height, stand height.
    static let quarterWaxRadius: Float = 0.035
    static let quarterWaxHeight: Float = 0.22
    static let quarterStandHeight: Float = 0.90
    /// Altar candle wax radius / height.
    static let altarWaxRadius: Float = 0.025
    static let altarWaxHeight: Float = 0.18
    /// Wick height above the wax top (flame origin = wax top + wick).
    static let wickHeight: Float = 0.01
    /// Sigil centre and outer ring radius.
    static let sigilCenter = SIMD3<Float>(0, 1.55, 0)
    static let sigilOuterRadius: Float = 0.75
    /// Chalk double-circle radii.
    static let chalkInnerRadius: Float = 1.45
    static let chalkOuterRadius: Float = 1.60
    /// Daemon condensation centre and final height.
    static let daemonCenter = SIMD3<Float>(0, 1.15, -0.25)
    static let daemonHeight: Float = 2.4

    /// Flame origin of a quarter candle (y = 1.13 m).
    static func quarterFlameOrigin(_ quarter: Quarter) -> SIMD3<Float> {
        quarter.flamePositionSIMD
    }

    /// Flame origin of altar candle `index` (0 = west, 1 = east).
    static func altarFlameOrigin(_ index: Int) -> SIMD3<Float> {
        let base = altarCandlePositions[min(max(index, 0), altarCandlePositions.count - 1)]
        return base + SIMD3<Float>(0, altarWaxHeight + wickHeight, 0)
    }
}

// MARK: - SDF primitive factory

/// Builders for `SDFPrimitive` records (ShaderTypes.h layout; `SDF.h` semantics).
enum SDFPrimitives {
    /// Identity quaternion (x, y, z, w).
    static let identityRotation = SIMD4<Float>(0, 0, 0, 1)

    private static func base(type: Int32, position: SIMD3<Float>, halfExtents: SIMD3<Float>, material: MaterialIndex,
                             rotation: SIMD4<Float> = identityRotation, endB: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                             rounding: Float = 0) -> SDFPrimitive {
        var primitive = SDFPrimitive()
        primitive.position = position
        primitive.type = UInt32(type)
        primitive.halfExtents = halfExtents
        primitive.materialIndex = material.rawValue
        primitive.rotation = rotation
        primitive.endB = endB
        primitive.rounding = rounding
        return primitive
    }

    /// Axis-aligned (or rotated) box with optional edge rounding.
    static func box(center: SIMD3<Float>, halfExtents: SIMD3<Float>, material: MaterialIndex,
                    rotation: simd_quatf = .identity, rounding: Float = 0) -> SDFPrimitive {
        base(type: SDF_BOX, position: center, halfExtents: halfExtents, material: material, rotation: rotation.xyzw, rounding: rounding)
    }

    /// Sphere.
    static func sphere(center: SIMD3<Float>, radius: Float, material: MaterialIndex) -> SDFPrimitive {
        base(type: SDF_SPHERE, position: center, halfExtents: SIMD3<Float>(radius, 0, 0), material: material)
    }

    /// Capsule between two world points.
    static func capsule(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, material: MaterialIndex) -> SDFPrimitive {
        base(type: SDF_CAPSULE, position: a, halfExtents: SIMD3<Float>(radius, simd_length(b - a) * 0.5, 0), material: material, endB: b)
    }

    /// Y-axis cylinder centred at `center` (half height `halfHeight`).
    static func cylinder(center: SIMD3<Float>, radius: Float, halfHeight: Float, material: MaterialIndex, rounding: Float = 0) -> SDFPrimitive {
        base(type: SDF_CYLINDER, position: center, halfExtents: SIMD3<Float>(radius, halfHeight, 0), material: material, rounding: rounding)
    }

    /// Horizontal floor plane through `y` (positive above).
    static func floorPlane(y: Float, material: MaterialIndex) -> SDFPrimitive {
        base(type: SDF_PLANE, position: SIMD3<Float>(0, y, 0), halfExtents: SIMD3<Float>(0, 0, 0), material: material)
    }

    /// Chamber interior (inverted box).
    static func room(center: SIMD3<Float>, halfExtents: SIMD3<Float>, material: MaterialIndex) -> SDFPrimitive {
        base(type: SDF_ROOM, position: center, halfExtents: halfExtents, material: material)
    }
}

// MARK: - Built scene

/// Output of `SceneBuilder.build`: everything SceneUpdater needs per frame.
final class BuiltScene {
    /// Static instances (model = prevModel; geometryIndex = the region's slot 0).
    let staticInstances: [InstanceData]
    /// Static SDF primitives (room, floor, altar, candles, censer, pilasters, beam).
    let staticSDFPrimitives: [SDFPrimitive]
    /// Sorcerer cloth region (dynamic, registered second to last).
    let sorcererClothRegion: MeshRegion
    /// Sorcerer skin region (dynamic, registered last).
    let sorcererSkinRegion: MeshRegion
    /// The sorcerer model that rebuilds the dynamic vertices.
    let sorcerer: SorcererModel
    /// Registered mesh names in order (debug panel).
    let meshNames: [String]

    init(staticInstances: [InstanceData], staticSDFPrimitives: [SDFPrimitive],
         sorcererClothRegion: MeshRegion, sorcererSkinRegion: MeshRegion, sorcerer: SorcererModel, meshNames: [String]) {
        self.staticInstances = staticInstances
        self.staticSDFPrimitives = staticSDFPrimitives
        self.sorcererClothRegion = sorcererClothRegion
        self.sorcererSkinRegion = sorcererSkinRegion
        self.sorcerer = sorcerer
        self.meshNames = meshNames
    }
}

// MARK: - SceneBuilder

/// Generates the chamber meshes into `SceneResources`.
enum SceneBuilder {

    /// Mesh registry names.
    enum MeshName {
        static let chamber = "chamber"
        static let floor = "floor"
        static let altarBody = "altarBody"
        static let altarTop = "altarTop"
        static let candleWax = "candleWax"
        static let candleWick = "candleWick"
        static let candleStand = "candleStand"
        static let altarWax = "altarWax"
        static let altarWick = "altarWick"
        static let altarHolder = "altarHolder"
        static let censer = "censer"
        static let sorcererCloth = "sorcererCloth"
        static let sorcererSkin = "sorcererSkin"
    }

    /// Builds every mesh, uploads the material table and returns the static instances.
    ///
    /// - Parameters:
    ///   - scene: The scene buffers to fill (must be freshly created).
    ///   - seed: Simulation seed (used for the deterministic melted candle rims).
    /// - Throws: `SceneResourceError` when a capacity is exceeded.
    static func build(into scene: SceneResources, seed: UInt64) throws -> BuiltScene {
        scene.setMaterials(Materials.table)

        var instances: [InstanceData] = []
        var sdf: [SDFPrimitive] = []
        var names: [String] = []

        func register(_ name: String, _ mesh: MeshData, cull: MTLCullMode = .back) throws -> MeshRegion {
            let region = try scene.registerMesh(name: name, vertices: mesh.vertices, indices: mesh.indices, cullMode: cull, isDynamic: false)
            names.append(name)
            return region
        }
        func place(_ region: MeshRegion, _ material: MaterialIndex, _ model: float4x4) {
            instances.append(SceneBuilder.makeInstance(geometryIndex: region.firstGeometryIndex, material: material, model: model))
        }

        // Chamber: walls + ceiling (no floor face), corner pilasters, ceiling beam.
        let chamberRegion = try register(MeshName.chamber, chamberMesh(), cull: .back)
        place(chamberRegion, .wallStone, .identity)
        sdf.append(SDFPrimitives.room(center: SceneLayout.chamberCenter, halfExtents: SceneLayout.chamberHalfExtents, material: .wallStone))
        for pilaster in pilasterBoxes() {
            sdf.append(SDFPrimitives.box(center: pilaster.center, halfExtents: pilaster.halfExtents, material: .wallStone))
        }
        let beam = beamBox()
        sdf.append(SDFPrimitives.box(center: beam.center, halfExtents: beam.halfExtents, material: .wallStone))

        // Floor.
        let floorRegion = try register(MeshName.floor, MeshBuilder.horizontalGrid(width: 6, depth: 6, y: 0, subdivisions: 12))
        place(floorRegion, .floorStone, .identity)
        sdf.append(SDFPrimitives.floorPlane(y: 0, material: .floorStone))

        // Altar: rough body and a polished top slab.
        let altar = SceneLayout.altarSize
        let bodyHeight = altar.y - SceneLayout.altarTopThickness
        let bodyCenter = SceneLayout.altarPosition + SIMD3<Float>(0, bodyHeight * 0.5, 0)
        let bodyHalf = SIMD3<Float>(altar.x * 0.5, bodyHeight * 0.5, altar.z * 0.5)
        let bodyRegion = try register(MeshName.altarBody, MeshBuilder.roundedBox(center: bodyCenter, halfExtents: bodyHalf, radius: 0.03, subdivisions: 6))
        place(bodyRegion, .altarStone, .identity)
        sdf.append(SDFPrimitives.box(center: bodyCenter, halfExtents: bodyHalf, material: .altarStone, rounding: 0.03))
        let topCenter = SceneLayout.altarPosition + SIMD3<Float>(0, bodyHeight + SceneLayout.altarTopThickness * 0.5, 0)
        let topHalf = SIMD3<Float>(altar.x * 0.5 + 0.01, SceneLayout.altarTopThickness * 0.5, altar.z * 0.5 + 0.01)
        let topRegion = try register(MeshName.altarTop, MeshBuilder.roundedBox(center: topCenter, halfExtents: topHalf, radius: 0.012, subdivisions: 4))
        place(topRegion, .altarTop, .identity)
        sdf.append(SDFPrimitives.box(center: topCenter, halfExtents: topHalf, material: .altarTop, rounding: 0.012))

        // Quarter candles: wax (melted rim), wick, iron stand — one mesh each, four instances.
        let waxRegion = try register(MeshName.candleWax, candleWaxMesh(radius: SceneLayout.quarterWaxRadius, height: SceneLayout.quarterWaxHeight, seed: seed, salt: 11))
        let wickRegion = try register(MeshName.candleWick, MeshBuilder.cylinder(radius: 0.0022, height: SceneLayout.wickHeight + 0.004, radialSegments: 8))
        let standRegion = try register(MeshName.candleStand, candleStandMesh())
        for (index, quarter) in Quarter.allCases.enumerated() {
            let base = quarter.candlePositionSIMD
            // Rotate each candle so the shared melted rim looks different per quarter.
            let yaw = simd_quatf(angle: Float(index) * (Float.pi * 0.5) + 0.4, axis: SIMD3<Float>(0, 1, 0))
            let waxBase = base + SIMD3<Float>(0, SceneLayout.quarterStandHeight, 0)
            place(waxRegion, .wax, float4x4(translation: waxBase, rotation: yaw, scale: SIMD3<Float>(1, 1, 1)))
            let wickBase = waxBase + SIMD3<Float>(0, SceneLayout.quarterWaxHeight - 0.002, 0)
            place(wickRegion, .wick, float4x4(translation: wickBase))
            place(standRegion, .iron, float4x4(translation: base, rotation: yaw, scale: SIMD3<Float>(1, 1, 1)))
            sdf.append(SDFPrimitives.cylinder(center: waxBase + SIMD3<Float>(0, SceneLayout.quarterWaxHeight * 0.5, 0),
                                              radius: SceneLayout.quarterWaxRadius, halfHeight: SceneLayout.quarterWaxHeight * 0.5, material: .wax))
            sdf.append(SDFPrimitives.cylinder(center: base + SIMD3<Float>(0, SceneLayout.quarterStandHeight * 0.5, 0),
                                              radius: 0.012, halfHeight: SceneLayout.quarterStandHeight * 0.5 - 0.02, material: .iron))
        }

        // Altar candles.
        let altarWaxRegion = try register(MeshName.altarWax, candleWaxMesh(radius: SceneLayout.altarWaxRadius, height: SceneLayout.altarWaxHeight, seed: seed, salt: 23))
        let altarWickRegion = try register(MeshName.altarWick, MeshBuilder.cylinder(radius: 0.002, height: SceneLayout.wickHeight + 0.004, radialSegments: 8))
        let holderRegion = try register(MeshName.altarHolder, altarHolderMesh(innerRadius: SceneLayout.altarWaxRadius + 0.001))
        for (index, base) in SceneLayout.altarCandlePositions.enumerated() {
            let yaw = simd_quatf(angle: Float(index) * 2.2 + 1.0, axis: SIMD3<Float>(0, 1, 0))
            place(altarWaxRegion, .wax, float4x4(translation: base, rotation: yaw, scale: SIMD3<Float>(1, 1, 1)))
            place(altarWickRegion, .wick, float4x4(translation: base + SIMD3<Float>(0, SceneLayout.altarWaxHeight - 0.002, 0)))
            place(holderRegion, .iron, float4x4(translation: base))
            sdf.append(SDFPrimitives.cylinder(center: base + SIMD3<Float>(0, SceneLayout.altarWaxHeight * 0.5, 0),
                                              radius: SceneLayout.altarWaxRadius, halfHeight: SceneLayout.altarWaxHeight * 0.5, material: .wax))
        }

        // Censer.
        let censerRegion = try register(MeshName.censer, censerMesh())
        place(censerRegion, .iron, float4x4(translation: SceneLayout.censerPosition))
        sdf.append(SDFPrimitives.sphere(center: SceneLayout.censerPosition + SIMD3<Float>(0, 0.05, 0), radius: 0.07, material: .iron))

        // Sorcerer (dynamic, last). Topology from the rest pose; validate the winding once.
        let sorcerer = SorcererModel()
        var cloth = sorcerer.clothMesh(pose: .rest, buildIndices: true)
        var skin = sorcerer.skinMesh(pose: .rest, buildIndices: true)
        let clothFlips = cloth.enforceWinding()
        let skinFlips = skin.enforceWinding()
        if clothFlips != 0 || skinFlips != 0 {
            // The per-frame rebuild reuses these indices, so a generator inconsistency
            // would show up here (logged by the caller through `meshNames` inspection).
            names.append("warning: sorcerer winding fixed (cloth \(clothFlips), skin \(skinFlips))")
        }
        let clothRegion = try scene.registerMesh(name: MeshName.sorcererCloth, vertices: cloth.vertices, indices: cloth.indices, cullMode: .none, isDynamic: true)
        names.append(MeshName.sorcererCloth)
        let skinRegion = try scene.registerMesh(name: MeshName.sorcererSkin, vertices: skin.vertices, indices: skin.indices, cullMode: .back, isDynamic: true)
        names.append(MeshName.sorcererSkin)

        return BuiltScene(staticInstances: instances, staticSDFPrimitives: sdf,
                          sorcererClothRegion: clothRegion, sorcererSkinRegion: skinRegion,
                          sorcerer: sorcerer, meshNames: names)
    }

    // MARK: - Instances

    /// Fills an `InstanceData` (prevModel = model; SceneUpdater overrides prevModel for moving instances).
    static func makeInstance(geometryIndex: Int, material: MaterialIndex, model: float4x4) -> InstanceData {
        var instance = InstanceData()
        instance.model = model
        instance.prevModel = model
        instance.normalMatrix = model.normalMatrix
        instance.materialIndex = material.rawValue
        instance.geometryIndex = UInt32(max(geometryIndex, 0))
        instance.flags = 0
        instance.padding = 0
        return instance
    }

    // MARK: - Meshes

    /// A box description (centre, half extents).
    struct BoxSpec {
        let center: SIMD3<Float>
        let halfExtents: SIMD3<Float>
    }

    /// Corner pilasters: 0.30 × 0.30 m columns at the four corners, full height.
    static func pilasterBoxes() -> [BoxSpec] {
        let h = SceneLayout.chamberHalfExtents
        let size: Float = 0.30
        var boxes: [BoxSpec] = []
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                boxes.append(BoxSpec(center: SIMD3<Float>(sx * (h.x - size * 0.5), h.y, sz * (h.z - size * 0.5)),
                                     halfExtents: SIMD3<Float>(size * 0.5, h.y, size * 0.5)))
            }
        }
        return boxes
    }

    /// Ceiling beam along X at z = 1.5 m, 0.4 m square, flush with the ceiling.
    static func beamBox() -> BoxSpec {
        let h = SceneLayout.chamberHalfExtents
        return BoxSpec(center: SIMD3<Float>(0, 2 * h.y - 0.2, 1.5), halfExtents: SIMD3<Float>(h.x, 0.2, 0.2))
    }

    /// Chamber walls and ceiling with pilasters and the beam (inward-facing shell).
    static func chamberMesh() -> MeshData {
        var mesh = MeshBuilder.box(center: SceneLayout.chamberCenter, halfExtents: SceneLayout.chamberHalfExtents,
                                   inward: true, uvPerMetre: 0.5, omitFaces: [.negativeY])
        for pilaster in pilasterBoxes() {
            // Omit the two wall-flush faces and the floor/ceiling-flush faces.
            var omit: Set<MeshBuilder.BoxFace> = [.positiveY, .negativeY]
            omit.insert(pilaster.center.x > 0 ? .positiveX : .negativeX)
            omit.insert(pilaster.center.z > 0 ? .positiveZ : .negativeZ)
            mesh.append(MeshBuilder.box(center: pilaster.center, halfExtents: pilaster.halfExtents, uvPerMetre: 0.5, omitFaces: omit))
        }
        let beam = beamBox()
        mesh.append(MeshBuilder.box(center: beam.center, halfExtents: beam.halfExtents, uvPerMetre: 0.5,
                                    omitFaces: [.positiveY, .positiveX, .negativeX]))
        return mesh
    }

    /// Wax cylinder whose top rim is melted by seeded low-frequency noise.
    static func candleWaxMesh(radius: Float, height: Float, seed: UInt64, salt: UInt32) -> MeshData {
        let phase0 = Float(Hash.unit(seed, salt, 1, 0)) * MeshBuilder.twoPi
        let phase1 = Float(Hash.unit(seed, salt, 2, 0)) * MeshBuilder.twoPi
        let amplitude0 = 0.012 + 0.008 * Float(Hash.unit(seed, salt, 3, 0))
        let amplitude1 = 0.004 + 0.004 * Float(Hash.unit(seed, salt, 4, 0))
        return MeshBuilder.cylinder(radius: radius, height: height, radialSegments: 28, heightSegments: 4) { angle in
            -amplitude0 * (0.5 + 0.5 * sin(angle + phase0)) - amplitude1 * (0.5 + 0.5 * sin(3 * angle + phase1))
        }
    }

    /// Iron quarter-candle stand: base disc, shaft and a shallow cup (0.90 m tall).
    static func candleStandMesh() -> MeshData {
        let top = SceneLayout.quarterStandHeight
        let profile: [LatheProfilePoint] = [
            LatheProfilePoint(radius: 0, height: 0, v: 0),
            LatheProfilePoint(radius: 0.10, height: 0, v: 0.02),
            LatheProfilePoint(radius: 0.10, height: 0.012, v: 0.04),
            LatheProfilePoint(radius: 0.04, height: 0.022, v: 0.06),
            LatheProfilePoint(radius: 0.014, height: 0.04, v: 0.08),
            LatheProfilePoint(radius: 0.012, height: top - 0.06, v: 0.85),
            LatheProfilePoint(radius: 0.022, height: top - 0.04, v: 0.90),
            LatheProfilePoint(radius: 0.046, height: top - 0.02, v: 0.95),
            LatheProfilePoint(radius: 0.048, height: top, v: 0.98),
            LatheProfilePoint(radius: 0, height: top, v: 1.0),
        ]
        return MeshBuilder.lathe(profile: profile, radialSegments: 20)
    }

    /// Iron dish around an altar candle's base (annulus with a raised lip).
    static func altarHolderMesh(innerRadius: Float) -> MeshData {
        let profile: [LatheProfilePoint] = [
            LatheProfilePoint(radius: innerRadius, height: 0.012, v: 0),
            LatheProfilePoint(radius: innerRadius + 0.004, height: 0.012, v: 0.2),
            LatheProfilePoint(radius: 0.045, height: 0.004, v: 0.6),
            LatheProfilePoint(radius: 0.05, height: 0.012, v: 0.8),
            LatheProfilePoint(radius: 0.05, height: 0.0, v: 0.9),
            LatheProfilePoint(radius: innerRadius, height: 0.0, v: 1.0),
        ]
        return MeshBuilder.lathe(profile: profile, radialSegments: 20)
    }

    /// Censer: footed bowl with a flared rim and an inner surface (lathe).
    static func censerMesh() -> MeshData {
        let rows: [(Float, Float)] = [
            (0.0, 0.0), (0.032, 0.0), (0.032, 0.008), (0.016, 0.014), (0.014, 0.03), (0.04, 0.045), (0.064, 0.072),
            (0.071, 0.09), (0.08, 0.096), (0.08, 0.104), (0.064, 0.104), (0.06, 0.094), (0.05, 0.074), (0.03, 0.054), (0.0, 0.048),
        ]
        var profile: [LatheProfilePoint] = []
        for (k, row) in rows.enumerated() {
            profile.append(LatheProfilePoint(radius: row.0, height: row.1, v: Float(k) / Float(rows.count - 1)))
        }
        return MeshBuilder.lathe(profile: profile, radialSegments: 28)
    }
}
