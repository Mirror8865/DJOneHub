import Foundation
import Network
import UIKit
import UserNotifications

enum ModuleUpdatePolicy {
    static func shouldInstall(installed: String, available: String) -> Bool {
        compare(installed, available) < 0
    }

    private static func compare(_ left: String, _ right: String) -> Int {
        let lhs = left.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count, 3) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

private struct EmbeddedModuleUpdateInfo: Decodable {
    let version: String
}

enum ModuleSetupStage: Equatable {
    case idle
    case connecting
    case updating
    case initializing
    case checkingAudio
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "等待接入模块"
        case .connecting: return "正在连接模块"
        case .updating: return "正在更新模块"
        case .initializing: return "正在初始化通信"
        case .checkingAudio: return "正在检查通话音频"
        case .ready: return "模块已就绪"
        case let .failed(message): return message
        }
    }
}

/// 单个系统权限在引导页可见的状态。iOS 不允许 App 直接改系统开关，
/// 所以只区分：已授权 / 被拒绝（需去系统设置）/ 还没问过。
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

/// 首次接入引导页列出的系统权限。
enum AppPermission: String, CaseIterable, Identifiable {
    case microphone
    case notifications
    case localNetwork
    case contacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return L10n.t("麦克风")
        case .notifications: return L10n.t("通知")
        case .localNetwork: return L10n.t("本地网络与设备")
        case .contacts: return L10n.t("通讯录")
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            return L10n.t("通话语音需要麦克风")
        case .notifications:
            return L10n.t("接收来电与短信提醒")
        case .localNetwork:
            return L10n.t("连接模块需要「访问设备」权限")
        case .contacts:
            return L10n.t("来电显示联系人姓名与头像")
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .notifications: return "bell.badge.fill"
        case .localNetwork: return "wifi.router.fill"
        case .contacts: return "person.crop.circle.fill"
        }
    }
}

/// 移动端 App 的主状态中心：前台轮询模块代理并驱动五个主要页面。
@MainActor
final class AppModel: ObservableObject {
    @Published var activeCall: CallRecord?
    /// 用户刚拨出、模块还没在 CLCC 里报出来的呼出通话。
    ///
    /// 模块要先执行 ATD、再把通话写进 CLCC，轮询才会返回 active，App 内通话页
    /// 因此会晚上一两拍才出现（表现为「点完拨号卡一会儿」）。这里先铺一条本机
    /// 占位记录把通话页立刻点亮，真实的模块记录一到就被替换掉。
    @Published var pendingOutgoingCall: CallRecord?
    /// 用户在本机确认挂断/拒接后立刻记录的通话 ID。
    /// 模块状态轮询通常要慢一拍，这个标记让 App 内通话页马上退出，
    /// 不再出现「电话已经挂了但界面卡在通话页」的情况。
    @Published var locallyDismissedCallID: String?
    /// 当前通话是否由系统 CallKit 界面接管；它决定静音/DTMF 走系统事务还是模块直连。
    /// 注意：CallKit 只负责锁屏与后台的系统通话界面，App 在前台仍要自己呈现通话页。
    @Published private(set) var callKitManagesCall = false
    @Published var callHistory: [CallRecord] = []
    @Published var messages: [SMSMessage] = []
    @Published var numberInput = ""
    @Published var isOnline = false
    /// 本机 USB ECM 链路状态：区分「模块网卡正常 / 有网卡但没 DHCP 租约 / 没有网卡」。
    @Published var moduleLinkState: ModuleUSBLinkState = .unknown
    /// 首次接入引导页展示的系统权限状态；回到前台时刷新。
    @Published private(set) var permissionStates: [AppPermission: PermissionState] = [:]
    /// 权限状态是否已经读过一次；引导页在读到之前不显示「申请」按钮，
    /// 避免用户点了一个其实已经授权的项却看不到任何反应。
    @Published private(set) var permissionStatesLoaded = false
    @Published var connectionMessage: String?
    /// 用户此刻打开的短信会话；前台时用来跳过它自己的通知横幅。
    @Published var openConversationHandle: String?
    @Published var isBusy = false
    @Published var isMuted = false
    @Published var isSpeakerEnabled = false
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var setupStage: ModuleSetupStage = .idle
    @Published private(set) var preparingModule = false
    @Published private(set) var modemStatus: ModemStatus?
    @Published private(set) var agentVersion: String?
    @Published private(set) var systemPower: SystemPowerStatus?

    let api: DJOneHubAPI
    let contacts = ContactStore()
    let audio = AudioSessionController()
    let callKit = CallKitController()
    let backgroundStandby = BackgroundStandbyController()
    let incomingNotifier = IncomingCallNotifier()
    let smsNotifier = SMSNotifier()
    let liveActivity = LiveActivityController()

    /// 语音桥登记状态：模块侧取消登记会回滚 USB 音频路由（audio_enable=0）。
    /// 挂断时重复发送取消登记只会让 USB 音频功能反复启停，这里对 false 去重；
    /// true 始终重发，避免模块重启后漏登记。
    private var audioHostRegistered = false

    /// 保活唤醒期间借用的执行时间租约（见 BackgroundExecutionLease）。
    private let backgroundWakeLease = BackgroundExecutionLease()
    /// 系统可能在 SwiftUI 场景之外把 App 拉起（后台任务），
    /// 需要一条静态引用让 AppDelegate 与保活控制器找回主状态中心。
    /// App 全程只有一个 AppModel（在 App.init 里创建），因此这里持有强引用不会造成泄漏，
    /// 反而能保证保活控制器不会因为主状态中心被释放而失联。
    static var shared: AppModel?

    private let historyStore = LocalHistoryStore()

    private var pollingTask: Task<Void, Never>?
    private var callEventTask: Task<Void, Never>?
    private var moduleUpdateTask: Task<Void, Never>?
    private var moduleMetadataTask: Task<Void, Never>?
    /// USB ECM 掉租约后的自动恢复看护；只在本机链路状态不是 ready 时存在。
    private var moduleLinkRecoveryTask: Task<Void, Never>?
    private var moduleLinkRecoveryGeneration = 0
    private var nextModuleUpdateAttempt = Date.distantPast
    private var startingCallAudio = false
    private var appIsActive = true
    private var pollingGeneration = 0
    private var hasStarted = false
    private var consecutivePollFailures = 0
    private var nextMessagesRefresh = Date.distantPast
    /// 最近一次短信刷新是否失败。只用于设置页的保活状态文案：
    /// 「扫了但没有新短信」与「链路/模块取数失败」是两回事，必须能一眼分开。
    private var lastMessageRefreshFailed = false
    /// 短信刷新任务：PDU 读取要跑好几条 AT 指令，不能占着 1 秒一次的通话轮询。
    private var messagesRefreshTask: Task<Void, Never>?
    /// 短信读取串行闸门：PDU 读取要在同一个 AT 口上连发多条指令，
    /// 前台轮询、后台唤醒补扫、用户手动刷新可能同时打进来，必须串行化。
    private var messagesRefreshInFlight = false
    private var nextAudioDiagnosticRefresh = Date.distantPast
    private var nextModuleMetadataRefresh = Date.distantPast
    private var audioWarmupCallID: String?
    /// 语音桥起不来之后的退避：连续失败次数与下一次允许重建通话音频的时间。
    private var voiceAudioFailureCount = 0
    private var voiceAudioRetryNotBefore = Date.distantPast
    private var lowPowerModeEnabled = true
    private lazy var embeddedAgentVersion: String = {
        guard let url = Bundle.main.url(forResource: "EmbeddedModuleUpdate", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(EmbeddedModuleUpdateInfo.self, from: data) else {
            return "0.3.7"
        }
        return info.version
    }()
    private let backgroundStandbyKey = "djonehub.background-standby-enabled"
    private let lowPowerModeKey = "djonehub.low-power-mode-enabled"
    private let liveActivityKey = "djonehub.live-activity-enabled"
    private let smsNotificationKey = "djonehub.sms-notifications-enabled"
    /// 旧版本把模块文本模式的每条分段记录都写进本机历史；PDU 拼接上线后只清理一次。
    private let legacyFragmentPurgeKey = "djonehub.sms-pdu-purge-v1"
    private let maxCallHistoryCount = 500
    private let maxMessageCount = 2_000
    /// 已见过的呼入短信 ID 集合；后台刷新时只对集合外的新短信发通知，避免重复提醒。
    ///
    /// 去重键必须是**单条短信自己的身份**（`SMSMessage.id`）。曾经用过
    /// 「发件人 + 正文长度 + 正文前 12 字」这种粗粒度键：同一个服务号发来的
    /// 两条同模板短信（验证码就是最典型的例子）算出的键完全相同，第二条会被
    /// 判成「已经提醒过」而静默丢掉——锁屏收到验证码却一条提醒都没有。
    /// `SMSMessage.id` 逐条不同，而 PDU 拼接与文本模式拼接给同一条短信算出的是
    /// 同一个 id，所以既能分清两条不同的短信，也不会把一条长短信提醒两遍。
    private var seenIncomingSMSIDs: Set<String> = []
    /// 上面那个集合的落盘副本：进程被系统回收后在后台重启时内存集合是空的，
    /// 没有这份基线就会把模块缓存里还在的短信全部重弹一遍。
    private let seenIncomingSMSIDsKey = "djonehub.seen-incoming-sms-ids"
    /// 基线上限。必须大于本机历史条数（`maxMessageCount`），否则每次前台回来
    /// 重建基线都可能把集合清空一次，反而造成整屏重弹。
    private let maxSeenIncomingSMSIDs = 2_500

    /// 已经提醒过的未接来电 id：模块每轮都回传完整历史，不去重会反复弹。
    private var notifiedMissedCallIDs: Set<String> = []
    /// 用户在本机接听 / 拒接 / 挂断过的通话 id。
    /// 模块对所有「未接通就结束的来电」都记 `missed`，包括用户主动拒接的那通；
    /// 用它把用户自己处理过的通话从「未接来电」提醒里排除掉。
    private var handledCallIDs: Set<String> = []
    /// 用户主动拒接的来电 id（含在锁屏通知上直接拒接的）。
    ///
    /// 模块把「没接通就结束的来电」一律写成未接来电，没有字段能区分「对方没等到
    /// 我接」和「我明确拒接」。拒绝是一次明确的用户动作，本机据此把它按「已拒绝」
    /// 呈现，并排除在未接来电筛选与未接提醒之外。落盘保存，重启后仍然生效。
    private var declinedCallIDs: Set<String> = []
    private let declinedCallIDsKey = "djonehub.declined-call-ids"
    /// 用户在本机删除的通话记录 / 短信 ID。
    /// 模块接口每轮都会回传完整历史，不做墓碑过滤的话，用户刚删掉的记录下一轮就会复活。
    private var deletedCallIDs: Set<String> = []
    private var deletedMessageIDs: Set<String> = []
    private let deletedCallIDsKey = "djonehub.deleted-call-ids"
    private let deletedMessageIDsKey = "djonehub.deleted-message-ids"
    /// 墓碑集合上限，避免长期使用后 UserDefaults 无限增长。
    private let maxDeletedIDCount = 3_000

    init(api: DJOneHubAPI = DJOneHubAPI()) {
        self.api = api
        deletedCallIDs = Set(UserDefaults.standard.stringArray(forKey: deletedCallIDsKey) ?? [])
        deletedMessageIDs = Set(UserDefaults.standard.stringArray(forKey: deletedMessageIDsKey) ?? [])
        seenIncomingSMSIDs = Set(UserDefaults.standard.stringArray(forKey: seenIncomingSMSIDsKey) ?? [])
        declinedCallIDs = Set(UserDefaults.standard.stringArray(forKey: declinedCallIDsKey) ?? [])
        AppModel.shared = self
        callKit.handler = self
        // 背景启动时 SwiftUI 不会走 onAppear，这里延后一拍自行恢复轮询与保活。
        // 前台启动有 onAppear 接管，且 applicationState 不会是 background，因此不会重复启动。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            guard UIApplication.shared.applicationState == .background else { return }
            await self.resumeForBackgroundWake()
        }
        // 音频路由可能由 CallKit、蓝牙或系统控制中心改变，通话页按钮必须即时反映真实状态。
        audio.onSpeakerStateChanged = { [weak self] enabled in
            self?.isSpeakerEnabled = enabled
        }
        // 铃声播完、通话结束这类「本类主动交还会话」的时刻，立刻把静音音频保活接回来：
        // 等看门狗下一拍（12 秒）之间进程就可能被系统挂起，那正是保活失效的成因。
        audio.onSessionReleased = { [weak self] in
            self?.backgroundStandby.rearmAudioKeepAlive()
        }
        // 模块语音桥彻底连不上时收起本地通话音频：一通已经听不到声音的通话
        // 不能让麦克风、扬声器和语音处理单元一直空转（通话相关耗电里唯一会
        // 无限持续的一项）。通话状态本身不动，轮询看到模块仍报 active 会再拉起。
        audio.onTransportFailed = { [weak self] in
            Task { @MainActor [weak self] in self?.handleVoiceTransportFailure() }
        }
        // 通话优先：有电话（含响铃）或通话提示音时，静音音频保活一律让位。
        // 这是实时判断而非一次性开关，所以通话结束后它会自动恢复播放。
        backgroundStandby.setAudioKeepAliveCallPredicate { [weak self] in
            guard let self else { return true }
            if self.audio.callTonePlaying { return true }
            guard let call = self.activeCall else { return false }
            return ["dialing", "alerting", "incoming", "waiting", "active"].contains(call.state)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // 诊断器只监听系统网络路径并写入本地沙盒，不改变路由、DNS 或模块配置。
        Task { await NetworkDiagnosticRecorder.shared.start() }
        incomingNotifier.requestAuthorization()
        Task { await refreshPermissionStates() }
        let storedValue = UserDefaults.standard.object(forKey: backgroundStandbyKey) as? Bool
        let storedLowPowerValue = UserDefaults.standard.object(forKey: lowPowerModeKey) as? Bool
        let storedLiveActivityValue = UserDefaults.standard.object(forKey: liveActivityKey) as? Bool
        lowPowerModeEnabled = storedLowPowerValue ?? true
        liveActivity.setEnabled(storedLiveActivityValue ?? true)
        backgroundStandby.setEnabled(storedValue ?? true)
        // 先加载手机副本，再启动轮询，避免模块暂时离线时界面显示为空。
        restoreLocalHistory()
        captureSMSSnapshot()
        // 本机已有的未接来电不再补提醒，只提醒本次运行期间新产生的。
        notifiedMissedCallIDs.formUnion(callHistory.lazy.filter(\.missed).map(\.id))
        startCallEventBridgeIfNeeded()
        restartPolling()
    }

    /// 每次从锁屏或后台回来都舍弃旧连接，避免休眠前的超时结果覆盖新状态。
    func didBecomeActive() {
        appIsActive = true
        Task { await NetworkDiagnosticRecorder.shared.recordLifecycle("active") }
        consecutivePollFailures = 0
        backgroundStandby.setApplicationIsBackground(false)
        guard hasStarted else {
            start()
            return
        }
        // 手机重启后 App 可能先在受保护数据尚不可读时被后台唤醒。
        // 每次解锁回到前台重新合并磁盘副本，不能让首次空读取一直占据界面。
        restoreLocalHistory()
        // 回到前台把当前已知短信并入通知基线：用户正在看 App，不需要再为旧短信弹通知。
        captureSMSSnapshot()
        // 用户可能在系统设置里改过权限，回到前台重读一次。
        Task { await refreshPermissionStates() }
        // 通知权限只在首次申请；被划掉过就永远收不到提醒，回前台补一次。
        incomingNotifier.ensureAuthorization()
        // 系统「联系人 / 电话」里换过的头像要立刻同步进 App（详情页背景铺的就是它）：
        // 每次回到前台重读一次通讯录；未授权时直接跳过，不弹任何错误。
        if contacts.isAuthorized {
            Task { await contacts.requestAccessAndLoad() }
        }
        // 休眠期间 USB ECM 可能重枚举。先取消旧请求并清空接口缓存，再创建全新的轮询与事件连接。
        api.resetLocalConnectionState()
        restartCallEventBridge()
        restartPolling()
    }

    func didEnterBackground() {
        appIsActive = false
        Task { await NetworkDiagnosticRecorder.shared.recordLifecycle("background") }
        backgroundStandby.setApplicationIsBackground(true)
        // 进程一旦被系统回收，只有系统调度能重新拉起它；这里补排一次后台刷新任务。
        StandbyBackgroundScheduler.schedule()
    }

    /// 立刻重新读取一次本机 USB 链路状态；不发起 HTTP 请求，供设置页与轮询复用。
    /// 只在状态真正变化时写入 @Published，避免每秒刷新界面。
    func refreshModuleLinkState() {
        let link = api.moduleLinkState()
        if link != moduleLinkState { moduleLinkState = link }
        updateModuleLinkRecovery(for: link)
    }

    /// 模块网卡掉到 169.254.x（DHCP 租约丢了）之后，iOS 不会自己重跑 DHCP，
    /// 只有重新插拔 USB 或重启设备才会恢复。这里起一个低开销看护：持续对那块
    /// USB ECM 网卡制造真实需求并重建路径监控，尽力促使系统重新续租；一旦恢复立刻停。
    private func updateModuleLinkRecovery(for link: ModuleUSBLinkState) {
        guard !link.isReady else {
            stopModuleLinkRecovery()
            return
        }
        switch link {
        case .leaseMissing:
            startModuleLinkRecovery()
        case .missing:
            // 从未连上过模块时不要空转：只有「之前连上过、现在整块网卡都不见了」才值得尝试。
            if ModuleUSBInterfaceResolver.rememberedModuleInterfaceName() != nil {
                startModuleLinkRecovery()
            } else {
                stopModuleLinkRecovery()
            }
        case .ready, .unknown:
            break
        }
    }

    private func startModuleLinkRecovery() {
        guard moduleLinkRecoveryTask == nil else { return }
        moduleLinkRecoveryGeneration &+= 1
        let generation = moduleLinkRecoveryGeneration
        moduleLinkRecoveryTask = Task { [weak self] in
            // 有界重试：每次轮询失败都会重新触发，所以一轮跑空不会让恢复能力丢掉。
            for _ in 0..<150 {
                guard !Task.isCancelled else { break }
                guard let self else { return }
                // 丢掉缓存的 NWInterface 与路径监控，下一次解析从全新的 NWPathMonitor 开始。
                self.api.resetLocalConnectionState()
                await ModuleUSBInterfaceResolver.demandModuleInterface()
                guard !Task.isCancelled, generation == self.moduleLinkRecoveryGeneration else { return }
                let link = self.api.moduleLinkState()
                if self.moduleLinkState != link { self.moduleLinkState = link }
                if link.isReady { break }
                // 重建 NWPathMonitor 与触发 DHCP 都用 4 秒的稀疏节奏：够快恢复，
                // 又不会让 USB / 网络栈一直处于高频唤醒状态。
                try? await Task.sleep(for: .seconds(4))
            }
            self?.stopModuleLinkRecovery()
        }
    }

    private func stopModuleLinkRecovery() {
        moduleLinkRecoveryTask?.cancel()
        moduleLinkRecoveryTask = nil
    }

    // MARK: - 系统权限（首次接入引导页）

    func permissionState(for permission: AppPermission) -> PermissionState {
        permissionStates[permission] ?? .notDetermined
    }

    /// 只读状态，不会触发任何系统弹窗。
    func refreshPermissionStates() async {
        var states: [AppPermission: PermissionState] = [:]
        states[.microphone] = audio.microphonePermissionState
        states[.contacts] = contacts.permissionState
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            states[.notifications] = .granted
        case .denied:
            states[.notifications] = .denied
        default:
            states[.notifications] = .notDetermined
        }
        // iOS 没有公开的本地网络授权查询 API；模块一旦连上就说明系统已放行。
        states[.localNetwork] = (isOnline || moduleLinkState.isReady) ? .granted : .notDetermined
        if states != permissionStates { permissionStates = states }
        permissionStatesLoaded = true
    }

    /// 再申请一次指定权限；已被永久拒绝时系统不会再弹窗，UI 会引导用户去系统设置。
    @discardableResult
    func requestPermission(_ permission: AppPermission) async -> Bool {
        switch permission {
        case .microphone:
            _ = await audio.requestMicrophonePermission()
        case .notifications:
            IncomingCallNotification.registerCategory()
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        case .contacts:
            await contacts.requestAccessAndLoad()
        case .localNetwork:
            await probeLocalNetworkAccess()
        }
        await refreshPermissionStates()
        return permissionState(for: permission) == .granted
    }

    /// 首次安装打开 App 就把权限流程走完：按引导页列表的顺序逐个申请，
    /// 已授权的跳过；被永久拒绝的系统不会再弹窗，引导页会引导去系统设置。
    ///
    /// 系统同一时刻只允许在窗口上呈现一个授权面板。麦克风 / 通知的申请会一直
    /// 挂起到用户做出选择，但本地网络（Bonjour 探测）是「发起即返回」，只等
    /// 几百毫秒就轮到下一项——上一层面板还开着时提出的申请会被系统直接丢弃，
    /// 连面板都不弹。通讯录排在列表最后，
    /// 正是「首次进入时联系人权限不会自动弹出、必须手动去授权」的原因。
    func requestAllMissingPermissions() async {
        for permission in AppPermission.allCases where permissionState(for: permission) == .notDetermined {
            _ = await requestPermission(permission)
            await waitUntilPreviousPromptClears(permission)
        }
        // 兜底：即使前面的面板收得慢导致这次申请被系统丢掉，也保证通讯录面板弹出来。
        await requestContactsPermissionIfNeeded()
    }

    /// 等到上一条系统面板收起再申请下一项，避免申请被系统丢弃。
    ///
    /// 状态可查询的权限（麦克风 / 通知 / 通讯录）等到状态不再是「未决定」为止；
    /// 本地网络根本没有公开的查询 API，只能等一段固定时长，再留一点余量让系统
    /// 把窗口让出来。
    private func waitUntilPreviousPromptClears(_ permission: AppPermission) async {
        let isQueryable = permission != .localNetwork
        for _ in 0..<(isQueryable ? 40 : 8) {
            if isQueryable {
                await refreshPermissionStates()
                if permissionState(for: permission) != .notDetermined { break }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// 确保通讯录授权面板被真正弹出来。
    ///
    /// 启动时的系统面板（麦克风 / 通知）都不会带上通讯录，以前只有引导页的
    /// 「全部申请」按钮会申请它，所以首次进入 App 时联系人权限不会自动弹出，用户
    /// 必须手动去授权一次。首次接入流程现在直接调用这里补上这一项：申请后轮询到
    /// 用户真正做出选择为止；若面板被系统丢弃（上一层面板还没收起），稍后重试，
    /// 最多三次。
    @discardableResult
    func requestContactsPermissionIfNeeded() async -> Bool {
        guard permissionState(for: .contacts) == .notDetermined else { return false }
        for _ in 0..<3 {
            _ = await requestPermission(.contacts)
            for _ in 0..<25 {
                await refreshPermissionStates()
                if permissionState(for: .contacts) != .notDetermined { return true }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return false
    }

    /// 本地网络没有授权查询 API：起一次 Bonjour 浏览让系统弹一次授权，
    /// 之后再按「模块能否连上」反推是否已放行。
    private func probeLocalNetworkAccess() async {
        let browser = NWBrowser(
            for: .bonjour(type: "_djonehub._tcp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: DispatchQueue.global(qos: .utility))
        try? await Task.sleep(for: .seconds(1.5))
        browser.cancel()
    }

    /// 被系统在后台唤醒（显著位置变化 / 后台刷新任务）时恢复保活与轮询。
    /// 即使进程此前已被系统回收，这条路径也会重新建立轮询并补发遗漏的来电与短信通知。
    func resumeForBackgroundWake() async {
        appIsActive = false
        backgroundStandby.setApplicationIsBackground(true)
        backgroundStandby.ensureRunning()
        if !hasStarted {
            start()
        } else {
            let hadFailures = consecutivePollFailures > 0
            consecutivePollFailures = 0
            // 只在**确实取数失败过**的时候丢掉缓存的 USB 网卡对象。后台里
            // NWPathMonitor 不一定来得及送出新的路径，一旦把已经解析好的接口丢掉，
            // 后续请求会一直落在「按接口类型」的兜底路径上，后台取数全部落空——
            // 表现就是「进程活着，但通知一直不弹」。
            // 定时无条件重建（旧行为）正是把后台保活拖垮的那一半。
            if hadFailures {
                api.resetLocalConnectionState()
            }
            // 链路没就绪时顺手把恢复流程拉起来（续租 DHCP + 重新解析网卡），
            // 否则要等用户回到前台才会重新拿到 192.168.225.x。
            refreshModuleLinkState()
            restartCallEventBridge()
            restartPolling()
        }
        // 后台唤醒给的时间窗很短，先借一段执行时间，再跑通知补发。
        backgroundWakeLease.begin("djonehub.standby")
        // 唤醒后立刻补一轮通知扫描：不等轮询的下一拍（后台为了省电是 4 秒以上），
        // 读完短信与通话历史马上投递。BGAppRefresh / 后台处理任务 / 地理围栏 /
        // 显著位置变化这几种唤醒都只有几十秒窗口，必须先把提醒发出去。
        await performBackgroundNotificationSweep()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.backgroundWakeLease.end()
        }
    }

    /// 一次后台唤醒：一个短信请求 + 一个通话状态请求，然后把还欠着的提醒发出去。
    ///
    /// 短信走模块侧一次读完的 PDU 列表（`/api/sms/refresh`）：整段 AT 序列在模块的
    /// 同一个临界区里跑完，App 只花一个往返，后台那几十秒窗口里最容易成事；
    /// 拼好的完整短信走的还是前台同一套通知逻辑。旧版把这几条指令拆成好几次
    /// `/api/at`，被模块 8 秒文本模式轮询插队后经常整段失败，提醒就一直拖到
    /// 用户打开 App 才补上——「进程活着、心跳在走，但锁屏不弹通知」正是这么来的。
    func performBackgroundNotificationSweep() async {
        guard hasStarted else { return }
        // `refreshMessages` 返回它真正投递了几条提醒；失败原因记在
        // lastMessageRefreshFailed，设置页据此把「扫了但没有新短信」与
        // 「链路/模块取数失败」分开显示。
        var posted = await refreshMessages(silently: true)
        var suffix = lastMessageRefreshFailed ? " \u{00B7} \u{53D6}\u{6570}\u{5931}\u{8D25}" : ""
        // 第二通道：PDU 一条新短信都没取到时，再读一次模块的文本模式缓存。
        // 两条通道读的是同一个基带存储，但解码路径不同；只要任何一条看到了
        // 新短信，锁屏提醒就不能漏——后台唤醒只有几十秒窗口，漏一次就要等
        // 用户打开 App 才补上，那正是「锁屏收不到通知」的最终表现。
        // 只有后台补发走这里：前台每 4~6 秒刷一次，多花一个请求不值得。
        if posted == 0 {
            if let cached = await postNotificationsFromModuleCache() {
                posted = cached
            } else {
                suffix += " \u{00B7} \u{7F13}\u{5B58}\u{53D6}\u{6570}\u{5931}\u{8D25}"
            }
        }
        // 未接来电只出现在通话历史里（missed == true、active == nil），
        // 不会走 activeCall 那条路，所以这里补一次通话历史。
        if let status = try? await api.callStatus() {
            let history = await mergeCallHistory(status.history ?? [])
            if callHistory != history { callHistory = history }
            notifyMissedCalls(in: history)
        } else {
            suffix += " \u{00B7} \u{6765}\u{7535}\u{53D6}\u{6570}\u{5931}\u{8D25}"
        }
        let summary = posted > 0
            ? "\u{65B0}\u{77ED}\u{4FE1} \(posted)" + suffix
            : "\u{5DF2}\u{626B}\u{63CF}\u{00B7}\u{65E0}\u{65B0}\u{77ED}\u{4FE1}" + suffix
        recordBackgroundSweep(summary)
    }

    /// 后台补发的第二通道：模块文本模式列表（`/api/sms`）。
    ///
    /// PDU 通道没取到新短信时再确认一次。返回投递的提醒条数；读取失败返回 nil，
    /// 设置页据此把「两条通道都读了、确实没有新短信」与「缓存通道取数失败」分开。
    private func postNotificationsFromModuleCache() async -> Int? {
        guard let remoteMessages = try? await api.messages() else { return nil }
        let mergedMessages = mergeDisplayOnly(remoteMessages)
        if messages != mergedMessages { messages = mergedMessages }
        return handleIncomingSMSNotifications(mergedMessages)
    }

    /// Store what the last background sweep managed to do. The settings status line shows
    /// it, which tells "fetched, nothing new" apart from "fetch failed".
    private func recordBackgroundSweep(_ summary: String) {
        UserDefaults.standard.set(Date(), forKey: "djonehub.standby.last-sweep")
        UserDefaults.standard.set(summary, forKey: "djonehub.standby.last-sweep-result")
    }

    func setBackgroundStandbyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundStandbyKey)
        backgroundStandby.setEnabled(enabled)
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowPowerModeKey)
        lowPowerModeEnabled = enabled
        // 立即重建轮询任务，让用户切换后无需等待旧睡眠周期结束。
        if hasStarted { restartPolling() }
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: liveActivityKey)
        liveActivity.setEnabled(enabled)
    }

    func setSMSNotificationsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: smsNotificationKey)
    }

    private func restartPolling() {
        pollingGeneration &+= 1
        let generation = pollingGeneration
        pollingTask?.cancel()
        // 重新开始轮询（含从后台回到前台）时立刻补一次短信同步与一次模块全量扫描，
        // 不让用户回到 App 还要等上一轮的间隔走完才看到新短信。
        nextMessagesRefresh = .distantPast
        // 这里**不能**取消正在跑的短信刷新。后台唤醒会频繁重建轮询，
        // 取消一次半途的 PDU 读取会让它退回模块的文本模式缓存（UDH 被基带丢掉），
        // 一条长短信立刻被拆成多条、内容顺序也乱——那正是长短信反复裂开的放大器。
        // `refreshMessages` 自己有 in-flight 闸门：上一轮没跑完时新的一轮直接返回，
        // 不需要外部取消，也绝不该打断一次「模块正在逐条吐出分段」的读取。
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(generation: generation)
                guard let delay = self?.nextPollingDelay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        // 这里以前会顺带探测模块是否还停在 Mac 组合，从而自动请求切回手机直连。
        // 那次请求会重写模块 USB gadget（enable=0 → 改 functions → enable=1）并重启
        // 模块，iPad 侧 en3 随即掉租约退回 169.254.x，而且只有拔插 / 重启设备才能恢复。
        // 宁可让用户手动在「设置 › 模块设置 › 连接」里切一次，也不能让 App 自动改 gadget。
        refreshModuleLinkState()
    }

    /// 模块在线时与其 1 秒 AT 轮询对齐；离线后退避，避免断开模块时持续唤醒手机和 USB 栈。
    ///
    /// 省电原则：`/api/calls/status` 每次都要走一趟 USB ECM 与模块 HTTP 服务，
    /// 虽然不唤醒基带，但会唤醒模块 CPU、USB 控制器和 iPad 的网络栈。空闲期没有
    /// 任何时间敏感的事要做——来电由长轮询事件桥在状态变化时立刻推回 CallKit，
    /// 通话中（`activeCall != nil`）仍然保持 1 秒，所以空闲期可以显著放慢。
    private var nextPollingDelay: TimeInterval {
        if consecutivePollFailures > 0 {
            return min(3, pow(2, Double(consecutivePollFailures - 1)))
        }
        // 后台空闲：5 秒一拍（系统省电模式 8 秒）。漏接来电最多晚 5 秒出现在通话
        // 历史里；来电本身仍由事件桥即时唤醒系统通话界面。
        if !appIsActive, activeCall == nil {
            return lowPowerModeEnabled ? 8 : 5
        }
        // 前台空闲：3 秒一拍（省电模式 5 秒）。用户盯着界面时保持响应感。
        if activeCall == nil {
            return lowPowerModeEnabled ? 5 : 3
        }
        return 1
    }

    func stop() {
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        messagesRefreshTask?.cancel()
        messagesRefreshTask = nil
        callEventTask?.cancel()
        callEventTask = nil
        moduleUpdateTask?.cancel()
        moduleUpdateTask = nil
        moduleMetadataTask?.cancel()
        moduleMetadataTask = nil
        stopModuleLinkRecovery()
        audio.deactivate()
        backgroundStandby.setEnabled(false)
        Task { await liveActivity.stop() }
        Task { await self.registerAudioHost(false) }
    }

    /// 事件桥与 AppModel 同生命周期，前后台切换不重复创建长请求。
    /// 连接失败时指数退避，模块旧版本仍由现有轮询完整兜底。
    private func startCallEventBridgeIfNeeded() {
        guard callEventTask == nil else { return }
        callEventTask = Task { [weak self] in
            var revision: UInt64?
            var retryDelay: TimeInterval = 0.25
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let event = try await self.api.waitForCallEvent(after: revision)
                    guard !Task.isCancelled else { return }
                    revision = event.revision
                    retryDelay = 0.25
                    self.handleCallEvent(event)
                } catch {
                    guard !Task.isCancelled else { return }
#if DEBUG
                    print("[DJOneHub CallEvent] 事件桥暂时不可用：\(error.localizedDescription)")
#endif
                    try? await Task.sleep(for: .seconds(retryDelay))
                    retryDelay = min(retryDelay * 2, 15)
                }
            }
        }
    }

    /// 回到前台时必须重建长轮询；休眠前的阻塞请求不能继续代表当前 USB 路径。
    private func restartCallEventBridge() {
        callEventTask?.cancel()
        callEventTask = nil
        startCallEventBridgeIfNeeded()
    }

    /// 只在事件桥中处理对时延敏感的呼入上报，完整状态仍以轮询结果为权威数据。
    private func handleCallEvent(_ event: CallEventEnvelope) {
        guard let call = event.active,
              call.direction == "incoming",
              ["incoming", "waiting"].contains(call.state) else { return }
        let callerName = contacts.displayName(for: call.number)
        callKit.synchronize(call: call, previous: activeCall, callerName: callerName)
        if callKitManagesCall != callKit.managesCurrentCall {
            callKitManagesCall = callKit.managesCurrentCall
        }
        if callKit.suppressesInAppIncomingRingtone {
            audio.stopCallTone()
        }
        if audioWarmupCallID != call.id {
            audioWarmupCallID = call.id
            // 来电事件到达后立即预热，不再等待下一次状态轮询。
            Task { [weak self] in try? await self?.api.warmAudioHost() }
        }
    }

    private func poll(generation: Int) async {
        do {
            let status = try await api.callStatus()
            guard !Task.isCancelled, generation == pollingGeneration else { return }
            let previousCall = activeCall
            let history = await mergeCallHistory(status.history ?? [])
            if activeCall != status.active {
                activeCall = status.active
                // 模块确认通话已经换了一通（或已结束）后，清掉本机提前退出的标记。
                if status.active?.id != locallyDismissedCallID {
                    locallyDismissedCallID = nil
                }
            }
            if let pending = pendingOutgoingCall,
               status.active != nil || Date().timeIntervalSince(pending.startedAt) > 15 {
                // 模块已经报出这通通话，或者迟迟没报出来（ATD 被模块吞掉）：撤掉占位，
                // 界面不能一直停在「正在呼叫」。
                pendingOutgoingCall = nil
            }
            if callHistory != history { callHistory = history }
            notifyMissedCalls(in: history)
            consecutivePollFailures = 0

            if let call = status.active,
               ["dialing", "alerting", "incoming", "waiting"].contains(call.state),
               audioWarmupCallID != call.id {
                audioWarmupCallID = call.id
                // 预热只加载驱动和校准，把最慢的冷启动提前到接通之前。
                Task { [weak self] in
                    try? await self?.api.warmAudioHost()
                }
            } else if status.active == nil, previousCall != nil {
                audioWarmupCallID = nil
            }
            // HTTP 已成功返回就说明 USB 模块代理在线。last_poll_error 只是模块内部 AT+CLCC
            // 的最近轮询结果，通话建立期间可能短暂非空，不能据此把整条 USB 链路判为离线。
            if !isOnline {
                isOnline = true
                // 只在离线到在线的边沿运行一次公网探测，避免跟随每秒轮询增加流量与耗电。
                Task { await NetworkDiagnosticRecorder.shared.recordModuleOnline() }
            }
            if connectionMessage != nil { connectionMessage = nil }
            refreshModuleLinkState()
            scheduleModuleMetadataRefresh(generation: generation)
            let callerName = status.active.map { contacts.displayName(for: $0.number) }
            let confirmedEndedCall = previousCall.flatMap { previous in
                status.history?.first { $0.id == previous.id && $0.endedAt != nil }
            }
            // 必须先请求 CallKit，再决定是否发送本地通知。否则后台来电会同时出现
            // 系统通话界面和一条带接听按钮的通知；CallKit 上报失败时下一轮再自动降级。
            callKit.synchronize(
                call: status.active,
                previous: confirmedEndedCall ?? previousCall,
                callerName: callerName
            )
            // 系统通话界面接管后立即收起 App 内通话页，避免同时出现两套通话 UI。
            if callKitManagesCall != callKit.managesCurrentCall {
                callKitManagesCall = callKit.managesCurrentCall
            }
            await liveActivity.update(
                call: status.active,
                callerName: callerName,
                moduleOnline: true,
                radio: modemStatus,
                appIsActive: appIsActive
            )
            // CallKit 成功后由系统负责锁屏来电界面；仅在 CallKit 不可用或上报失败时发普通通知兜底。
            if !callKit.suppressesInAppIncomingRingtone {
                incomingNotifier.update(
                    call: status.active,
                    callerName: callerName,
                    appIsActive: appIsActive
                )
            }
            if status.active?.direction == "incoming", callKit.suppressesInAppIncomingRingtone {
                // CallKit 已负责系统铃声，不能再叠加应用内铃声。
                audio.stopCallTone()
            } else {
                audio.updateCallTone(for: status.active)
            }

            // 已完成首次向导的旧用户也要获得模块更新；仅在无通话时后台检查，避免中断基带媒体。
            if status.active == nil {
                scheduleAutomaticModuleUpdate()
            }

            // 接通期间持续确认本地音频仍在工作。CallKit 或系统音频服务重置后，
            // 即使模块状态没有发生变化，下一轮也必须能够重建网络 PCM。
            if status.active?.state == "active" {
                await startCallAudioIfReady()
            } else if status.active == nil, let finishedCall = previousCall {
                // 电话已经结束（含响铃结束变成未接来电）：先收掉锁屏上那条还在响的通知。
                // 只收掉振铃通知；若这通已经变成未接来电，那条提醒要留在锁屏上。
                incomingNotifier.clearRingNotification(for: finishedCall.id)
                audio.deactivate()
                await registerAudioHost(false)
                guard !Task.isCancelled, generation == pollingGeneration else { return }
                // 模块侧挂断后 1.5 秒会回滚语音路由并短暂改写 audio_enable，USB gadget 可能瞬时重枚举。
                // 立刻丢掉缓存网卡并重读链路，让 iOS 更快重新评估这块 ECM 网卡、尽快续租。
                api.resetLocalConnectionState()
                refreshModuleLinkState()
                voiceAudioFailureCount = 0
                voiceAudioRetryNotBefore = .distantPast
                backgroundStandby.resumeAfterCall()
                isMuted = false
                isSpeakerEnabled = false
                isRecording = false
            }
            if status.active?.state == "active",
               settingsTabIsVisible,
               Date() >= nextAudioDiagnosticRefresh,
               let audioConfig = try? await api.audioHostConfig() {
                // 语音桥诊断只有设置页会读；通话中不再每 3 秒为一个没人显示的
                // 字符串多做一次 USB / TCP 建连与 JSON 解码。
                nextAudioDiagnosticRefresh = Date().addingTimeInterval(3)
                audio.updateModuleDiagnostics(audioConfig)
            }
        } catch {
            guard !Task.isCancelled, generation == pollingGeneration else { return }
#if DEBUG
            print("[DJOneHub Poll] module status failed: \(error.localizedDescription)")
#endif
            consecutivePollFailures += 1
            // USB ECM 枚举、模块更新或 AT 忙时，单次 TCP 超时并不代表模块已经离线。
            // 连续三次失败后才改变用户可见状态，避免通话前后的状态灯频繁闪烁。
            if consecutivePollFailures >= 3 {
                if isOnline {
                    isOnline = false
                    Task {
                        await NetworkDiagnosticRecorder.shared.recordModuleOffline(
                            error: error.localizedDescription
                        )
                    }
                }
                audio.stopCallTone()
                await liveActivity.markOffline(appIsActive: appIsActive)
                // 连续失败说明链路或模块代理已经变了：丢掉缓存的 USB
                // 网卡与路径监控，让下一次轮询从全新的 NWPathMonitor 重新解析，
                // 避免旧接口对象把 App 永久钉在离线状态（旧行为要重启设备才恢复）。
                // 只在失败连击的起点重建一次解析器；之后每次失败只重读链
                // 路状态（getifaddrs，几乎零成本），避免反复重建 NWPathMonitor。
                if consecutivePollFailures == 3 { api.resetLocalConnectionState() }
                refreshModuleLinkState()
                // 链路连续不可达且通话仍挂在本机账本上：先收起本地通话音频，
                // 别让麦克风 / 扬声器在一条已经断掉的链路上无限空转。
                if consecutivePollFailures >= 6,
                   ["active", "held"].contains(activeCall?.state ?? "") {
                    handleVoiceTransportFailure()
                }
                // 后台轮询失败只更新离线状态；否则用户关闭弹窗后一秒又会被同一错误轰炸。
                connectionMessage = moduleLinkState.pollFailureDescription
            }
        }

        if Date() >= nextMessagesRefresh {
            // 短信改走 PDU 读取（AT+CMGF=0 + AT+CMGL=4），一次要跑好几条 AT 指令，
            // 比原来只读模块缓存 JSON 慢，所以前台 3 秒、后台 8 秒一次。
            // 读取放在独立任务里异步跑：同一个 AT 端口还承担 1 秒一次的通话轮询，
            // 同步等待会把来电检测拖慢，甚至错过 CallKit 上报窗口。
            let active = appIsActive
            // 后台也要及时收短信，但整段 PDU 读取是模块侧最重的周期性 AT 工作
            // （切模式 + 选存储区 + 整存储区 CMGL），所以前台 5 秒、后台 8 秒。
            // 后台另有 15 秒一次的唤醒补扫兜底，锁屏提醒不会因此漏掉；
            // PDU 读取仍走串行闸门，不会和通话轮询抢 AT 口。
            nextMessagesRefresh = Date().addingTimeInterval(active ? 5 : 8)
            if messagesRefreshTask == nil {
                messagesRefreshTask = Task { [weak self] in
                    await self?.refreshMessages(silently: true)
                    self?.messagesRefreshTask = nil
                }
            }
        }
    }

    /// 设置 tab 是否当前可见。顶层 tab 的选择写在 UserDefaults 里，
    /// 这里直接读它，不需要额外的状态同步链路。
    private var settingsTabIsVisible: Bool {
        (UserDefaults.standard.string(forKey: "djonehub.selected-tab") ?? PhoneTab.calls.rawValue)
            == PhoneTab.settings.rawValue
    }

    /// 周期性模块元数据（信号 / 版本 / sysfs 功率）是否有可能被看到。
    /// iPad 上实时活动是空操作，用户又没停在设置页时，这一整套请求不会改变任何界面。
    private var periodicMetadataIsObservable: Bool {
        if settingsTabIsVisible { return true }
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        return UserDefaults.standard.object(forKey: liveActivityKey) as? Bool ?? true
    }

    /// 蜂窝状态和版本不必跟随每秒通话轮询；独立刷新避免慢 AT 状态接口拖住来电检测。
    private func scheduleModuleMetadataRefresh(generation: Int) {
        // 没人能看到这些数据时干脆不排期：不然每 15 / 60 秒都会唤醒一次模块 CPU
        // 去跑 AT 与整棵 sysfs 读取，换来的只是几个没人显示的 @Published 赋值。
        // 不写 nextModuleMetadataRefresh，用户切到设置页后下一拍立刻就会补上。
        guard periodicMetadataIsObservable else { return }
        guard moduleMetadataTask == nil, Date() >= nextModuleMetadataRefresh else { return }
        // 这一路要读蜂窝状态、版本和整块 sysfs 功率/温度（模块侧最重的周期性 IO）。
        // 它只在设置页被看到，放慢到 30/120 秒对界面没有可感知影响，
        // 却能把模块被唤醒读写 sysfs 的次数再降一半。
        nextModuleMetadataRefresh = Date().addingTimeInterval(appIsActive ? 30 : 120)
        moduleMetadataTask = Task { [weak self] in
            await self?.refreshModuleMetadata(generation: generation)
        }
    }

    private func refreshModuleMetadata(generation: Int) async {
        defer { moduleMetadataTask = nil }
        async let radioRequest = try? api.modemStatus()
        async let versionRequest = try? api.moduleUpdateStatus()
        let (radio, versionStatus) = await (radioRequest, versionRequest)
        guard !Task.isCancelled, generation == pollingGeneration, isOnline else { return }
        if let radio { modemStatus = radio }
        if let version = versionStatus?.installedVersion, !version.isEmpty {
            agentVersion = version
        }
        // 功率 / 温度要扫整棵 sysfs（几十个传感器与电源节点），是这一路里最重的
        // 只读 IO；它只在设置页可见，离开设置页就不再让模块为此被唤醒。
        if settingsTabIsVisible, let power = try? await api.systemPower() {
            systemPower = power
        }
        await liveActivity.update(
            call: activeCall,
            callerName: activeCall.map { contacts.displayName(for: $0.number) },
            moduleOnline: true,
            radio: modemStatus,
            appIsActive: appIsActive
        )
    }

    /// 登记模块语音桥。
    ///
    /// 只发「登记」，绝不再发「注销」：模块 Agent 自己在通话结束时
    /// （检测到 `calls.Active == nil` 后 1.5 秒）就会回滚 UAC 路由。
    /// 手机再补发一次注销，只会让模块把 `/sys/class/android_usb/f_audio/audio_enable`
    /// 写成 0 两次；而这次写入会把 USB gadget 整体 deactivate，iPad 侧 en3 随之
    /// 重新枚举、丢掉 DHCP 租约退回 169.254.x——正是「用一会儿就断连、非要重启
    /// 设备才能恢复」的根因之一。所以注销只更新本地标记，不产生任何模块写入。
    private func registerAudioHost(_ enabled: Bool) async {
        guard enabled else {
            audioHostRegistered = false
            return
        }
        audioHostRegistered = true
        try? await api.setAudioHostEnabled(true)
    }

    func dial() async {
        let number = Self.validatedNumber(numberInput)
        guard !number.isEmpty else { return }
        debugDialLog("呼出提交系统 CallKit")
        await perform {
            self.resetControlsForNewCall()
            self.audio.stopCallTone()
            do {
                // 与来电保持一致统一走系统 CallKit：锁屏、后台、小窗都由系统通话界面承载，
                // App 内不再维护第二套拨号界面。
                try await self.callKit.startOutgoingCall(number: number)
                self.debugDialLog("CallKit 已接管呼出")
            } catch CallKitBridgeError.unavailable {
                // 个人侧载或受限设备没有 CallKit 权限时回退模块 ATD，保证仍然拨得出去。
                self.debugDialLog("CallKit 不可用，回退模块直接拨号")
                try await self.api.dial(number: number)
            } catch {
                // 系统事务失败同样不能吞掉用户的拨号动作：清掉残留的系统通话后立即回退模块 ATD，
                // 保证「点拨号一定有反应」，而不是界面闪一下什么都没发生。
                self.debugDialLog("CallKit 事务失败，回退模块直接拨号：\(error.localizedDescription)")
                self.callKit.abandonSystemCall()
                try await self.api.dial(number: number)
            }
            // 仅当模块已确认接收拨号请求后清空，失败时保留号码供用户重试或修改。
            self.numberInput = ""
            self.callKitManagesCall = self.callKit.managesCurrentCall
            // 模块要先执行 ATD、再把这通电话写进 CLCC，轮询才看得到；先铺一条本机
            // 占位记录，用户点完拨号立刻就能进通话页，而不是干等一两拍轮询。
            self.pendingOutgoingCall = Self.pendingOutgoingCallRecord(number: number)
        }
    }

    /// 呼出占位通话：只用于立刻点亮 App 内通话页，模块的真实记录一到就被替换。
    private static func pendingOutgoingCallRecord(number: String) -> CallRecord {
        let now = Date()
        return CallRecord(
            id: "local-outgoing-\(Int(now.timeIntervalSince1970 * 1_000))",
            index: 0,
            direction: "outgoing",
            state: "dialing",
            number: number,
            startedAt: now,
            updatedAt: now,
            endedAt: nil,
            missed: false
        )
    }

    func answer() async {
        audio.stopCallTone()
        markCallHandled(activeCall?.id)
        if callKit.managesCurrentCall {
            await perform {
                do {
                    try await self.callKit.answerCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    // 系统界面重建期间仍可直接接通模块端来电，避免按钮失效。
                    try await self.api.answerCall()
                }
            }
        } else {
            await perform { try await api.answerCall() }
        }
    }

    func reject() async {
        audio.stopCallTone()
        let dismissedID = activeCall?.id
        markCallHandled(dismissedID)
        markCallDeclined(dismissedID)
        // 呼出还没被模块报出来时界面上是本机占位通话：先撤掉它，界面立刻回到拨号盘。
        if dismissedID == nil { pendingOutgoingCall = nil }
        // 拒接同样是关键操作，理由与挂断一致。
        isBusy = true
        defer { isBusy = false }
        do {
            if callKit.managesCurrentCall {
                do {
                    try await callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    _ = try await api.rejectCall()
                }
            } else {
                _ = try await api.rejectCall()
            }
            locallyDismissedCallID = dismissedID
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hangup() async {
        audio.stopCallTone()
        let dismissedID = activeCall?.id
        markCallHandled(dismissedID)
        // 呼出还没被模块报出来时界面上是本机占位通话：先撤掉它，界面立刻回到拨号盘。
        if dismissedID == nil { pendingOutgoingCall = nil }
        // 挂断是关键操作，不能受 isBusy 早退影响：否则界面点了没反应，
        // 模块侧却已经挂断，就出现「电话挂了但界面停在通话页」。
        isBusy = true
        defer { isBusy = false }
        do {
            if callKit.managesCurrentCall {
                do {
                    try await callKit.endCurrentCall()
                } catch CallKitBridgeError.staleSystemCall {
                    try await api.hangupCall()
                }
            } else {
                try await api.hangupCall()
            }
            locallyDismissedCallID = dismissedID
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func sendDTMF(_ digit: String) async {
        await perform {
            if self.callKit.managesCurrentCall {
                do {
                    // App 内键盘与系统通话页共用 CallKit 事务，避免两边的 DTMF 顺序不一致。
                    try await self.callKit.playDTMF(digit)
                } catch CallKitBridgeError.staleSystemCall {
                    // 系统通话 UUID 刚被重建时，模块通话仍然有效；直接降级发送一次按键。
                    try await self.api.sendDTMF(digit)
                }
            } else {
                try await self.api.sendDTMF(digit)
            }
        }
    }

    /// 首次接入或用户点“重新检测”时串行完成版本、AT、语音和 USB 模式自检。
    func prepareModuleForFirstConnection() async {
        guard !preparingModule else { return }
        preparingModule = true
        defer { preparingModule = false }
        do {
            setupStage = .connecting
            let updateStatus = try await api.moduleUpdateStatus()
            agentVersion = updateStatus.installedVersion
            if updateStatus.supported,
               ModuleUpdatePolicy.shouldInstall(
                   installed: updateStatus.installedVersion ?? "0.0.0",
                   available: embeddedAgentVersion
               ),
               let packageURL = Bundle.main.url(forResource: "module-update", withExtension: "djupdate") {
                setupStage = .updating
                _ = try await api.uploadModuleUpdate(from: packageURL)
                try await waitForModuleAgent()
            }

            setupStage = .initializing
            let setup = try await api.moduleSetupStatus()
            if setup.canInitialize { _ = try await api.initializeModule() }

            setupStage = .checkingAudio
            let voice = try await api.voiceRuntimeStatus()
            guard voice.ready else {
                throw ModuleSetupError.notReady(voice.runtimeDetail ?? "模块语音运行时未就绪")
            }
            guard await audio.requestMicrophonePermission() else {
                throw ModuleSetupError.notReady("请允许 DJOneHub 使用麦克风后重试")
            }
            // 这里以前会自动读一次 usb profile，并在「看起来是 Mac 组合」时 POST 切回手机直连。
            // 模块侧的 `POST /api/usb/profile` 在手机直连 Agent 下会执行 activateMobileGadget()：
            // 先写 gadget/enable=0，再重写 functions，最后 enable=1——整条 USB gadget 重新枚举，
            // iPad 侧 en3 立刻掉 DHCP 租约退回 169.254.x，而且只有拔插 / 重启设备才能恢复。
            // 连接模式只用于展示；真正需要切回手机直连时，必须由用户在
            // 「设置 › 模块设置 › 连接」里显式点按，App 任何路径都不再自动改 gadget。
            setupStage = .ready
            // 这里绝不能写 `djonehub.first-connection-complete`：RootView 的 fullScreenCover
            // 观察的就是这个键，模块一就绪就会把引导页强制关掉，用户还没授权系统权限
            // 就被送进主界面，之后也再没有入口弹权限面板。首次页何时结束只由用户在
            // 页内点「完成 / 稍后」决定，这里只记录「模块侧已经准备好」。
            UserDefaults.standard.set(true, forKey: "djonehub.module-setup-ready")
        } catch {
            setupStage = .failed(error.localizedDescription)
        }
    }

    func resetModuleSetup() {
        setupStage = .idle
        UserDefaults.standard.set(false, forKey: "djonehub.first-connection-complete")
    }

    private func waitForModuleAgent() async throws {
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            // 代理能响应即表示 USB 控制链路已经恢复；AT 子系统的瞬时错误不应阻塞接入向导。
            if (try? await api.callStatus()) != nil { return }
        }
        throw ModuleSetupError.timeout
    }

    private func scheduleAutomaticModuleUpdate() {
        guard moduleUpdateTask == nil, Date() >= nextModuleUpdateAttempt else { return }
        moduleUpdateTask = Task { [weak self] in
            await self?.installAutomaticModuleUpdateIfNeeded()
        }
    }

    private func installAutomaticModuleUpdateIfNeeded() async {
        defer { moduleUpdateTask = nil }
        do {
            let status = try await api.moduleUpdateStatus()
            agentVersion = status.installedVersion
            guard status.supported,
                  ModuleUpdatePolicy.shouldInstall(
                      installed: status.installedVersion ?? "0.0.0",
                      available: embeddedAgentVersion
                  ) else {
                // 当前 App 生命周期内无需重复请求版本接口。
                nextModuleUpdateAttempt = .distantFuture
                return
            }
            guard let packageURL = Bundle.main.url(
                forResource: "module-update",
                withExtension: "djupdate"
            ) else {
                nextModuleUpdateAttempt = Date().addingTimeInterval(30)
                return
            }
            _ = try await api.uploadModuleUpdate(from: packageURL)
            try await waitForModuleAgent()
            nextModuleUpdateAttempt = .distantFuture
        } catch is CancellationError {
            return
        } catch {
            // 模块重启或 USB 网络尚未稳定时退避重试，不用后台错误弹窗打断用户。
            nextModuleUpdateAttempt = Date().addingTimeInterval(30)
        }
    }

    func toggleMute() async {
        let target = !isMuted
        if callKit.managesCurrentCall {
            do {
                try await callKit.setMuted(target)
                errorMessage = nil
            } catch {
                // CallKit UUID 可能因系统重置而短暂失效；本地 PCM 仍可可靠控制麦克风。
                if case CallKitBridgeError.staleSystemCall = error {
                    isMuted = target
                    audio.setMuted(target)
                    errorMessage = nil
                } else {
                    errorMessage = "系统静音切换失败：\(error.localizedDescription)"
                }
            }
            return
        }
        // 移动端上行语音由本地 PCM 管线产生，必须先本地静音，不能依赖模块 AT 命令成功。
        isMuted = target
        audio.setMuted(target)
        // QDC507 部分固件不实现 AT+CMUT；本地 PCM 已经是移动端的权威静音状态，
        // 后台同步失败不能阻断通话或弹出误导性的“麦克风已静音”错误。
        Task { try? await api.setAudioMuted(target) }
        errorMessage = nil
    }

    func toggleSpeaker() {
        let target = !isSpeakerEnabled
        do {
            // 扬声器切换只作用于当前系统音频会话，不需要向模块发送控制命令。
            try audio.setSpeakerEnabled(target)
            // 以 AVAudioSession 实际路由为准，避免系统因蓝牙/听筒抢占导致 UI 假状态。
            isSpeakerEnabled = audio.speakerEnabled
            errorMessage = nil
        } catch {
            errorMessage = "无法切换通话输出：\(error.localizedDescription)"
        }
    }

    func toggleRecording() async {
        let target = !isRecording
        do {
            let response = try await api.setCallRecording(target)
            isRecording = response.recording
            errorMessage = nil
        } catch {
            debugDialLog("操作失败：\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// 真机联调阶段输出拨号链路，不记录电话号码；Release 构建会完全移除。
    private func debugDialLog(_ message: String) {
#if DEBUG
        print("[DJOneHub Dial] \(message)")
#endif
    }

    func sendSMS(to phone: String, content: String) async -> Bool {
        let target = Self.validatedNumber(phone)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty, body.count <= 2_000 else { return false }
        do {
            let result = try await api.sendSMS(to: target, message: body)
            if result.sent {
                // 模块的短信收件箱通常不会回传已发送内容，不能等刷新接口来补这一条。
                // 先落盘再刷新，断线、重启模块或自动清理都不会让已发送短信消失。
                saveSentMessage(recipient: target, content: body)
            }
            await refreshMessages(silently: true)
            return result.sent
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 刷新短信列表。
    ///
    /// 主通道是模块侧一次读完的 PDU 列表（`/api/sms/refresh`）：只有 PDU 里的 UDH
    /// 才带长短信的参考号与段序号，能拼出顺序正确、不再分裂的完整短信；整段
    /// AT 序列由模块在同一个 AT 临界区里跑完，App 不再自己拼好几条 `/api/at` 请求
    /// ——那样会被 8 秒文本模式轮询插队，PDU 通道时通时断，长短信跟着一会儿拼好
    /// 一会儿裂开。模块的 `/api/sms` 走文本模式、UDH 已被基带丢掉，只作为链路或
    /// 模块未就绪时的兜底。
    @discardableResult
    func refreshMessages(silently: Bool = false) async -> Int {
        // 同一个 AT 口不能并发跑两轮 PDU 读取：分段会互相插队，收到一半的长短信
        // 会被当成新消息投递，正是「消息反复裂开 / 通知多条」的放大器。
        // AppModel 是 @MainActor，这个布尔闸门天然无竞争；重叠调用直接返回，
        // 由已经在跑的那一轮负责落盘与通知。
        guard !messagesRefreshInFlight else { return 0 }
        messagesRefreshInFlight = true
        defer { messagesRefreshInFlight = false }
        var fetched = await fetchIncomingMessagesViaPDU()
        if fetched == nil {
            // 单次失败多半只是 AT 口正忙（通话轮询、模块刚切模式）。
            // PDU 是唯一带 UDH 的通道，值得立刻重试一次再考虑兜底，
            // 否则一次忙就会退回会把长短信拆开的文本模式缓存。
            try? await Task.sleep(for: .milliseconds(250))
            fetched = await fetchIncomingMessagesViaPDU()
        }
        if let fetched = fetched {
            lastMessageRefreshFailed = false
            purgeLegacyModuleFragmentsIfNeeded()
            let mergedMessages = await mergeIncomingMessages(fetched.messages)
            if messages != mergedMessages { messages = mergedMessages }
            if !silently { errorMessage = nil }
            let posted = handleIncomingSMSNotifications(mergedMessages)
            await acknowledgeDeliveredRecords(consumed: fetched.consumed)
            return posted
        }
        do {
            let remoteMessages = try await api.messages()
            let mergedMessages = mergeDisplayOnly(remoteMessages)
            if messages != mergedMessages { messages = mergedMessages }
            if !silently { errorMessage = nil }
            lastMessageRefreshFailed = false
            return handleIncomingSMSNotifications(mergedMessages)
        } catch {
            lastMessageRefreshFailed = true
            if !silently { errorMessage = error.localizedDescription }
            return 0
        }
    }

    /// 让模块一次读完 SM/ME 两个存储区的 PDU 列表，再按 UDH 拼回完整短信。
    ///
    /// 返回 nil 表示 PDU 通道当前不可用（模块没就绪 / 链路断了），调用方退回文本模式缓存。
    /// 读取动作在模块侧的一个 AT 临界区里完成，App 只发一个请求：后台唤醒只有几十秒
    /// 窗口，往返越少、越不容易被系统的挂起和 AT 口竞争打断。
    private func fetchIncomingMessagesViaPDU() async -> (messages: [SMSMessage], consumed: [SMSListingEntry])? {
        let payload: SMSListingResponse
        do {
            payload = try await api.pduListing()
        } catch {
            return nil
        }
        var entries: [SMSListingEntry] = []
        for memory in payload.memories {
            guard let listing = memory.listing, memory.error == nil else { continue }
            entries += SMSDecoder.parseListing(listing, memory: memory.memory)
        }
        // 只有两个存储区都没读成功才算通道不可用。「读到了但里面确实没有短信」必须
        // 正常返回空结果，否则每一轮都会白白退回文本模式缓存，长短信在那里是碎的。
        guard payload.memories.contains(where: { $0.listing != nil }) else { return nil }
        // 只把已经收齐的短信交出去，同时只确认这些短信对应的模块槽位：
        // 还没收齐的长短信分段必须留在模块存储里，否则永远拼不完整。
        let assembly = SMSDecoder.assemble(entries)
        return (assembly.messages, assembly.consumed)
    }

    /// Merge the PDU-assembled complete SMS into local history; anything the user
    /// deleted (tombstone set) must not come back.
    private func mergeIncomingMessages(_ remote: [SMSMessage]) async -> [SMSMessage] {
        let pendingMessages = remote.filter { !deletedMessageIDs.contains($0.id) }
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for message in pendingMessages { byID[message.id] = message }
        // Records that only the text-mode fallback ever saw carry a module delivery id;
        // PDU-assembled messages do not, and their body contains the segments they were
        // joined from. Dropping those fragments here keeps one paragraph from showing up
        // twice, once as fragments and once as the joined message.
        let merged = removingSupersededFragments(
            normalizedMessages(Array(byID.values)),
            complete: pendingMessages
        )
        if !pendingMessages.isEmpty { _ = historyStore.saveMessages(merged) }
        return merged
    }

    /// Drop text-mode fragments whose body a complete message of the same sender contains.
    private func removingSupersededFragments(
        _ records: [SMSMessage],
        complete: [SMSMessage]
    ) -> [SMSMessage] {
        let completeIncoming = complete.filter { !$0.isOutgoing && $0.deliveryID == nil }
        guard !completeIncoming.isEmpty else { return records }
        return records.filter { record in
            guard !record.isOutgoing, record.deliveryID != nil else { return true }
            let text = record.content
            // Short bodies, a verification code for instance, collide too easily.
            guard text.utf16.count >= 24 else { return true }
            return !completeIncoming.contains {
                $0.sender == record.sender && $0.content.contains(text)
            }
        }
    }

    /// 本机已落盘后让模块清掉对应记录，SIM/ME 存储区不会被历史短信塞满。
    ///
    /// 只删这一轮真正拼成完整短信的那些槽位：分段还没收齐的长短信，它已经占住的
    /// 槽位不属于任何已交付消息，删掉就等于把先到的段扔掉，剩下几段永远拼不起来
    /// ——那正是「一条长短信裂成两个半截气泡」的来源。PDU 拼出来的完整短信没有
    /// 交付 ID，所以这里直接按「存储区 + 槽位」删，不再走 /api/sms/ack。
    private func acknowledgeDeliveredRecords(consumed: [SMSListingEntry]) async {
        guard !consumed.isEmpty else { return }
        do {
            try await api.deleteSMSRecords(consumed)
        } catch {
            // 删除失败只影响模块存储占用，不影响本机历史；下一轮还会再确认一次。
        }
    }

    /// 一次性清理旧版本留下的文本模式碎片。
    ///
    /// 旧版本把模块文本模式返回的每条分段记录都当成一条短信写进了本机历史，
    /// 升级到 PDU 拼接后这些碎片会和新拼好的完整短信同时出现在聊天窗口里。
    /// 只删「带模块交付 ID 的来信」：PDU 解出的短信没有交付 ID，不会被误伤。
    private func purgeLegacyModuleFragmentsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: legacyFragmentPurgeKey) else { return }
        UserDefaults.standard.set(true, forKey: legacyFragmentPurgeKey)
        let legacy = messages.filter { !$0.isOutgoing && $0.deliveryID != nil }
        guard !legacy.isEmpty else { return }
        messages = messages.filter { $0.isOutgoing || $0.deliveryID == nil }
        _ = historyStore.saveMessages(messages)
    }

    /// Record every SMS already known as the baseline for background reminders, so the
    /// user is never notified about a message that is already on screen.
    private func captureSMSSnapshot() {
        let incoming = receivedMessages(from: messages)
        // The baseline must use the same keys as the notifier, otherwise every segment of
        // one long SMS would count as a separate message and be announced again.
        rememberNotifiedSMS(incoming)
    }

    /// 收到的短信（不含本机发出的）。
    ///
    /// PDU 通道已经在 `SMSDecoder` 里按 UDH 把长短信拼成一条，这里不再做任何
    /// 「按长度猜分段」的二次合并——旧启发式正是长短信在刷新之间反复裂开又合上的原因。
    private func receivedMessages(from records: [SMSMessage]) -> [SMSMessage] {
        records.filter { !$0.isOutgoing }
    }

    /// Foreground merges new SMS into the seen set; an unseen incoming SMS is announced
    /// with a local notification first and marked afterwards, so the same message is
    /// never announced twice.
    @discardableResult
    private func handleIncomingSMSNotifications(_ merged: [SMSMessage]) -> Int {
        let incoming = receivedMessages(from: merged)
        let smsNotificationsEnabled =
            UserDefaults.standard.object(forKey: smsNotificationKey) as? Bool ?? true
        // Freshness is decided per record identity. The previous coarse key
        // (sender + body length + first twelve characters) made two same-template SMS
        // from one sender collapse into one, so the second one — a second verification
        // code is the everyday case — was silently dropped and nothing was announced.
        let freshMessages = incoming.filter { !seenIncomingSMSIDs.contains($0.id) }
        let grouped = coalescedForNotification(freshMessages)
        var posted = 0
        if smsNotificationsEnabled {
            // Only the conversation the user is currently reading is skipped. Skipping
            // everything while the app is active is what made a second message from the
            // same sender stay silent.
            for message in grouped where !isViewingConversation(message.sender) {
                smsNotifier.post(
                    message: message,
                    displayName: contacts.displayName(for: message.sender)
                )
                posted += 1
            }
        }
        seenIncomingSMSIDs.formUnion(incoming.map(\.id))
        rememberNotifiedSMS(incoming)
        // The coalesced form carries the whole body, so remember it too: the PDU channel
        // assembles the same message moments later and must not announce it again.
        rememberNotifiedSMS(grouped)
        return posted
    }

    /// 通知基线写入：记的是每条短信自己的 id（`SMSMessage.id`），并落盘。
    ///
    /// 落盘是为了让「进程被系统回收后在后台重启」这条路径也有基线：只在内存里记
    /// 的话，重启后集合是空的，模块缓存里还在的短信会被整批重弹。
    private func rememberNotifiedSMS(_ records: [SMSMessage]) {
        let incoming = records.filter { !$0.isOutgoing }
        guard !incoming.isEmpty else { return }
        let before = seenIncomingSMSIDs.count
        for message in incoming { seenIncomingSMSIDs.insert(message.id) }
        if seenIncomingSMSIDs.count > maxSeenIncomingSMSIDs { seenIncomingSMSIDs.removeAll() }
        guard seenIncomingSMSIDs.count != before else { return }
        UserDefaults.standard.set(Array(seenIncomingSMSIDs), forKey: seenIncomingSMSIDsKey)
    }

    /// Collapse records that arrive from one sender within the same second into a single
    /// reminder: the module text-mode list hands a long SMS back as one record per stored
    /// segment, and announcing each record rings several times with the segments in
    /// storage order instead of reading order.
    private func coalescedForNotification(_ records: [SMSMessage]) -> [SMSMessage] {
        var order: [String] = []
        var groups: [String: [SMSMessage]] = [:]
        for record in records {
            let key = "\(record.sender)\u{1}\(Int(record.timestamp.timeIntervalSince1970))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        return order.compactMap { key in
            guard let items = groups[key], let first = items.first else { return nil }
            guard items.count > 1 else { return first }
            // Keep the order the module returned: its list follows arrival order, so the
            // joined body reads the same way the assembled message does.
            return SMSMessage(
                sender: first.sender,
                content: items.map(\.content).joined(),
                code: first.code,
                timestamp: first.timestamp,
                deliveryID: nil,
                direction: .incoming
            )
        }
    }

    /// 用户此刻是否正开在这个会话里（只有这种情况下才不打扰）。
    private func isViewingConversation(_ sender: String) -> Bool {
        appIsActive && openConversationHandle == sender
    }

    /// 记录用户已处理的通话，并收掉它留在锁屏上的振铃通知。
    private func markCallHandled(_ callID: String?) {
        guard let callID, !callID.isEmpty else { return }
        handledCallIDs.insert(callID)
        if handledCallIDs.count > 200 { handledCallIDs.removeAll() }
        incomingNotifier.clearNotifications(for: callID)
    }

    /// 记下用户主动拒接的来电：模块仍会写成 `missed`，本机按「已拒绝」呈现。
    private func markCallDeclined(_ callID: String?) {
        guard let callID, !callID.isEmpty else { return }
        declinedCallIDs.insert(callID)
        if declinedCallIDs.count > 500 { declinedCallIDs.removeAll() }
        UserDefaults.standard.set(Array(declinedCallIDs), forKey: declinedCallIDsKey)
    }

    /// 这条记录在本机是否要显示成「已拒绝」（用户在响铃时明确拒接过的来电）。
    func isDeclinedCall(_ record: CallRecord) -> Bool {
        record.direction == "incoming" && declinedCallIDs.contains(record.id)
    }

    /// 锁屏通知上的接听 / 拒接按钮由后台直接调用模块接口，App 侧也要把这通记成
    /// 「用户已处理」，否则模块回传的 missed 记录马上会变成一条未接来电提醒。
    func markCallHandledByUser(_ callID: String, declined: Bool) {
        markCallHandled(callID)
        if declined { markCallDeclined(callID) }
    }

    /// 未接来电提醒。
    ///
    /// 模块把未接来电写成一条**历史记录**（`missed == true`、`endedAt != nil`、`active == nil`），
    /// 它永远不会经过 `activeCall`，所以原来的来电通知路径完全看不到它——这正是
    /// 「有未接电话没有通知」。这里在历史列表里发现新出现的未接记录时补一条通知。
    private func notifyMissedCalls(in history: [CallRecord]) {
        for record in history where record.missed && record.direction == "incoming" {
            guard !notifiedMissedCallIDs.contains(record.id) else { continue }
            notifiedMissedCallIDs.insert(record.id)
            // 用户自己接听 / 拒接 / 挂断过的通话不是「未接来电」，不再补提醒。
            guard !handledCallIDs.contains(record.id) else { continue }
            incomingNotifier.postMissed(
                record: record,
                displayName: contacts.displayName(for: record.number ?? "")
            )
        }
        if notifiedMissedCallIDs.count > 1_000 { notifiedMissedCallIDs.removeAll() }
    }

    func clearLocalMessages() {
        // 先记墓碑：模块侧仍保存着这些短信，只清本机列表的话下一轮刷新会全部复活。
        recordDeletedMessageIDs(Set(messages.map(\.id)))
        guard historyStore.saveMessages([]) else {
            errorMessage = "无法清空本机短信，请稍后重试"
            return
        }
        messages = []
        // 清空后重新拉回的短信不应再被旧通知基线吞掉。
        seenIncomingSMSIDs.removeAll()
        errorMessage = nil
    }

    /// 删除选中的本机短信（系统「信息」App 的多选删除语义）。
    func deleteMessages(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = messages.filter { !ids.contains($0.id) }
        guard historyStore.saveMessages(remaining) else {
            errorMessage = "无法删除短信，请稍后重试"
            return
        }
        messages = remaining
        seenIncomingSMSIDs.subtract(ids)
        recordDeletedMessageIDs(ids)
        errorMessage = nil
    }

    /// 删除选中的本机通话记录（系统「电话」App 的多选删除语义）。
    func deleteCalls(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = callHistory.filter { !ids.contains($0.id) }
        guard historyStore.saveCallHistory(remaining) else {
            errorMessage = "无法删除通话记录，请稍后重试"
            return
        }
        callHistory = remaining
        recordDeletedCallIDs(ids)
        errorMessage = nil
    }

    private func recordDeletedCallIDs(_ ids: Set<String>) {
        deletedCallIDs.formUnion(ids)
        if deletedCallIDs.count > maxDeletedIDCount {
            deletedCallIDs = Set(deletedCallIDs.suffix(maxDeletedIDCount))
        }
        UserDefaults.standard.set(Array(deletedCallIDs), forKey: deletedCallIDsKey)
    }

    private func recordDeletedMessageIDs(_ ids: Set<String>) {
        deletedMessageIDs.formUnion(ids)
        if deletedMessageIDs.count > maxDeletedIDCount {
            deletedMessageIDs = Set(deletedMessageIDs.suffix(maxDeletedIDCount))
        }
        UserDefaults.standard.set(Array(deletedMessageIDs), forKey: deletedMessageIDsKey)
    }

    /// 将磁盘副本并入当前内存，只增加或更新记录，绝不以空读取清掉现有界面数据。
    private func restoreLocalHistory() {
        let storedCalls = historyStore.loadCallHistory().filter { !deletedCallIDs.contains($0.id) }
        if !storedCalls.isEmpty {
            var callsByID: [String: CallRecord] = [:]
            for record in callHistory { callsByID[record.id] = record }
            for record in storedCalls {
                if let existing = callsByID[record.id], existing.updatedAt >= record.updatedAt { continue }
                callsByID[record.id] = record
            }
            callHistory = normalizedCallHistory(Array(callsByID.values))
        }

        let storedMessages = historyStore.loadMessages().filter { !deletedMessageIDs.contains($0.id) }
        if !storedMessages.isEmpty {
            var messagesByID: [String: SMSMessage] = [:]
            for message in messages { messagesByID[message.id] = message }
            for message in storedMessages { messagesByID[message.id] = message }
            messages = normalizedMessages(Array(messagesByID.values))
        }
    }

    /// 远端列表可能因模块重启、自动清理或离线而变短，因此只做并集，不删除手机副本。
    private func mergeCallHistory(_ remote: [CallRecord]) async -> [CallRecord] {
        // 本机已删除的记录不再并入：模块仍会回传它们，墓碑集合负责过滤。
        let pendingRecords = remote.filter { !deletedCallIDs.contains($0.id) }
        var byID: [String: CallRecord] = [:]
        for record in callHistory {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt { continue }
            byID[record.id] = record
        }
        for record in pendingRecords {
            if let local = byID[record.id], local.updatedAt > record.updatedAt {
                continue
            }
            byID[record.id] = record
        }
        // 用户主动拒接的来电模块始终写 `missed = true`，本机把它还原成普通呼入：
        // 列表里显示「已拒绝」，也不计入未接来电筛选。
        let merged = normalizedCallHistory(Array(byID.values)).map { record in
            record.missed && declinedCallIDs.contains(record.id)
                ? record.withoutMissedFlag()
                : record
        }
        if !pendingRecords.isEmpty, historyStore.saveCallHistory(merged) {
            // 只有手机副本写入成功才确认模块，断线时模块仍会保留未交付队列。
            let persistedIDs = Set(merged.map(\.id))
            let acknowledgedIDs = pendingRecords.map(\.id).filter { persistedIDs.contains($0) }
            try? await api.acknowledgeCallHistory(ids: acknowledgedIDs)
        }
        return merged
    }

    /// Rejoin the records of one long SMS with the same rule the PDU channel uses.
    ///
    /// The module text-mode list holds one record per stored segment and the UDH is
    /// already gone, so the segments have to be rejoined here: keep absorbing the next
    /// record while the previous one fills a whole segment, and order the records by
    /// module storage slot instead of by body text. Showing the raw records is what made
    /// one SMS flicker between a single bubble and several scrambled ones. The timestamp
    /// of the joined message is the one of its last segment, exactly like the assembled
    /// message, so the two channels produce the same `SMSMessage.id` instead of two
    /// competing bubbles.
    private func joiningFragments(_ records: [SMSMessage]) -> [SMSMessage] {
        let ordered = records.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            let left = lhs.deliverySlotIndex
            let right = rhs.deliverySlotIndex
            if let left, let right, left != right { return left < right }
            if left != nil, right == nil { return true }
            if left == nil, right != nil { return false }
            return lhs.id < rhs.id
        }
        var joined: [SMSMessage] = []
        for record in ordered {
            guard !record.isOutgoing,
                  let previous = joined.last,
                  !previous.isOutgoing,
                  previous.sender == record.sender,
                  record.timestamp.timeIntervalSince(previous.timestamp)
                    <= SMSDecoder.unsegmentedSiblingWindow,
                  previous.content.utf16.count
                    >= SMSDecoder.unsegmentedSegmentUnits(for: previous.content) else {
                joined.append(record)
                continue
            }
            joined[joined.count - 1] = SMSMessage(
                sender: previous.sender,
                content: previous.content + record.content,
                code: previous.code ?? record.code,
                timestamp: record.timestamp,
                deliveryID: nil,
                direction: .incoming
            )
        }
        return joined
    }

    /// Display-only merge of the module text-mode list.
    ///
    /// Unlike a PDU-assembled message, one text-mode record may be only a segment of a
    /// long SMS. It must neither be persisted nor acknowledged: acknowledging makes the
    /// module drop the segments, after which the PDU channel can never assemble the
    /// complete message and the chat keeps showing several fragment bubbles forever.
    private func mergeDisplayOnly(_ remote: [SMSMessage]) -> [SMSMessage] {
        let pendingMessages = joiningFragments(
            remote.filter { !deletedMessageIDs.contains($0.id) }
        )
        var byID: [String: SMSMessage] = [:]
        for message in messages { byID[message.id] = message }
        for var message in pendingMessages {
            if message.deliveryID == nil { message.deliveryID = byID[message.id]?.deliveryID }
            byID[message.id] = message
        }
        return normalizedMessages(Array(byID.values))
    }

    /// 将发送成功的短信保存为本机记录；`sender` 这里表示对话对端，沿用既有会话分组方式。
    private func saveSentMessage(recipient: String, content: String) {
        let sentMessage = SMSMessage(
            sender: recipient,
            content: content,
            code: nil,
            timestamp: .now,
            deliveryID: nil,
            direction: .outgoing
        )
        let updatedMessages = normalizedMessages(messages + [sentMessage])
        messages = updatedMessages
        if !historyStore.saveMessages(updatedMessages) {
            // 仍在当前界面保留该记录，避免用户重复发送；下次刷新会再次尝试写入最新列表。
            errorMessage = "短信已发送，但保存到本机失败，请稍后刷新确认"
        }
    }

    private func normalizedCallHistory(_ records: [CallRecord]) -> [CallRecord] {
        Array(records
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxCallHistoryCount))
    }

    private func normalizedMessages(_ records: [SMSMessage]) -> [SMSMessage] {
        // 时间戳完全相同的多条记录（同一条长短信的各段）必须有确定的先后：
        // 原先只按时间戳排，而 Swift 的 sorted 并不稳定、输入又来自字典的值，
        // 每次刷新的相对顺序都可能不同——界面就会在「合并成一条」和「拆成
        // 好几条」之间反复跳。这里补一个稳定的全序决胜键。
        Array(records
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                // Same tie as `chronological`: the segments of one long SMS share a SCTS,
                // so order them by module storage slot rather than by body text. This list
                // is newest first, hence the slot is compared descending.
                let left = lhs.deliverySlotIndex
                let right = rhs.deliverySlotIndex
                if let left, let right, left != right { return left > right }
                if left != nil, right == nil { return true }
                if left == nil, right != nil { return false }
                return lhs.id < rhs.id
            }
            .prefix(maxMessageCount))
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 模块语音桥在重试窗口内始终连不上时的收尾。
    ///
    /// 这时模块侧的 D5/D6 路由已经不在，继续留着本地音频引擎只会让麦克风、
    /// 扬声器和 VoiceProcessingIO 一直空转。只收音频，不动通话状态：
    /// 轮询只要看到模块仍报 active，下一拍就会重新拉起（受退避窗口约束）。
    private func handleVoiceTransportFailure() {
        voiceAudioFailureCount += 1
        voiceAudioRetryNotBefore = Date().addingTimeInterval(
            min(60, 10 * Double(voiceAudioFailureCount))
        )
        guard audio.active else { return }
        audio.deactivate()
    }

    private func startCallAudioIfReady() async {
        guard activeCall?.state == "active", !audio.active, !startingCallAudio else { return }
        // 语音桥连续失败后的退避窗口：这段时间不再重建音频，避免麦克风与
        // 扬声器在一条起不来的链路上反复空转（每次失败都要等满 45 秒重试窗口）。
        guard Date() >= voiceAudioRetryNotBefore else { return }
        let callID = activeCall?.id
        let managedByCallKit = callKit.managesCurrentCall
        guard !managedByCallKit || callKit.audioSessionIsActive else { return }
        startingCallAudio = true
        defer { startingCallAudio = false }
        backgroundStandby.suspendForCall()

        // Agent 在基带状态进入 active 时已经自动启动模块 PCM。这里绝不能再发送
        // “停止后启动”，否则会杀掉刚完成的 D4/D5/D6 路由并重新产生 8 秒冷启动。
        // CallKit 激活时也不能手动 setActive，否则系统通话路由会被应用抢占。
        guard await audio.activateForCall(sessionAlreadyActive: managedByCallKit) else {
            backgroundStandby.resumeAfterCall()
            return
        }
        // 模块轮询也会在 active 状态拉起语音桥，但主动发起一次请求可以消除
        // “手机先启动 PCM、模块下一轮轮询才发现”的竞速，减少首次握手等待。
        await registerAudioHost(true)
        // 请求可能与对端挂断并行完成；过期请求不得在下一通电话前重新拉起语音桥。
        if activeCall?.id != callID || activeCall?.state != "active" {
            await registerAudioHost(false)
        }
    }

    /// 仅允许电话网络常见字符，防止意外把 AT 控制字符传入模块代理。
    private static func validatedNumber(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "+*#0123456789")
        guard trimmed.count <= 82,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return trimmed
    }
}

extension AppModel: CallKitActionHandling {
    func callKitStart(number: String) async throws {
        // 呼出由 App、Siri 或系统联系人发起时都要从听筒开始。
        resetControlsForNewCall()
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            try audio.prepareForCallKit()
            try await api.dial(number: number)
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitAnswer() async throws {
        audio.stopCallTone()
        backgroundStandby.suspendForCall()
        do {
            try audio.prepareForCallKit()
            try await api.answerCall()
        } catch {
            backgroundStandby.resumeAfterCall()
            throw error
        }
    }

    func callKitEnd(backendID: String?, wasRinging: Bool) async throws {
        audio.stopCallTone()
        // 系统通话界面上的挂断 / 拒接也必须落到本机账本上：响铃时拒接，activeCall
        // 可能还没被轮询更新，所以用 CallKit 侧记下的模块 id 兜底。
        let endedID = backendID ?? activeCall?.id
        markCallHandled(endedID)
        let stillRinging = wasRinging
            || (activeCall?.direction == "incoming"
                && ["incoming", "waiting"].contains(activeCall?.state ?? ""))
        if stillRinging {
            // 明确拒接：排除出未接来电，历史里显示「已拒绝」。
            markCallDeclined(endedID)
            _ = try await api.rejectCall()
        } else {
            try await api.hangupCall()
        }
        if activeCall == nil { pendingOutgoingCall = nil }
    }

    func callKitSetMuted(_ muted: Bool) async {
        isMuted = muted
        audio.setMuted(muted)
        // CallKit 的静音动作直接作用于本地 PCM 编码器；模块 AT+CMUT 失败不应影响双向音频。
        Task { try? await api.setAudioMuted(muted) }
        errorMessage = nil
    }

    func callKitPlayDTMF(_ digits: String) async throws {
        for digit in digits where "0123456789*#".contains(digit) {
            try await api.sendDTMF(String(digit))
        }
    }

    /// CXStartCallAction 回调里、fulfill 之前调用：先声明语音类别，
    /// 让系统在通话建立的第一时间就切到通话态并显示通话界面。
    func callKitPrepareAudioSession() {
        try? audio.prepareForCallKit()
    }
    func callKitAudioSessionDidActivate() async {
        await startCallAudioIfReady()
    }

    func callKitAudioSessionDidDeactivate() {
        let callStillActive = activeCall?.state == "active"
        // 切换免提或系统重建路由时可能短暂失活；保留用户路由与模块 PCM，等待 didActivate 快速恢复。
        audio.deactivate(preservingCallKitRoute: callStillActive)
        audioWarmupCallID = nil
        guard !callStillActive else { return }
        backgroundStandby.resumeAfterCall()
        Task { await self.registerAudioHost(false) }
    }

    func callKitProviderDidReset() async {
        // CXProvider reset 只代表系统通话界面失效，绝不等于用户挂断真实模块通话。
        // 清理本地音频后交给下一轮状态同步按 App 内通话模式自动恢复。
        let callStillActive = activeCall?.state == "active"
        audio.deactivate(preservingCallKitRoute: callStillActive)
        if callStillActive {
            // 模块路由保持预热，下一轮轮询只需重建手机侧音频引擎。
            return
        }
        await registerAudioHost(false)
        backgroundStandby.resumeAfterCall()
    }

    func callKitDidFail(_ message: String) {
        // 拨号事务失败时占位通话必须撤掉，否则界面会停在「正在呼叫」。
        pendingOutgoingCall = nil
        errorMessage = message
    }

    private func resetControlsForNewCall() {
        isMuted = false
        isSpeakerEnabled = false
        audio.resetControlsForNewCall()
    }
}

private enum ModuleSetupError: LocalizedError {
    case notReady(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case let .notReady(message): return message
        case .timeout: return "模块重启后未重新上线，请重新插拔 USB 线"
        }
    }
}
