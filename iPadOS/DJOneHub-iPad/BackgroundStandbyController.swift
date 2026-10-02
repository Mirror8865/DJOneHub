import AVFoundation
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// 锁屏来电通知使用的稳定标识；动作不要求设备解锁，也不会强制打开 App 界面。
enum IncomingCallNotification {
    static let categoryIdentifier = "DJONEHUB_INCOMING_CALL"
    static let answerActionIdentifier = "DJONEHUB_ANSWER_CALL"
    static let rejectActionIdentifier = "DJONEHUB_REJECT_CALL"
    static let callIDKey = "call_id"

    static func registerCategory() {
        let answer = UNNotificationAction(
            identifier: answerActionIdentifier,
            title: "接听",
            options: []
        )
        let reject = UNNotificationAction(
            identifier: rejectActionIdentifier,
            title: "拒绝",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [answer, reject],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// 接收锁屏通知动作，并在系统授予的后台执行时间内直接控制模块通话。
final class DJOneHubNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        IncomingCallNotification.registerCategory()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        guard actionIdentifier == IncomingCallNotification.answerActionIdentifier
                || actionIdentifier == IncomingCallNotification.rejectActionIdentifier,
              let callID = response.notification.request.content.userInfo[
                  IncomingCallNotification.callIDKey
              ] as? String else {
            completionHandler()
            return
        }

        Task { @MainActor in
            defer {
                center.removeDeliveredNotifications(
                    withIdentifiers: [response.notification.request.identifier]
                )
                completionHandler()
            }
            do {
                let api = DJOneHubAPI()
                let status = try await api.callStatus()
                // 必须匹配仍在振铃的同一通电话，防止用户点击过期通知误操作新通话。
                guard status.active?.id == callID,
                      status.active?.direction == "incoming",
                      let state = status.active?.state,
                      ["incoming", "waiting"].contains(state) else { return }

                if actionIdentifier == IncomingCallNotification.answerActionIdentifier {
                    try await api.answerCall()
                } else {
                    _ = try await api.rejectCall()
                }
            } catch {
                Self.reportActionFailure(error)
            }
        }
    }

    private static func reportActionFailure(_ error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "DJOneHub 操作失败"
        content.body = error.localizedDescription
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "djonehub.call-action-failed.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }
}

/// 保活控制器：用「始终允许」的后台定位更新让 iOS 在熄屏与后台继续调度本进程，
/// 从而持续轮询模块的来电与短信。刻意不使用静音音频后台播放：
/// 既不需要长期占用音频硬件，也不会与通话的 voiceChat 会话争抢输出节点。
///
/// 定位精度降到公里级、只当作「进程存活心跳」使用：不读取坐标、不上传、不落盘，
/// 借的是系统对定位类 App 的后台调度能力，而不是位置本身。
@MainActor
final class BackgroundStandbyController: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var enabled = false
    private var appIsBackground = false
    private var suspendedForCall = false
    private var heartbeatActive = false
    private var restartTask: Task<Void, Never>?

    /// 是否授予了「始终允许」；只有它才能让定位更新在后台持续投递。
    var hasAlwaysAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// 保活是否真正在运行，设置页用它给出可读状态，避免用户以为开关无效。
    var statusText: String {
        guard enabled else { return "已关闭" }
        if suspendedForCall { return "通话中已暂停" }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if !appIsBackground { return "已就绪，进入后台后自动保活" }
            return heartbeatActive ? "保活运行中" : "正在启动"
        case .authorizedWhenInUse:
            return "需要在“设置 › 隐私与安全性 › 定位”里改为“始终允许”"
        case .notDetermined:
            return "等待定位授权"
        case .denied, .restricted:
            return "定位权限被拒绝，保活无法生效"
        @unknown default:
            return "状态未知"
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        // 公里级精度 + 不过滤距离：即使原地不动也能持续收到回调，作为进程存活心跳。
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        // 只有 Info.plist 声明了 location 后台能力，系统才允许后台持续投递定位更新。
        // 缺失时直接开启会抛异常，因此这里按实际声明决定，保证 App 永不因保活崩溃。
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        manager.allowsBackgroundLocationUpdates = backgroundModes?.contains("location") ?? false
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            // 权限弹窗必须在前台出现，用户才能看到并授权；随后由进入后台触发心跳。
            requestAuthorizationIfNeeded()
            startIfAuthorized()
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopHeartbeat()
        }
    }

    func setApplicationIsBackground(_ isBackground: Bool) {
        appIsBackground = isBackground
        // 前台由模块轮询本身维持进程；只有进入后台才需要定位心跳兜底，避免无谓耗电。
        if isBackground {
            startIfAuthorized()
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopHeartbeat()
        }
    }

    /// 回到前台、被系统中断或通话结束后重新确认定位心跳仍在运行。
    func ensureRunning() {
        guard enabled, !suspendedForCall else { return }
        startIfAuthorized()
    }

    /// 通话期间由后台音频模式维持进程，定位心跳可以停掉省电。
    func suspendForCall() {
        suspendedForCall = true
        stopHeartbeat()
    }

    func resumeAfterCall() {
        suspendedForCall = false
        ensureRunning()
    }

    private func startIfAuthorized() {
        guard enabled, appIsBackground, !suspendedForCall else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            guard !heartbeatActive else { return }
            heartbeatActive = true
            manager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined:
            requestAuthorizationIfNeeded()
        case .denied, .restricted:
            heartbeatActive = false
        @unknown default:
            heartbeatActive = false
        }
    }

    /// 只有「始终允许」才能让定位更新穿透到后台；权限不足时补一次系统申请。
    private func requestAuthorizationIfNeeded() {
        let status = manager.authorizationStatus
        guard status == .notDetermined || status == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    private func stopHeartbeat() {
        heartbeatActive = false
        manager.stopUpdatingLocation()
    }

    private func scheduleRestart() {
        guard restartTask == nil, enabled, !suspendedForCall else { return }
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.restartTask = nil
            self?.startIfAuthorized()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.manager.authorizationStatus == .authorizedAlways {
                self.heartbeatActive = false
                self.startIfAuthorized()
            } else if self.manager.authorizationStatus == .denied
                        || self.manager.authorizationStatus == .restricted {
                self.heartbeatActive = false
            }
        }
    }

    /// 回调本身就是心跳；不读取坐标、不落盘、不上传任何位置数据。
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.heartbeatActive = false
            self.scheduleRestart()
        }
    }
}

/// App 在后台检测到模块新短信后发送本地通知；不依赖 APNs 或远程服务器。
/// 与来电通知共用同一套通知授权，样式贴近 iMessage：标题显示联系人，正文显示短信内容。
@MainActor
final class SMSNotifier {
    func post(message: SMSMessage, displayName: String) {
        let sender = message.sender.isEmpty ? "未知号码" : message.sender
        let name = displayName.isEmpty ? sender : displayName
        let content = UNMutableNotificationContent()
        content.title = name
        if name != sender { content.subtitle = sender }
        content.body = message.content
        content.sound = .default
        // 同一联系人按会话线程聚合，锁屏上相同发件人的通知会折叠成一组。
        content.threadIdentifier = "djonehub.sms.\(sender)"
        let request = UNNotificationRequest(
            // 标识符不能包含短信 ID 中的控制字符，改用哈希加随机串保证唯一。
            identifier: "djonehub.sms.\(abs(message.id.hashValue)).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// App 在后台检测到模块来电后发送本地通知；不依赖 APNs 或远程服务器。
@MainActor
final class IncomingCallNotifier {
    private var notifiedCallIDs: [String] = []

    func requestAuthorization() {
        IncomingCallNotification.registerCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(call: CallRecord?, callerName: String?, appIsActive: Bool) {
        guard !appIsActive,
              let call,
              call.direction == "incoming",
              ["incoming", "waiting"].contains(call.state),
              !notifiedCallIDs.contains(call.id) else { return }

        notifiedCallIDs.append(call.id)
        if notifiedCallIDs.count > 32 { notifiedCallIDs.removeFirst() }

        let content = UNMutableNotificationContent()
        let number = call.number?.isEmpty == false ? call.number! : "未知号码"
        let displayName = callerName?.isEmpty == false ? callerName! : number
        content.title = "DJOneHub 来电"
        // 同时保留姓名和号码，用户可以在锁屏直接确认来电者。
        content.body = displayName == number ? number : "\(displayName) · \(number)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = IncomingCallNotification.categoryIdentifier
        content.userInfo = [IncomingCallNotification.callIDKey: call.id]
        let request = UNNotificationRequest(
            identifier: "djonehub.incoming.\(call.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
