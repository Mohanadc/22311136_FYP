import XCTest
@testable import FYP_22311136

final class JPEGExtractorTests: XCTestCase {

    var extractor: JPEGExtractor?

    override func setUp() {
        super.setUp()
        extractor = JPEGExtractor.shared
    }

    override func tearDown() {
        super.tearDown()
        extractor = nil
    }

    // MARK: - Header Tests

    func testFindHeaderOffsets_AtStart() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let offsets = try await extractor.findHeaderOffsets(in: data)
        XCTAssertEqual(offsets, [0], "Should find header at index 0")
        return 0;
    }

    func testFindHeaderOffsets_InMiddle() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0x00, 0x11, 0x22, 0xFF, 0xD8, 0xFF, 0xAA])
        let offsets = try await extractor.findHeaderOffsets(in: data)
        XCTAssertEqual(offsets, [3], "Should find header at index 3")
        return 0;
    }

    func testFindHeaderOffsets_Multiple() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0,
                         0x00, 0x10, 0xFF, 0xD8, 0xFF, 0xE1])
        let offsets = try await extractor.findHeaderOffsets(in: data)
        XCTAssertEqual(offsets.sorted(), [0, 7], "Should find headers at indices 0 and 7")
        return 0;
    }

    func testFindHeaderOffsets_CrossChunkBoundary() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        var data = Data(repeating: 0x00, count: 5)
        data.append(Data([0xFF, 0xD8, 0xFF]))
        let offsets = try await extractor.findHeaderOffsets(in: data, chunkSize: 5)
        XCTAssertEqual(offsets, [5], "Should find header spanning chunk boundary at index 5")
        return 0;
    }

    // MARK: - Footer Tests

    func testFindFooterOffsets_AtStart() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0xFF, 0xD9, 0xAA, 0xBB])
        let offsets = try await extractor.findFooterOffsets(in: data)
        XCTAssertEqual(offsets, [0], "Should find footer at index 0")
    }

    func testFindFooterOffsets_InMiddle() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0x00, 0x11, 0xFF, 0xD9, 0x22])
        let offsets = try await extractor.findFooterOffsets(in: data)
        XCTAssertEqual(offsets, [2], "Should find footer at index 2")
    }

    func testFindFooterOffsets_Multiple() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0xFF, 0xD9, 0xAA, 0xBB, 0xFF, 0xD9])
        let offsets = try await extractor.findFooterOffsets(in: data)
        XCTAssertEqual(offsets.sorted(), [0, 4], "Should find footers at indices 0 and 4")
    }

    func testFindFooterOffsets_CrossChunkBoundary() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        var data = Data(repeating: 0x00, count: 5)
        data.append(Data([0xFF, 0xD9]))
        let offsets = try await extractor.findFooterOffsets(in: data, chunkSize: 5)
        XCTAssertEqual(offsets, [5], "Should find footer spanning chunk boundary at index 5")
    }

    // MARK: - Integration Tests

    func testHeaderAndFooterTogether() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        let data = Data([0xFF, 0xD8, 0xFF,  // Header
                         0xE0, 0x00, 0x10,
                         0xFF, 0xD9])       // Footer
        let headers = try await extractor.findHeaderOffsets(in: data)
        let footers = try await extractor.findFooterOffsets(in: data)
        XCTAssertEqual(headers, [0], "Should find header at 0")
        XCTAssertEqual(footers, [6], "Should find footer at 6")
    }

    func testLargeDataWithMultipleMatches() async throws {
        guard let extractor = extractor else {
            XCTSkip("Metal device unavailable")
        }
        var data = Data()
        data.append(Data([0xFF, 0xD8, 0xFF]))  // Header at 0
        data.append(Data(repeating: 0x00, count: 100))
        data.append(Data([0xFF, 0xD9]))        // Footer at 103
        data.append(Data(repeating: 0xAA, count: 50))
        data.append(Data([0xFF, 0xD8, 0xFF]))  // Header at 156
        data.append(Data(repeating: 0xBB, count: 50))
        data.append(Data([0xFF, 0xD9]))        // Footer at 209

        let headers = try await extractor.findHeaderOffsets(in: data)
        let footers = try await extractor.findFooterOffsets(in: data)
        XCTAssertEqual(headers.sorted(), [0, 156], "Should find headers at 0 and 156")
        XCTAssertEqual(footers.sorted(), [103, 209], "Should find footers at 103 and 209")
    }
}
