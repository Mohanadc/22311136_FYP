import XCTest
@testable import FYP_22311136

final class CpuFileCarverTests: XCTestCase {

    func testName() {
        let carver = CpuFileCarver()
        XCTAssertEqual(carver.name, "CPU")
    }

    // MARK: - Scanning synthetic data

    /// Build a byte buffer containing embedded JPEG markers and write it to a temp file.
    /// Then verify the CPU carver finds the correct header/footer offsets.
    func testScanFindsEmbeddedJPEGMarkers() async throws {
        // Layout:
        //   [0..2]   FF D8 FF   (header)
        //   [3..49]  padding
        //   [50..51] FF D9      (footer)
        //   [52..99] padding
        var data = Data(count: 100)
        // Header at offset 0
        data[0] = 0xFF; data[1] = 0xD8; data[2] = 0xFF
        // Footer at offset 50
        data[50] = 0xFF; data[51] = 0xD9

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpu_carver_test_\(UUID().uuidString).bin")
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let carver = CpuFileCarver()
        let matches = try await carver.scanFile(url: tmpURL, fileTypes: [.jpeg])

        XCTAssertEqual(matches.count, 1, "Should find exactly one JPEG")
        XCTAssertEqual(matches[0].headerOffset, 0)
        XCTAssertEqual(matches[0].footerOffset, 50)
    }

    /// Multiple JPEGs embedded in the same buffer.
    func testScanFindsMultipleJPEGs() async throws {
        var data = Data(count: 200)
        // JPEG 1: header at 0, footer at 30
        data[0] = 0xFF; data[1] = 0xD8; data[2] = 0xFF
        data[30] = 0xFF; data[31] = 0xD9
        // JPEG 2: header at 100, footer at 150
        data[100] = 0xFF; data[101] = 0xD8; data[102] = 0xFF
        data[150] = 0xFF; data[151] = 0xD9

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpu_carver_test_\(UUID().uuidString).bin")
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let carver = CpuFileCarver()
        let matches = try await carver.scanFile(url: tmpURL, fileTypes: [.jpeg])

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].headerOffset, 0)
        XCTAssertEqual(matches[0].footerOffset, 30)
        XCTAssertEqual(matches[1].headerOffset, 100)
        XCTAssertEqual(matches[1].footerOffset, 150)
    }

    /// No markers → no matches.
    func testScanNoMarkersReturnsEmpty() async throws {
        let data = Data(repeating: 0x00, count: 100)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpu_carver_test_\(UUID().uuidString).bin")
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let carver = CpuFileCarver()
        let matches = try await carver.scanFile(url: tmpURL, fileTypes: [.jpeg])

        XCTAssertTrue(matches.isEmpty)
    }

    /// Empty file types should throw.
    func testScanThrowsIfNoFileTypesSelected() async {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpu_carver_test_\(UUID().uuidString).bin")
        try? Data(count: 10).write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let carver = CpuFileCarver()
        do {
            _ = try await carver.scanFile(url: tmpURL, fileTypes: [])
            XCTFail("Expected CarverError.noFileTypesSelected")
        } catch is CarverError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
