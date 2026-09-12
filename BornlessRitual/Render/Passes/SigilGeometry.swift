//
//  SigilGeometry.swift
//  Bornless Ritual — built-in filament geometry for the sigil's five rune rings
//  (RENDER_CONTRACT §2 row 10 "filament rune rings (SigilFilamentVertex line strips,
//  rotated per ring by RingHistory[tick].angle)"; ARCHITECTURE §3 "rings i = 0..4 with
//  radii 0.75, 0.62, 0.50, 0.39, 0.29 m … the Hebrew name letters and the kamea path
//  are inscribed"; ShaderTypes.h `SigilFilamentVertex`).
//
//  Role: builds, once on the CPU from a `DaemonProfile` (the owner's by default), the
//  stroke geometry SigilPass draws through `sigil_filament_vertex`:
//    ring 0 (0.75 m)  the closed kamea sigil path (`SigilPath.polyline` with its start
//                     circle and end bar) inscribed inside the ring, plus the ring circle;
//    ring 1 (0.62 m)  a circle filament;
//    ring 2 (0.50 m)  the five Hebrew letters of the name (HebrewStrokes glyphs) spaced
//                     around the ring, upright when read from the centre facing outward;
//    ring 3 (0.39 m)  a circle with 12 radial rune ticks;
//    ring 4 (0.29 m)  a circle with 8 radial rune ticks.
//  Encoding: a SEGMENT LIST — two vertices per straight segment (`a`, `b`), the same
//  layout Render/Scene/SigilFilaments.swift (the scene job) emits, so the vertex shader
//  (`segment = vertex_id / 6`) draws either without knowing which built it. Every ring is
//  emitted at ring angle 0 in world space; the shader rotates ring `i` about the sigil
//  centre by RingHistory[tick][i].angle.
//
//  SigilPass uploads this geometry only when the scene's filament buffer is still empty
//  (SceneUpdater normally writes SigilFilaments' layout at construction), or when its
//  `filamentSource` is set to `.builtIn`.
//

import Foundation
import simd
import RitualCore

/// Builder of the built-in sigil filament segment list.
enum SigilGeometry {

    // MARK: Tunables

    /// Segments per full ring circle.
    static let circleSegments = 96
    /// Segments of the kamea start-marker circle.
    static let startMarkerSegments = 16
    /// Half side of the square the normalised kamea path is mapped into (metres); the
    /// path's cell centres span [1/12, 11/12] of the square, so the farthest vertex sits
    /// at ≈ 0.60 m from the centre, inside ring 0 (0.75 m).
    static let kameaHalfSide: Float = 0.51
    /// Letter em height on ring 2 (metres).
    static let letterEm: Float = 0.09
    /// Inset of the ring circles' inner glyph band from the ring radius (metres).
    static let glyphInset: Float = 0.03
    /// Rune tick counts on rings 3 and 4.
    static let ring3TickCount = 12
    static let ring4TickCount = 8
    /// Rune tick length (metres); every other tick is 1.6× longer.
    static let tickLength: Float = 0.03
    /// Inset of the tick's outer end from the ring radius (metres).
    static let tickInset: Float = 0.006

    /// Stroke colours (linear RGB, multiplied by the shader's core/edge glow profile).
    static let circleColor = SIMD3<Float>(1.0, 0.92, 0.75)
    static let pathColor = SIMD3<Float>(1.0, 0.72, 0.38)
    static let letterColor = SIMD3<Float>(1.0, 0.70, 0.35)
    static let tickColor = SIMD3<Float>(1.0, 0.45, 0.10)

    /// Ring radii in metres, outermost first (ARCHITECTURE §3 / `SigilDynamics.ringRadii`).
    static var defaultRadii: [Float] {
        SigilDynamics.ringRadii.map { Float($0) }
    }

    // MARK: Build

    /// Builds the segment list for `daemon` around `center` with the given ring radii.
    ///
    /// - Parameters:
    ///   - daemon: Supplies the name letters (ring 2) and the kamea path (ring 0).
    ///   - center: Sigil centre in world space (ARCHITECTURE §2: (0, 1.55, 0)).
    ///   - radii: Ring radii, outermost first; rings beyond the fifth are ignored.
    /// - Returns: Vertices, two per segment, at ring angle 0.
    static func build(daemon: DaemonProfile, center: SIMD3<Float>, radii: [Float] = SigilGeometry.defaultRadii) -> [SigilFilamentVertex] {
        var vertices: [SigilFilamentVertex] = []
        vertices.reserveCapacity(2048)
        let ringCount = min(radii.count, Int(RING_COUNT))
        for ring in 0..<ringCount {
            let radius = radii[ring]
            switch ring {
            case 0:
                appendCircle(radius: radius, ring: ring, glow: 0.8, color: circleColor, center: center, into: &vertices)
                appendKameaPath(daemon.sigil, ring: ring, center: center, into: &vertices)
            case 1:
                appendCircle(radius: radius, ring: ring, glow: 1.0, color: circleColor, center: center, into: &vertices)
            case 2:
                appendCircle(radius: radius, ring: ring, glow: 0.7, color: circleColor, center: center, into: &vertices)
                appendNameLetters(daemon.name.letters, ringRadius: radius, ring: ring, center: center, into: &vertices)
            case 3:
                appendCircle(radius: radius, ring: ring, glow: 1.0, color: circleColor, center: center, into: &vertices)
                appendTicks(count: ring3TickCount, ringRadius: radius, ring: ring, center: center, into: &vertices)
            default:
                appendCircle(radius: radius, ring: ring, glow: 1.0, color: circleColor, center: center, into: &vertices)
                appendTicks(count: ring4TickCount, ringRadius: radius, ring: ring, center: center, into: &vertices)
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
            let p0 = SIMD2<Float>(cos(a0), sin(a0)) * radius
            let p1 = SIMD2<Float>(cos(a1), sin(a1)) * radius
            appendSegment(lift(p0, center), lift(p1, center), glow: glow, color: color, ring: ring, into: &vertices)
        }
    }

    /// The kamea sigil path — polyline, start circle and end bar — inscribed in ring 0.
    /// Normalised sigil space (x right, y down, [0, 1]²) maps to the plane square of half
    /// side `kameaHalfSide` centred on the sigil centre.
    private static func appendKameaPath(_ sigil: SigilPath, ring: Int, center: SIMD3<Float>,
                                        into vertices: inout [SigilFilamentVertex]) {
        let polyline = sigil.polyline.map { $0.simd }
        guard polyline.count >= 2 else { return }
        let side = kameaHalfSide * 2
        func place(_ p: SIMD2<Float>) -> SIMD3<Float> {
            lift(SIMD2<Float>((p.x - 0.5) * side, (p.y - 0.5) * side), center)
        }
        for i in 0..<(polyline.count - 1) {
            appendSegment(place(polyline[i]), place(polyline[i + 1]), glow: 1.0, color: pathColor, ring: ring, into: &vertices)
        }
        if let start = sigil.startMarkerCenter?.simd {
            let markerRadius = Float(sigil.startMarkerRadius)
            let steps = startMarkerSegments
            for k in 0..<steps {
                let t0 = Float(k) / Float(steps) * 2 * Float.pi
                let t1 = Float(k + 1) / Float(steps) * 2 * Float.pi
                let p0 = start + SIMD2<Float>(cos(t0), sin(t0)) * markerRadius
                let p1 = start + SIMD2<Float>(cos(t1), sin(t1)) * markerRadius
                appendSegment(place(p0), place(p1), glow: 0.9, color: pathColor, ring: ring, into: &vertices)
            }
        }
        if let bar = sigil.endBarSegment {
            appendSegment(place(bar.start.simd), place(bar.end.simd), glow: 1.0, color: pathColor, ring: ring, into: &vertices)
        }
    }

    /// The name's letters spaced evenly around the inside of a ring. Hebrew reads right
    /// to left, so the first letter takes the largest angle and each following letter
    /// steps clockwise (decreasing angle) as seen by a reader at the centre.
    private static func appendNameLetters(_ letters: [HebrewLetter], ringRadius: Float, ring: Int, center: SIMD3<Float>,
                                          into vertices: inout [SigilFilamentVertex]) {
        guard !letters.isEmpty else { return }
        let em = letterEm
        let glyphRadius = ringRadius - glyphInset - em * 0.5
        let step = 2 * Float.pi / Float(letters.count)
        for (k, letter) in letters.enumerated() {
            let angle = Float.pi * 0.5 - Float(k) * step
            let direction = SIMD2<Float>(cos(angle), sin(angle))       // (x, z)
            let up = direction                                          // outward = "up" for a reader at the centre
            let right = SIMD2<Float>(-direction.y, direction.x)         // increasing angle = reader's right
            let glyphCenter = direction * glyphRadius
            for (a, b) in HebrewStrokes.segments(for: letter) {
                let pa = glyphCenter + right * ((a.x - 0.5) * em) + up * ((a.y - 0.4) * em)
                let pb = glyphCenter + right * ((b.x - 0.5) * em) + up * ((b.y - 0.4) * em)
                appendSegment(lift(pa, center), lift(pb, center), glow: 0.9, color: letterColor, ring: ring, into: &vertices)
            }
        }
    }

    /// Radial rune ticks just inside a ring; every other tick is longer.
    private static func appendTicks(count: Int, ringRadius: Float, ring: Int, center: SIMD3<Float>,
                                    into vertices: inout [SigilFilamentVertex]) {
        guard count > 0 else { return }
        for k in 0..<count {
            let angle = Float(k) / Float(count) * 2 * Float.pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let isLong = k % 2 == 0
            let length = isLong ? tickLength * 1.6 : tickLength
            let outer = direction * (ringRadius - tickInset)
            let inner = direction * (ringRadius - tickInset - length)
            appendSegment(lift(outer, center), lift(inner, center), glow: isLong ? 0.85 : 0.65, color: tickColor, ring: ring, into: &vertices)
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
