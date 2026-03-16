import XCTest
@testable import FYP_22311136

final class SignatureMatcherTests: XCTestCase {

    // MARK: - Empty input

    func testEmptyHeadersReturnsNoMatches() {
        let result = SignatureMatcher.pairHeadersWithFooters(headers: [], footers: [100, 200])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyFootersReturnsNoMatches() {
        let result = SignatureMatcher.pairHeadersWithFooters(headers: [0, 50], footers: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBothEmptyReturnsNoMatches() {
        let result = SignatureMatcher.pairHeadersWithFooters(headers: [], footers: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Single match

    func testSingleHeaderFooterPair() {
        let result = SignatureMatcher.pairHeadersWithFooters(headers: [0], footers: [100])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].headerOffset, 0)
        XCTAssertEqual(result[0].footerOffset, 100)
    }

    // MARK: - Multiple matches

    func testMultiplePairs() {
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [0, 200, 500],
            footers: [100, 400, 700]
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].headerOffset, 0)
        XCTAssertEqual(result[0].footerOffset, 100)
        XCTAssertEqual(result[1].headerOffset, 200)
        XCTAssertEqual(result[1].footerOffset, 400)
        XCTAssertEqual(result[2].headerOffset, 500)
        XCTAssertEqual(result[2].footerOffset, 700)
    }

    // MARK: - Edge cases

    func testFooterBeforeHeaderIsSkipped() {
        // Footer at 10 should be skipped; header at 50 pairs with footer at 100
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [50],
            footers: [10, 100]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].footerOffset, 100)
    }

    func testFooterAtSameOffsetAsHeaderIsSkipped() {
        // Footer must be strictly AFTER header
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [100],
            footers: [100, 200]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].footerOffset, 200)
    }

    func testMoreHeadersThanFooters() {
        // Only the first two headers can be paired
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [0, 200, 500],
            footers: [100, 400]
        )
        XCTAssertEqual(result.count, 2)
    }

    func testMoreFootersThanHeaders() {
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [0],
            footers: [100, 200, 300]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].footerOffset, 100)
    }

    func testEachFooterConsumedOnlyOnce() {
        // Two headers close together should each get their own footer
        let result = SignatureMatcher.pairHeadersWithFooters(
            headers: [0, 10],
            footers: [50, 100]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].footerOffset, 50)
        XCTAssertEqual(result[1].footerOffset, 100)
    }
}
