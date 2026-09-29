import AVFoundation
import CallKit
import Foundation

/// 把系统 CallKit 操作转发给模块控制层，协议限定在主线程以保护 AppModel 状态。
@MainActor
protocol CallKitActionHandling: AnyObject {
    func callKitStart(number: String) async throws
    func callKitAnswer() async throws
    func callKitEnd() async throws
    func callKitSetMuted(_ muted: Bool) async
    func callKitPlayDTMF(_ digits: String) async throws
    func callKitAudioSessionDidActivate() async
    func callKitAudioSessionDidDeactivate()
    func callKitProviderDidReset() async
    func callKitDidFail(_ message: String)
}

/// 维护模块通话与系统通话 UUID 的一一映射，并承接锁屏与系统通话界面的操作。
@MainActor
final class CallKitController: NSObject {
    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var audioSessionIsActive = false
    private(set) var isAvailable = true
    weak var handler: (any CallKitActionHandling)?

    private var currentUUID: UUID?
    private var currentBackendID: String?
    private var currentState: String?
    private var currentNumber: String?
    private var currentDirection: String?
    private var incomingReportRequested = false
    private var incomingReportFailed = false
    private var systemCallReported = false
    private var endActionFulfilled = false
    private var missingCallPolls = 0
    private var outgoingStartInFlight = false

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit {
        provider.invalidate()
    }

    var managesCurrentCall: Bool {
        isAvailable && currentUUID != nil && (systemCallReported || currentDirection == "outgoing")
    }

    var suppressesInAppIncomingRingtone: Bool {
        incomingReportRequested && !incomingReportFailed
    }

    /// 先让系统接管呼出事务；真正的模块 ATD 只能在 CXProvider delegate 回调中执行。
    func startOutgoingCall(number: String) async throws {
        guard isAvailable else { throw CallKitBridgeError.unavailable }
        guard currentUUID == nil else { throw CallKitBridgeError.callInProgress }

        let uuid = UUID()
        currentUUID = uuid
        currentDirection = "outgoing"
        currentNumber = number
        currentState = "dialing"
        missingCallPolls = 0
        endActionFulfilled = false

        do {
            let handle = CXHandle(type: .phoneNumber, value: number)
            try await request(CXStartCallAction(call: uuid, handle: handle))
        } catch {
            let unavailable = disableCallKitIfUnentitled(error)
            resetCurrentCall()
            if unavailable { throw CallKitBridgeError.unavailable }
            throw error
        }
    }

    func answerCurrentCall() async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXAnswerCallAction(call: uuid))
    }

    func endCurrentCall() async throws {
        guard let uuid = currentUUID, systemCallReported || currentDirection == "outgoing" else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXEndCallAction(call: uuid))
    }

    func setMuted(_ muted: Bool) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        try await requestSystemAction(CXSetMutedCallAction(call: uuid, muted: muted))
    }

    /// App 内键盘也走 CallKit 事务，保证系统通话页和 App 页不会各自维护一套 DTMF 状态。
    func playDTMF(_ digits: String) async throws {
        guard let uuid = currentUUID, systemCallReported else {
            throw CallKitBridgeError.noSystemCall
        }
        let validDigits = digits.filter { "0123456789*#".contains($0) }
        guard !validDigits.isEmpty else { return }
        try await requestSystemAction(
            CXPlayDTMFCallAction(call: uuid, digits: validDigits, type: .singleTone)
        )
    }

    /// 每次模块轮询后把呼入与呼出生命周期同步给系统。
    func synchronize(call: CallRecord?, previous: CallRecord?, callerName: String?) {
        // CallKit 权限被系统拒绝后只保留 App 内状态机，不能继续伪造系统通话 UUID。
        guard isAvailable else {
            if call == nil { resetCurrentCall() }
            return
        }
        guard let call else {
            // 模块已把同一 ID 写入带 ended_at 的 history，这是明确的结束事件，
            // 必须立即关闭系统通话，不再等待空 CLCC 防抖。
            if previous?.endedAt != nil {
                finishCurrentCall(previous: previous)
                return
            }
            // AT+CLCC 偶发空响应不等于电话已挂断；保留 UUID，避免系统扬声器/静音事务变成未知 UUID。
            if currentUUID != nil, systemCallReported || currentDirection == "outgoing" {
                missingCallPolls += 1
                guard missingCallPolls >= 3 else { return }
            }
            finishCurrentCall(previous: previous)
            return
        }

        if call.direction == "outgoing" {
            // 只同步由 startOutgoingCall 建立的系统呼出；不为外部 ATD 伪造 UUID。
            guard currentDirection == "outgoing", let uuid = currentUUID else { return }
            if let backendID = currentBackendID, backendID != call.id {
                finishCurrentCall(previous: previous, reason: .failed)
                return
            }
            currentBackendID = call.id
            currentNumber = call.number ?? currentNumber
            missingCallPolls = 0
            if call.state == "active", currentState != "active", systemCallReported {
                provider.reportOutgoingCall(with: uuid, connectedAt: call.updatedAt)
            }
            currentState = call.state
            return
        }

        if currentDirection == "outgoing" {
            finishCurrentCall(previous: previous, reason: .failed)
        }

        missingCallPolls = 0
        outgoingStartInFlight = false

        if let backendID = currentBackendID, backendID != call.id {
            finishCurrentCall(previous: previous, reason: .failed)
        }
        if currentUUID == nil { currentUUID = UUID() }
        currentDirection = "incoming"
        currentBackendID = call.id
        currentNumber = call.number

        if ["incoming", "waiting"].contains(call.state) {
            reportIncomingIfNeeded(call: call, callerName: callerName)
        }
        currentState = call.state
    }

    private func reportIncomingIfNeeded(call: CallRecord, callerName: String?) {
        guard !incomingReportRequested, !systemCallReported, let uuid = currentUUID else { return }
        incomingReportRequested = true
        debugLog("请求系统来电界面；状态=\(call.state)")
        provider.reportNewIncomingCall(
            with: uuid,
            update: update(number: call.number, callerName: callerName)
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    let diagnosticError = error as NSError
                    self.debugLog(
                        "系统来电上报失败；domain=\(diagnosticError.domain) code=\(diagnosticError.code) "
                            + "message=\(diagnosticError.localizedDescription)"
                    )
                    if self.disableCallKitIfUnentitled(error) {
                        self.resetCurrentCall()
                        return
                    }
                    self.systemCallReported = false
                    self.incomingReportFailed = true
                    self.handler?.callKitDidFail("系统来电界面启动失败：\(error.localizedDescription)")
                } else {
                    self.debugLog("系统来电上报成功")
                    self.systemCallReported = true
                }
            }
        }
    }

    private func finishCurrentCall(
        previous: CallRecord?,
        reason explicitReason: CXCallEndedReason? = nil
    ) {
        guard let uuid = currentUUID else { return }
        if systemCallReported, !endActionFulfilled {
            let reason = explicitReason ?? endedReason(for: previous)
            provider.reportCall(with: uuid, endedAt: previous?.endedAt ?? Date(), reason: reason)
        }
        resetCurrentCall()
    }

    private func endedReason(for call: CallRecord?) -> CXCallEndedReason {
        guard let call else { return .failed }
        return call.state == "active" || call.state == "held" ? .remoteEnded : .unanswered
    }

    private func update(number: String?, callerName: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        let value = number?.isEmpty == false ? number! : "未知号码"
        update.remoteHandle = CXHandle(type: .phoneNumber, value: value)
        if let callerName, !callerName.isEmpty, callerName != number {
            update.localizedCallerName = callerName
        }
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        update.hasVideo = false
        return update
    }

    private func request(_ action: CXAction) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            callController.request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// CallKit 可能在系统界面重建期间短暂丢失 UUID；转换成业务层可恢复错误，
    /// 不让错误 4 直接传播成“通话已结束”。
    private func requestSystemAction(_ action: CXAction) async throws {
        do {
            try await request(action)
        } catch {
            let nsError = error as NSError
            if nsError.domain == CXErrorDomainRequestTransaction,
               nsError.code == CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue {
                throw CallKitBridgeError.staleSystemCall
            }
            throw error
        }
    }

    /// 个人签名或受限设备可能返回 requesttransaction/unentitled；此时自动使用 App 内通话。
    private func disableCallKitIfUnentitled(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CXErrorDomainRequestTransaction,
              error.code == CXErrorCodeRequestTransactionError.Code.unentitled.rawValue else {
            return false
        }
        isAvailable = false
        audioSessionIsActive = false
        debugLog("CallKit 被系统判定为无权限，已降级到 App 内通话")
        return true
    }

    /// 真机联调只记录状态与系统错误码，避免把电话号码写入设备日志。
    private func debugLog(_ message: String) {
#if DEBUG
        print("[DJOneHub CallKit] \(message)")
#endif
    }

    private func resetCurrentCall() {
        currentUUID = nil
        currentBackendID = nil
        currentState = nil
        currentNumber = nil
        currentDirection = nil
        incomingReportRequested = false
        incomingReportFailed = false
        systemCallReported = false
        endActionFulfilled = false
        missingCallPolls = 0
        outgoingStartInFlight = false
    }

    private func fail(_ action: CXAction, error: Error) {
        action.fail()
        handler?.callKitDidFail(error.localizedDescription)
    }

    private func performAnswer(_ action: CXAnswerCallAction) async {
        do {
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            try await handler.callKitAnswer()
            // 必须先完成系统接听动作，CallKit 才会激活 AVAudioSession 并回调 didActivate。
            // 音频启动由 didActivate 与模块状态轮询汇合完成，不能在 fulfill 前同步等待。
            action.fulfill()
        } catch {
            fail(action, error: error)
        }
    }

    private func performStart(_ action: CXStartCallAction) async {
        if action.isComplete { return }
        if outgoingStartInFlight { return }
        if systemCallReported, currentUUID == action.callUUID, currentDirection == "outgoing" {
            action.fulfill()
            return
        }
        outgoingStartInFlight = true
        defer { outgoingStartInFlight = false }
        do {
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            // 除了 App 内提交的事务，系统也可能通过 Siri/联系人把呼出动作
            // 直接交给 provider；此时以系统 UUID 建立同一套状态。
            if currentUUID == nil {
                currentUUID = action.callUUID
                currentDirection = "outgoing"
                currentNumber = action.handle.value
                currentState = "dialing"
            }
            guard currentUUID == action.callUUID, currentDirection == "outgoing" else {
                throw CallKitBridgeError.staleSystemCall
            }
            try await handler.callKitStart(number: action.handle.value)
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            systemCallReported = true
            if currentState == "active" {
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
            }
            action.fulfill()
        } catch {
            if currentUUID == action.callUUID { resetCurrentCall() }
            fail(action, error: error)
        }
    }

    private func performEnd(_ action: CXEndCallAction) async {
        do {
            guard let handler else { throw CallKitBridgeError.handlerUnavailable }
            try await handler.callKitEnd()
            endActionFulfilled = true
            action.fulfill()
        } catch {
            fail(action, error: error)
        }
    }
}

extension CallKitController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioSessionIsActive = false
            await self.handler?.callKitProviderDidReset()
            self.resetCurrentCall()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in await self?.performStart(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in await self?.performAnswer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in await self?.performEnd(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else {
                action.fail()
                return
            }
            await handler.callKitSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor [weak self] in
            do {
                guard let handler = self?.handler else { throw CallKitBridgeError.handlerUnavailable }
                try await handler.callKitPlayDTMF(action.digits)
                action.fulfill()
            } catch {
                self?.fail(action, error: error)
            }
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioSessionIsActive = true
            await self.handler?.callKitAudioSessionDidActivate()
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioSessionIsActive = false
            self.handler?.callKitAudioSessionDidDeactivate()
        }
    }
}

enum CallKitBridgeError: LocalizedError {
    case noSystemCall
    case staleSystemCall
    case handlerUnavailable
    case unavailable
    case callInProgress

    var errorDescription: String? {
        switch self {
        case .noSystemCall: return "系统通话尚未建立"
        case .staleSystemCall: return "系统通话状态已刷新"
        case .handlerUnavailable: return "通话控制器尚未就绪"
        case .unavailable: return "系统 CallKit 当前不可用"
        case .callInProgress: return "当前已有进行中的系统通话"
        }
    }
}
