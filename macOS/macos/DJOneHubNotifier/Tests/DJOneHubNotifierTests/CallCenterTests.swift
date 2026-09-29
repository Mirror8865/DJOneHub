import XCTest
@testable import DJOneHubNotifier

/// CallCenter 受主线程隔离，测试也必须在相同执行上下文中运行。
@MainActor
final class CallCenterTests: XCTestCase {
    func testOnlyCurrentCallCanConsumeAsyncAudioResult() {
        XCTAssertTrue(
            CallCenter.shouldAcceptMaVoResult(
                for: "call-a",
                activeCallID: "call-a",
                routeCallID: "call-a"
            )
        )
        XCTAssertFalse(
            CallCenter.shouldAcceptMaVoResult(
                for: "call-a",
                activeCallID: "call-b",
                routeCallID: "call-a"
            )
        )
        XCTAssertFalse(
            CallCenter.shouldAcceptMaVoResult(
                for: "call-a",
                activeCallID: "call-a",
                routeCallID: nil
            )
        )
    }
}
