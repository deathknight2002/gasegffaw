import Foundation

// MARK: - RVec2

/// A two-component vector of `Double`s.
///
/// Used for normalised trace/sigil coordinates (x right, y down, in [0, 1]) and for
/// 2-D velocities. RitualCore defines its own vector types because `simd` is not
/// available on Linux; the app converts to `SIMD2<Float>` at the render boundary.
public struct RVec2: Hashable, Codable, Sendable {
    /// Horizontal component.
    public var x: Double
    /// Vertical component.
    public var y: Double

    /// Creates a vector from its components.
    ///
    /// - Parameters:
    ///   - x: Horizontal component.
    ///   - y: Vertical component.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Creates a vector from its components (positional form).
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// The zero vector.
    public static let zero = RVec2(0, 0)

    // MARK: Arithmetic

    /// Component-wise sum.
    public static func + (lhs: RVec2, rhs: RVec2) -> RVec2 {
        RVec2(lhs.x + rhs.x, lhs.y + rhs.y)
    }

    /// Component-wise difference.
    public static func - (lhs: RVec2, rhs: RVec2) -> RVec2 {
        RVec2(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    /// Negation.
    public static prefix func - (vector: RVec2) -> RVec2 {
        RVec2(-vector.x, -vector.y)
    }

    /// Scales every component by `rhs`.
    public static func * (lhs: RVec2, rhs: Double) -> RVec2 {
        RVec2(lhs.x * rhs, lhs.y * rhs)
    }

    /// Scales every component by `lhs`.
    public static func * (lhs: Double, rhs: RVec2) -> RVec2 {
        RVec2(lhs * rhs.x, lhs * rhs.y)
    }

    /// Component-wise (Hadamard) product.
    public static func * (lhs: RVec2, rhs: RVec2) -> RVec2 {
        RVec2(lhs.x * rhs.x, lhs.y * rhs.y)
    }

    /// Divides every component by `rhs`.
    public static func / (lhs: RVec2, rhs: Double) -> RVec2 {
        RVec2(lhs.x / rhs, lhs.y / rhs)
    }

    /// In-place component-wise sum.
    public static func += (lhs: inout RVec2, rhs: RVec2) { lhs = lhs + rhs }
    /// In-place component-wise difference.
    public static func -= (lhs: inout RVec2, rhs: RVec2) { lhs = lhs - rhs }
    /// In-place scalar multiplication.
    public static func *= (lhs: inout RVec2, rhs: Double) { lhs = lhs * rhs }
    /// In-place scalar division.
    public static func /= (lhs: inout RVec2, rhs: Double) { lhs = lhs / rhs }

    // MARK: Geometry

    /// Dot product with `other`.
    public func dot(_ other: RVec2) -> Double {
        x * other.x + y * other.y
    }

    /// Squared Euclidean length (cheaper than `length` when only comparing).
    public var lengthSquared: Double {
        x * x + y * y
    }

    /// Euclidean length.
    public var length: Double {
        lengthSquared.squareRoot()
    }

    /// Unit-length copy. The zero vector normalises to the zero vector rather than NaN.
    public var normalized: RVec2 {
        let magnitude = length
        return magnitude > 0 ? self / magnitude : .zero
    }

    /// Euclidean distance to `other`.
    public func distance(to other: RVec2) -> Double {
        (self - other).length
    }

    /// Linear interpolation `a + (b − a)·t`; `t` is not clamped.
    public static func lerp(_ a: RVec2, _ b: RVec2, _ t: Double) -> RVec2 {
        a + (b - a) * t
    }

    /// Linear interpolation from `self` toward `other`; `t` is not clamped.
    public func lerp(to other: RVec2, t: Double) -> RVec2 {
        RVec2.lerp(self, other, t)
    }
}

// MARK: - RVec3

/// A three-component vector of `Double`s in scene units (metres, right-handed, +Y up).
///
/// See ``RVec2`` for why RitualCore carries its own vector type.
public struct RVec3: Hashable, Codable, Sendable {
    /// X component (East is +X).
    public var x: Double
    /// Y component (up).
    public var y: Double
    /// Z component (South is +Z, North is −Z).
    public var z: Double

    /// Creates a vector from its components.
    ///
    /// - Parameters:
    ///   - x: X component.
    ///   - y: Y component.
    ///   - z: Z component.
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Creates a vector from its components (positional form).
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The zero vector.
    public static let zero = RVec3(0, 0, 0)

    // MARK: Arithmetic

    /// Component-wise sum.
    public static func + (lhs: RVec3, rhs: RVec3) -> RVec3 {
        RVec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    /// Component-wise difference.
    public static func - (lhs: RVec3, rhs: RVec3) -> RVec3 {
        RVec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    /// Negation.
    public static prefix func - (vector: RVec3) -> RVec3 {
        RVec3(-vector.x, -vector.y, -vector.z)
    }

    /// Scales every component by `rhs`.
    public static func * (lhs: RVec3, rhs: Double) -> RVec3 {
        RVec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    /// Scales every component by `lhs`.
    public static func * (lhs: Double, rhs: RVec3) -> RVec3 {
        RVec3(lhs * rhs.x, lhs * rhs.y, lhs * rhs.z)
    }

    /// Component-wise (Hadamard) product.
    public static func * (lhs: RVec3, rhs: RVec3) -> RVec3 {
        RVec3(lhs.x * rhs.x, lhs.y * rhs.y, lhs.z * rhs.z)
    }

    /// Divides every component by `rhs`.
    public static func / (lhs: RVec3, rhs: Double) -> RVec3 {
        RVec3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    /// In-place component-wise sum.
    public static func += (lhs: inout RVec3, rhs: RVec3) { lhs = lhs + rhs }
    /// In-place component-wise difference.
    public static func -= (lhs: inout RVec3, rhs: RVec3) { lhs = lhs - rhs }
    /// In-place scalar multiplication.
    public static func *= (lhs: inout RVec3, rhs: Double) { lhs = lhs * rhs }
    /// In-place scalar division.
    public static func /= (lhs: inout RVec3, rhs: Double) { lhs = lhs / rhs }

    // MARK: Geometry

    /// Dot product with `other`.
    public func dot(_ other: RVec3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    /// Right-handed cross product `self × other`.
    public func cross(_ other: RVec3) -> RVec3 {
        RVec3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    /// Squared Euclidean length (cheaper than `length` when only comparing).
    public var lengthSquared: Double {
        x * x + y * y + z * z
    }

    /// Euclidean length.
    public var length: Double {
        lengthSquared.squareRoot()
    }

    /// Unit-length copy. The zero vector normalises to the zero vector rather than NaN.
    public var normalized: RVec3 {
        let magnitude = length
        return magnitude > 0 ? self / magnitude : .zero
    }

    /// Euclidean distance to `other`.
    public func distance(to other: RVec3) -> Double {
        (self - other).length
    }

    /// Linear interpolation `a + (b − a)·t`; `t` is not clamped.
    public static func lerp(_ a: RVec3, _ b: RVec3, _ t: Double) -> RVec3 {
        a + (b - a) * t
    }

    /// Linear interpolation from `self` toward `other`; `t` is not clamped.
    public func lerp(to other: RVec3, t: Double) -> RVec3 {
        RVec3.lerp(self, other, t)
    }
}

// MARK: - Angle

/// Angle helpers. All arguments and results are in **degrees** unless the name says radians.
public enum Angle {
    /// Degrees per radian (180/π).
    public static let degreesPerRadian = 180.0 / Double.pi
    /// Radians per degree (π/180).
    public static let radiansPerDegree = Double.pi / 180.0

    /// Wraps `degrees` into `[0, 360)`.
    ///
    /// Longitudes throughout RitualCore are stored in this range. Negative zero is mapped
    /// to positive zero; a result that would round up to exactly 360 is folded back to 0.
    public static func normalize(_ degrees: Double) -> Double {
        var remainder = degrees.truncatingRemainder(dividingBy: 360.0)
        if remainder < 0 {
            remainder += 360.0
        }
        if remainder >= 360.0 {
            remainder -= 360.0
        }
        return remainder + 0.0
    }

    /// Wraps `degrees` into `(-180, 180]`, so that ±180 both map to +180.
    ///
    /// Use it for signed differences such as `wrap180(yaw − quarterYaw)`.
    public static func wrap180(_ degrees: Double) -> Double {
        let wrapped = normalize(degrees)
        return wrapped > 180.0 ? wrapped - 360.0 : wrapped
    }

    /// Converts degrees to radians.
    public static func deg2rad(_ degrees: Double) -> Double {
        degrees * radiansPerDegree
    }

    /// Converts radians to degrees.
    public static func rad2deg(_ radians: Double) -> Double {
        radians * degreesPerRadian
    }
}
