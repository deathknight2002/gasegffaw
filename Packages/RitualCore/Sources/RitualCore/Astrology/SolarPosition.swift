import Foundation

/// One `A cos(B + Cτ)` term of a VSOP87 series (Meeus Appendix III).
///
/// `a` is in units of 10⁻⁸ radian (longitude, latitude) or 10⁻⁸ AU (radius vector),
/// `b` in radians and `c` in radians per Julian millennium.
struct VSOPTerm {
    let a: Double
    let b: Double
    let c: Double

    init(_ a: Double, _ b: Double, _ c: Double) {
        self.a = a
        self.b = b
        self.c = c
    }
}

extension Ephemeris {
    // MARK: - VSOP87D Earth, Meeus Appendix III (values as printed)

    /// Earth heliocentric longitude, L0 (64 terms).
    static let earthL0: [VSOPTerm] = [
        VSOPTerm(175347046, 0, 0),
        VSOPTerm(3341656, 4.6692568, 6283.07585),
        VSOPTerm(34894, 4.62610, 12566.15170),
        VSOPTerm(3497, 2.7441, 5753.38488),
        VSOPTerm(3418, 2.8289, 3.52312),
        VSOPTerm(3136, 3.6277, 77713.77147),
        VSOPTerm(2676, 4.4181, 7860.41939),
        VSOPTerm(2343, 6.1352, 3930.20970),
        VSOPTerm(1324, 0.7425, 11506.76977),
        VSOPTerm(1273, 2.0371, 529.69097),
        VSOPTerm(1199, 1.1096, 1577.34354),
        VSOPTerm(990, 5.233, 5884.92685),
        VSOPTerm(902, 2.045, 26.29832),
        VSOPTerm(857, 3.508, 398.14900),
        VSOPTerm(780, 1.179, 5223.69392),
        VSOPTerm(753, 2.533, 5507.55324),
        VSOPTerm(505, 4.583, 18849.22755),
        VSOPTerm(492, 4.205, 775.52261),
        VSOPTerm(357, 2.920, 0.06731),
        VSOPTerm(317, 5.849, 11790.62909),
        VSOPTerm(284, 1.899, 796.29801),
        VSOPTerm(271, 0.315, 10977.07880),
        VSOPTerm(243, 0.345, 5486.77784),
        VSOPTerm(206, 4.806, 2544.31442),
        VSOPTerm(205, 1.869, 5573.14280),
        VSOPTerm(202, 2.458, 6069.77675),
        VSOPTerm(156, 0.833, 213.29910),
        VSOPTerm(132, 3.411, 2942.46342),
        VSOPTerm(126, 1.083, 20.77540),
        VSOPTerm(115, 0.645, 0.98032),
        VSOPTerm(103, 0.636, 4694.00295),
        VSOPTerm(102, 0.976, 15720.83878),
        VSOPTerm(102, 4.267, 7.11355),
        VSOPTerm(99, 6.21, 2146.17),
        VSOPTerm(98, 0.68, 155.42),
        VSOPTerm(86, 5.98, 161000.69),
        VSOPTerm(85, 1.30, 6275.96),
        VSOPTerm(85, 3.67, 71430.70),
        VSOPTerm(80, 1.81, 17260.15),
        VSOPTerm(79, 3.04, 12036.46),
        VSOPTerm(75, 1.76, 5088.63),
        VSOPTerm(74, 3.50, 3154.69),
        VSOPTerm(74, 4.68, 801.82),
        VSOPTerm(70, 0.83, 9437.76),
        VSOPTerm(62, 3.98, 8827.39),
        VSOPTerm(61, 1.82, 7084.90),
        VSOPTerm(57, 2.78, 6286.60),
        VSOPTerm(56, 4.39, 14143.50),
        VSOPTerm(56, 3.47, 6279.55),
        VSOPTerm(52, 0.19, 12139.55),
        VSOPTerm(52, 1.33, 1748.02),
        VSOPTerm(51, 0.28, 5856.48),
        VSOPTerm(49, 0.49, 1194.45),
        VSOPTerm(41, 5.37, 8429.24),
        VSOPTerm(41, 2.40, 19651.05),
        VSOPTerm(39, 6.17, 10447.39),
        VSOPTerm(37, 6.04, 10213.29),
        VSOPTerm(37, 2.57, 1059.38),
        VSOPTerm(36, 1.71, 2352.87),
        VSOPTerm(36, 1.78, 6812.77),
        VSOPTerm(33, 0.59, 17789.85),
        VSOPTerm(30, 0.44, 83996.85),
        VSOPTerm(30, 2.74, 1349.87),
        VSOPTerm(25, 3.16, 4690.48),
    ]

    /// Earth heliocentric longitude, L1 (34 terms).
    static let earthL1: [VSOPTerm] = [
        VSOPTerm(628331966747, 0, 0),
        VSOPTerm(206059, 2.678235, 6283.07585),
        VSOPTerm(4303, 2.6351, 12566.1517),
        VSOPTerm(425, 1.590, 3.523),
        VSOPTerm(119, 5.796, 26.298),
        VSOPTerm(109, 2.966, 1577.344),
        VSOPTerm(93, 2.59, 18849.23),
        VSOPTerm(72, 1.14, 529.69),
        VSOPTerm(68, 1.87, 398.15),
        VSOPTerm(67, 4.41, 5507.55),
        VSOPTerm(59, 2.89, 5223.69),
        VSOPTerm(56, 2.17, 155.42),
        VSOPTerm(45, 0.40, 796.30),
        VSOPTerm(36, 0.47, 775.52),
        VSOPTerm(29, 2.65, 7.11),
        VSOPTerm(21, 5.34, 0.98),
        VSOPTerm(19, 1.85, 5486.78),
        VSOPTerm(19, 4.97, 213.30),
        VSOPTerm(17, 2.99, 6275.96),
        VSOPTerm(16, 0.03, 2544.31),
        VSOPTerm(16, 1.43, 2146.17),
        VSOPTerm(15, 1.21, 10977.08),
        VSOPTerm(12, 2.83, 1748.02),
        VSOPTerm(12, 3.26, 5088.63),
        VSOPTerm(12, 5.27, 1194.45),
        VSOPTerm(12, 2.08, 4694.00),
        VSOPTerm(11, 0.77, 553.57),
        VSOPTerm(10, 1.30, 6286.60),
        VSOPTerm(10, 4.24, 1349.87),
        VSOPTerm(9, 2.70, 242.73),
        VSOPTerm(9, 5.64, 951.72),
        VSOPTerm(8, 5.30, 2352.87),
        VSOPTerm(6, 2.65, 9437.76),
        VSOPTerm(6, 4.67, 4690.48),
    ]

    /// Earth heliocentric longitude, L2 (20 terms).
    static let earthL2: [VSOPTerm] = [
        VSOPTerm(52919, 0, 0),
        VSOPTerm(8720, 1.0721, 6283.0758),
        VSOPTerm(309, 0.867, 12566.152),
        VSOPTerm(27, 0.05, 3.52),
        VSOPTerm(16, 5.19, 26.30),
        VSOPTerm(16, 3.68, 155.42),
        VSOPTerm(10, 0.76, 18849.23),
        VSOPTerm(9, 2.06, 77713.77),
        VSOPTerm(7, 0.83, 775.52),
        VSOPTerm(5, 4.66, 1577.34),
        VSOPTerm(4, 1.03, 7.11),
        VSOPTerm(4, 3.44, 5573.14),
        VSOPTerm(3, 5.14, 796.30),
        VSOPTerm(3, 6.05, 5507.55),
        VSOPTerm(3, 1.19, 242.73),
        VSOPTerm(3, 6.12, 529.69),
        VSOPTerm(3, 0.31, 398.15),
        VSOPTerm(3, 2.28, 553.57),
        VSOPTerm(2, 4.38, 5223.69),
        VSOPTerm(2, 3.75, 0.98),
    ]

    /// Earth heliocentric longitude, L3 (7 terms).
    static let earthL3: [VSOPTerm] = [
        VSOPTerm(289, 5.844, 6283.076),
        VSOPTerm(35, 0, 0),
        VSOPTerm(17, 5.49, 12566.15),
        VSOPTerm(3, 5.20, 155.42),
        VSOPTerm(1, 4.72, 3.52),
        VSOPTerm(1, 5.30, 18849.23),
        VSOPTerm(1, 5.97, 242.73),
    ]

    /// Earth heliocentric longitude, L4 (3 terms).
    static let earthL4: [VSOPTerm] = [
        VSOPTerm(114, 3.142, 0),
        VSOPTerm(8, 4.13, 6283.08),
        VSOPTerm(1, 3.84, 12566.15),
    ]

    /// Earth heliocentric longitude, L5 (1 term).
    static let earthL5: [VSOPTerm] = [
        VSOPTerm(1, 3.14, 0),
    ]

    /// Earth heliocentric latitude, B0 (5 terms).
    static let earthB0: [VSOPTerm] = [
        VSOPTerm(280, 3.199, 84334.662),
        VSOPTerm(102, 5.422, 5507.553),
        VSOPTerm(80, 3.88, 5223.69),
        VSOPTerm(44, 3.70, 2352.87),
        VSOPTerm(32, 4.00, 1577.34),
    ]

    /// Earth heliocentric latitude, B1 (2 terms).
    static let earthB1: [VSOPTerm] = [
        VSOPTerm(9, 3.90, 5507.55),
        VSOPTerm(6, 1.73, 5223.69),
    ]

    /// Earth radius vector, R0 (40 terms).
    static let earthR0: [VSOPTerm] = [
        VSOPTerm(100013989, 0, 0),
        VSOPTerm(1670700, 3.0984635, 6283.07585),
        VSOPTerm(13956, 3.05525, 12566.15170),
        VSOPTerm(3084, 5.1985, 77713.7715),
        VSOPTerm(1628, 1.1739, 5753.3849),
        VSOPTerm(1576, 2.8469, 7860.4194),
        VSOPTerm(925, 5.453, 11506.770),
        VSOPTerm(542, 4.564, 3930.210),
        VSOPTerm(472, 3.661, 5884.927),
        VSOPTerm(346, 0.964, 5507.553),
        VSOPTerm(329, 5.900, 5223.694),
        VSOPTerm(307, 0.299, 5573.143),
        VSOPTerm(243, 4.273, 11790.629),
        VSOPTerm(212, 5.847, 1577.344),
        VSOPTerm(186, 5.022, 10977.079),
        VSOPTerm(175, 3.012, 18849.228),
        VSOPTerm(110, 5.055, 5486.778),
        VSOPTerm(98, 0.89, 6069.78),
        VSOPTerm(86, 5.69, 15720.84),
        VSOPTerm(86, 1.27, 161000.69),
        VSOPTerm(65, 0.27, 17260.15),
        VSOPTerm(63, 0.92, 529.69),
        VSOPTerm(57, 2.01, 83996.85),
        VSOPTerm(56, 5.24, 71430.70),
        VSOPTerm(49, 3.25, 2544.31),
        VSOPTerm(47, 2.58, 775.52),
        VSOPTerm(45, 5.54, 9437.76),
        VSOPTerm(43, 6.01, 6275.96),
        VSOPTerm(39, 5.36, 4694.00),
        VSOPTerm(38, 2.39, 8827.39),
        VSOPTerm(37, 0.83, 19651.05),
        VSOPTerm(37, 4.90, 12139.55),
        VSOPTerm(36, 1.67, 12036.46),
        VSOPTerm(35, 1.84, 2942.46),
        VSOPTerm(33, 0.24, 7084.90),
        VSOPTerm(32, 0.18, 5088.63),
        VSOPTerm(32, 1.78, 398.15),
        VSOPTerm(28, 1.21, 6286.60),
        VSOPTerm(28, 1.90, 6279.55),
        VSOPTerm(26, 4.59, 10447.39),
    ]

    /// Earth radius vector, R1 (10 terms).
    static let earthR1: [VSOPTerm] = [
        VSOPTerm(103019, 1.107490, 6283.075850),
        VSOPTerm(1721, 1.0644, 12566.1517),
        VSOPTerm(702, 3.142, 0),
        VSOPTerm(32, 1.02, 18849.23),
        VSOPTerm(31, 2.84, 5507.55),
        VSOPTerm(25, 1.32, 5223.69),
        VSOPTerm(18, 1.42, 1577.34),
        VSOPTerm(10, 5.91, 10977.08),
        VSOPTerm(9, 1.42, 6275.96),
        VSOPTerm(9, 0.27, 5486.78),
    ]

    /// Earth radius vector, R2 (6 terms).
    static let earthR2: [VSOPTerm] = [
        VSOPTerm(4359, 5.7846, 6283.0758),
        VSOPTerm(124, 5.579, 12566.152),
        VSOPTerm(12, 3.14, 0),
        VSOPTerm(9, 3.63, 77713.77),
        VSOPTerm(6, 1.87, 5573.14),
        VSOPTerm(3, 5.47, 18849.23),
    ]

    /// Earth radius vector, R3 (2 terms).
    static let earthR3: [VSOPTerm] = [
        VSOPTerm(145, 4.273, 6283.076),
        VSOPTerm(7, 3.92, 12566.15),
    ]

    /// Earth radius vector, R4 (1 term).
    static let earthR4: [VSOPTerm] = [
        VSOPTerm(4, 2.56, 6283.08),
    ]

    /// Evaluates `Σ A cos(B + Cτ)` for one VSOP87 series.
    static func vsopSeries(_ terms: [VSOPTerm], tau: Double) -> Double {
        terms.reduce(0.0) { sum, term in sum + term.a * cos(term.b + term.c * tau) }
    }

    /// Evaluates a full VSOP87 coordinate `(S0 + S1τ + S2τ² + …) / 10⁸`.
    static func vsopCoordinate(_ series: [[VSOPTerm]], tau: Double) -> Double {
        var sum = 0.0
        var power = 1.0
        for terms in series {
            sum += vsopSeries(terms, tau: tau) * power
            power *= tau
        }
        return sum / 1e8
    }

    /// Heliocentric ecliptic coordinates of the Earth (VSOP87D, dynamical ecliptic and
    /// equinox of date), truncated to the Meeus Appendix III tables.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    /// - Returns: Longitude and latitude in degrees (longitude in [0, 360)), radius in AU.
    static func earthHeliocentric(jdTT: Double) -> (longitude: Double, latitude: Double, radiusAU: Double) {
        let tau = JulianDay.millenniaSinceJ2000(jdTT)
        let longitudeRadians = vsopCoordinate([earthL0, earthL1, earthL2, earthL3, earthL4, earthL5], tau: tau)
        let latitudeRadians = vsopCoordinate([earthB0, earthB1], tau: tau)
        let radius = vsopCoordinate([earthR0, earthR1, earthR2, earthR3, earthR4], tau: tau)
        return (Angle.normalize(Angle.rad2deg(longitudeRadians)), Angle.rad2deg(latitudeRadians), radius)
    }

    /// Geometric geocentric Sun (mean equinox of date, FK5 frame): the Earth's heliocentric
    /// position reversed (Θ = L + 180°, β = −B) with the FK5 correction of Meeus 25.9.
    ///
    /// - Parameter jdTT: Julian Day in Terrestrial Time.
    static func sunGeometric(jdTT: Double) -> (longitude: Double, latitude: Double, distanceAU: Double) {
        let earth = earthHeliocentric(jdTT: jdTT)
        var longitude = Angle.normalize(earth.longitude + 180.0)
        var latitude = -earth.latitude

        // FK5 correction (Meeus 25.9): reduce the VSOP dynamical equinox to FK5.
        let t = JulianDay.centuriesSinceJ2000(jdTT)
        let lambdaPrime = Angle.deg2rad(longitude - 1.397 * t - 0.00031 * t * t)
        longitude -= 0.09033 / 3600.0
        latitude += 0.03916 / 3600.0 * (cos(lambdaPrime) - sin(lambdaPrime))
        return (Angle.normalize(longitude), latitude, earth.radiusAU)
    }

    /// Apparent geocentric Sun referred to the true ecliptic and equinox of date.
    ///
    /// VSOP87D Earth (Appendix III truncation, ~1″), FK5 correction, nutation in
    /// longitude, and aberration `−20.4898″ / R` (Meeus 25.10). `jdUT` is converted to
    /// Terrestrial Time with ``JulianDay/deltaT(jd:)`` before the theory is evaluated.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time.
    /// - Returns: Longitude in [0, 360) and latitude in degrees, distance in AU.
    public static func sun(jdUT: Double) -> (longitude: Double, latitude: Double, distanceAU: Double) {
        let jdTT = JulianDay.terrestrialTime(fromUT: jdUT)
        let geometric = sunGeometric(jdTT: jdTT)
        let deltaPsi = nutation(jdTT: jdTT).longitude
        let aberration = -20.4898 / 3600.0 / geometric.distanceAU
        let longitude = Angle.normalize(geometric.longitude + deltaPsi + aberration)
        return (longitude, geometric.latitude, geometric.distanceAU)
    }
}
