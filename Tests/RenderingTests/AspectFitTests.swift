import XCTest
@testable import PhotoApp

final class AspectFitTests: XCTestCase {
    func testLandscapeImageIntoPortraitContainer() {
        let rect = AspectFit.rect(
            fitting: CGSize(width: 4000, height: 2000),
            in: CGSize(width: 1000, height: 2000)
        )

        // Width-constrained: fitted width == container width, centered vertically.
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 500, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 750, accuracy: 0.001)
    }

    func testPortraitImageIntoLandscapeContainer() {
        let rect = AspectFit.rect(
            fitting: CGSize(width: 2000, height: 4000),
            in: CGSize(width: 2000, height: 1000)
        )

        // Height-constrained: fitted height == container height, centered horizontally.
        XCTAssertEqual(rect.height, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.width, 500, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 750, accuracy: 0.001)
    }

    func testExactAspectMatchFillsContainerWithNoOffset() {
        let rect = AspectFit.rect(
            fitting: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 960, height: 540)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    func testSquareImageIntoWideContainerIsCenteredHorizontally() {
        let rect = AspectFit.rect(
            fitting: CGSize(width: 100, height: 100),
            in: CGSize(width: 300, height: 100)
        )

        XCTAssertEqual(rect, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    func testZeroSizedImageProducesZeroRect() {
        let rect = AspectFit.rect(
            fitting: .zero,
            in: CGSize(width: 500, height: 500)
        )

        XCTAssertEqual(rect, .zero)
    }

    func testZeroSizedContainerProducesZeroRect() {
        let rect = AspectFit.rect(
            fitting: CGSize(width: 500, height: 500),
            in: .zero
        )

        XCTAssertEqual(rect, .zero)
    }
}
