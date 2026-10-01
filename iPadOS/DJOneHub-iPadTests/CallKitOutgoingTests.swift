import CallKit
import AVFoundation
import XCTest
@testable import DJOneHub

@MainActor
private final class CallKitHandlerProbe: CallKitActionHandling {
    private let started: XCTestExpectation
    private(set) var startedNumbers: [String] = []

    init(started: XCTestExpectation) {
        self.started = started
    }

    // 当生产协议增加呼出回调后，这个同名方法会直接满足协议。
    func callKitStart(number: String) async throws {
        startedNumbers.append(number)
        started.fulfill()
    }

    func callKitAnswer() async throws {}
    func callKitEnd() async throws {}
    func callKitSetMuted(_ muted: Bool) async {}
    func callKitPlayDTMF(_ digits: String) async throws {}
    func callKitAudioSessionDidActivate() async {}
    func callKitAudioSessionDidDeactivate() {}
    func callKitProviderDidReset() async {}
    func callKitDidFail(_ message: String) {}
}

@MainActor
final class CallKitOutgoingTests: XCTestCase {

    func testLocalHistorySurvivesStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJOneHubHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let call = CallRecord(
            id: "call-1",
            index: 1,
            direction: "incoming",
            state: "ended",
            number: "10086",
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_010),
            endedAt: Date(timeIntervalSince1970: 1_010),
            missed: false
        )
        let message = SMSMessage(
            sender: "10086",
            content: "测试短信",
            code: nil,
            timestamp: Date(timeIntervalSince1970: 2_000),
            deliveryID: "delivery-1",
            direction: .incoming
        )

        let writer = LocalHistoryStore(directoryURL: directory)
        XCTAssertTrue(writer.saveCallHistory([call]))
        XCTAssertTrue(writer.saveMessages([message]))

        // 用全新的 Store 模拟 App 被系统结束后重新启动，确保数据来自磁盘而不是旧内存。
        let reader = LocalHistoryStore(directoryURL: directory)
        XCTAssertEqual(reader.loadCallHistory(), [call])
        XCTAssertEqual(reader.loadMessages(), [message])
    }

    func testWiredRequestCancellationGateHandlesBothCancellationOrdersOnce() {
        let installedFirst = WiredRequestCancellationGate()
        var installedFirstCount = 0
        installedFirst.install { installedFirstCount += 1 }
        installedFirst.cancel()
        installedFirst.cancel()
        XCTAssertEqual(installedFirstCount, 1)

        let cancelledFirst = WiredRequestCancellationGate()
        var cancelledFirstCount = 0
        cancelledFirst.cancel()
        cancelledFirst.install { cancelledFirstCount += 1 }
        cancelledFirst.cancel()
        XCTAssertEqual(cancelledFirstCount, 1)
    }

    func testDialPadDeletePolicyRemovesOneCharacterAndHandlesEmptyInput() {
        XCTAssertEqual(DialPadDeletePolicy.removingLast(from: "10086"), "1008")
        XCTAssertEqual(DialPadDeletePolicy.removingLast(from: "+8613"), "+861")
        XCTAssertEqual(DialPadDeletePolicy.removingLast(from: ""), "")
    }
    func testCallKitActivatedSessionPreservesSystemSpeakerRoute() {
        let plan = CallAudioActivationPlan.make(
            sessionAlreadyActive: true,
            speakerEnabled: false
        )

        XCTAssertFalse(plan.shouldConfigureSession)
        XCTAssertFalse(plan.shouldActivateSession)
        XCTAssertNil(plan.outputOverride)
    }

    func testAppManagedSessionAppliesRequestedInitialRoute() {
        let receiverPlan = CallAudioActivationPlan.make(
            sessionAlreadyActive: false,
            speakerEnabled: false
        )
        let speakerPlan = CallAudioActivationPlan.make(
            sessionAlreadyActive: false,
            speakerEnabled: true
        )

        XCTAssertTrue(receiverPlan.shouldConfigureSession)
        XCTAssertTrue(receiverPlan.shouldActivateSession)
        XCTAssertEqual(receiverPlan.outputOverride, .some(AVAudioSession.PortOverride.none))
        XCTAssertEqual(speakerPlan.outputOverride, .speaker)
    }

    func testNewCallResetsSpeakerPreferenceToReceiver() throws {
        let audio = AudioSessionController()
        try audio.setSpeakerEnabled(true)

        audio.resetControlsForNewCall()

        XCTAssertFalse(audio.speakerEnabled)
    }

    func testGPSStatusDecodesLastAgentError() throws {
        let payload = #"{"enabled":true,"last_fix":null,"last_error":"暂未获得定位"}"#.data(using: .utf8)!

        let status = try JSONDecoder().decode(GPSStatus.self, from: payload)

        XCTAssertEqual(status.lastError, "暂未获得定位")
    }

    func testSystemPowerStatusDecodesThermalReading() throws {
        let payload = #"""
        {
          "supported": true,
          "readings": [{
            "kind": "thermal", "name": "soc", "path": "/sys/class/thermal/thermal_zone0",
            "temperature_c": 43.25
          }],
          "sampled_at_ms": 1787078400000
        }
        """#.data(using: .utf8)!

        let status = try JSONDecoder().decode(SystemPowerStatus.self, from: payload)
        XCTAssertTrue(status.supported)
        XCTAssertEqual(status.readings.count, 1)
        XCTAssertEqual(status.readings[0].kind, "thermal")
        XCTAssertEqual(status.readings[0].temperatureC ?? 0, 43.25, accuracy: 0.000_001)
    }

    func testModuleUpdatePolicyInstallsNewerEmbeddedAgent() {
        XCTAssertTrue(ModuleUpdatePolicy.shouldInstall(installed: "0.3.12", available: "0.3.13"))
        XCTAssertFalse(ModuleUpdatePolicy.shouldInstall(installed: "0.3.13", available: "0.3.13"))
        XCTAssertFalse(ModuleUpdatePolicy.shouldInstall(installed: "0.3.14", available: "0.3.13"))
    }

    func testGPSRefreshRequiresEnabledSwitch() {
        XCTAssertTrue(GPSRefreshPolicy.shouldRequest(isEnabled: true))
        XCTAssertFalse(GPSRefreshPolicy.shouldRequest(isEnabled: false))
    }

    func testWiredTransportOnlyAllowsSafeInterfaceFallback() {
        XCTAssertTrue(WiredHTTPTransport.allowsInterfaceFallback(httpMethod: "GET"))
        XCTAssertTrue(WiredHTTPTransport.allowsInterfaceFallback(httpMethod: "HEAD"))
        XCTAssertFalse(WiredHTTPTransport.allowsInterfaceFallback(httpMethod: "POST"))
        XCTAssertFalse(WiredHTTPTransport.allowsInterfaceFallback(httpMethod: "PATCH"))
    }

    func testNetworkDiagnosticProbePolicyPreventsDuplicateRequests() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            NetworkDiagnosticProbePolicy.shouldStart(now: now, lastStartedAt: nil, isRunning: false)
        )
        XCTAssertFalse(
            NetworkDiagnosticProbePolicy.shouldStart(
                now: now,
                lastStartedAt: now.addingTimeInterval(-5),
                isRunning: false
            )
        )
        XCTAssertFalse(
            NetworkDiagnosticProbePolicy.shouldStart(
                now: now,
                lastStartedAt: now.addingTimeInterval(-20),
                isRunning: true
            )
        )
        XCTAssertTrue(
            NetworkDiagnosticProbePolicy.shouldStart(
                now: now,
                lastStartedAt: now.addingTimeInterval(-20),
                isRunning: false
            )
        )
    }

    func testModuleUSBResolverOnlySelectsLocalECMHostAddress() {
        let addresses = [
            NetworkInterfaceAddress(name: "en8", address: "192.168.225.2"),
            NetworkInterfaceAddress(name: "en9", address: "192.168.225.254"),
            NetworkInterfaceAddress(name: "utun3", address: "192.168.225.1"),
            NetworkInterfaceAddress(name: "utun4", address: "10.0.0.2"),
            NetworkInterfaceAddress(name: "en10", address: "192.168.224.2"),
            NetworkInterfaceAddress(name: "en11", address: "192.168.225.999")
        ]

        XCTAssertEqual(
            ModuleUSBInterfaceResolver.moduleInterfaceNames(from: addresses),
            Set(["en8", "en9"])
        )
    }

    func testPhoneTabsRemainFourStableTopLevelDestinations() {
        // 设置改为各主页面右上角入口，底部标签栏只保留四个高频功能。
        XCTAssertEqual(PhoneTab.allCases, [.dial, .recents, .messages, .contacts])
        XCTAssertEqual(Set(PhoneTab.allCases.map(\.tabTitle)).count, 4)
        XCTAssertTrue(PhoneTab.allCases.allSatisfy { !$0.icon.isEmpty })
    }

    func testRecentCallFormattingAndDialValidation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12, minute: 0))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 10, minute: 20))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        XCTAssertEqual(RecentCallTimeFormatter.string(for: today, now: now, calendar: calendar), "10:20")
        XCTAssertEqual(RecentCallTimeFormatter.string(for: yesterday, now: now, calendar: calendar), "昨天")
        XCTAssertEqual(RecentCallDialPolicy.numberToDial("10086"), "10086")
        XCTAssertNil(RecentCallDialPolicy.numberToDial(nil))
        XCTAssertNil(RecentCallDialPolicy.numberToDial(""))
    }

    func testLiveActivityOfflineOverridesStandbyRadioSnapshot() {
        let radio = ModemStatus(
            imei: nil, firmware: nil, iccid: nil, imsi: nil,
            operatorName: "中国联通", simInserted: true, signalDBM: -61,
            networkMode: "FDD LTE", radioBand: "B3", registrationText: "已注册"
        )

        let state = LiveActivityStateBuilder.make(
            call: nil,
            callerName: nil,
            moduleOnline: false,
            radio: radio,
            idleStartedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )

        XCTAssertEqual(state.phase, .offline)
        XCTAssertNil(state.signalDBM)
        XCTAssertNil(state.operatorName)
        XCTAssertNil(state.networkMode)
    }

    func testLiveActivityStandbyIncludesModuleRadioSnapshot() {
        let radio = ModemStatus(
            imei: nil, firmware: nil, iccid: nil, imsi: nil,
            operatorName: "中国联通", simInserted: true, signalDBM: -61,
            networkMode: "FDD LTE", radioBand: "B3", registrationText: "已注册"
        )

        let state = LiveActivityStateBuilder.make(
            call: nil,
            callerName: nil,
            moduleOnline: true,
            radio: radio,
            idleStartedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )

        XCTAssertEqual(state.phase, .standby)
        XCTAssertEqual(state.signalDBM, -61)
        XCTAssertEqual(state.operatorName, "中国联通")
        XCTAssertEqual(state.networkMode, "FDD LTE")
        XCTAssertEqual(state.radioBand, "B3")
    }

    func testStaleStandbyDoesNotPretendModuleIsOffline() {
        let state = DJOneHubCallActivityAttributes.ContentState(
            callID: "",
            number: "",
            displayName: "等待模块来电",
            phase: .standby,
            startedAt: Date(timeIntervalSince1970: 1_787_000_000),
            signalDBM: -67,
            operatorName: "中国联通",
            networkMode: "FDD LTE",
            radioBand: "B3"
        )

        let displayed = state.liveActivityDisplayState(isStale: true)

        XCTAssertEqual(displayed.phase, .standby)
        XCTAssertEqual(displayed.operatorName, "中国联通")
        XCTAssertEqual(displayed.signalDBM, -67)
    }

    func testForegroundOfflineStateCanReplaceOrphanedLiveActivity() {
        XCTAssertTrue(
            LiveActivityCreationPolicy.shouldCreate(
                appIsActive: true,
                moduleOnline: false,
                hasActivity: false
            )
        )
        XCTAssertFalse(
            LiveActivityCreationPolicy.shouldCreate(
                appIsActive: false,
                moduleOnline: false,
                hasActivity: false
            )
        )
    }

    func testStartActionDialsModuleExactlyOnce() async {
        let started = expectation(description: "CallKit 呼出动作交给模块")
        let handler = CallKitHandlerProbe(started: started)
        let controller = CallKitController()
        controller.handler = handler
        let action = CXStartCallAction(
            call: UUID(),
            handle: CXHandle(type: .phoneNumber, value: "10086")
        )

        controller.provider(CXProvider(configuration: CXProviderConfiguration()), perform: action)

        await fulfillment(of: [started], timeout: 0.3)
        XCTAssertEqual(handler.startedNumbers, ["10086"])
    }

    func testDuplicateStartActionNeverRedialsModule() async {
        let started = expectation(description: "重复 CallKit 动作仅拨号一次")
        // 不启用 XCTest 的致命过量 fulfill 断言；下方通过最终调用数稳定检测重复拨号。
        let handler = CallKitHandlerProbe(started: started)
        let controller = CallKitController()
        controller.handler = handler
        let action = CXStartCallAction(
            call: UUID(),
            handle: CXHandle(type: .phoneNumber, value: "10010")
        )
        let provider = CXProvider(configuration: CXProviderConfiguration())

        controller.provider(provider, perform: action)
        await fulfillment(of: [started], timeout: 0.3)
        controller.provider(provider, perform: action)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(handler.startedNumbers, ["10010"])
    }

    func testConfirmedRemoteEndClosesSystemCallOnFirstPoll() async {
        let started = expectation(description: "先建立系统呼出")
        let handler = CallKitHandlerProbe(started: started)
        let controller = CallKitController()
        controller.handler = handler
        let action = CXStartCallAction(
            call: UUID(),
            handle: CXHandle(type: .phoneNumber, value: "10000")
        )
        controller.provider(CXProvider(configuration: CXProviderConfiguration()), perform: action)
        await fulfillment(of: [started], timeout: 0.3)

        let startedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let active = CallRecord(
            id: "outgoing-1", index: 1, direction: "outgoing", state: "active", number: "10000",
            startedAt: startedAt, updatedAt: startedAt, endedAt: nil, missed: false
        )
        controller.synchronize(call: active, previous: nil, callerName: nil)
        let endedAt = startedAt.addingTimeInterval(10)
        let ended = CallRecord(
            id: active.id, index: active.index, direction: active.direction, state: "active", number: active.number,
            startedAt: active.startedAt, updatedAt: endedAt, endedAt: endedAt, missed: false
        )

        controller.synchronize(call: nil, previous: ended, callerName: nil)

        XCTAssertFalse(controller.managesCurrentCall)
    }
}
