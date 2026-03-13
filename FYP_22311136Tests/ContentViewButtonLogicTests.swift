import XCTest
@testable import FYP_22311136

final class ContentViewButtonLogicTests: XCTestCase {

    func testStartButtonLabel_whenCarvingShowsCarving() {
        let label = ContentView.startButtonLabel(isCarving: true, finishedCarving: false, selectedFileTypesEmpty: false)
        XCTAssertEqual(label, "Carving…")
    }

    func testStartButtonLabel_whenFinishedShowsSelectAnother() {
        let label = ContentView.startButtonLabel(isCarving: false, finishedCarving: true, selectedFileTypesEmpty: false)
        XCTAssertEqual(label, "Select another file to carve.")
    }

    func testStartButtonLabel_whenNoTypesShowsSelectFileTypes() {
        let label = ContentView.startButtonLabel(isCarving: false, finishedCarving: false, selectedFileTypesEmpty: true)
        XCTAssertEqual(label, "Select file types")
    }

    func testStartButtonLabel_defaultShowsStartCarving() {
        let label = ContentView.startButtonLabel(isCarving: false, finishedCarving: false, selectedFileTypesEmpty: false)
        XCTAssertEqual(label, "Start Carving")
    }

    func testStartButtonDisabled_logic() {
        // disabled when path empty
        XCTAssertTrue(ContentView.isStartButtonDisabled(selectedFilePathEmpty: true, isCarving: false, finishedCarving: false, selectedFileTypesEmpty: false))
        // disabled when carving
        XCTAssertTrue(ContentView.isStartButtonDisabled(selectedFilePathEmpty: false, isCarving: true, finishedCarving: false, selectedFileTypesEmpty: false))
        // disabled when finished
        XCTAssertTrue(ContentView.isStartButtonDisabled(selectedFilePathEmpty: false, isCarving: false, finishedCarving: true, selectedFileTypesEmpty: false))
        // disabled when no selected types
        XCTAssertTrue(ContentView.isStartButtonDisabled(selectedFilePathEmpty: false, isCarving: false, finishedCarving: false, selectedFileTypesEmpty: true))
        // enabled when none of the disabling conditions apply
        XCTAssertFalse(ContentView.isStartButtonDisabled(selectedFilePathEmpty: false, isCarving: false, finishedCarving: false, selectedFileTypesEmpty: false))
    }

    func testRevealButtonDisabled_logic() {
        XCTAssertTrue(ContentView.isRevealButtonDisabled(savedFileURLsEmpty: true, isCarving: false))
        XCTAssertTrue(ContentView.isRevealButtonDisabled(savedFileURLsEmpty: false, isCarving: true))
        XCTAssertFalse(ContentView.isRevealButtonDisabled(savedFileURLsEmpty: false, isCarving: false))
    }

    func testSelectButtonLabel() {
        XCTAssertEqual(ContentView.selectButtonLabel(selectedFileNameEmpty: true), "Select")
        XCTAssertEqual(ContentView.selectButtonLabel(selectedFileNameEmpty: false), "Change")
    }

    func testClearVisibility() {
        XCTAssertTrue(ContentView.isClearVisible(isCarving: false))
        XCTAssertFalse(ContentView.isClearVisible(isCarving: true))
    }
}
