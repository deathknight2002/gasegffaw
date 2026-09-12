import Foundation

/// Julian Day arithmetic and the UT → TT time-scale bridge.
///
/// Calendar conversions follow Meeus, *Astronomical Algorithms* chapter 7 (Gregorian
/// calendar only) and delegate to the same internal helper that ``BirthData/jdUT`` uses,
/// so a chart's birth instant and the ephemeris always agree. `deltaT` supplies the
/// ΔT = TT − UT offset needed before evaluating the planetary and lunar theories,
/// which are expressed in Terrestrial (dynamical) Time.
public enum JulianDay {
    /// Julian Day of the J2000.0 epoch (2000 January 1.5 TT).
    public static let j2000 = 2_451_545.0
    /// Days per Julian century.
    public static let daysPerCentury = 36_525.0
    /// Seconds per day.
    public static let secondsPerDay = 86_400.0

    /// Julian Day for a Gregorian calendar date and decimal hour (Meeus 7.1).
    ///
    /// - Parameters:
    ///   - year: Astronomical year (1 BC = 0).
    ///   - month: Month 1…12.
    ///   - day: Day of month.
    ///   - hourUT: Decimal hours since 0h (13.5 = 13:30).
    /// - Returns: The Julian Day in the same time scale as `hourUT` (UT for chart work).
    public static func fromCalendar(year: Int, month: Int, day: Int, hourUT: Double) -> Double {
        JulianDayMath.julianDay(year: year, month: month, day: day, hourUT: hourUT)
    }

    /// Gregorian calendar date and decimal hour for a Julian Day (Meeus chapter 7).
    ///
    /// - Parameter jd: Julian Day (any time scale; the hour comes back in the same scale).
    /// - Returns: Year, month, day and decimal hours since 0h.
    public static func toCalendar(_ jd: Double) -> (year: Int, month: Int, day: Int, hourUT: Double) {
        JulianDayMath.calendar(fromJulianDay: jd)
    }

    /// Julian centuries elapsed since J2000.0: `(jd − 2451545) / 36525`.
    ///
    /// - Parameter jd: Julian Day (UT or TT; callers pick the scale the theory wants).
    public static func centuriesSinceJ2000(_ jd: Double) -> Double {
        (jd - j2000) / daysPerCentury
    }

    /// Julian millennia elapsed since J2000.0 (the VSOP87 time argument τ).
    ///
    /// - Parameter jd: Julian Day (TT).
    public static func millenniaSinceJ2000(_ jd: Double) -> Double {
        (jd - j2000) / (daysPerCentury * 10.0)
    }

    /// ΔT = TT − UT in seconds.
    ///
    /// Before 2005 the Espenak–Meeus polynomial fit (NASA eclipse site, 2005 revision) is
    /// used unchanged; it reproduces the observed ΔT to a fraction of a second between
    /// 1600 and 2005. From 2005 the observed IERS values (``observedDeltaT``, annual,
    /// linearly interpolated) take over, and beyond the end of that table the value is
    /// extrapolated with the Stephenson–Morrison–Hohenkerk (2016) long-term curvature
    /// anchored at the table end, cross-fading into the Morrison–Stephenson (2004)
    /// millennial parabola by ``longTermHandoverYear`` (see ``deltaT(decimalYear:)``).
    /// Through 2100 the model stays within a few seconds of contemporary predictions;
    /// the Moon's ephemeris error from a 20 s ΔT error is about 10″, far below the
    /// module's tolerances.
    ///
    /// - Parameter jd: Julian Day in UT (the difference between UT and TT is negligible for
    ///   picking the segment).
    /// - Returns: ΔT in seconds, or `.nan` when `jd` is not finite; add `deltaT / 86400`
    ///   to a UT Julian Day to obtain TT.
    public static func deltaT(jd: Double) -> Double {
        guard jd.isFinite else { return .nan }
        let calendar = toCalendar(jd)
        let year = Double(calendar.year) + (Double(calendar.month) - 0.5) / 12.0
        return deltaT(decimalYear: year)
    }

    /// Converts a Julian Day in UT to Terrestrial Time using ``deltaT(jd:)``.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time.
    public static func terrestrialTime(fromUT jdUT: Double) -> Double {
        jdUT + deltaT(jd: jdUT) / secondsPerDay
    }

    /// First year (1 January, 0h) of ``observedDeltaT``.
    static let observedDeltaTStartYear = 2005.0

    /// Observed ΔT = TT − UT1 at 0h on 1 January of 2005 … 2025, in seconds, from the IERS
    /// Earth-orientation series (`ΔT = 32.184 + (TAI − UTC) − (UT1 − UTC)`), rounded to
    /// 0.01 s. The series is essentially flat since 2017 (the Earth's rotation has been
    /// slightly faster than nominal).
    static let observedDeltaT: [Double] = [
        64.69, 64.85, 65.15, 65.46, 65.78,  // 2005 … 2009
        66.07, 66.32, 66.60, 66.91, 67.28,  // 2010 … 2014
        67.64, 68.10, 68.59, 68.97, 69.22,  // 2015 … 2019
        69.36, 69.36, 69.29, 69.20, 69.17,  // 2020 … 2024
        69.14,                              // 2025
    ]

    /// Last year of ``observedDeltaT`` (2025.0); the extrapolation is anchored here.
    static var observedDeltaTEndYear: Double {
        observedDeltaTStartYear + Double(observedDeltaT.count - 1)
    }

    /// ΔT at ``observedDeltaTEndYear``.
    static var observedDeltaTEndValue: Double {
        observedDeltaT[observedDeltaT.count - 1]
    }

    /// Year by which the extrapolation has fully handed over to the millennial parabola.
    static let longTermHandoverYear = 2500.0

    /// Long-term curvature of ΔT in s/century² from the tidal deceleration of the Earth's
    /// rotation (Stephenson, Morrison & Hohenkerk 2016: +1.78 ms/day per century).
    static let longTermCurvature = 32.5

    /// ΔT keyed on the decimal year: Espenak–Meeus polynomials before 2005, the observed
    /// table through ``observedDeltaTEndYear``, the anchored extrapolation to
    /// ``longTermHandoverYear``, and the Morrison–Stephenson parabola beyond (and before
    /// −500). Every segment boundary is continuous.
    ///
    /// - Parameter y: Decimal year, e.g. 2002.625.
    /// - Returns: ΔT in seconds.
    static func deltaT(decimalYear y: Double) -> Double {
        if y < -500.0 {
            return longTermParabola(decimalYear: y)
        }
        if y < 500.0 {
            let u = y / 100.0
            return polynomial(u, [10583.6, -1014.41, 33.78311, -5.952053, -0.1798452, 0.022174192, 0.0090316521])
        }
        if y < 1600.0 {
            let u = (y - 1000.0) / 100.0
            return polynomial(u, [1574.2, -556.01, 71.23472, 0.319781, -0.8503463, -0.005050998, 0.0083572073])
        }
        if y < 1700.0 {
            let t = y - 1600.0
            return polynomial(t, [120.0, -0.9808, -0.01532, 1.0 / 7129.0])
        }
        if y < 1800.0 {
            let t = y - 1700.0
            return polynomial(t, [8.83, 0.1603, -0.0059285, 0.00013336, -1.0 / 1_174_000.0])
        }
        if y < 1860.0 {
            let t = y - 1800.0
            return polynomial(t, [13.72, -0.332447, 0.0068612, 0.0041116, -0.00037436, 0.0000121272, -0.0000001699, 0.000000000875])
        }
        if y < 1900.0 {
            let t = y - 1860.0
            return polynomial(t, [7.62, 0.5737, -0.251754, 0.01680668, -0.0004473624, 1.0 / 233_174.0])
        }
        if y < 1920.0 {
            let t = y - 1900.0
            return polynomial(t, [-2.79, 1.494119, -0.0598939, 0.0061966, -0.000197])
        }
        if y < 1941.0 {
            let t = y - 1920.0
            return polynomial(t, [21.20, 0.84493, -0.076100, 0.0020936])
        }
        if y < 1961.0 {
            let t = y - 1950.0
            return polynomial(t, [29.07, 0.407, -1.0 / 233.0, 1.0 / 2547.0])
        }
        if y < 1986.0 {
            let t = y - 1975.0
            return polynomial(t, [45.45, 1.067, -1.0 / 260.0, -1.0 / 718.0])
        }
        if y < observedDeltaTStartYear {
            let t = y - 2000.0
            return polynomial(t, [63.86, 0.3345, -0.060374, 0.0017275, 0.000651814, 0.00002373599])
        }
        if y < observedDeltaTEndYear {
            return observedDeltaT(decimalYear: y)
        }
        if y < longTermHandoverYear {
            return extrapolatedDeltaT(decimalYear: y)
        }
        return longTermParabola(decimalYear: y)
    }

    /// Linear interpolation in ``observedDeltaT`` for `observedDeltaTStartYear ≤ y < observedDeltaTEndYear`.
    private static func observedDeltaT(decimalYear y: Double) -> Double {
        let offset = y - observedDeltaTStartYear
        let index = min(max(Int(offset.rounded(.down)), 0), observedDeltaT.count - 2)
        let fraction = offset - Double(index)
        return observedDeltaT[index] + (observedDeltaT[index + 1] - observedDeltaT[index]) * fraction
    }

    /// Extrapolation beyond the observed table (`observedDeltaTEndYear ≤ y < longTermHandoverYear`).
    ///
    /// The anchored parabola `ΔT_end + 32.5·((y − y_end)/100)²` carries the observed level
    /// with zero initial slope (the observed rate over 2019–2025 is ≈ 0) and the
    /// long-term tidal curvature. The Morrison–Stephenson millennial parabola runs some
    /// 45 s above present-day observations, so the two are cross-faded with a smoothstep
    /// weight over the handover interval; the blend is continuous in value and slope at
    /// both ends and equals the millennial parabola from ``longTermHandoverYear`` on.
    private static func extrapolatedDeltaT(decimalYear y: Double) -> Double {
        let sinceAnchor = y - observedDeltaTEndYear
        let centuries = sinceAnchor / 100.0
        let anchored = observedDeltaTEndValue + longTermCurvature * centuries * centuries
        let millennial = longTermParabola(decimalYear: y)
        let t = min(max(sinceAnchor / (longTermHandoverYear - observedDeltaTEndYear), 0.0), 1.0)
        let weight = t * t * (3.0 - 2.0 * t)
        return anchored + weight * (millennial - anchored)
    }

    /// Morrison & Stephenson (2004) long-term parabola: `−20 + 32u²`, `u = (y − 1820)/100`.
    private static func longTermParabola(decimalYear y: Double) -> Double {
        let u = (y - 1820.0) / 100.0
        return -20.0 + 32.0 * u * u
    }

    /// Horner evaluation of `Σ coefficients[i] · x^i`.
    private static func polynomial(_ x: Double, _ coefficients: [Double]) -> Double {
        coefficients.reversed().reduce(0.0) { accumulator, coefficient in accumulator * x + coefficient }
    }
}
