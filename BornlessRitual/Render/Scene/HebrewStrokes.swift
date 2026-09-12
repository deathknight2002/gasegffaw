//
//  HebrewStrokes.swift
//  Bornless Ritual — stroke-font table for the 22 Hebrew letters and the chalk
//  stroke layout (RENDER_CONTRACT §2 row 1 "chalk mask 2048² (circle + name letters
//  … simple stroked glyph paths from Hebrew letter strokes table)"; ARCHITECTURE §2
//  "the daemon's name in chalk at the four quarter marks").
//
//  Role: each letter is a small set of polylines (3–7 segments) in an em box with
//  x ∈ [0, 1] (left → right), y ∈ [−0.2, 1] (baseline 0, descenders below). `layout`
//  places a right-to-left word along an arbitrary 2-D frame and returns `ChalkSegment`
//  records in floor metres (x, z) for ProceduralTextures.metal (`proctex_chalk`).
//  The same table is reused by SceneUpdater for the sigil's rune-ring filaments.
//
//  `ChalkSegment` is a locally defined struct (not in ShaderTypes.h); its layout is
//  duplicated in ProceduralTextures.metal and must stay identical (24 bytes).
//

import Foundation
import simd
import RitualCore

// MARK: - ChalkSegment (mirrored in ProceduralTextures.metal)

/// One chalk stroke segment in floor metres. Layout: float2 a, float2 b, float width,
/// float grain (stride 24, alignment 8) — identical to the MSL struct.
struct ChalkSegment {
    /// Segment start (world x, z).
    var a: SIMD2<Float>
    /// Segment end (world x, z).
    var b: SIMD2<Float>
    /// Stroke width in metres.
    var width: Float
    /// Per-stroke grain phase (decorrelates the chalk texture between strokes).
    var grain: Float

    /// Creates a segment.
    init(a: SIMD2<Float>, b: SIMD2<Float>, width: Float, grain: Float) {
        self.a = a
        self.b = b
        self.width = width
        self.grain = grain
    }
}

// MARK: - Stroke table

/// Simplified block-Hebrew glyphs as polylines.
enum HebrewStrokes {

    /// Polylines of `letter` in the em box (x right 0…1, y up, baseline 0).
    static func polylines(for letter: HebrewLetter) -> [[SIMD2<Float>]] {
        switch letter {
        case .aleph:
            return [[p(0.15, 0.92), p(0.88, 0.08)],
                    [p(0.90, 0.92), p(0.90, 0.75), p(0.62, 0.52)],
                    [p(0.42, 0.50), p(0.12, 0.28), p(0.12, 0.08)]]
        case .beth:
            return [[p(0.15, 0.92), p(0.88, 0.92), p(0.88, 0.08)],
                    [p(0.98, 0.08), p(0.08, 0.08)]]
        case .gimel:
            return [[p(0.50, 0.96), p(0.70, 0.92), p(0.70, 0.08)],
                    [p(0.70, 0.45), p(0.25, 0.08)]]
        case .daleth:
            return [[p(0.10, 0.92), p(0.92, 0.92)],
                    [p(0.76, 0.92), p(0.76, 0.08)]]
        case .he:
            return [[p(0.10, 0.92), p(0.90, 0.92), p(0.90, 0.08)],
                    [p(0.15, 0.62), p(0.15, 0.08)]]
        case .vav:
            return [[p(0.35, 0.96), p(0.52, 0.92), p(0.52, 0.08)]]
        case .zayin:
            return [[p(0.30, 0.92), p(0.72, 0.92)],
                    [p(0.52, 0.92), p(0.50, 0.08)]]
        case .chet:
            return [[p(0.10, 0.08), p(0.10, 0.92), p(0.90, 0.92), p(0.90, 0.08)]]
        case .tet:
            return [[p(0.15, 0.92), p(0.15, 0.22), p(0.30, 0.08), p(0.70, 0.08), p(0.85, 0.22), p(0.85, 0.72)],
                    [p(0.85, 0.72), p(0.62, 0.90)]]
        case .yod:
            return [[p(0.40, 0.96), p(0.58, 0.92), p(0.58, 0.58)]]
        case .kaf:
            return [[p(0.15, 0.92), p(0.72, 0.92), p(0.88, 0.76), p(0.88, 0.24), p(0.72, 0.08), p(0.15, 0.08)]]
        case .lamed:
            return [[p(0.85, 1.00), p(0.60, 0.82), p(0.60, 0.32), p(0.15, 0.08)]]
        case .mem:
            return [[p(0.90, 0.92), p(0.25, 0.92), p(0.10, 0.76), p(0.10, 0.36)],
                    [p(0.90, 0.92), p(0.90, 0.08), p(0.30, 0.08)],
                    [p(0.55, 0.76), p(0.55, 0.40)]]
        case .nun:
            return [[p(0.38, 0.96), p(0.60, 0.92), p(0.60, 0.16), p(0.15, 0.08)]]
        case .samekh:
            return [[p(0.15, 0.92), p(0.85, 0.92), p(0.85, 0.22), p(0.70, 0.08), p(0.30, 0.08), p(0.15, 0.22), p(0.15, 0.92)]]
        case .ayin:
            return [[p(0.90, 0.92), p(0.55, 0.16), p(0.15, 0.08)],
                    [p(0.20, 0.92), p(0.36, 0.42), p(0.55, 0.16)]]
        case .pe:
            return [[p(0.15, 0.08), p(0.85, 0.08), p(0.85, 0.76), p(0.70, 0.92), p(0.30, 0.92)],
                    [p(0.30, 0.92), p(0.46, 0.80), p(0.56, 0.60)]]
        case .tsade:
            return [[p(0.20, 0.92), p(0.50, 0.50), p(0.20, 0.10), p(0.90, 0.10)],
                    [p(0.90, 0.92), p(0.50, 0.50)]]
        case .qof:
            return [[p(0.15, 0.92), p(0.85, 0.92), p(0.85, 0.56), p(0.50, 0.46)],
                    [p(0.20, 0.82), p(0.20, -0.18)]]
        case .resh:
            return [[p(0.10, 0.92), p(0.74, 0.92), p(0.86, 0.80), p(0.86, 0.08)]]
        case .shin:
            return [[p(0.10, 0.88), p(0.15, 0.10), p(0.90, 0.10), p(0.90, 0.90)],
                    [p(0.50, 0.86), p(0.50, 0.10)]]
        case .tav:
            return [[p(0.10, 0.92), p(0.90, 0.92), p(0.90, 0.08)],
                    [p(0.32, 0.92), p(0.32, 0.26), p(0.12, 0.08)]]
        }
    }

    /// Straight segments (a, b) of `letter` in the em box.
    static func segments(for letter: HebrewLetter) -> [(SIMD2<Float>, SIMD2<Float>)] {
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for line in polylines(for: letter) {
            guard line.count >= 2 else { continue }
            for i in 0..<(line.count - 1) {
                result.append((line[i], line[i + 1]))
            }
        }
        return result
    }

    /// Nominal glyph width in em (letters occupy x ∈ [0.1, 0.9]).
    static let glyphWidthEm: Float = 0.85
    /// Advance between consecutive letters in em.
    static let advanceEm: Float = 1.0

    /// Lays out `letters` (reading order, written right-to-left) with the word centred
    /// on `center`. `right` and `up` are the unit axes of the text frame in the target
    /// 2-D space; `em` is the letter height in that space.
    ///
    /// - Returns: Segments in the target space (a, b pairs).
    static func layoutWord(_ letters: [HebrewLetter], center: SIMD2<Float>, right: SIMD2<Float>, up: SIMD2<Float>,
                           em: Float) -> [(SIMD2<Float>, SIMD2<Float>)] {
        guard !letters.isEmpty else { return [] }
        let count = Float(letters.count)
        let totalWidth = ((count - 1) * advanceEm + glyphWidthEm) * em
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for (k, letter) in letters.enumerated() {
            // First letter sits at the right end; each following letter steps left.
            let leftEdge = totalWidth * 0.5 - (Float(k) * advanceEm + glyphWidthEm) * em
            for (a, b) in segments(for: letter) {
                let pa = center + right * (leftEdge + a.x * em) + up * (a.y * em)
                let pb = center + right * (leftEdge + b.x * em) + up * (b.y * em)
                result.append((pa, pb))
            }
        }
        return result
    }

    /// Chalk segments for the daemon's name at the four quarters between the double
    /// circle (radii `innerRadius`/`outerRadius`), plus a pair of radial tick marks
    /// flanking each word. Coordinates are floor metres (world x, z).
    ///
    /// - Parameters:
    ///   - letters: The name in derivation order (`AgrippaName.letters`).
    ///   - innerRadius: Inner chalk circle radius (1.45 m).
    ///   - outerRadius: Outer chalk circle radius (1.60 m).
    ///   - strokeWidth: Chalk stroke width in metres.
    static func quarterNameSegments(letters: [HebrewLetter], innerRadius: Float, outerRadius: Float,
                                    strokeWidth: Float) -> [ChalkSegment] {
        var result: [ChalkSegment] = []
        let band = outerRadius - innerRadius
        let em = band * 0.62
        let midRadius = (innerRadius + outerRadius) * 0.5
        // Quarter directions in (x, z): East +X, South +Z, West −X, North −Z.
        let directions: [SIMD2<Float>] = [SIMD2<Float>(1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(-1, 0), SIMD2<Float>(0, -1)]
        var grain: Float = 0
        for direction in directions {
            // A reader at the centre facing the quarter: "up" is outward, "right" is to their right.
            let up = direction
            let right = SIMD2<Float>(-direction.y, direction.x)
            let center = direction * midRadius - up * (em * 0.5)
            for (a, b) in layoutWord(letters, center: center, right: right, up: up, em: em) {
                result.append(ChalkSegment(a: a, b: b, width: strokeWidth, grain: grain))
                grain += 0.37
            }
            // Flanking tick marks.
            let count = Float(max(letters.count, 1))
            let halfWidth = ((count - 1) * advanceEm + glyphWidthEm) * em * 0.5 + 0.05
            for side: Float in [-1, 1] {
                let base = direction * innerRadius + right * (side * halfWidth)
                let tip = direction * outerRadius + right * (side * halfWidth)
                result.append(ChalkSegment(a: base - up * 0.03, b: tip + up * 0.03, width: strokeWidth * 1.2, grain: grain))
                grain += 0.37
            }
        }
        return result
    }

    private static func p(_ x: Float, _ y: Float) -> SIMD2<Float> {
        SIMD2<Float>(x, y)
    }
}
