import XCTest
@testable import MediaFilter

final class GenericCaptionFilterTests: XCTestCase {
    func testSystemPlaceholdersAreDropped() {
        for placeholder in [
            "Screenshot",
            "Screen Recording",
            "screenshot",
            "SCREENSHOT",
            "  Screen Recording  \n",
        ] {
            XCTAssertNil(GenericCaptionFilter.userCaption(placeholder), placeholder)
        }
    }

    func testEmptyAndMissingCaptionsStayNil() {
        XCTAssertNil(GenericCaptionFilter.userCaption(nil))
        XCTAssertNil(GenericCaptionFilter.userCaption(""))
        XCTAssertNil(GenericCaptionFilter.userCaption("  \n "))
    }

    func testRealCaptionsAreKeptVerbatim() {
        for caption in [
            "Screenshot 工具太好用了",
            "截图",
            "screen recordings compared",
            "  傍晚的江边  ",
        ] {
            XCTAssertEqual(GenericCaptionFilter.userCaption(caption), caption)
        }
    }
}
