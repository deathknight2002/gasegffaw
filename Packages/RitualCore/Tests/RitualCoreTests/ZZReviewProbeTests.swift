import XCTest
@testable import RitualCore
final class ZZThreshOK: XCTestCase { func testHour1e22() {
    let c = NatalChart.compute(birth: BirthData(year: 2002, month: 8, day: 16, hourUT: 1e22, latitude: 45, longitudeEast: -122)); print("PROBE 1e22 ok jd=\(c.birth.jdUT) \(c.sun.formatted)") } }
final class ZZThreshBad: XCTestCase { func testHour1e23() {
    let c = NatalChart.compute(birth: BirthData(year: 2002, month: 8, day: 16, hourUT: 1e23, latitude: 45, longitudeEast: -122)); print("PROBE 1e23 ok \(c.sun.formatted)") } }
