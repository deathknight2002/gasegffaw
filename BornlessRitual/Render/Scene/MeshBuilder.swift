//
//  MeshBuilder.swift
//  Bornless Ritual — procedural triangle-mesh primitives (ShaderTypes.h `Vertex`
//  layout: position, normal, tangent xyz + handedness, uv; RENDER_CONTRACT §2 row 2
//  G-buffer vertex fetch, §5 acceleration-structure vertex source).
//
//  Role: `MeshData` accumulates vertices and 32-bit triangle indices for one mesh
//  region, and `MeshBuilder` generates boxes, rounded boxes, grids, cylinders and
//  surfaces of revolution (lathes) used by SceneBuilder and Sorcerer. All primitives
//  produce outward normals and counter-clockwise front faces (the winding
//  GBufferPass expects); `MeshData.enforceWinding()` re-checks every triangle against
//  its vertex normals so a generator mistake can never flip a face.
//
//  Tangent convention (matches GBuffer.metal `sample_uv_mapped`): tangent.xyz points
//  along +u, `cross(normal, tangent) × tangent.w` points along +v.
//

import Foundation
import simd

// MARK: - MeshData

/// Vertices and triangle indices of one mesh (indices are relative to the mesh's first vertex).
struct MeshData {
    /// Vertex records in `Vertex` layout.
    var vertices: [Vertex] = []
    /// Triangle list (three indices per triangle).
    var indices: [UInt32] = []

    /// Creates an empty mesh.
    init() {}

    /// Number of triangles.
    var triangleCount: Int { indices.count / 3 }

    /// Builds one vertex record.
    static func makeVertex(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD4<Float>, uv: SIMD2<Float>) -> Vertex {
        var vertex = Vertex()
        vertex.position = position
        vertex.normal = normal
        vertex.tangent = tangent
        vertex.uv = uv
        vertex.padding = SIMD2<Float>(0, 0)
        return vertex
    }

    /// Appends another mesh, offsetting its indices.
    mutating func append(_ other: MeshData) {
        let base = UInt32(vertices.count)
        vertices.append(contentsOf: other.vertices)
        indices.reserveCapacity(indices.count + other.indices.count)
        for index in other.indices {
            indices.append(index + base)
        }
    }

    /// Appends a triangle by absolute vertex indices.
    mutating func addTriangle(_ a: Int, _ b: Int, _ c: Int) {
        indices.append(UInt32(a))
        indices.append(UInt32(b))
        indices.append(UInt32(c))
    }

    /// Appends a quad (a, b, c, d in counter-clockwise order) as two triangles.
    mutating func addQuad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        addTriangle(a, b, c)
        addTriangle(a, c, d)
    }

    /// Transforms positions by `matrix`, normals by its inverse-transpose and tangents as directions.
    mutating func transform(by matrix: float4x4) {
        let normalMatrix = matrix.normalMatrix
        for i in 0..<vertices.count {
            var vertex = vertices[i]
            vertex.position = matrix.transformPoint(vertex.position)
            vertex.normal = normalMatrix.transformDirection(vertex.normal).safeNormalized(fallback: vertex.normal)
            let tangent = matrix.transformDirection(SIMD3<Float>(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z))
            let unitTangent = tangent.safeNormalized(fallback: SIMD3<Float>(1, 0, 0))
            vertex.tangent = SIMD4<Float>(unitTangent.x, unitTangent.y, unitTangent.z, vertex.tangent.w)
            vertices[i] = vertex
        }
        if matrix.upperLeft3x3.determinant < 0 {
            flipWinding()
        }
    }

    /// Translates every position.
    mutating func translate(by offset: SIMD3<Float>) {
        for i in 0..<vertices.count {
            vertices[i].position += offset
        }
    }

    /// Reverses every triangle (front faces become back faces).
    mutating func flipWinding() {
        var i = 0
        while i + 2 < indices.count {
            let b = indices[i + 1]
            indices[i + 1] = indices[i + 2]
            indices[i + 2] = b
            i += 3
        }
    }

    /// Negates every normal and reverses the winding (turns a box inside out).
    mutating func invert() {
        for i in 0..<vertices.count {
            vertices[i].normal = -vertices[i].normal
        }
        flipWinding()
    }

    /// Makes every triangle counter-clockwise when viewed from the side its vertex
    /// normals point to. Returns the number of triangles that had to be flipped.
    @discardableResult
    mutating func enforceWinding() -> Int {
        var flipped = 0
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { i += 3; continue }
            let a = vertices[ia].position, b = vertices[ib].position, c = vertices[ic].position
            let faceNormal = simd_cross(b - a, c - a)
            let averageNormal = vertices[ia].normal + vertices[ib].normal + vertices[ic].normal
            if simd_dot(faceNormal, averageNormal) < 0 {
                indices[i + 1] = UInt32(ic)
                indices[i + 2] = UInt32(ib)
                flipped += 1
            }
            i += 3
        }
        return flipped
    }

    /// Recomputes tangents from the uv parameterisation (Lengyel's accumulation),
    /// orthogonalised against the vertex normal, with the handedness in `w`.
    mutating func computeTangents() {
        let count = vertices.count
        guard count > 0 else { return }
        var tangentSum = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: count)
        var bitangentSum = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: count)
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            guard ia < count, ib < count, ic < count else { i += 3; continue }
            let p0 = vertices[ia].position, p1 = vertices[ib].position, p2 = vertices[ic].position
            let w0 = vertices[ia].uv, w1 = vertices[ib].uv, w2 = vertices[ic].uv
            let e1 = p1 - p0, e2 = p2 - p0
            let d1 = w1 - w0, d2 = w2 - w0
            let det = d1.x * d2.y - d2.x * d1.y
            if abs(det) > 1e-12 {
                let r = 1 / det
                let tangent = (e1 * d2.y - e2 * d1.y) * r
                let bitangent = (e2 * d1.x - e1 * d2.x) * r
                tangentSum[ia] += tangent; tangentSum[ib] += tangent; tangentSum[ic] += tangent
                bitangentSum[ia] += bitangent; bitangentSum[ib] += bitangent; bitangentSum[ic] += bitangent
            }
            i += 3
        }
        for v in 0..<count {
            let normal = vertices[v].normal
            var tangent = tangentSum[v] - normal * simd_dot(normal, tangentSum[v])
            if simd_length_squared(tangent) < 1e-12 {
                tangent = MeshBuilder.anyPerpendicular(to: normal)
            }
            tangent = simd_normalize(tangent)
            let handedness: Float = simd_dot(simd_cross(normal, tangent), bitangentSum[v]) < 0 ? -1 : 1
            vertices[v].tangent = SIMD4<Float>(tangent.x, tangent.y, tangent.z, handedness)
        }
    }

    /// Axis-aligned bounds of the positions (min, max); zero for an empty mesh.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = vertices.first else { return (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0)) }
        var lo = first.position
        var hi = first.position
        for vertex in vertices {
            lo = simd_min(lo, vertex.position)
            hi = simd_max(hi, vertex.position)
        }
        return (lo, hi)
    }
}

// MARK: - Lathe profile

/// One point of a surface-of-revolution profile.
struct LatheProfilePoint {
    /// Distance from the axis (0 at a pole).
    var radius: Float
    /// Height along the axis.
    var height: Float
    /// Texture v coordinate of this ring.
    var v: Float

    /// Creates a profile point.
    init(radius: Float, height: Float, v: Float) {
        self.radius = radius
        self.height = height
        self.v = v
    }
}

// MARK: - MeshBuilder

/// Procedural primitive generators. Every generator returns a mesh with outward
/// normals, counter-clockwise front faces and valid tangents.
enum MeshBuilder {

    /// Two-pi as Float.
    static let twoPi: Float = 2 * Float.pi

    /// Any unit vector perpendicular to `n`.
    static func anyPerpendicular(to n: SIMD3<Float>) -> SIMD3<Float> {
        let axis = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(n, axis))
    }

    /// Tangent record along +u with the handedness that makes `cross(n, t) · w` point along `vDirection`.
    static func tangent(alongU u: SIMD3<Float>, normal n: SIMD3<Float>, vDirection: SIMD3<Float>) -> SIMD4<Float> {
        var t = u - n * simd_dot(n, u)
        if simd_length_squared(t) < 1e-12 {
            t = anyPerpendicular(to: n)
        }
        t = simd_normalize(t)
        let handedness: Float = simd_dot(simd_cross(n, t), vDirection) < 0 ? -1 : 1
        return SIMD4<Float>(t.x, t.y, t.z, handedness)
    }

    // MARK: Box

    /// Axis-aligned box centred at `center`. `uvPerMetre` scales the per-face uv
    /// (face-local metres × uvPerMetre). Inward boxes (the chamber) have their normals
    /// pointing to the inside and are wound to be front-facing from inside; faces in
    /// `omitFaces` (e.g. the floor side of the chamber, wall-flush sides of a pilaster)
    /// are not generated.
    /// Face indices of `box` in generation order (for `omitFaces`).
    enum BoxFace: Int, CaseIterable {
        case positiveX = 0, negativeX, positiveY, negativeY, positiveZ, negativeZ
    }

    static func box(center: SIMD3<Float>, halfExtents h: SIMD3<Float>, inward: Bool = false, uvPerMetre: Float = 1,
                    omitFaces: Set<BoxFace> = []) -> MeshData {
        var mesh = MeshData()
        // (normal, u axis, v axis) per face; u × v = normal for outward faces.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1)),
            (SIMD3<Float>(0, -1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)),
            (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0)),
        ]
        for (faceIndex, face) in faces.enumerated() {
            if let boxFace = BoxFace(rawValue: faceIndex), omitFaces.contains(boxFace) {
                continue
            }
            let (normal, uAxis, vAxis) = face
            let faceCenter = center + normal * simd_dot(simd_abs(normal), h)
            let uHalf = simd_dot(simd_abs(uAxis), h)
            let vHalf = simd_dot(simd_abs(vAxis), h)
            let base = mesh.vertices.count
            let shadingNormal = inward ? -normal : normal
            let tangent = MeshBuilder.tangent(alongU: uAxis, normal: shadingNormal, vDirection: vAxis)
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            for (su, sv) in corners {
                let position = faceCenter + uAxis * (su * uHalf) + vAxis * (sv * vHalf)
                let uv = SIMD2<Float>((su * uHalf + uHalf) * uvPerMetre, (sv * vHalf + vHalf) * uvPerMetre)
                mesh.vertices.append(MeshData.makeVertex(position: position, normal: shadingNormal, tangent: tangent, uv: uv))
            }
            mesh.addQuad(base, base + 1, base + 2, base + 3)
        }
        if inward {
            mesh.flipWinding()
        }
        mesh.enforceWinding()
        return mesh
    }

    // MARK: Rounded box

    /// Box with edges rounded by `radius`, built from a subdivided cube whose surface
    /// points are projected onto the rounded shell (`q = clamp(p, ±(h − r))`,
    /// `p' = q + r · normalize(p − q)`). Normals are exact.
    static func roundedBox(center: SIMD3<Float>, halfExtents h: SIMD3<Float>, radius: Float, subdivisions: Int = 8, uvPerMetre: Float = 1) -> MeshData {
        var mesh = MeshData()
        let r = max(min(radius, min(h.x, min(h.y, h.z)) * 0.999), 0)
        let inner = h - SIMD3<Float>(repeating: r)
        let n = max(subdivisions, 1)
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1)),
            (SIMD3<Float>(0, -1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)),
            (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0)),
        ]
        for (normal, uAxis, vAxis) in faces {
            let faceCenter = normal * simd_dot(simd_abs(normal), h)
            let uHalf = simd_dot(simd_abs(uAxis), h)
            let vHalf = simd_dot(simd_abs(vAxis), h)
            let base = mesh.vertices.count
            for j in 0...n {
                for i in 0...n {
                    let su = Float(i) / Float(n) * 2 - 1
                    let sv = Float(j) / Float(n) * 2 - 1
                    let p = faceCenter + uAxis * (su * uHalf) + vAxis * (sv * vHalf)
                    let q = simd_clamp(p, -inner, inner)
                    var shell = p - q
                    if simd_length_squared(shell) < 1e-12 {
                        shell = normal
                    }
                    let shellNormal = simd_normalize(shell)
                    let position = center + q + shellNormal * r
                    let uv = SIMD2<Float>((su * uHalf + uHalf) * uvPerMetre, (sv * vHalf + vHalf) * uvPerMetre)
                    let tangent = MeshBuilder.tangent(alongU: uAxis, normal: shellNormal, vDirection: vAxis)
                    mesh.vertices.append(MeshData.makeVertex(position: position, normal: shellNormal, tangent: tangent, uv: uv))
                }
            }
            for j in 0..<n {
                for i in 0..<n {
                    let a = base + j * (n + 1) + i
                    let b = a + 1
                    let c = a + (n + 1) + 1
                    let d = a + (n + 1)
                    mesh.addQuad(a, b, c, d)
                }
            }
        }
        mesh.enforceWinding()
        return mesh
    }

    // MARK: Grid (floor)

    /// Horizontal grid in the XZ plane at `y`, normal +Y, `width` along X and `depth`
    /// along Z, centred on (0, y, 0). uv runs 0…1 across the grid (x → u, z → v).
    static func horizontalGrid(width: Float, depth: Float, y: Float, subdivisions: Int) -> MeshData {
        var mesh = MeshData()
        let n = max(subdivisions, 1)
        let normal = SIMD3<Float>(0, 1, 0)
        let tangent = MeshBuilder.tangent(alongU: SIMD3<Float>(1, 0, 0), normal: normal, vDirection: SIMD3<Float>(0, 0, 1))
        for j in 0...n {
            for i in 0...n {
                let u = Float(i) / Float(n)
                let v = Float(j) / Float(n)
                let position = SIMD3<Float>((u - 0.5) * width, y, (v - 0.5) * depth)
                mesh.vertices.append(MeshData.makeVertex(position: position, normal: normal, tangent: tangent, uv: SIMD2<Float>(u, v)))
            }
        }
        for j in 0..<n {
            for i in 0..<n {
                let a = j * (n + 1) + i
                let b = a + 1
                let c = a + (n + 1) + 1
                let d = a + (n + 1)
                mesh.addQuad(a, d, c, b)
            }
        }
        mesh.enforceWinding()
        return mesh
    }

    // MARK: Lathe

    /// Surface of revolution of `profile` about the +Y axis through the origin.
    ///
    /// The profile runs from bottom to top; radii of 0 make poles (fan-capped). Normals
    /// come from the profile's tangent (central differences), optionally displaced by
    /// `radiusOffset(angle, index)` (used for the melted candle rim and cloth folds).
    /// `angleFraction` < 1 sweeps only part of the circle (open surface).
    ///
    /// - Parameters:
    ///   - profile: Profile points, bottom first.
    ///   - radialSegments: Segments around the axis.
    ///   - angleStart: Start angle in radians (0 = +X, increasing toward +Z).
    ///   - angleFraction: Fraction of the full turn swept (1 = closed).
    ///   - radiusOffset: Optional per-vertex radius displacement (angle, profile index).
    static func lathe(profile: [LatheProfilePoint], radialSegments: Int, angleStart: Float = 0, angleFraction: Float = 1,
                      radiusOffset: ((Float, Int) -> Float)? = nil) -> MeshData {
        var mesh = MeshData()
        let rings = profile.count
        guard rings >= 2, radialSegments >= 3 else { return mesh }
        let closed = angleFraction >= 0.9999
        let segments = radialSegments
        let columns = closed ? segments : segments + 1
        let sweep = twoPi * min(max(angleFraction, 0.01), 1)

        // Profile tangents (2-D) by central differences for the normals.
        var profileTangents: [SIMD2<Float>] = []
        profileTangents.reserveCapacity(rings)
        for k in 0..<rings {
            let prev = profile[max(k - 1, 0)]
            let next = profile[min(k + 1, rings - 1)]
            var t = SIMD2<Float>(next.radius - prev.radius, next.height - prev.height)
            if simd_length_squared(t) < 1e-14 {
                t = SIMD2<Float>(0, 1)
            }
            profileTangents.append(simd_normalize(t))
        }

        for k in 0..<rings {
            let point = profile[k]
            let pt = profileTangents[k]
            // Outward 2-D normal of the profile curve: rotate the tangent by −90°.
            var normal2D = SIMD2<Float>(pt.y, -pt.x)
            if point.radius <= 1e-6 {
                // Pole: the cap faces down at the bottom of the profile and up at the top.
                normal2D = SIMD2<Float>(0, k == 0 ? -1 : 1)
            }
            for c in 0..<columns {
                let fraction = Float(c) / Float(segments)
                let angle = angleStart + fraction * sweep
                let cosA = cos(angle), sinA = sin(angle)
                var radius = point.radius
                if let offset = radiusOffset, point.radius > 1e-6 {
                    radius = max(radius + offset(angle, k), 1e-4)
                }
                let radial = SIMD3<Float>(cosA, 0, sinA)
                let position = radial * radius + SIMD3<Float>(0, point.height, 0)
                let normal = simd_normalize(radial * normal2D.x + SIMD3<Float>(0, normal2D.y, 0))
                let uDirection = SIMD3<Float>(-sinA, 0, cosA)
                let vDirection = radial * pt.x + SIMD3<Float>(0, pt.y, 0)
                let tangent = MeshBuilder.tangent(alongU: uDirection, normal: normal, vDirection: vDirection)
                mesh.vertices.append(MeshData.makeVertex(position: position, normal: normal, tangent: tangent, uv: SIMD2<Float>(fraction, point.v)))
            }
        }
        for k in 0..<(rings - 1) {
            let lowerPole = profile[k].radius <= 1e-6
            let upperPole = profile[k + 1].radius <= 1e-6
            for c in 0..<segments {
                let cNext = closed ? (c + 1) % segments : c + 1
                let a = k * columns + c
                let b = k * columns + cNext
                let cc = (k + 1) * columns + cNext
                let d = (k + 1) * columns + c
                // Orders chosen so the face normal points outward without relying on
                // `enforceWinding` (Sorcerer rebuilds lathes per frame with fixed indices).
                if lowerPole && upperPole {
                    continue
                } else if lowerPole {
                    mesh.addTriangle(a, d, cc)
                } else if upperPole {
                    mesh.addTriangle(a, cc, b)
                } else {
                    mesh.addQuad(a, d, cc, b)
                }
            }
        }
        mesh.enforceWinding()
        return mesh
    }

    // MARK: Derived lathes

    /// Closed Y-axis cylinder from y = 0 to `height` with flat caps.
    /// `rimOffset(angle)` displaces the top rim height (melted wax).
    static func cylinder(radius: Float, height: Float, radialSegments: Int = 24, heightSegments: Int = 1,
                         rimOffset: ((Float) -> Float)? = nil) -> MeshData {
        var profile: [LatheProfilePoint] = []
        profile.append(LatheProfilePoint(radius: 0, height: 0, v: 0))
        profile.append(LatheProfilePoint(radius: radius, height: 0, v: 0))
        let hs = max(heightSegments, 1)
        for k in 0...hs {
            let t = Float(k) / Float(hs)
            profile.append(LatheProfilePoint(radius: radius, height: height * t, v: t))
        }
        profile.append(LatheProfilePoint(radius: radius, height: height, v: 1))
        profile.append(LatheProfilePoint(radius: 0, height: height, v: 1))
        var mesh = lathe(profile: profile, radialSegments: radialSegments)
        if let rimOffset = rimOffset {
            // Rows at the top (rim ring, top cap edge and centre) follow the melt.
            let columns = radialSegments
            let topRows = [profile.count - 3, profile.count - 2]
            for row in topRows {
                for c in 0..<columns {
                    let index = row * columns + c
                    if index < mesh.vertices.count {
                        let angle = Float(c) / Float(columns) * twoPi
                        mesh.vertices[index].position.y += rimOffset(angle)
                    }
                }
            }
            let poleRow = profile.count - 1
            var average: Float = 0
            for c in 0..<columns {
                average += rimOffset(Float(c) / Float(columns) * twoPi)
            }
            average /= Float(columns)
            for c in 0..<columns {
                let index = poleRow * columns + c
                if index < mesh.vertices.count {
                    mesh.vertices[index].position.y += average
                }
            }
            mesh.enforceWinding()
        }
        return mesh
    }

    /// UV sphere of `radius` centred at the origin.
    static func sphere(radius: Float, segments: Int = 24, rings: Int = 16) -> MeshData {
        var profile: [LatheProfilePoint] = []
        let ringCount = max(rings, 3)
        for k in 0...ringCount {
            let t = Float(k) / Float(ringCount)
            let theta = Float.pi * t
            profile.append(LatheProfilePoint(radius: radius * sin(theta), height: -radius * cos(theta), v: t))
        }
        return lathe(profile: profile, radialSegments: segments)
    }

    /// Capsule along +Y from y = 0 to y = `length` (hemispherical ends extend beyond).
    static func capsule(radius: Float, length: Float, segments: Int = 12, capRings: Int = 4) -> MeshData {
        var profile: [LatheProfilePoint] = []
        let caps = max(capRings, 2)
        let total = length + 2 * radius
        for k in 0...caps {
            let theta = Float.pi * 0.5 * Float(k) / Float(caps)
            let y = -radius * cos(theta)
            profile.append(LatheProfilePoint(radius: radius * sin(theta), height: y, v: (y + radius) / total))
        }
        for k in 0...caps {
            let theta = Float.pi * 0.5 * Float(k) / Float(caps)
            let y = length + radius * sin(theta)
            profile.append(LatheProfilePoint(radius: radius * cos(theta), height: y, v: (y + radius) / total))
        }
        return lathe(profile: profile, radialSegments: segments)
    }
}
