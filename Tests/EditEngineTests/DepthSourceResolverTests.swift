import XCTest
@testable import PhotoApp

final class DepthSourceResolverTests: XCTestCase {
    private typealias R = DepthSourceResolver

    func testAutomaticPrefersEmbeddedThenModelThenExplainsWhyNot() {
        XCTAssertEqual(R.resolve(.automatic, embeddedAvailable: true, modelAvailable: true), .use(.embedded))
        XCTAssertEqual(R.resolve(.automatic, embeddedAvailable: true, modelAvailable: false), .use(.embedded))
        XCTAssertEqual(R.resolve(.automatic, embeddedAvailable: false, modelAvailable: true), .use(.model))
        XCTAssertEqual(R.resolve(.automatic, embeddedAvailable: false, modelAvailable: false), .unavailable(R.noDepthAnywhere))
    }

    func testExplicitChoicesAreNeverSilentlySwitched() {
        XCTAssertEqual(R.resolve(.embedded, embeddedAvailable: true, modelAvailable: true), .use(.embedded))
        XCTAssertEqual(R.resolve(.embedded, embeddedAvailable: false, modelAvailable: true), .unavailable(R.noEmbedded), "an explicit iPhone-depth request must not fall back to the model")
        XCTAssertEqual(R.resolve(.model, embeddedAvailable: true, modelAvailable: true), .use(.model))
        XCTAssertEqual(R.resolve(.model, embeddedAvailable: true, modelAvailable: false), .unavailable(R.noModel), "nor the other way round")
    }

    func testRegenerateKeepsTheMasksCurrentSource() {
        XCTAssertEqual(R.preference(forTag: DepthSourceTag.embedded), .embedded)
        XCTAssertEqual(R.preference(forTag: DepthSourceTag.model(id: "m", revision: "r")), .model)
        XCTAssertEqual(R.preference(forTag: ""), .automatic)
        XCTAssertEqual(R.preference(forTag: "something-else"), .automatic)
    }

    func testMessagesTellTheUserWhatToDo() {
        XCTAssertTrue(R.noModel.contains("fetch_depth_model.sh"))
        XCTAssertTrue(R.noDepthAnywhere.contains("fetch_depth_model.sh"))
        XCTAssertTrue(R.noEmbedded.contains("depth model"))
    }
}
