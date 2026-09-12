import Foundation

/// Locates lunations (New and Full Moons) from the apparent Sun and Moon longitudes.
public enum SyzygyFinder {
    /// Step of the coarse backward search, in days (about 0.6° of elongation per step).
    public static let coarseStepDays = 0.05
    /// Target precision of the bisection, in days (0.5 s).
    public static let bisectionToleranceDays = 0.5 / 86_400.0

    /// Moon − Sun elongation in [0, 360): 0 at a New Moon, 180 at a Full Moon.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time.
    static func elongation(jdUT: Double) -> Double {
        Angle.normalize(Ephemeris.moon(jdUT: jdUT).longitude - Ephemeris.sun(jdUT: jdUT).longitude)
    }

    /// The last New or Full Moon strictly before `jdUT`.
    ///
    /// The elongation is sampled backwards in ``coarseStepDays`` steps until it is seen to
    /// pass through 0° (New) or 180° (Full) between two samples; the crossing is then
    /// refined by bisection to better than one second. The longitude reported is the Sun's
    /// for a New Moon and the Moon's for a Full Moon.
    ///
    /// - Parameter jdUT: Julian Day in Universal Time to search back from.
    public static func prenatal(before jdUT: Double) -> Syzygy {
        var later = jdUT
        var laterElongation = elongation(jdUT: later)
        // Elongation increases at ≈12.19°/day, so a step never spans more than one crossing.
        for _ in 0 ..< 2000 {
            let earlier = later - coarseStepDays
            let earlierElongation = elongation(jdUT: earlier)
            if let kind = crossing(from: earlierElongation, to: laterElongation) {
                let instant = refine(kind: kind, lower: earlier, upper: later)
                return makeSyzygy(kind: kind, jdUT: instant)
            }
            later = earlier
            laterElongation = earlierElongation
        }
        // Unreachable for finite input: a lunation occurs at least every 14.8 days.
        return makeSyzygy(kind: .newMoon, jdUT: jdUT)
    }

    /// Which syzygy, if any, the elongation crossed while advancing from `earlier` to
    /// `later` (both in [0, 360), the two samples being one coarse step apart).
    private static func crossing(from earlier: Double, to later: Double) -> SyzygyKind? {
        if earlier > later {
            return .newMoon      // wrapped from just under 360° to just over 0°
        }
        if earlier < 180.0 && later >= 180.0 {
            return .fullMoon
        }
        return nil
    }

    /// Signed distance of the elongation from the syzygy point, negative before it.
    private static func residual(kind: SyzygyKind, jdUT: Double) -> Double {
        switch kind {
        case .newMoon: return Angle.wrap180(elongation(jdUT: jdUT))
        case .fullMoon: return Angle.wrap180(elongation(jdUT: jdUT) - 180.0)
        }
    }

    /// Bisects `[lower, upper]` (residual negative at `lower`, positive at `upper`) until
    /// the bracket is narrower than ``bisectionToleranceDays``.
    private static func refine(kind: SyzygyKind, lower: Double, upper: Double) -> Double {
        var low = lower
        var high = upper
        var iterations = 0
        while high - low > bisectionToleranceDays && iterations < 64 {
            let middle = 0.5 * (low + high)
            if residual(kind: kind, jdUT: middle) < 0 {
                low = middle
            } else {
                high = middle
            }
            iterations += 1
        }
        return 0.5 * (low + high)
    }

    /// Builds the record, taking the Sun's longitude for a New Moon and the Moon's for a
    /// Full Moon.
    private static func makeSyzygy(kind: SyzygyKind, jdUT: Double) -> Syzygy {
        let longitude: Double
        switch kind {
        case .newMoon: longitude = Ephemeris.sun(jdUT: jdUT).longitude
        case .fullMoon: longitude = Ephemeris.moon(jdUT: jdUT).longitude
        }
        return Syzygy(kind: kind, jdUT: jdUT, longitude: longitude)
    }
}
