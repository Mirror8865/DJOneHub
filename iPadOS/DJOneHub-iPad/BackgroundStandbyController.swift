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

    /// App 在前台时系统默认不展示任何横幅；显式声明展示选项，
    /// 让前台运行期间收到的短信与未接来电也能正常提醒。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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
///
/// 状态栏「定位服务」指示（Core Location 官方文档原文）：
/// - `showsBackgroundLocationIndicator` **只对拿到「始终允许」的 App 生效**；
///   本 App 全程设为 `false`，所以「始终允许」下状态栏干净。
/// - 只拿到「使用期间」时，系统**强制**在后台使用定位时改变状态栏外观，
///   App 无法关闭——这就是旧版本里「定位图标点亮」的真正原因。
///
/// 后台保活的依据（Core Location 官方文档 `allowsBackgroundLocationUpdates` 原文）：
/// 「当该属性为 true、且**在前台**开始定位更新时，Core Location 会把系统配置成
/// 持续保活本进程以接收后台定位更新」——这是让 iOS 不挂起本 App 的唯一办法。
/// 推论同样重要：**一条更新都不能丢**（`distanceFilter` 必须不过滤、
/// `pausesLocationUpdatesAutomatically` 必须为 false）。一旦系统停止投递，
/// 进程随即被挂起、轮询停摆，表现就是「切后台 / 锁屏收不到通知，只有重新打开
/// App 才补齐」。所以持续定位是保活的地基，任何情况下都不能被动关掉。
///
/// 关于 `CLServiceSession`：官方文档《Handling location updates in the background》
/// 把「后台持续投递」明确挂在它上面——「Create a `CLServiceSession` requiring the
/// relevant form of authorization… Create the session while your app is in the foreground.
/// If your app terminates, you must recreate the `CLServiceSession` immediately upon launch
/// in the background.」v39 为了去掉状态栏图标把它删掉了，后台投递因此失去了
/// 官方要求的授权目标声明，进程随即被系统挂起，表现就是「切后台 / 锁屏收不到通知」。
/// 现在把它和 `CLLocationUpdate.liveUpdates()` 一起恢复成主链路。
/// `CLBackgroundActivitySession` 只用于「使用期间」授权的回退路径——
/// 那种授权下它的指示由系统强制显示，App 关不掉。
/// 另有显著位置变化 / 访问事件 / 地理围栏 / 后台刷新任务四条唤醒通道兜底。
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
    /// 「使用期间」授权下的回退会话（iOS 17+）。
    /// 它自带系统指示（状态栏常驻的定位 / 导航样式图标），App 关不掉；
    /// 只有拿不到「始终允许」时才启用，因为那种授权档位下没有它系统不投递后台定位。
    private var backgroundActivitySession: Any?
    /// iOS 18+ 服务会话：向 Core Location 声明「本 App 的后台工作流需要始终允许」。
    ///
    /// 官方文档要求它**必须在前台创建**；进程被系统回收后重新拉起时要立刻重建。
    /// 它同时会在前台自动补一次「始终允许」升级申请，是拿到干净授权档位的关键。
    private var serviceSession: Any?
    /// iOS 17+ 官方连续定位流（`CLLocationUpdate.liveUpdates()`）。
    /// 每个回调都是一次进程存活心跳，与 `CLLocationManager` 的持续定位互为备份：
    /// 任一条链路被系统掐断，另一条仍能把进程留在运行态。
    private var liveUpdatesTask: Task<Void, Never>?
    /// 连续定位流当前是否处于已连接状态（用于设置页诊断文案）。
    private var liveUpdatesActive = false
    /// 连续定位流异常结束后的重连间隔，收到回调即复位。
    private var liveUpdatesRetryDelay: TimeInterval = 2
    /// 最近一次收到定位回调的时刻。定位回调本身就是进程存活心跳，
    /// 看门狗据此判断投递链路是否还活着（见 `watchdogTick()`）。
    private var lastDeliveryAt = Date.distantPast
    /// 保活看门狗任务（见 `startWatchdog()`）。
    private var watchdogTask: Task<Void, Never>?
    /// 后台唤醒去重时间戳：定位回调很密集，避免每一次回调都重建轮询。
    private var lastBackgroundWake = Date.distantPast
    /// 精度档位（设置页的「定位保活」开关）：**两档都持续投递定位**，
    /// 只切换精度——开启 = 公里级（基站 / Wi-Fi，默认），关闭 = 三公里级（更省电）。
    ///
    /// 它以前是「总开关」：关掉后完全不做持续定位，于是进程一进后台就被系统挂起、
    /// 轮询停摆——正是「保活失效、只有打开 App 才收到通知」的原因。
    /// 持续定位是保活的地基，不能再被任何开关关掉，所以降级成精度档位。
    private var locationHeartbeatEnabled = true

    /// 是否授予了「始终允许」；只有它才能让定位更新在后台持续投递。
    var hasAlwaysAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// 设置页展示用的定位授权文案。
    ///
    /// 「使用期间」下系统会**强制**显示状态栏定位图标且 App 关不掉，
    /// 所以这里把差异直接写在文案里，引导用户改成「始终允许」。
    var locationAuthorizationText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "始终允许"
        case .authorizedWhenInUse: return "使用期间（状态栏会被强制显示定位图标）"
        case .denied, .restricted: return "已拒绝"
        default: return "未授权"
        }
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
            guard heartbeatActive else { return "正在启动" }
            // 把「最近一次定位心跳」显示出来：只有它新鲜，后台保活才真的成立。
            // 「后台心跳」是后台期间收到的系统回调时间，它会一直留在这里：
            // 切后台或锁屏待一会儿再回来，若它停在你离开 App 的那一刻，说明后台
            // 投递真的断了；若它一直在往后走，保活就是活的。
            let age = max(0, Int(Date().timeIntervalSince(lastDeliveryAt)))
            let beat = lastDeliveryAt == Date.distantPast ? "等待首次定位心跳" : "定位心跳 \(age) 秒前"
            let backgroundBeat: String
            if let last = UserDefaults.standard.object(
                forKey: "djonehub.standby.last-background-beat"
            ) as? Date {
                let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
                backgroundBeat = " · 后台心跳 \(minutes) 分钟前"
            } else {
                backgroundBeat = ""
            }
            let modernChannel = liveUpdatesActive ? " · 官方定位流已连接" : " · 官方定位流重连中"
            return "保活运行中（\(beat)\(backgroundBeat)\(modernChannel) · 状态栏无指示）"
        case .authorizedWhenInUse:
            // 只拿到「使用期间」时系统会优先回收进程，保活随时可能失效，
            // 所以这里明确提示去升级授权。
            return heartbeatActive
                ? "保活运行中；「使用期间」会被系统强制显示定位图标，请改为“始终允许”"
                : "请在“设置 › 隐私与安全性 › 定位”里改为“始终允许”"
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
        // 公里级精度：走基站 / Wi-Fi 定位，基本不点亮 GPS，这是省电的那一半。
        // 但距离过滤**必须是「不过滤」**：iPad 常放在桌上不动，任何大于 0 的过滤
        // 都会让系统停止投递定位更新，进程随即被挂起、轮询停止——
        // 表现就是「切后台 / 锁屏后收不到短信与来电通知，只有重新打开 App 才补齐」。
        // 省电只能靠降精度，绝不能靠丢更新；丢更新等于丢保活。
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        // 只有 Info.plist 声明了 location 后台能力，系统才允许后台持续投递定位更新。
        // 缺失时直接开启会抛异常，因此这里按实际声明决定，保证 App 永不因保活崩溃。
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        manager.allowsBackgroundLocationUpdates = backgroundModes?.contains("location") ?? false
        // 官方文档：该属性只对「始终允许」的 App 生效，是系统用来决定
        // 「App 在后台使用定位时要不要改变状态栏外观」的唯一开关；
        // 设为 false 即「始终允许」下状态栏不出现后台定位指示。
        // 「使用期间」授权时由系统强制改变状态栏外观，App 关不掉。
        manager.showsBackgroundLocationIndicator = false
    }

    /// 「定位保活」档位：只切换精度，**不会**关掉持续定位（见 `locationHeartbeatEnabled`）。
    func setLocationHeartbeatEnabled(_ enabled: Bool) {
        locationHeartbeatEnabled = enabled
        applyAccuracy()
        startIfAuthorized()
    }

    /// 精度档位：**后台永远是公里级**——保活只发生在后台，任何省电档位都不能把
    /// 投递链路饿死（三公里级在静止时几乎不再产生回调，进程随即被系统挂起，
    /// 这就是「切后台 / 锁屏收不到通知」的一种成因）。
    /// 只有前台允许按设置降档：关闭「定位保活」= 前台用三公里级省电。
    /// 距离过滤保持「不过滤」、`pausesLocationUpdatesAutomatically` 保持 false，
    /// 保证原地不动也持续有回调可当心跳。
    private func applyAccuracy() {
        let relaxInForeground = !appIsBackground && !locationHeartbeatEnabled
        manager.desiredAccuracy = relaxInForeground
            ? kCLLocationAccuracyThreeKilometers
            : kCLLocationAccuracyKilometer
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
            startWatchdog()
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopWatchdog()
            stopHeartbeat()
            stopSignificantChangeMonitoring()
            stopVisitMonitoring()
            stopRegionMonitoring()
            stopServiceSession()
        }
    }

    func setApplicationIsBackground(_ isBackground: Bool) {
        appIsBackground = isBackground
        restartTask?.cancel()
        restartTask = nil
        applyAccuracy()
        // 进入后台**不**动定位：官方文档说明「在前台开始定位更新」时 Core Location
        // 才会把系统配置成持续保活本进程；已经在跑就让它继续跑，绝不从后台重新
        // 协商（后台重建投递链路经常协商不上，这正是 v44 之后保活后退的根因）。
        // 回到前台则相反：主动 stop + start 重新登记一次，把一份「在前台开始」的
        // 干净定位请求交给系统（前台操作安全，后台绝不做）。
        if !isBackground, !suspendedForCall, enabled {
            heartbeatActive = false
            manager.stopUpdatingLocation()
        }
        startIfAuthorized()
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
        guard enabled, !suspendedForCall else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !heartbeatActive else {
                // 已经在跑：再调一次 startUpdatingLocation() 是幂等的，但能让系统
                // 重新确认这次后台定位请求（进程被回收后又被系统拉起、或系统丢掉
                // 了旧请求时，就靠这一步把投递链路接回来）。
                manager.startUpdatingLocation()
                startModernChannelsIfNeeded()
                return
            }
            heartbeatActive = true
            applyAccuracy()
            // 「使用期间」授权必须由 App 在前台创建后台活动会话：官方文档说它是
            // when-in-use App 在后台继续收到更新的通道；「始终允许」不需要它，
            // 创建了只会点亮状态栏定位指示（而且 App 关不掉）。
            startWhenInUseBackgroundSessionIfNeeded()
            lastDeliveryAt = Date()
            manager.startUpdatingLocation()
            // iOS 17/18 起官方把「后台持续投递」挂在服务会话 + 连续定位流上：
            // 和老的 CLLocationManager 同时跑，两条链路互为备份。
            startModernChannelsIfNeeded()
        case .notDetermined:
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

    /// 只拿到「使用期间」时再补一次「始终允许」申请。
    ///
    /// 系统只允许在前台弹这层升级面板，所以每次回到前台都补申请一次；
    /// 升到「始终允许」后，后台唤醒通道与持续定位都能生效，进程最不容易被回收。
    func requestAlwaysUpgradeIfNeeded() {
        guard enabled else { return }
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    private func stopHeartbeat() {
        heartbeatActive = false
        manager.stopUpdatingLocation()
        stopBackgroundSessions()
        stopLiveUpdates()
    }

    /// 「使用期间」授权下的回退：`CLBackgroundActivitySession` 是官方文档里
    /// 给 when-in-use App 的后台投递途径（它自带一个系统指示，关不掉）。
    /// 「始终允许」时不需要它——那种授权靠 `allowsBackgroundLocationUpdates`
    /// 就已经被系统持续保活，而且状态栏干净。
    private func startWhenInUseBackgroundSessionIfNeeded() {
        guard manager.authorizationStatus == .authorizedWhenInUse else {
            stopBackgroundActivitySession()
            return
        }
        // `CLBackgroundActivitySession` 是 iOS 17 才有的类型，而本 App 最低支持 16.1，
        // 所以必须做可用性检查；16.x 上没有它，只能靠显著位置变化 / 访问 / 围栏兜底。
        if #available(iOS 17.0, *) {
            startBackgroundActivitySessionIfNeeded()
        }
    }

    @available(iOS 17.0, *)
    private func startBackgroundActivitySessionIfNeeded() {
        guard backgroundActivitySession == nil else { return }
        backgroundActivitySession = CLBackgroundActivitySession()
    }

    private func stopBackgroundActivitySession() {
        if #available(iOS 17.0, *) {
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        }
        backgroundActivitySession = nil
    }

    private func stopBackgroundSessions() {
        stopBackgroundActivitySession()
    }

    /// 现代定位链路（iOS 17+）：服务会话 + 连续定位流。
    ///
    /// 旧版只有 `CLLocationManager.startUpdatingLocation()` 一条链路，而 iOS 26 的
    /// 官方文档把「后台持续投递」明确挂在 `CLServiceSession` 与
    /// `CLLocationUpdate.liveUpdates()` 上。两条链路一起跑：
    /// 老的负责显著位置变化 / 访问事件 / 地理围栏，新的负责持续心跳与授权声明。
    private func startModernChannelsIfNeeded() {
        guard enabled, !suspendedForCall else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return
        }
        if #available(iOS 18.0, *) {
            startServiceSessionIfNeeded()
        }
        if #available(iOS 17.0, *) {
            startLiveUpdatesIfNeeded()
        }
    }

    /// 服务会话：官方文档要求「在前台创建」，进程被系统回收后重新启动时还要
    /// 「immediately upon launch in the background」立刻重建，所以两条路径都补建。
    @available(iOS 18.0, *)
    private func startServiceSessionIfNeeded() {
        guard enabled, serviceSession == nil else { return }
        let status = manager.authorizationStatus
        // 「被拒绝 / 受限」时创建会话没有意义，系统也不会再弹授权面板。
        guard status != .denied, status != .restricted else { return }
        // 未授权时系统只在前台弹面板；后台被拉起的进程跳过，等回到前台再补建。
        if status == .notDetermined, UIApplication.shared.applicationState == .background {
            return
        }
        serviceSession = CLServiceSession(authorization: .always)
    }

    private func stopServiceSession() {
        if #available(iOS 18.0, *) {
            (serviceSession as? CLServiceSession)?.invalidate()
        }
        serviceSession = nil
    }

    @available(iOS 17.0, *)
    private func startLiveUpdatesIfNeeded() {
        guard enabled, !suspendedForCall, liveUpdatesTask == nil else { return }
        liveUpdatesActive = true
        liveUpdatesTask = Task { @MainActor [weak self] in
            await self?.runLiveUpdates()
            self?.liveUpdatesTask = nil
        }
    }

    private func stopLiveUpdates() {
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveUpdatesActive = false
    }

    /// 连续定位流：正常时永不结束；被系统断开就按退避重连，
    /// 保证进程永远有一条定位请求在途，系统就不会因为「无投递需求」而挂起它。
    @available(iOS 17.0, *)
    private func runLiveUpdates() async {
        while !Task.isCancelled {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if Task.isCancelled { break }
                    liveUpdatesRetryDelay = 2
                    handleLiveUpdate(update)
                }
            } catch {
                // 授权被收回、会话缺失或系统临时拒绝投递都会走到这里，退避后重连。
            }
            liveUpdatesActive = false
            guard !Task.isCancelled, enabled, !suspendedForCall else { break }
            try? await Task.sleep(for: .seconds(liveUpdatesRetryDelay))
            liveUpdatesRetryDelay = min(30, liveUpdatesRetryDelay * 2)
        }
        liveUpdatesActive = false
    }

    /// 一次定位回调 = 一次「进程还活着」的凭证，与 `CLLocationManager` 的回调同等待遇。
    @available(iOS 17.0, *)
    private func handleLiveUpdate(_ update: CLLocationUpdate) {
        heartbeatActive = true
        lastDeliveryAt = Date()
        guard UIApplication.shared.applicationState != .active else { return }
        appIsBackground = true
        UserDefaults.standard.set(lastDeliveryAt, forKey: "djonehub.standby.last-background-beat")
        dispatchBackgroundWake()
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
        // 进程刚被系统拉起，定位更新还没恢复：
        // 这里必须真的去 startUpdatingLocation，不能只把标志位写真——
        // 否则 startIfAuthorized() 会被它自己的 guard 挡住，心跳再也点不亮。
        startIfAuthorized()
        refreshRegionIfNeeded()
        guard UIApplication.shared.applicationState != .active else { return }
        appIsBackground = true
        dispatchBackgroundWake()
    }

    /// 后台被系统唤醒（定位事件 / 后台刷新任务）时，把 AppModel 拉回「正在轮询」的状态。
    /// 去重是为了让密集的定位回调不至于反复重启轮询任务。
    /// 保活看门狗：每 30 秒确认一次投递链路是不是还活着。
    /// 定位回调本身就是心跳，所以「太久没有任何回调」等价于「保活已经断了」，
    /// 此时立刻重建一次投递链路（stop + start 幂等，误判的代价只是一次重启）。
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.watchdogTick()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func watchdogTick() {
        guard enabled, !suspendedForCall else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return
        }
        guard heartbeatActive else {
            startIfAuthorized()
            return
        }
        // 现代链路同样要自愈：进程被拉起、授权档位变化或系统掐断投递时，
        // 每 30 秒确认一次服务会话与连续定位流都还在。
        startModernChannelsIfNeeded()
        // 5 分钟没有任何定位回调：**只补一次 startUpdatingLocation()**，绝不 stop + start。
        // 从后台重新协商定位会话会被系统延迟投递甚至直接拒绝，那正是「切后台 /
        // 锁屏收不到通知」的老根因；而重复 start 是幂等的，只会让请求更稳。
        guard Date().timeIntervalSince(lastDeliveryAt) > 300 else { return }
        manager.startUpdatingLocation()
    }

    private func dispatchBackgroundWake() {
        guard enabled, !suspendedForCall else { return }
        // 去重窗口压到 15 秒：唤醒本身会立刻补一轮通知扫描，
        // 窗口越长，来电 / 短信从「模块已收到」到「锁屏弹提醒」的延迟就越大。
        guard Date().timeIntervalSince(lastBackgroundWake) > 15 else { return }
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
            switch self.manager.authorizationStatus {
            case .authorizedAlways:
                self.heartbeatActive = false
                // 拿到「始终允许」后才补登记访问 / 围栏监控（这两者都要求 always 授权）。
                self.startVisitMonitoring()
                self.startRegionMonitoring()
                self.startIfAuthorized()
            case .authorizedWhenInUse:
                // 用户刚选「使用期间」：立刻把心跳跑起来，
                // 并补上后台活动会话，先保证后台能推通知。
                self.heartbeatActive = false
                self.startIfAuthorized()
            case .denied, .restricted:
                self.heartbeatActive = false
                self.stopBackgroundSessions()
            default:
                break
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
            // 回调时间就是心跳时间：看门狗据此判断投递链路是否还活着。
            self.lastDeliveryAt = Date()
            // 前台也会收到显著位置变化回调，只有确认不在前台时才按「后台复活」处理。
            self.refreshRegionIfNeeded()
            guard UIApplication.shared.applicationState != .active else { return }
            self.appIsBackground = true
            // 后台回调的时间单独落盘：它是「后台保活到底有没有在跑」的凭据，
            // 回到前台后设置页的「保活状态」里会显示「后台心跳 N 分钟前」。
            UserDefaults.standard.set(
                self.lastDeliveryAt,
                forKey: "djonehub.standby.last-background-beat"
            )
            self.applyAccuracy()
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

/// App 检测到模块新短信后发送本地通知；不依赖 APNs 或远程服务器。
/// 与来电通知共用同一套通知授权，样式贴近 iMessage：标题显示联系人，正文显示短信内容。
@MainActor
final class SMSNotifier {
    /// 已投递过的「短信身份 → 通知标识符」。
    ///
    /// 身份直接用 `SMSMessage.id`：不同的短信身份不同，各自独立提醒，
    /// 因此不会出现「同一个人连发多条只有第一条有通知」；同一条短信被重复
    /// 投递时复用同一个 identifier 原地替换，也不会重复弹。
    ///
    /// 长短信的「先半条、后整条」已经由 `SMSDecoder.assemble` 在源头压住
    /// （段数不齐的分组不交付），所以这里不需要再按正文前缀猜分段。
    private var posted: [String: String] = [:]

    func post(message: SMSMessage, displayName: String) {
        let sender = message.sender.isEmpty ? "未知号码" : message.sender
        let name = displayName.isEmpty ? sender : displayName
        let content = UNMutableNotificationContent()
        content.title = name
        if name != sender { content.subtitle = sender }
        content.body = message.content
        content.sound = .default
        // 同一联系人按会话线程聚合，锁屏上相同发件人的通知折叠成一组，
        // 组内每一条仍然各自可见。
        content.threadIdentifier = "djonehub.sms.\(sender)"
        content.userInfo = ["djonehub_sms_id": message.id]

        let identity = message.id
        let identifier: String
        if let existing = posted[identity] {
            identifier = existing
        } else {
            identifier = "djonehub.sms.\(Self.sanitized(identity)).\(abs(identity.hashValue))"
        }
        posted[identity] = identifier
        // 只用于判断「这条短信是否已经提醒过」，不需要长期保留。
        if posted.count > 256 { posted.removeAll() }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 系统通知标识符只接受常规字符：`SMSMessage.id` 用 `\u{0}` 连接字段，
    /// 直接塞进 identifier 会被系统静默丢弃，这里统一映射掉。
    private static func sanitized(_ identity: String) -> String {
        String(identity.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

/// App 在后台检测到模块来电后发送本地通知；不依赖 APNs 或远程服务器。
@MainActor
final class IncomingCallNotifier {
    private var notifiedCallIDs: [String] = []
    /// 已经提醒过的未接来电 id；模块每轮都回传完整历史，不去重会反复弹。
    private var notifiedMissedCallIDs: [String] = []

    func requestAuthorization() {
        IncomingCallNotification.registerCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 每次回到前台补一次通知授权确认。
    ///
    /// 本地通知只在「已授权」时才会真正弹出来。若安装时那一次授权弹窗被划掉
    /// （或系统还没来得及弹），`add(request)` 会静默丢弃——表现就是
    /// 「锁屏一条提醒都没有」。这里只在 `notDetermined` 时再申请一次，
    /// 已授权 / 已拒绝都不做任何事，不会打扰用户。
    func ensureAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func update(call: CallRecord?, callerName: String?, appIsActive: Bool) {
        // 通话已经离开振铃状态（被接听或结束）时立刻收掉锁屏上那条还在响的通知，
        // 避免点进去是一通早就结束的电话。
        if let call, !["incoming", "waiting"].contains(call.state) {
            // 只收掉还在响的来电通知；未接来电通知必须留在锁屏上。
            clearRingNotification(for: call.id)
        }
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

    /// 未接来电提醒。
    ///
    /// 模块把未接来电只写成一条**历史记录**（`missed == true`、`active == nil`），
    /// 它永远不会经过 `update(call:)` 的振铃分支，所以必须单独补一条通知，
    /// 否则锁屏与通知中心里完全看不到有电话打来过。
    func postMissed(record: CallRecord, displayName: String) {
        guard !notifiedMissedCallIDs.contains(record.id) else { return }
        notifiedMissedCallIDs.append(record.id)
        if notifiedMissedCallIDs.count > 64 { notifiedMissedCallIDs.removeFirst(32) }

        let number = record.number?.isEmpty == false ? record.number! : "未知号码"
        let title = displayName.isEmpty ? number : displayName
        let content = UNMutableNotificationContent()
        content.title = "未接来电"
        content.body = title == number ? number : "\(title) · \(number)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "djonehub.missed"
        content.userInfo = [IncomingCallNotification.callIDKey: record.id]
        let request = UNNotificationRequest(
            identifier: "djonehub.missed.\(record.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 只收掉「还在振铃」的那条通知。
    ///
    /// 绝不能顺手把未接来电通知一起删：模块把一通未接电话写成一条历史记录
    /// （`missed == true`、`active == nil`），同一轮轮询里刚补过「未接来电」通知，
    /// 紧接着的「通话已结束」分支又会调用本方法。此前它连 missed 通知一起删掉，
    /// 锁屏上就永远留不下未接来电——正是「未接电话的通知无法在锁屏界面保留」的原因。
    func clearRingNotification(for callID: String) {
        clear(identifiers: ["djonehub.incoming.\(callID)"])
    }

    /// 用户已经处理过这通电话（接听 / 拒接 / 主动挂断）后，两条通知都不该再留。
    func clearNotifications(for callID: String) {
        clear(identifiers: ["djonehub.incoming.\(callID)", "djonehub.missed.\(callID)"])
    }

    private func clear(identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
        // earliestBeginDate 只是「不早于」，真实唤醒时机仍由系统按使用习惯决定；
        // 这里压到 4 分钟，让系统在愿意的时候有更早的补发机会。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleProcessing() {
        guard isPermitted(processingTaskIdentifier) else { return }
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        // 需要网络才能把积压的来电/短信补发出去；不强制外接电源，模块本身是 USB 供电。
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60)
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
