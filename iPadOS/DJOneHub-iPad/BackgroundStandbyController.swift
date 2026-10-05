import AVFoundation
import BackgroundTasks
import Foundation
import MediaPlayer
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

/// 保活控制器：只用「静音音频后台播放」把进程留在运行态。
///
/// 音频保活的做法：在**前台**启动一段全零音频循环播放，锁屏 / 切后台后系统因为
/// App 仍持有音频会话而不挂起进程，来电与短信轮询照常运行、通知即时弹出。
/// 这段音频用可混音（`.mixWithOthers`）会话播放，只叠加不抢占；不提供媒体信息、
/// 不注册媒体控件，所以锁屏与控制中心不会出现播放卡片。
///
/// 已整体移除定位保活：不再申请定位权限、不再创建 `CLLocationManager`、
/// 不再登记显著位置变化 / 访问 / 围栏，Info.plist 里的定位用途串与后台 location
/// 能力也已删除，状态栏不会出现任何定位指示。进程被系统回收后只由后台刷新任务
/// （`StandbyBackgroundScheduler`）负责把它叫回来补发通知。
@MainActor
final class BackgroundStandbyController: NSObject {
    private var enabled = false
    private var appIsBackground = false
    private var suspendedForCall = false
    private var restartTask: Task<Void, Never>?
    /// 保活看门狗任务（见 `startWatchdog()`）。
    private var watchdogTask: Task<Void, Never>?

    /// 静音音频是唯一的保活通道：它负责「进程持续存活」；
    /// 后台刷新任务负责「被回收后重新拉起」。
    private let audioKeepAlive = StandbyAudioKeepAlive()

    /// 保活是否真正在运行，设置页用它给出可读状态，避免用户以为开关无效。
    var statusText: String {
        guard enabled else { return "已关闭" }
        if suspendedForCall { return "通话中已暂停" }
        // 唯一的保活通道：静音音频是否真的在播。它断了就等于进程随时会被系统挂起。
        let audio = audioKeepAlive.isPlaying ? "静音音频保活运行中" : "静音音频未在播放"
        let wakeCount = UserDefaults.standard.integer(forKey: "djonehub.standby.wake-count")
        let wakeAge: String
        if let lastWake = UserDefaults.standard.object(
            forKey: "djonehub.standby.last-wake"
        ) as? Date {
            wakeAge = "\(max(0, Int(Date().timeIntervalSince(lastWake) / 60))) 分钟前"
        } else {
            wakeAge = "尚未"
        }
        // 后台补发的结果：「取数成功但没新短信」与「取数失败」
        // 是两回事，分开显示才能一眼看出后台通知为什么没弹。
        let sweep: String
        if let lastSweep = UserDefaults.standard.object(
            forKey: "djonehub.standby.last-sweep"
        ) as? Date {
            let result = UserDefaults.standard.string(forKey: "djonehub.standby.last-sweep-result") ?? ""
            let age = max(0, Int(Date().timeIntervalSince(lastSweep)))
            sweep = " · 后台取数 \(age) 秒前" + (result.isEmpty ? "" : "（\(result)）")
        } else {
            sweep = ""
        }
        return "\(audio) · 后台唤醒 \(wakeCount) 次（\(wakeAge)）\(sweep)"
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            startWatchdog()
            // 音频保活是唯一的保活通道：在**前台**就把会话建立好，
            // 等切后台时它已经在播，不靠后台重新协商（后台起播更容易失败）。
            audioKeepAlive.start()
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopWatchdog()
            audioKeepAlive.stop()
        }
    }

    func setApplicationIsBackground(_ isBackground: Bool) {
        appIsBackground = isBackground
        restartTask?.cancel()
        restartTask = nil
        guard enabled, !suspendedForCall else { return }
        // 进出前后台都刷新一次：后台起播失败时由看门狗与重启任务兜底。
        audioKeepAlive.refresh()
    }

    /// 回到前台、被系统中断或通话结束后重新确认静音音频仍在播放。
    func ensureRunning() {
        guard enabled, !suspendedForCall else { return }
        audioKeepAlive.resume()
    }

    /// 通话期间整条保活链路让位：静音音频把会话完整交给 CallKit。
    func suspendForCall() {
        suspendedForCall = true
        audioKeepAlive.suspend()
    }

    func resumeAfterCall() {
        suspendedForCall = false
        ensureRunning()
    }

    /// 音频会话被别的模块释放（来电铃声收尾等）后立刻重建静音音频，
    /// 不等看门狗的下一拍——那一拍之间进程可能已经被系统挂起。
    func rearmAudioKeepAlive() {
        guard enabled, !suspendedForCall else { return }
        audioKeepAlive.refresh()
    }

    /// 把「当前是否有通话占用音频」的实时判断注入静音音频保活。
    func setAudioKeepAliveCallPredicate(_ predicate: @escaping () -> Bool) {
        audioKeepAlive.isCallActive = predicate
    }

    /// 保活看门狗：每 30 秒确认一次静音音频是不是还在播。
    /// 音频断了就等于进程随时会被系统挂起，此时立刻重建播放。
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
        guard !audioKeepAlive.isPlaying else { return }
        audioKeepAlive.refresh()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard restartTask == nil, enabled, !suspendedForCall else { return }
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.restartTask = nil
            self?.audioKeepAlive.refresh()
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

/// 静音音频保活：把一段全零音频循环播放，用系统 audio 后台能力把进程留在运行态。
///
/// 它解决的是「进程持续存活」；后台刷新任务解决的是「被回收后重新拉起」：
/// 音频挡得住系统在后台挂起进程，但用户手动划掉 App 时救不回来；后台任务
/// 救得回被回收的进程，却挡不住挂起。两条腿一起走，锁屏期间的短信与来电提醒才稳。
///
/// 三个必须守住的边界：
/// 1. **锁屏与控制中心不出现播放控件**：会话声明为可混音（`.mixWithOthers`），系统就
///    不会把本 App 认成「正在播放的 App」；同时清空 `nowPlayingInfo`、把
///    `playbackState` 写成 `.stopped`，也不注册任何 `MPRemoteCommandCenter` 动作，
///    锁屏媒体卡片不会出现。
/// 2. **不打断其他视频与音乐**：可混音会话只做叠加，不抢路由、不 ducking；
///    别的 App 开始时它照样是「正在播放的 App」，我们只是安静地混在里面。
/// 3. **通话优先**：通话期间整条链路让位给 CallKit 的 `.playAndRecord`（`suspend()`），
///    通话结束、铃声收尾后由看门狗自动重建，绝不与通话抢音频会话。
@MainActor
final class StandbyAudioKeepAlive {
    /// 是否应该保持播放（保活开关打开、且当前不在通话中）。
    private var shouldRun = false
    private var player: AVAudioPlayer?
    private var watchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// 上层注入的实时状态：当前有通话或通话提示音正在占用音频会话。
    /// 有它就让位——但**不锁死**：谓词变回 false 后看门狗会自己把播放接回来，
    /// 不会出现「某次通话没收到结束通知就永久不保活」的死锁。
    var isCallActive: (() -> Bool)?

    var isPlaying: Bool { player?.isPlaying == true }

    init() {
        let session = AVAudioSession.sharedInstance()
        // 系统中断（来电、闹钟、其他 App 的不可混音会话）结束后按系统建议恢复。
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        })
        // 媒体服务被系统重置时所有音频对象都会失效，整体重建一次。
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player = nil
                self?.refresh()
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 保活开关打开：立刻起播并启动自愈看门狗。
    func start() {
        shouldRun = true
        refresh()
        startWatchdog()
    }

    /// 保活开关关闭：停播并把会话交还系统。
    func stop() {
        shouldRun = false
        stopWatchdog()
        let wasPlaying = player?.isPlaying == true
        player?.stop()
        player = nil
        guard wasPlaying else { return }
        // 会话可能已经被通话方接管（.playAndRecord），那种情况绝不能由我们关闭。
        if AVAudioSession.sharedInstance().category == .playback {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    /// 通话开始：停播但**不动会话**，把音频会话完整让给 CallKit。
    func suspend() {
        shouldRun = false
        stopWatchdog()
        player?.stop()
        player = nil
    }

    /// 通话真正结束：把会话交还媒体类别并重新起播。
    func resume() {
        shouldRun = true
        resetSessionToMediaIfNeeded()
        refresh()
        startWatchdog()
    }

    /// 幂等重建：确实没在播时才重新配置，避免打断正在播放的铃声/提示音。
    func refresh() {
        guard shouldRun else { return }
        // 通话优先：有电话或通话提示音在跑时绝不抢音频会话。
        if isCallActive?() == true { return }
        if let player, player.isPlaying { return }
        let session = AVAudioSession.sharedInstance()
        // 通话（.playAndRecord / .record）或语音模式的会话一律不碰：
        // 这时把类别改回媒体会直接打断通话，必须等 resume() 明确交还。
        if session.category == .playAndRecord || session.category == .record { return }
        if session.mode == .voiceChat || session.mode == .videoChat { return }
        do {
            // 可混音：既不影响其他 App，也不会被系统当成「正在播放的 App」。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAVData)
            player.numberOfLoops = -1   // 无限循环
            player.volume = 0           // 双保险：即使解码出残余也听不见
            player.prepareToPlay()
            guard player.play() else { throw StandbyAudioError.playbackFailed }
            self.player = player
            Self.hideNowPlaying()
        } catch {
            // 会话被别的不可混音 App 占着时激活会失败；交给看门狗下一拍重试，
            // 绝不在这里反复重试拖慢通话链路。
            self.player = nil
        }
    }

    /// 通话结束后会话常常还停在 .playAndRecord/.voiceChat，先显式交还媒体类别，
    /// 否则看门狗会被 refresh() 自己的安全检查一直挡住。
    private func resetSessionToMediaIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord
                || session.category == .record
                || session.mode == .voiceChat
                || session.mode == .videoChat else { return }
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // 系统已经把播放暂停了；保留 shouldRun，等结束后重建。
            player = nil
        case .ended:
            guard shouldRun else { return }
            refresh()
        @unknown default:
            break
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// 清掉媒体卡片：没有元数据、也没有播放状态，锁屏与控制中心就不会出现本 App。
    private static func hideNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    /// 1 秒 8 kHz 单声道 16 bit 的全零 WAV，循环播放：体积 16 KB，解码开销可忽略。
    private static let silentWAVData: Data = {
        let sampleRate = 8_000
        let channels = 1
        let bitsPerSample = 16
        let frames = sampleRate
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = frames * blockAlign
        var data = Data()
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        put("RIFF"); put(UInt32(36 + dataSize)); put("WAVE")
        put("fmt "); put(UInt32(16)); put(UInt16(1))
        put(UInt16(channels)); put(UInt32(sampleRate))
        put(UInt32(byteRate)); put(UInt16(blockAlign)); put(UInt16(bitsPerSample))
        put("data"); put(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }()
}

private enum StandbyAudioError: Error {
    case playbackFailed
}

/// 后台刷新任务：App 被系统回收后，系统仍会按自己的节奏把进程唤醒一次。
/// 静音音频负责「持续活着」，这个任务负责「被回收后还能被叫醒」，两者互补。
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
        // 唤醒次数与最近一次时间落盘：设置页把它显示出来，一眼就能区分
        // 「进程没被唤醒」与「唤醒了但取不到数据」（模块链路断了）。
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: "djonehub.standby.last-wake")
        defaults.set(
            defaults.integer(forKey: "djonehub.standby.wake-count") + 1,
            forKey: "djonehub.standby.wake-count"
        )
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
