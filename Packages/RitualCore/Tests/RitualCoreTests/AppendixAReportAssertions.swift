import XCTest
@testable import RitualCore

/// The Appendix A report of the owner chart, line by line (CORE_API "Tests required").
///
/// The nine-line layout, the labels, the sign names and the degree/minute strings must
/// match Appendix A exactly; the decimal longitudes printed in parentheses are parsed and
/// compared numerically, because the shipped Meeus chapter 47 Moon differs from the
/// reference ephemeris the appendix was cast from by a few arc-seconds (247.693° against
/// 247.694°), which also moves the two lots by the same amount.
enum AppendixAReport {
    /// Tolerance on every decimal longitude in parentheses.
    static let longitudeTolerance = 0.01
    /// Accepted values of the printed Sun altitude (Appendix A: −2.87°).
    static let altitudeRange = -2.88 ... -2.86
    /// Label of the altitude line and its sect suffix.
    static let altitudePrefix = "Sun altitude "
    static let altitudeSuffix = "° → night chart"
    /// The ruler line, reproduced verbatim.
    static let rulerLine = "Chart ruler Sun — in domicile, rising"

    /// One longitude line: the text before " (" and the Appendix A decimal.
    struct LongitudeLine {
        let index: Int
        let text: String
        let longitude: Double
    }

    /// The seven lines carrying a decimal longitude, with their Appendix A values.
    static let longitudeLines: [LongitudeLine] = [
        LongitudeLine(index: 0, text: "Sun 23°30' Leo", longitude: 143.494),
        LongitudeLine(index: 1, text: "Moon 7°42' Sagittarius", longitude: 247.694),
        LongitudeLine(index: 2, text: "Ascendant 20°13' Leo", longitude: 140.211),
        LongitudeLine(index: 3, text: "MC 9°28' Taurus", longitude: 39.468),
        LongitudeLine(index: 5, text: "Prenatal syzygy New Moon 2002-08-08 19:15 UT 16°04' Leo", longitude: 136.063),
        LongitudeLine(index: 6, text: "Lot of Fortune 6°01' Taurus", longitude: 36.010),
        LongitudeLine(index: 7, text: "Lot of Spirit 4°25' Sagittarius", longitude: 244.411),
    ]

    /// Splits `"<text> (<decimal>°)"` into the text and the parsed decimal, which must be
    /// printed with exactly three decimals; `nil` when the line is not of that shape.
    static func splitLongitude(_ line: String) -> (text: String, value: Double?) {
        guard line.hasSuffix("°)"), let open = line.range(of: " (", options: .backwards) else {
            return (line, nil)
        }
        let text = String(line[..<open.lowerBound])
        let number = line[open.upperBound...].dropLast(2)
        guard let decimals = number.split(separator: ".", omittingEmptySubsequences: false).last,
              decimals.count == 3, number.filter({ $0 == "." }).count == 1 else {
            return (text, nil)
        }
        return (text, Double(number))
    }

    /// Parses the altitude line, accepting the U+2212 MINUS SIGN the report prints.
    static func parseAltitude(_ line: String) -> Double? {
        guard line.hasPrefix(altitudePrefix), line.hasSuffix(altitudeSuffix) else { return nil }
        let number = line.dropFirst(altitudePrefix.count).dropLast(altitudeSuffix.count)
        return Double(number.replacingOccurrences(of: "\u{2212}", with: "-"))
    }
}

/// Asserts that `report` is the Appendix A report: nine lines whose text matches the
/// appendix exactly and whose decimal longitudes agree with it to 0.01°.
func assertAppendixAReport(_ report: String, file: StaticString = #filePath, line: UInt = #line) {
    let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(lines.count, 9, "the report has exactly nine lines:\n\(report)", file: file, line: line)
    XCTAssertFalse(report.hasSuffix("\n"), "no trailing newline", file: file, line: line)
    guard lines.count == 9 else { return }

    for expected in AppendixAReport.longitudeLines {
        let actual = lines[expected.index]
        let (text, value) = AppendixAReport.splitLongitude(actual)
        XCTAssertEqual(text, expected.text, "line \(expected.index + 1): \(actual)", file: file, line: line)
        XCTAssertNotNil(value, "line \(expected.index + 1) ends in a three-decimal longitude: \(actual)", file: file, line: line)
        if let value {
            XCTAssertEqual(value, expected.longitude, accuracy: AppendixAReport.longitudeTolerance,
                           "line \(expected.index + 1): \(actual)", file: file, line: line)
        }
    }

    let altitudeLine = lines[4]
    XCTAssertTrue(altitudeLine.hasPrefix(AppendixAReport.altitudePrefix + "\u{2212}"),
                  "negative altitude uses U+2212 MINUS SIGN: \(altitudeLine)", file: file, line: line)
    XCTAssertTrue(altitudeLine.hasSuffix(AppendixAReport.altitudeSuffix), "night chart: \(altitudeLine)", file: file, line: line)
    let altitude = AppendixAReport.parseAltitude(altitudeLine)
    XCTAssertNotNil(altitude, "altitude parses: \(altitudeLine)", file: file, line: line)
    if let altitude {
        XCTAssertTrue(AppendixAReport.altitudeRange.contains(altitude), "altitude −2.86…−2.88: \(altitudeLine)", file: file, line: line)
    }

    XCTAssertEqual(lines[8], AppendixAReport.rulerLine, file: file, line: line)
    XCTAssertTrue(lines[8].contains(" \u{2014} "), "ruler line uses an em dash", file: file, line: line)
}
