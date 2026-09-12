//
//  SigilFilaments.swift
//  Bornless Ritual — the sigil's ember-filament rune rings as `SigilFilamentVertex`
//  geometry (ARCHITECTURE §3 "rings i = 0..4 with radii 0.75, 0.62, 0.50, 0.39, 0.29 m,
//  ember filament rune rings (the Hebrew name letters and the kamea path are inscribed
//  on rings 0 and 2)"; RENDER_CONTRACT §2 row 10 "filament rune rings (SigilFilamentVertex
//  line strips, rotated per ring by RingHistory[tick].angle, expanded to quads)";
//  ShaderTypes.h `SigilFilamentVertex`, `BufferIndexSigilVertices`).
//
//  Role: builds, once, the world-space stroke geometry of the five rings: the ring
//  circles, the daemon's name (HebrewStrokes glyphs) written four times around ring 0,
//  the kamea sigil path (`DaemonProfile.sigil`, with its start circle and end bar)
//  repeated six times inside ring 2, and rune tick marks on rings 1, 3 and 4. Every ring
//  is emitted at `RingHistory` angle 0; SigilPass rotates ring `i` about the sigil centre
//  (SigilParams.center, axis +Y) by RingHistory[tick][i].angle.
//
//  Encoding (assumption for SigilPass, recorded in the caveats): the buffer is a
//  SEGMENT LIST — two vertices per straight segment (a, b), `filamentVertexCount` is even,
//  and the vertex shader expands vertex pair k = vertexID / 6 … into a camera-facing quad.
//  Each vertex carries `glow` (stroke intensity), `color` (linear) and `ring` (index as
//  float). No strip-restart markers are needed with this encoding.
//

import Foundation
import simd
import RitualCore

/// Builder of the sigil filament stroke buffer.
enum SigilFilaments {

    /// Segments per full ring circle.
    static let circleSegments = 96
    /// Letter height on ring 0 (metres).
    static let letterEm: Float = 0.075
    /// Kamea glyph size on ring 2 (metres).
    static let sigilGlyphSize: Float = 0.10
    /// Copies of the kamea sigil around ring 2.
    static let sigilGlyphCount = 6
    /// Copies of the name around ring 0 (one per quarter).
    static let nameCopies = 4

    /// Stroke colours (linear RGB).
    static let circleColor = SIMD3<Float>(1.0, 0.92, 0.75)
    static let glyphColor = SIMD3<Float>(1.0, 0.70, 0.35)
    static let tickColor = SIMD3<Float>(1.0, 0.45, 0.10)

    /// Builds the filament segment list.
    ///
    /// - Parameters:
    ///   - daemon: Supplies the name letters and the kamea sigil path.
    ///   - center: Sigil centre in world space (ARCHITECTURE §2: (0, 1.55, 0)).
    ///   - radii: Ring radii, outermost first (`SigilDynamics.ringRadii`).
    /// - Returns: Vertices, two per segment, in world space at ring angle 0.
    static func build(daemon: DaemonProfile, center: SIMD3<Float>, radii: [Float]) -> [SigilFilamentVertex] {
        var vertices: [SigilFilamentVertex] = []
        vertices.reserveCapacity(4096)
        for (ring, radius) in radii.enumerated() {
            appendCircle(radius: radius, ring: ring, glow: 1.0, color: circleColor, center: center, into: &vertices)
            switch ring {
            case 0:
                appendCircle(radius: radius - 0.014, ring: ring, glow: 0.7, color: circleColor, center: center, into: &vertices)
                appendName(daemon.name.letters, ringRadius: radius, ring: ring, center: center, into: &vertices)
            case 1:
                appendTicks(count: 36, ringRadius: radius, length: 0.028, longEvery: 3, ring: ring, center: center, into: &vertices)
            case 2:
                appendKameaSigil(daemon.sigil, ringRadius: radius, ring: ring, center: center, into: &vertices)
            case 3:
                appendTicks(count: 24, ringRadius: radius, length: 0.024, longEvery: 4, ring: ring, center: center, into: &vertices)
            default:
                appendTicks(count: 12, ringRadius: radius, length: 0.02, longEvery: 2, ring: ring, center: center, into: &vertices)
                appendCircle(radius: max(radius - 0.05, 0.05), ring: ring, glow: 0.6, color: tickColor, center: center, into: &vertices)
            }
        }
        return vertices
    }

    // MARK: - Pieces

    /// Full circle of `radius` in the sigil plane.
    private static func appendCircle(radius: Float, ring: Int, glow: Float, color: SIMD3<Float>, center: SIMD3<Float>,
                                     into vertices: inout [SigilFilamentVertex]) {
        let segments = circleSegments
        for k in 0..<segments {
            let a0 = Float(k) / Float(segments) * 2 * Float.pi
            let a1 = Float(k + 1) / Float(segments) * 2 * Float.pi
            let p0 = center + SIMD3<Float>(cos(a0) * radius, 0, sin(a0) * radius)
            let p1 = center + SIMD3<Float>(cos(a1) * radius, 0, sin(a1) * radius)
            appendSegment(p0, p1, glow: glow, color: color, ring: ring, into: &vertices)
        }
    }

    /// The name written `nameCopies` times around the inside of ring 0, letters upright
    /// when read from the centre facing outward.
    private static func appendName(_ letters: [HebrewLetter], ringRadius: Float, ring: Int, center: SIMD3<Float>,
                                   into vertices: inout [SigilFilamentVertex]) {
        guard !letters.isEmpty else { return }
        let em = letterEm
        let wordRadius = ringRadius - 0.03 - em * 0.5
        for copy in 0..<nameCopies {
            let angle = Float(copy) / Float(nameCopies) * 2 * Float.pi + Float.pi * 0.5
            let direction = SIMD2<Float>(cos(angle), sin(angle))       // (x, z)
            let up = direction
            let right = SIMD2<Float>(-direction.y, direction.x)
            let wordCenter = direction * wordRadius - up * (em * 0.5)
            for (a, b) in HebrewStrokes.layoutWord(letters, center: wordCenter, right: right, up: up, em: em) {
                appendSegment(lift(a, center), lift(b, center), glow: 0.85, color: glyphColor, ring: ring, into: &vertices)
            }
        }
    }

    /// The kamea sigil (polyline + start circle + end bar) repeated inside ring 2.
    private static func appendKameaSigil(_ sigil: SigilPath, ringRadius: Float, ring: Int, center: SIMD3<Float>,
                                         into vertices: inout [SigilFilamentVertex]) {
        let polyline = sigil.polyline.map { $0.simd }
        guard polyline.count >= 2 else { return }
        let size = sigilGlyphSize
        let glyphRadius = ringRadius - 0.03 - size * 0.5
        for copy in 0..<sigilGlyphCount {
            let angle = Float(copy) / Float(sigilGlyphCount) * 2 * Float.pi + Float.pi / Float(sigilGlyphCount)
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let up = direction
            let right = SIMD2<Float>(-direction.y, direction.x)
            let glyphCenter = direction * glyphRadius
            // Normalised sigil space: x right, y down, [0,1]².
            func place(_ p: SIMD2<Float>) -> SIMD3<Float> {
                let local = glyphCenter + right * ((p.x - 0.5) * size) + up * ((0.5 - p.y) * size)
                return lift(local, center)
            }
            for i in 0..<(polyline.count - 1) {
                appendSegment(place(polyline[i]), place(polyline[i + 1]), glow: 0.9, color: glyphColor, ring: ring, into: &vertices)
            }
            if let start = sigil.startMarkerCenter?.simd {
                let markerRadius = Float(sigil.startMarkerRadius)
                let steps = 12
                for k in 0..<steps {
                    let t0 = Float(k) / Float(steps) * 2 * Float.pi
                    let t1 = Float(k + 1) / Float(steps) * 2 * Float.pi
                    let p0 = start + SIMD2<Float>(cos(t0), sin(t0)) * markerRadius
                    let p1 = start + SIMD2<Float>(cos(t1), sin(t1)) * markerRadius
                    appendSegment(place(p0), place(p1), glow: 0.8, color: glyphColor, ring: ring, into: &vertices)
                }
            }
            if let bar = sigil.endBarSegment {
                appendSegment(place(bar.start.simd), place(bar.end.simd), glow: 0.9, color: glyphColor, ring: ring, into: &vertices)
            }
        }
    }

    /// Radial rune ticks just inside a ring; every `longEvery`-th tick is longer.
    private static func appendTicks(count: Int, ringRadius: Float, length: Float, longEvery: Int, ring: Int,
                                    center: SIMD3<Float>, into vertices: inout [SigilFilamentVertex]) {
        guard count > 0 else { return }
        for k in 0..<count {
            let angle = Float(k) / Float(count) * 2 * Float.pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let isLong = longEvery > 0 && k % longEvery == 0
            let tickLength = isLong ? length * 1.8 : length
            let outer = direction * (ringRadius - 0.006)
            let inner = direction * (ringRadius - 0.006 - tickLength)
            appendSegment(lift(outer, center), lift(inner, center), glow: isLong ? 0.8 : 0.6, color: tickColor, ring: ring, into: &vertices)
        }
    }

    // MARK: - Vertex helpers

    /// (x, z) in the sigil plane → world position at the sigil height.
    private static func lift(_ p: SIMD2<Float>, _ center: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(center.x + p.x, center.y, center.z + p.y)
    }

    /// Appends one segment (two vertices).
    private static func appendSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, glow: Float, color: SIMD3<Float>, ring: Int,
                                      into vertices: inout [SigilFilamentVertex]) {
        vertices.append(makeVertex(a, glow: glow, color: color, ring: ring))
        vertices.append(makeVertex(b, glow: glow, color: color, ring: ring))
    }

    /// Fills one `SigilFilamentVertex`.
    static func makeVertex(_ position: SIMD3<Float>, glow: Float, color: SIMD3<Float>, ring: Int) -> SigilFilamentVertex {
        var vertex = SigilFilamentVertex()
        vertex.position = position
        vertex.glow = glow
        vertex.color = color
        vertex.ring = Float(ring)
        return vertex
    }
}
