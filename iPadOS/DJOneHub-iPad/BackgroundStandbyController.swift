import AVFoundation
import BackgroundTasks
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
        // 进程被系统回收后只有系统能重新拉起它；这里登记后台刷新任务作为复活通道之一。
        StandbyBackgroundScheduler.register()
        return true
    }

    /// 每次进入后台都补排一次后台刷新；系统按自己的节奏唤醒，用这段时间补发遗漏的通知。
    func applicationDidEnterBackground(_ application: UIApplication) {
        StandbyBackgroundScheduler.schedule()
    }

    /// 旧版「后台刷新」唤醒回调，与 BGTask 走同一条恢复路径。
    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let model = AppModel.shared else {
                completionHandler(.noData)
                return
            }
            await model.resumeForBackgroundWake()
            completionHandler(.newData)
        }
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
    /// 显著位置变化监控是否已登记；它决定 App 被系统回收后还能不能被自动拉起。
    private var significantChangeMonitoring = false
    /// 名称访问监控（CLVisit）：系统在进程被回收后仍可因一次访问事件把它重新拉起。
    private var monitoringVisits = false
    /// 地理围栏监控：进出围栏同样能拉起已被系统回收的进程，作为第三条复活通道。
    private var monitoredRegion: CLCircularRegion?
    /// 后台唤醒去重时间戳：定位回调很密集，避免每一次回调都重建轮询。
    private var lastBackgroundWake = Date.distantPast

    /// 是否授予了「始终允许」；只有它才能让定位更新在后台持续投递。
    var hasAlwaysAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// 显著位置变化监控是否已生效：生效后即使用户杀掉后台，系统仍可能在位置显著变化时重新拉起 App。
    var supportsTerminatedRelaunch: Bool {
        hasAlwaysAuthorization && (significantChangeMonitoring || monitoringVisits || monitoredRegion != nil)
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
            // 三条「被回收后仍能拉起进程」的通道全部登记：显著位置变化、访问事件、地理围栏。
            startSignificantChangeMonitoring()
            startVisitMonitoring()
            startRegionMonitoring()
            startIfAuthorized()
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopHeartbeat()
            stopSignificantChangeMonitoring()
            stopVisitMonitoring()
            stopRegionMonitoring()
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

    /// 首次接入页展示用的定位授权状态；不触发系统弹窗。
    /// 只拿到「使用期间」时仍算未完成，因为保活必须是「始终允许」。
    var locationPermissionState: PermissionState {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            return .granted
        case .denied, .restricted:
            return .denied
        default:
            return .notDetermined
        }
    }

    /// 首次接入页的「始终允许」按钮：再申请一次；已拒绝时系统不会再弹窗。
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
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

    /// 显著位置变化监控：这是系统允许的「进程被回收后仍能被拉起」通道。
    /// 只要登记着，iOS 就会在基站 / Wi-Fi 发生显著切换时把 App 重新启动到后台，
    /// 即使它此前已经被系统回收；耗电远低于持续开启高精度定位。
    private func startSignificantChangeMonitoring() {
        guard !significantChangeMonitoring else { return }
        significantChangeMonitoring = true
        manager.startMonitoringSignificantLocationChanges()
    }

    private func stopSignificantChangeMonitoring() {
        guard significantChangeMonitoring else { return }
        significantChangeMonitoring = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// 访问监控：用户到访一处地点后系统会把进程叫醒（即使它此前已被回收）。
    private func startVisitMonitoring() {
        guard !monitoringVisits else { return }
        monitoringVisits = true
        manager.startMonitoringVisits()
    }

    private func stopVisitMonitoring() {
        guard monitoringVisits else { return }
        monitoringVisits = false
        manager.stopMonitoringVisits()
    }

    /// 地理围栏：在当前坐标附近登记一个 200m 围栏，进出事件都是系统级的复活机会。
    /// 定位权限不足时 startMonitoring 不生效，等授权回调或下一次心跳再补登记。
    private func startRegionMonitoring() {
        guard monitoredRegion == nil else { return }
        guard let location = manager.location else { return }
        let region = CLCircularRegion(
            center: location.coordinate,
            radius: 200,
            identifier: "djonehub.standby.region"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        monitoredRegion = region
        manager.startMonitoring(for: region)
    }

    private func stopRegionMonitoring() {
        guard let region = monitoredRegion else { return }
        monitoredRegion = nil
        manager.stopMonitoring(for: region)
    }

    /// 心跳把进程带到新位置后，围栏要跟着挪，否则一直等不到进出事件。
    private func refreshRegionIfNeeded() {
        guard enabled, hasAlwaysAuthorization else { return }
        guard let region = monitoredRegion, let location = manager.location else {
            startRegionMonitoring()
            return
        }
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        guard location.distance(from: center) > 100 else { return }
        manager.stopMonitoring(for: region)
        monitoredRegion = nil
        startRegionMonitoring()
    }

    /// 围栏 / 访问事件统一走后台复活路径。
    private func handleTerminatedRelaunchEvent() {
        heartbeatActive = true
        refreshRegionIfNeeded()
        guard UIApplication.shared.applicationState != .active else { return }
        appIsBackground = true
        dispatchBackgroundWake()
    }

    /// 后台被系统唤醒（定位事件 / 后台刷新任务）时，把 AppModel 拉回「正在轮询」的状态。
    /// 去重是为了让密集的定位回调不至于反复重启轮询任务。
    private func dispatchBackgroundWake() {
        guard enabled, !suspendedForCall else { return }
        guard Date().timeIntervalSince(lastBackgroundWake) > 45 else { return }
        lastBackgroundWake = Date()
        Task { @MainActor in
            await AppModel.shared?.resumeForBackgroundWake()
        }
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
                // 拿到「始终允许」后才补登记访问 / 围栏监控（这两者都要求 always 授权）。
                self.startVisitMonitoring()
                self.startRegionMonitoring()
                self.startIfAuthorized()
            } else if self.manager.authorizationStatus == .denied
                        || self.manager.authorizationStatus == .restricted {
                self.heartbeatActive = false
            }
        }
    }

    /// 回调本身就是心跳；不读取坐标、不落盘、不上传任何位置数据。
    /// App 被系统回收后再被定位事件拉起时，这里负责把它从空壳恢复成持续轮询的状态。
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.heartbeatActive = true
            // 前台也会收到显著位置变化回调，只有确认不在前台时才按「后台复活」处理。
            self.refreshRegionIfNeeded()
            guard UIApplication.shared.applicationState != .active else { return }
            self.appIsBackground = true
            self.dispatchBackgroundWake()
        }
    }

    /// 访问事件：进程被回收后系统因一次到访把它叫醒。
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor [weak self] in
            self?.handleTerminatedRelaunchEvent()
        }
    }

    /// 进入围栏：第三条复活通道。
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor [weak self] in
            self?.handleTerminatedRelaunchEvent()
        }
    }

    /// 离开围栏：顺手把围栏挪到新位置，保持后续还有事件可等。
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let monitored = self.monitoredRegion, monitored.identifier == region.identifier {
                self.manager.stopMonitoring(for: monitored)
                self.monitoredRegion = nil
            }
            self.handleTerminatedRelaunchEvent()
        }
    }

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

/// 后台刷新任务：App 被系统回收后，系统仍会按自己的节奏把进程唤醒一次。
/// 保活定位负责「持续活着」，这个任务负责「被回收后还能被叫醒」，两者互补。
enum StandbyBackgroundScheduler {
    static let refreshTaskIdentifier = "com.djonehub.standby.refresh"
    /// 后台处理任务给的时间窗比 App 刷新长得多，用来把被回收后的补发做完整。
    static let processingTaskIdentifier = "com.djonehub.standby.processing"

    private static var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    private static func isPermitted(_ identifier: String) -> Bool {
        permittedIdentifiers.contains(identifier)
    }

    /// 标识符必须先在 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 里声明，
    /// 否则 register 会抛 Objective-C 异常（Swift 捕不到）直接崩溃，所以先校验再注册。
    static func register() {
        if isPermitted(refreshTaskIdentifier) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: refreshTaskIdentifier,
                using: nil
            ) { task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                handle(refreshTask)
            }
        }
        if isPermitted(processingTaskIdentifier) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: processingTaskIdentifier,
                using: nil
            ) { task in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                handle(processingTask)
            }
        }
    }

    /// 两条通道一起排：刷新任务负责「轻量叫醒」，处理任务负责「跑完整一轮补发」。
    static func schedule() {
        scheduleRefresh()
        scheduleProcessing()
    }

    private static func scheduleRefresh() {
        guard isPermitted(refreshTaskIdentifier) else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        // earliestBeginDate 只是「不早于」，真实唤醒时机仍由系统按使用习惯决定。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleProcessing() {
        guard isPermitted(processingTaskIdentifier) else { return }
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        // 需要网络才能把积压的来电/短信补发出去；不强制外接电源，模块本身是 USB 供电。
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        // 先排下一次，保证本次即使被中断也不会丢掉后续唤醒机会。
        schedule()
        let work = Task { @MainActor in
            await AppModel.shared?.resumeForBackgroundWake()
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}

/// 借一段 beginBackgroundTask 执行时间，保证后台唤醒后能完整跑完一轮轮询与通知投递。
@MainActor
final class BackgroundExecutionLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(_ name: String) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
