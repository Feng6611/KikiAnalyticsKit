import XCTest
import KikiAnalyticsTesting

final class RecordingAnalyticsTransportTests: XCTestCase {
    func testRecordingAndPrivacyAssertion() {
        let recorder = RecordingAnalyticsTransport()
        recorder.send(name: "test performed", distinctID: "installation", properties: ["count": 2, "nested": ["source": ["manual"]]])
        recorder.flush()
        recorder.setOptedOut(true)
        XCTAssertEqual(recorder.names, ["test performed"])
        XCTAssertEqual(recorder.events[0].distinctID, "installation")
        XCTAssertEqual(recorder.events[0].properties["count"] as? Int, 2)
        XCTAssertEqual(recorder.flushCallCount, 1)
        XCTAssertEqual(recorder.optOutCalls, [true])
        recorder.assertNoProperty(containing: "com.apple")
    }

    func testPrivacyAssertionReportsXCTestFailureAtCaller() {
        let recorder = RecordingAnalyticsTransport()
        recorder.send(name: "test", distinctID: "installation", properties: ["nested": ["values": ["com.apple.Finder"]]])
        XCTExpectFailure("Deliberate privacy failure proves the helper uses XCTest, including nested values.") {
            recorder.assertNoProperty(containing: "com.apple")
        }
    }
}
