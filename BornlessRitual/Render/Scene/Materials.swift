//
//  Materials.swift
//  Bornless Ritual — the `MaterialData` table (ShaderTypes.h `MaterialData`,
//  BufferIndexMaterials; ARCHITECTURE §2 surfaces; RENDER_CONTRACT §2 rows 2/4/6:
//  glossy floor + altar top, wax translucency, skin SSS, chalk decal by flag).
//
//  Role: fixed material indices shared by SceneBuilder (instances), SceneUpdater
//  (SDF mirror material ids) and the G-buffer / reflection shaders (via the buffer),
//  plus the linear-sRGB blackbody helper that mirrors `blackbody_rgb` in Common.h so
//  CPU-computed light radiance matches what the flame shader emits.
//
//  Atlas convention (matches GBuffer.metal, which computes `albedo = material.albedo ×
//  atlas.rgb` and `roughness = material.roughness × normalAtlas.z`): the procedural
//  atlases store *multipliers* in [0, 1]. ProceduralTextures.metal keeps the albedo
//  multiplier's plateau near 0.92 and the roughness multiplier's mean near 0.93, so the
//  `MaterialData` values below are the ARCHITECTURE targets divided by those means
//  (floor albedo 0.32 → 0.35, roughness 0.18 → 0.19, …). Stone layers are sampled
//  triplanar in world space, so their `uvScale` is tiles per metre; the other layers
//  use the mesh uv × `uvScale`.
//

import Foundation
import simd

// MARK: - Material flags

/// Swift mirror of the `MATERIAL_FLAG_*` bit masks in ShaderTypes.h. The C macros are
/// shift expressions (`(1u << n)`), which the Clang importer does not reliably expose
/// as constants, so the values are restated here; they must stay identical.
enum MaterialFlags {
    /// `MATERIAL_FLAG_SSS` — screen-space subsurface (skin).
    static let sss: UInt32 = 1 << 0
    /// `MATERIAL_FLAG_WAX` — wax translucency.
    static let wax: UInt32 = 1 << 1
    /// `MATERIAL_FLAG_CHALK` — floor: apply the chalk decal mask.
    static let chalk: UInt32 = 1 << 2
    /// `MATERIAL_FLAG_GLOSSY` — traced reflections.
    static let glossy: UInt32 = 1 << 3
    /// `MATERIAL_FLAG_EMISSIVE`.
    static let emissive: UInt32 = 1 << 4
    /// `MATERIAL_FLAG_NO_SHADOW` — excluded from the acceleration structure.
    static let noShadow: UInt32 = 1 << 5
}

// MARK: - Material indices

/// Fixed indices into the material buffer (`InstanceData.materialIndex`,
/// `SDFPrimitive.materialIndex`). Order is part of the scene contract.
enum MaterialIndex: UInt32, CaseIterable {
    /// Polished dark flagstone floor (glossy, carries the chalk decal).
    case floorStone = 0
    /// Rough chamber wall stone (walls, ceiling, pilasters, beam).
    case wallStone = 1
    /// Altar block body (rough-cut stone).
    case altarStone = 2
    /// Altar top slab (polished, glossy).
    case altarTop = 3
    /// Near-black robe cloth (sorcerer robe, hood, sleeves).
    case cloth = 4
    /// Candle wax (translucent).
    case wax = 5
    /// Skin (hands, face) with screen-space subsurface scattering.
    case skin = 6
    /// Iron (candle stands, altar-candle holders, censer).
    case iron = 7
    /// Wick (untextured, near black).
    case wick = 8

    /// Sentinel for "no atlas layer" (`MaterialData.textureLayer`).
    static let noTextureLayer: UInt32 = 0xFFFF_FFFF

    /// The material record for this index.
    var data: MaterialData {
        switch self {
        case .floorStone:
            return Materials.make(albedo: SIMD3<Float>(0.35, 0.35, 0.36), roughness: 0.19,
                                  flags: MaterialFlags.glossy | MaterialFlags.chalk,
                                  layer: MaterialTextureLayerFloorStone, uvScale: 0.5, normalStrength: 1.0)
        case .wallStone:
            return Materials.make(albedo: SIMD3<Float>(0.49, 0.47, 0.435), roughness: 0.91,
                                  flags: 0, layer: MaterialTextureLayerWallStone, uvScale: 0.5, normalStrength: 1.2)
        case .altarStone:
            return Materials.make(albedo: SIMD3<Float>(0.39, 0.38, 0.36), roughness: 0.65,
                                  flags: 0, layer: MaterialTextureLayerAltarStone, uvScale: 1.0, normalStrength: 1.0)
        case .altarTop:
            return Materials.make(albedo: SIMD3<Float>(0.37, 0.36, 0.35), roughness: 0.24,
                                  flags: MaterialFlags.glossy, layer: MaterialTextureLayerAltarStone, uvScale: 1.0, normalStrength: 0.5)
        case .cloth:
            return Materials.make(albedo: SIMD3<Float>(0.055, 0.05, 0.055), roughness: 0.97,
                                  flags: 0, layer: MaterialTextureLayerCloth, uvScale: 6.0, normalStrength: 0.8)
        case .wax:
            return Materials.make(albedo: SIMD3<Float>(1.0, 0.955, 0.85), roughness: 0.38,
                                  flags: MaterialFlags.wax, sssColor: SIMD3<Float>(1.0, 0.88, 0.66), sssRadiusMm: 6.0,
                                  layer: MaterialTextureLayerWax, uvScale: 2.0, normalStrength: 0.6)
        case .skin:
            return Materials.make(albedo: SIMD3<Float>(0.78, 0.565, 0.455), roughness: 0.48,
                                  flags: MaterialFlags.sss, sssColor: SIMD3<Float>(0.9, 0.3, 0.2), sssRadiusMm: 2.5,
                                  layer: MaterialTextureLayerSkin, uvScale: 4.0, normalStrength: 0.5)
        case .iron:
            return Materials.make(albedo: SIMD3<Float>(0.045, 0.045, 0.05), roughness: 0.54, metallic: 1.0,
                                  flags: 0, layer: MaterialTextureLayerIron, uvScale: 4.0, normalStrength: 0.6)
        case .wick:
            return Materials.make(albedo: SIMD3<Float>(0.05, 0.04, 0.03), roughness: 0.90,
                                  flags: 0, layer: nil, uvScale: 1.0, normalStrength: 0.0)
        }
    }
}

// MARK: - Table

/// Builders for the material table.
enum Materials {
    /// The full table in `MaterialIndex` order (upload with `SceneResources.setMaterials`).
    static var table: [MaterialData] {
        MaterialIndex.allCases.map { $0.data }
    }

    /// Fills one `MaterialData`.
    ///
    /// - Parameters:
    ///   - albedo: Linear base colour (multiplied by the atlas albedo factor).
    ///   - roughness: Base roughness (multiplied by the atlas roughness factor).
    ///   - metallic: 0 dielectric, 1 metal.
    ///   - emissive: Linear emissive radiance (0 for every scene material).
    ///   - flags: `MATERIAL_FLAG_*` bits.
    ///   - sssColor: Subsurface tint.
    ///   - sssRadiusMm: Subsurface radius in millimetres.
    ///   - layer: Atlas layer, or nil for untextured.
    ///   - uvScale: Multiplier applied to the mesh uv before sampling the atlas.
    ///   - normalStrength: Scale of the atlas normal perturbation.
    static func make(albedo: SIMD3<Float>, roughness: Float, metallic: Float = 0,
                     emissive: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                     flags: UInt32,
                     sssColor: SIMD3<Float> = SIMD3<Float>(0, 0, 0), sssRadiusMm: Float = 0,
                     layer: MaterialTextureLayer?, uvScale: Float, normalStrength: Float) -> MaterialData {
        var material = MaterialData()
        material.albedo = albedo
        material.roughness = roughness
        material.emissive = emissive
        material.metallic = metallic
        material.sssColor = sssColor
        material.sssRadiusMm = sssRadiusMm
        material.flags = flags
        if let layer = layer {
            material.textureLayer = UInt32(layer.rawValue)
        } else {
            material.textureLayer = MaterialIndex.noTextureLayer
        }
        material.uvScale = uvScale
        material.normalStrength = normalStrength
        return material
    }
}

// MARK: - Blackbody (mirror of Common.h)

/// CPU mirror of the Common.h colour helpers so light radiance computed by
/// SceneUpdater agrees with the flame shader's emission.
enum BlackbodyColor {
    /// Linear-sRGB colour of the Planckian fit at 6500 K (`kBlackbodyWhite6500` in Common.h).
    static let white6500 = SIMD3<Float>(1.043989, 0.983291, 1.035941)

    /// CIE 1931 (x, y) of a Planckian radiator (Krystek 1985 uv fit, clamped 800–15000 K).
    static func planckianXY(_ temperatureK: Float) -> SIMD2<Float> {
        let t = ScalarMath.clamp(temperatureK, 800, 15000)
        let t2 = t * t
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) /
                (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t2)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) /
                (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t2)
        let d = 2.0 * u - 8.0 * v + 4.0
        return SIMD2<Float>(3.0 * u / d, 2.0 * v / d)
    }

    /// CIE XYZ (Y = 1) → linear sRGB (Rec.709, D65).
    static func xyzToLinearSRGB(_ xyz: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>( 3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
                     -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
                      0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z)
    }

    /// Linear-sRGB chromaticity of a blackbody, normalised so 6500 K is (1, 1, 1)
    /// (identical arithmetic to `blackbody_rgb`).
    static func rgb(_ temperatureK: Float) -> SIMD3<Float> {
        let xy = planckianXY(temperatureK)
        let y = max(xy.y, 1e-4)
        let xyz = SIMD3<Float>(xy.x / y, 1.0, (1.0 - xy.x - xy.y) / y)
        let rgb = simd_max(xyzToLinearSRGB(xyz), SIMD3<Float>(0, 0, 0))
        return rgb / white6500
    }

    /// `(T / Tref)^4` (`blackbody_relative_power`).
    static func relativePower(_ temperatureK: Float, reference: Float) -> Float {
        let r = temperatureK / max(reference, 1)
        let r2 = r * r
        return r2 * r2
    }
}
