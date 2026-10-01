import XCTest
@testable import MacResourceMonitor

final class UITests: XCTestCase {
    func testApplicationMetadataIsStable() {
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.local.MacResourceMonitor")
        XCTAssertEqual(AppMetadata.minimumSystemVersion, "13.0")
    }
}
