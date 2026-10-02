import SwiftUI

enum GPSRefreshPolicy {
    static func shouldRequest(isEnabled: Bool) -> Bool { isEnabled }
}

/// 设置页只在前台刷新，避免关闭弹层后仍持续请求模块并额外耗电。
enum SettingsRefreshPolicy {
    static func shouldRefresh(appIsActive: Bool) -> Bool { appIsActive }
}

/// iPad 设置页左栏分区。系统设置式「分区列表 + 详情」双栏：
/// 左栏是等高的分区条目，右栏只显示当前分区，不存在两块卡片高度差造成的空白。
private enum SettingsSection: String, CaseIterable, Identifiable {
    case status
    case appearance
    case notification
    case connection
    case voice
    case network
    case power
    case esim
    case debugAT
    case service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "状态"
        case .appearance: return "外观与语言"
        case .notification: return "后台与保活"
        case .connection: return "连接"
        case .voice: return "通话支持"
        case .network: return "网络"
        case .power: return "功率与温度"
        case .esim: return "eSIM 与卡片"
        case .debugAT: return "AT 调试"
        case .service: return "服务控制"
        }
    }

    var icon: String {
        switch self {
        case .status: return "info.circle"
        case .appearance: return "paintbrush"
        case .notification: return "bell"
        case .connection: return "link"
        case .voice: return "phone"
        case .network: return "antenna.radiowaves.left.and.right"
        case .power: return "bolt"
        case .esim: return "simcard"
        case .debugAT: return "terminal"
        case .service: return "gearshape.2"
        }
    }
}

/// 左栏分组：和系统设置 App 一致，先分组标题、再列具体条目。
private enum SettingsGroup: String, CaseIterable, Identifiable {
    case djonehub
    case module
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .djonehub: return "DJOneHub 设置"
        case .module: return "模块设置"
        case .advanced: return "高级"
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .djonehub: return [.status, .appearance, .notification]
        case .module: return [.connection, .voice, .network, .power, .esim]
        case .advanced: return [.debugAT, .service]
        }
    }
}

/// 设置页完整承载 Mac 版“状态 / 通用 / 网络 / GPS / eSIM / AT / 服务控制”功能。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("djonehub.background-standby-enabled") private var backgroundStandbyEnabled = true
    @AppStorage("djonehub.low-power-mode-enabled") private var lowPowerModeEnabled = true
    @AppStorage("djonehub.live-activity-enabled") private var liveActivityEnabled = true
    @AppStorage("djonehub.sms-notifications-enabled") private var smsNotificationsEnabled = true

    @State private var modem: ModemStatus?
    @State private var traffic: NetworkTrafficSnapshot?
    @State private var previousTraffic: NetworkTrafficSnapshot?
    @State private var downloadRate: Double?
    @State private var uploadRate: Double?
    @State private var systemPower: SystemPowerStatus?
    @State private var showingPowerDetails = false
    @State private var powerDetailsPresented = false
    @State private var cellularAllowed = true
    /// 4G 策略写入期间，禁止轮询回包覆盖用户刚刚选择的状态。
    @State private var isUpdatingCellularPolicy = false
    /// 每次用户修改策略都递增，用于丢弃修改前已发出的旧查询结果。
    @State private var cellularPolicyRevision = 0
    @State private var gps: GPSStatus?
    @State private var gpsMessage = ""
    @State private var esim: ESIMOverview?
    @State private var esimHealth: ESIMHealth?
    @State private var voice: VoiceRuntimeStatus?
    @State private var setup: ModuleSetupStatus?
    @State private var usbProfile: USBProfileStatus?
    @State private var actionMessage = ""
    @State private var atCommand = "AT+CSQ"
    @State private var atResponse = ""
    @State private var networkDiagnostic: NetworkDiagnostic?
    @State private var showingDiagnostic = false
    @State private var showingESIMDownload = false
    @State private var showingShutdownConfirmation = false
    @State private var showingMacModeConfirmation = false
    @State private var busy = false
    // List(selection:) 在 iOS 上要求可选绑定，因此这里用可选值，读取时回退到“状态”。
    @State private var selectedSection: SettingsSection? = .status
    let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        Group {
            // iPad（regular）：系统设置式「分区列表 + 详情」双栏，左右都是整列内容，
            // 不存在两块卡片高度差造成的空白；iPhone（compact）：官方 grouped Form 单列范式。
            if horizontalSizeClass == .regular {
                settingsSplitView
            } else {
                NavigationStack {
                    settingsForm
                        .navigationTitle(L10n.t("设置"))
                        .toolbar { settingsToolbar }
                }
            }
        }
        .task(id: scenePhase) {
                guard SettingsRefreshPolicy.shouldRefresh(appIsActive: scenePhase == .active) else { return }
                await runStatusLoop()
            }
            .sheet(isPresented: $showingDiagnostic) {
                NetworkDiagnosticView(diagnostic: networkDiagnostic)
                    .presentationSizingIfAvailable()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingESIMDownload) {
                ESIMDownloadView { smdp, matchingID, confirmationCode, imei, aid in
                    await downloadProfile(smdp, matchingID, confirmationCode, imei, aid)
                }
                .presentationSizingIfAvailable()
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog("确认完全退出模块服务？", isPresented: $showingShutdownConfirmation, titleVisibility: .visible) {
                Button("完全退出", role: .destructive) {
                    Task { await shutdownAgent() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("代理停止后需重新插拔或重启模块才能恢复。")
            }
            .confirmationDialog("切换为 Mac 完整模式？", isPresented: $showingMacModeConfirmation, titleVisibility: .visible) {
                Button("切换并重启模块", role: .destructive) {
                    Task { await switchToMacMode() }
                }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text("只会写入已验证的 USB Audio 配置位。模块重启后，请把它从\(DeviceContext.displayName)拔出并连接到 Mac。")
            }
        // 弹窗放到整个设置页顶层，不能附在 Form 单行上，否则长内容会被列表裁切。
        .overlay {
            if showingPowerDetails {
                ZStack {
                    Color.black.opacity(0.14)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissPowerDetails() }
                        .opacity(powerDetailsPresented ? 1 : 0)

                    PowerDetailsPopover(systemPower: systemPower, onDismiss: dismissPowerDetails)
                        // 吞掉卡片内的普通点击，只有点击遮罩才关闭。
                        .onTapGesture {}
                        // 模拟 iOS 原生弹层：轻微上浮并以弹簧回弹，不硬切显示。
                        .scaleEffect(powerDetailsPresented ? 1 : 0.92)
                        .offset(y: powerDetailsPresented ? 0 : 16)
                        .opacity(powerDetailsPresented ? 1 : 0)
                        .onAppear {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                powerDetailsPresented = true
                            }
                        }
                }
                // 顶部导航栏不进入遮罩范围，用户随时都能点“完成”退出设置。
                .padding(.top, 64)
                .zIndex(10)
            }
        }
    }

    // MARK: - iPhone 单列表单（官方 grouped Form）
    private var settingsForm: some View {
        Form {
            statusSection
            appearanceSection
            notificationSection
            connectionSection
            voiceSection
            networkSection
            powerSection
            esimSection
            atSection
            serviceSection
            if !actionMessage.isEmpty {
                Section {
                    Text(actionMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - iPad 分区列表 + 详情（系统设置式，左右各为一整列）

    /// 左栏按系统设置 App 分成「DJOneHub 设置 / 模块设置 / 高级」三组，
    /// 右栏只承载当前分区的分组表单，不再使用自绘玻璃卡片。
    private var settingsSplitView: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsGroup.allCases) { group in
                    Section(L10n.t(group.title)) {
                        ForEach(group.sections) { section in
                            Label(L10n.t(section.title), systemImage: section.icon)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 侧栏选中高亮用系统蓝，避免父级 primary tint 把选中行染成黑色。
            .tint(Color(uiColor: .systemBlue))
            .navigationTitle(L10n.t("设置"))
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            // 右栏严格按系统设置 App 的分组表单呈现：没有卡片、没有玻璃底板。
            Form {
                sectionContent(selectedSection ?? .status)
                if !actionMessage.isEmpty {
                    Section {
                        Text(actionMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t((selectedSection ?? .status).title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { settingsToolbar }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .status: statusSection
        case .appearance: appearanceSection
        case .notification: notificationSection
        case .connection: connectionSection
        case .voice: voiceSection
        case .network: networkSection
        case .power: powerSection
        case .esim: esimSection
        case .debugAT: atSection
        case .service: serviceSection
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        // 作为顶层 tab 时无“完成”按钮；仅 sheet/cover 模式（onClose 非空）显示。
        if onClose != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("完成")) { closeSettings() }
                    .fontWeight(.semibold)
            }
        }
    }

    /// 状态：系统设置式分组行（LabeledContent），每行一项，不再做两列卡片。
    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent(L10n.t("模块代理")) {
                Text(model.isOnline ? L10n.t("在线") : L10n.t("离线"))
                    .foregroundStyle(model.isOnline ? Color.green : Color.red)
            }
            LabeledContent("App 版本", value: appVersionText)
            LabeledContent("Agent 版本", value: model.agentVersion ?? (model.isOnline ? "读取中" : "--"))
            LabeledContent(L10n.t("运营商"), value: operatorDisplayName(modem?.operatorName) ?? "--")
            LabeledContent(L10n.t("SIM 卡"), value: modem?.simInserted == true ? "已接入" : "未接入")
            LabeledContent(L10n.t("网络模式"), value: modem?.networkMode ?? "--")
            LabeledContent(L10n.t("信号强度"), value: modem?.signalDBM.map { "\($0) dBm" } ?? "--")
        } header: {
            Text(L10n.t("模块"))
        }
        Section {
            LabeledContent(L10n.t("下载速度"), value: rateText(downloadRate))
            LabeledContent(L10n.t("上传速度"), value: rateText(uploadRate))
            LabeledContent(L10n.t("本次流量"), value: byteText(traffic?.sessionTotal))
        } header: {
            Text(L10n.t("流量"))
        }
        Section {
            Button {
                Task { await refreshAll() }
            } label: {
                Label(L10n.t("刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(busy)
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "--"
        return "\(version) (\(build))"
    }

    /// 外观与语言：系统设置式 Picker 行。
    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker(L10n.t("显示模式"), selection: $appSettings.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.t("语言"), selection: $appSettings.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text(L10n.t("外观与语言"))
        }
    }

    /// 后台与保活：保活开关 + 通知开关，全部是系统设置式行。
    /// 保活不使用静音音频后台播放，改用「始终允许」的后台定位维持进程。
    @ViewBuilder
    private var notificationSection: some View {
        Section {
            Toggle(L10n.t("后台保活"), isOn: $backgroundStandbyEnabled)
                // 开关保持系统绿色（TabView 的 primary tint 不得染到开关）。
                .tint(Color(uiColor: .systemGreen))
                .onChange(of: backgroundStandbyEnabled) { enabled in
                    model.setBackgroundStandbyEnabled(enabled)
                }
            LabeledContent(L10n.t("保活状态"), value: model.backgroundStandby.statusText)
        } header: {
            Text(L10n.t("后台与保活"))
        } footer: {
            Text("不使用静音音频后台播放。开启后 App 借助“始终允许”的后台定位让进程保持活跃，熄屏或切到后台仍能及时收到模块转发的来电与短信，代价是略高的耗电。")
        }
        Section {
            Toggle("短信通知", isOn: $smsNotificationsEnabled)
                .tint(Color(uiColor: .systemGreen))
                .onChange(of: smsNotificationsEnabled) { enabled in
                    model.setSMSNotificationsEnabled(enabled)
                }
            Toggle("灵动岛", isOn: $liveActivityEnabled)
                .tint(Color(uiColor: .systemGreen))
                .onChange(of: liveActivityEnabled) { enabled in
                    model.setLiveActivityEnabled(enabled)
                }
            Toggle("省电模式", isOn: $lowPowerModeEnabled)
                .tint(Color(uiColor: .systemGreen))
                .onChange(of: lowPowerModeEnabled) { enabled in
                    model.setLowPowerModeEnabled(enabled)
                }
                .disabled(!backgroundStandbyEnabled)
        } header: {
            Text(L10n.t("通知"))
        } footer: {
            Text("App 在后台时，新短信与来电会像来电一样弹出系统通知；灵动岛关闭后结束实时活动，普通通知仍然保留。省电模式降低后台空闲时的检测频率。")
        }
    }

    /// 连接：系统设置式信息行 + 模式切换动作行。
    @ViewBuilder
    private var connectionSection: some View {
        Section {
            LabeledContent("连接模式", value: usbProfile?.mode == "mac" ? "Mac 完整模式" : "\(DeviceContext.displayName) 直连模式")
            LabeledContent("模块地址", value: "192.168.225.1")
            NavigationLink {
                RingtoneSettingsView()
            } label: {
                Label("来电铃声", systemImage: "bell.fill")
            }
        } header: {
            Text(L10n.t("连接"))
        }
        Section {
            Button {
                showingMacModeConfirmation = true
            } label: {
                Label("切换为 Mac 完整模式", systemImage: "laptopcomputer.and.iphone")
            }
            .disabled(busy || !model.isOnline || usbProfile?.mode == "mac")
        } footer: {
            Text("快速切换只改 UAC 位，不重刷整套固件；重启和 USB 重新枚举通常只需十几秒。")
        }
    }

    /// 通话支持：状态行 + 两个动作行。
    @ViewBuilder
    private var voiceSection: some View {
        Section {
            LabeledContent(L10n.t("语音运行时")) {
                Text(voice?.ready == true ? "已就绪" : "未就绪")
                    .foregroundStyle(voice?.ready == true ? Color.green : Color.secondary)
            }
            if let detail = voice?.runtimeDetail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            } else if voice?.ready != true, let error = voice?.lastError, !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.t("通话支持"))
        }
        Section {
            Button("刷新") { Task { await refreshVoice() } }
            if voice?.ready != true {
                Button("安装语音运行时") { Task { await provisionVoice() } }
            }
        }
    }

    /// 网络：4G 出口开关 + 诊断动作行。
    @ViewBuilder
    private var networkSection: some View {
        Section {
            Toggle(L10n.t("允许 4G 上网"), isOn: cellularAllowedBinding)
                .tint(Color(uiColor: .systemGreen))
                .disabled(isUpdatingCellularPolicy)
        } footer: {
            Text("关闭后禁止\(DeviceContext.displayName)通过模块访问互联网；短信与来电监控不受影响。")
        }
        Section {
            Button { Task { await check4G() } } label: {
                Label(L10n.t("检查 4G 出口"), systemImage: "antenna.radiowaves.left.and.right")
            }
            Button { Task { await checkProxy() } } label: {
                Label(L10n.t("检查代理出口"), systemImage: "network")
            }
            Button { Task { await showNetworkDiagnostic() } } label: {
                Label(L10n.t("网络诊断"), systemImage: "stethoscope")
            }
            Button { Task { await rebootModule() } } label: {
                Label(L10n.t("重启模块"), systemImage: "restart")
            }
        } header: {
            Text(L10n.t("诊断与维护"))
        }
        .disabled(busy)
    }

    /// 温度与供电仅每次设置页状态刷新时读取一次，不保持额外后台轮询。
    /// 功率与温度：系统设置式读数行，完整传感器列表放到二级入口。
    @ViewBuilder
    private var powerSection: some View {
        Section {
            LabeledContent("模块温度", value: primaryTemperature.map { String(format: "%.0f°C", $0) } ?? "--")
            LabeledContent("当前功率", value: primaryPower.map { String(format: "%.1f W", $0) } ?? "--")
            LabeledContent("电压", value: primaryVoltage.map { String(format: "%.2f V", $0) } ?? "--")
            LabeledContent("电流", value: primaryCurrent.map { String(format: "%.2f A", $0) } ?? "--")
            LabeledContent("供电状态", value: modulePowerOnline ? "已连接" : "--")
        } header: {
            Text(L10n.t("功率与温度"))
        } footer: {
            Text(powerCardSubtitle)
        }
        Section {
            Button {
                showingPowerDetails = true
            } label: {
                Label(L10n.t("查看全部传感器"), systemImage: "list.bullet.rectangle")
            }
        }
    }

    /// 无论模块是否插入都保留同一张卡，避免读取结果返回时设置页面跳动。
    private var powerCardSubtitle: String {
        guard let systemPower else { return "等待模块连接" }
        guard systemPower.supported, !systemPower.readings.isEmpty else { return "暂不支持读取" }
        return primaryTemperature.map { String(format: "最高 %.0f°C", $0) } ?? "正在读取"
    }

    private func dismissPowerDetails() {
        withAnimation(.easeOut(duration: 0.18)) {
            powerDetailsPresented = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            guard !powerDetailsPresented else { return }
            showingPowerDetails = false
        }
    }

    private func closeSettings() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// 卡片只呈现最有用的一组读数；完整传感器列表保留在模块接口中，不塞进设置页。
    private var primaryTemperature: Double? {
        systemPower?.readings.compactMap(\.temperatureC).max()
    }

    private var primaryVoltage: Double? {
        systemPower?.readings.compactMap(\.voltageV).first
    }

    private var primaryCurrent: Double? {
        systemPower?.readings.compactMap(\.currentA).first
    }

    private var primaryPower: Double? {
        systemPower?.readings.compactMap(\.powerW).first
    }

    private var modulePowerOnline: Bool {
        systemPower?.readings.contains(where: { $0.online == true }) == true
    }

    /// eSIM 与卡片：卡片信息行 + 每个 Profile 一行 + 两个动作行。
    @ViewBuilder
    private var esimSection: some View {
        Section {
            LabeledContent(L10n.t("卡片类型"), value: cardTypeText)
            if let message = esim?.message, !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let groups = esim?.profiles {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    ForEach(group.profiles ?? []) { profile in
                        ESIMProfileRow(profile: profile) { action in
                            // 把所属 eUICC AID 一并传给模块，避免双 eUICC 卡跨 SE 误操作。
                            Task { await handleProfile(action, profile: profile, aid: group.aidHex ?? "") }
                        }
                    }
                }
            }
        } header: {
            Text(L10n.t("eSIM 与卡片"))
        } footer: {
            if let healthMessage = esimHealth?.message, !healthMessage.isEmpty {
                Text(healthMessage)
            }
        }
        Section {
            Button(L10n.t("通讯录检测")) { Task { await probePhonebook() } }
            Button(L10n.t("下载新 Profile")) { showingESIMDownload = true }
        }
    }

    /// AT 调试：输入行 + 发送动作行 + 等宽的返回结果行。
    @ViewBuilder
    private var atSection: some View {
        Section {
            TextField(L10n.t("AT 指令"), text: $atCommand)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            Button(L10n.t("发送 AT")) { Task { await executeAT() } }
                .disabled(busy || atCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text(L10n.t("AT 调试"))
        } footer: {
            Text("指令需以 AT 开头，长度不超过 256。")
        }
        if !atResponse.isEmpty {
            Section {
                ScrollView(.horizontal) {
                    Text(atResponse)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            } header: {
                Text("返回结果")
            }
        }
    }

    /// 服务控制：破坏性动作单独成组，说明放到脚注。
    @ViewBuilder
    private var serviceSection: some View {
        Section {
            Button("完全退出", role: .destructive) {
                showingShutdownConfirmation = true
            }
            .disabled(busy)
        } header: {
            Text(L10n.t("服务控制"))
        } footer: {
            Text("停止模块内 4G 后台、短信守护、通话与控制服务。代理停止后需重新插拔或重启模块才能恢复。")
        }
    }

    // MARK: - 状态刷新

    private func runStatusLoop() async {
        while !Task.isCancelled,
              SettingsRefreshPolicy.shouldRefresh(appIsActive: scenePhase == .active) {
            await refreshAll()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshAll() async {
        // 轮询开始时记录版本；请求返回时若用户已修改策略，则该回包已过期。
        let policyRevisionAtRequest = cellularPolicyRevision
        async let modemRequest = try? model.api.modemStatus()
        async let trafficRequest = try? model.api.networkTraffic()
        async let powerRequest = try? model.api.systemPower()
        async let policyRequest = try? model.api.cellularPolicy()
        async let gpsRequest = try? model.api.gpsStatus()
        async let esimRequest = try? model.api.esimOverview()
        async let healthRequest = try? model.api.esimHealth()
        async let voiceRequest = try? model.api.voiceRuntimeStatus()
        async let setupRequest = try? model.api.moduleSetupStatus()
        async let usbProfileRequest = try? model.api.usbProfile()

        modem = await modemRequest
        if let current = await trafficRequest {
            updateRates(with: current)
            traffic = current
        }
        systemPower = await powerRequest
        if let policy = await policyRequest,
           policyRevisionAtRequest == cellularPolicyRevision,
           !isUpdatingCellularPolicy {
            cellularAllowed = !policy.forceOff
        }
        gps = await gpsRequest
        esim = await esimRequest
        esimHealth = await healthRequest
        voice = await voiceRequest
        setup = await setupRequest
        usbProfile = await usbProfileRequest
    }

    private func updateRates(with current: NetworkTrafficSnapshot) {
        defer { previousTraffic = current }
        guard let previousTraffic,
              previousTraffic.interface == current.interface,
              current.sampledAtMS > previousTraffic.sampledAtMS else {
            downloadRate = nil
            uploadRate = nil
            return
        }
        let elapsed = Double(current.sampledAtMS - previousTraffic.sampledAtMS) / 1_000
        downloadRate = Double(current.rxBytes &- previousTraffic.rxBytes) / elapsed
        uploadRate = Double(current.txBytes &- previousTraffic.txBytes) / elapsed
    }

    // MARK: - 操作

    private var cellularAllowedBinding: Binding<Bool> {
        Binding(
            get: { cellularAllowed },
            set: { requestedAllowed in
                guard requestedAllowed != cellularAllowed, !isUpdatingCellularPolicy else { return }
                updateCellularPolicy(allowed: requestedAllowed)
            }
        )
    }

    /// 先立即更新界面，再等待模块确认；失败时恢复原值，避免开关“点了又弹回”的假象。
    private func updateCellularPolicy(allowed: Bool) {
        let previousAllowed = cellularAllowed
        cellularAllowed = allowed
        cellularPolicyRevision &+= 1
        let requestRevision = cellularPolicyRevision
        isUpdatingCellularPolicy = true

        Task {
            defer {
                if requestRevision == cellularPolicyRevision {
                    isUpdatingCellularPolicy = false
                }
            }

            do {
                let policy = try await model.api.setCellularPolicy(forceOff: !allowed)
                guard requestRevision == cellularPolicyRevision else { return }
                // 以模块回包为准，避免本地显示与实际策略不一致。
                cellularAllowed = !policy.forceOff
                actionMessage = cellularAllowed
                    ? "已允许\(DeviceContext.displayName)使用模块 4G"
                    : "已禁止\(DeviceContext.displayName)使用模块 4G"
            } catch {
                guard requestRevision == cellularPolicyRevision else { return }
                cellularAllowed = previousAllowed
                actionMessage = "4G 上网设置失败：\(error.localizedDescription)"
            }
        }
    }

    private func perform(_ operation: () async throws -> String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { actionMessage = try await operation() }
        catch { actionMessage = error.localizedDescription }
    }

    private func check4G() async { await perform { let r = try await model.api.check4GRoute(); return r.summary ?? (r.ok ? "检查通过" : "检查未通过") } }
    private func checkProxy() async { await perform { let r = try await model.api.checkProxyRoute(); return r.summary ?? (r.ok ? "检查通过" : "检查未通过") } }
    private func rebootModule() async { await perform { try await model.api.rebootModule(); return "已发送模块重启指令" } }
    private func showNetworkDiagnostic() async {
        await perform {
            networkDiagnostic = try await model.api.networkDiagnostic()
            showingDiagnostic = true
            return "网络诊断已更新"
        }
    }
    private func refreshVoice() async { voice = try? await model.api.voiceRuntimeStatus() }
    private func provisionVoice() async { await perform { voice = try await model.api.provisionVoiceRuntime(); return "语音运行时已安装" } }
    private func refreshGPSFix() async {
        guard GPSRefreshPolicy.shouldRequest(isEnabled: gps?.enabled == true) else { return }
        gpsMessage = "正在定位；首次定位请在窗边或室外等待 30–120 秒"
        await perform {
            let fix = try await model.api.gpsRefresh()
            gps = GPSStatus(enabled: true, lastFix: fix, lastError: nil)
            return "定位已刷新"
        }
        gpsMessage = actionMessage
    }
    private func probePhonebook() async { await perform { let r = try await model.api.probeESIMPhonebook(); return r.readSupported == true ? "模块支持读取卡内联系人" : "模块未确认读取能力" } }
    private func executeAT() async {
        let command = atCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.uppercased().hasPrefix("AT"), command.count <= 256 else {
            atResponse = "请输入以 AT 开头、长度不超过 256 的指令"
            return
        }
        await perform { let result = try await model.api.executeAT(command); atResponse = result.response; return "AT 指令已执行" }
    }
    private func shutdownAgent() async { await perform { try await model.api.shutdownModuleAgent(); model.stop(); return "模块代理已停止" } }
    private func switchToMacMode() async {
        await perform {
            let result = try await model.api.setUSBProfile("mac")
            usbProfile = result
            return result.message ?? "已切换为 Mac 完整模式，模块正在重启"
        }
    }
    private func downloadProfile(_ smdp: String, _ matchingID: String, _ confirmationCode: String, _ imei: String, _ aid: String) async {
        await perform {
            let result = try await model.api.downloadESIMProfile(smdp: smdp, matchingID: matchingID, confirmationCode: confirmationCode, imei: imei, aid: aid)
            await refreshAll()
            return result.message ?? "Profile 下载完成"
        }
    }
    private func handleProfile(_ action: ESIMProfileAction, profile: ESIMProfile, aid: String) async {
        guard let iccid = profile.iccid else { return }
        switch action {
        case .switchProfile:
            await perform { _ = try await model.api.switchESIM(iccid: iccid, aid: aid); return "已切换 Profile，模块正在重启" }
        case let .rename(name):
            await perform { try await model.api.renameESIMProfile(iccid: iccid, aid: aid, name: name); await refreshAll(); return "Profile 名称已修改" }
        case .delete:
            await perform { try await model.api.deleteESIMProfile(iccid: iccid, aid: aid); await refreshAll(); return "Profile 已删除" }
        }
    }

    private var gpsBinding: Binding<Bool> {
        Binding(
            get: { gps?.enabled == true },
            set: { enabled in
                Task {
                    await perform {
                        if enabled {
                            let result = try await model.api.gpsStart()
                            gps = GPSStatus(enabled: result.enabled, lastFix: result.lastFix, lastError: nil)
                            return "已启动定位"
                        }
                        _ = try await model.api.gpsStop()
                        gps = GPSStatus(enabled: false, lastFix: nil, lastError: nil)
                        return "已停止定位"
                    }
                }
            }
        )
    }

    // MARK: - 展示辅助

    private var coordinateText: String {
        guard let lat = gps?.lastFix?.latitude, let lng = gps?.lastFix?.longitude else { return L10n.t("等待定位") }
        return "\(lat), \(lng)"
    }
    private var cardTypeText: String {
        switch esim?.cardType { case "physical_sim": return "实体 SIM"; case "esim": return "eSIM"; default: return esim?.cardType ?? "查询中" }
    }
    private func rateText(_ bytes: Double?) -> String {
        guard let bytes else { return "--" }
        return bytes >= 1_048_576 ? String(format: "%.1f MB/s", bytes / 1_048_576) : String(format: "%.1f KB/s", bytes / 1_024)
    }
    private func byteText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "--" }
        return bytes >= 1_073_741_824 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
    private func operatorDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let map = ["CHINA TELECOM": "中国电信", "CTCC": "中国电信", "CHINA MOBILE": "中国移动", "CMCC": "中国移动", "CHINA UNICOM": "中国联通", "UNICOM": "中国联通", "CHINA BROADNET": "中国广电"]
        return map[raw.uppercased()] ?? raw
    }
    private func powerKindName(_ kind: String) -> String {
        switch kind {
        case "power_supply": return "电源"
        case "thermal": return "温度"
        case "hwmon": return "硬件监控"
        case "adc": return "电源采样"
        default: return kind
        }
    }
}

private enum ESIMProfileAction { case switchProfile; case rename(String); case delete }

private struct ESIMProfileRow: View {
    let profile: ESIMProfile
    let action: (ESIMProfileAction) -> Void
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading) {
                    Text(profile.displayName).font(.subheadline.weight(.semibold))
                    Text(mask(profile.iccid)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if profile.enabled { Label("使用中", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            }
            HStack {
                if !profile.enabled { Button(L10n.t("切换")) { action(.switchProfile) } }
                Button(L10n.t("重命名")) { name = profile.name ?? ""; showingRename = true }
                Button(L10n.t("删除"), role: .destructive) { showingDelete = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .alert("重命名 Profile", isPresented: $showingRename) {
            TextField("Profile 名称", text: $name)
            Button(L10n.t("保存")) { action(.rename(name.trimmingCharacters(in: .whitespacesAndNewlines))) }
            Button(L10n.t("取消"), role: .cancel) {}
        }
        .confirmationDialog("确认删除 Profile？", isPresented: $showingDelete) {
            Button(L10n.t("删除"), role: .destructive) { action(.delete) }
            Button(L10n.t("取消"), role: .cancel) {}
        }
    }

    private func mask(_ value: String?) -> String {
        guard let value, value.count > 8 else { return value ?? "--" }
        return "\(value.prefix(4)) •••• \(value.suffix(4))"
    }
}

private struct NetworkDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    let diagnostic: NetworkDiagnostic?

    var body: some View {
        NavigationStack {
            List {
                Section("USB") {
                    LabeledContent("USB 网卡", value: diagnostic?.usbNetworkPresent == true ? "已识别" : "未识别")
                    LabeledContent("模式", value: diagnostic?.usbnetMode ?? "--")
                    LabeledContent("设备", value: [diagnostic?.usbDevice?.vendor, diagnostic?.usbDevice?.product].compactMap { $0 }.joined(separator: " · "))
                }
                Section("蜂窝网络") {
                    LabeledContent("蜂窝 IP", value: diagnostic?.pdpAddresses?.joined(separator: ", ") ?? "--")
                    LabeledContent("活动 PDP", value: diagnostic?.activeContexts?.map(String.init).joined(separator: ", ") ?? "--")
                }
                Section("\(DeviceContext.displayName) 路由") {
                    LabeledContent("默认出口", value: diagnostic?.defaultRoute?.interface ?? "--")
                    LabeledContent("网关", value: diagnostic?.defaultRoute?.gateway ?? "--")
                }
                if let interfaces = diagnostic?.interfaces {
                    Section("接口") {
                        ForEach(Array(interfaces.enumerated()), id: \.offset) { _, item in
                            LabeledContent(item.name ?? "--", value: item.ipv4 ?? item.status ?? "--")
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("网络诊断"))
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

/// 设置页功率卡的完整读数面板；卡片保持紧凑，详细传感器只在用户长按时显示。
private struct PowerDetailsPopover: View {
    let systemPower: SystemPowerStatus?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("完整功率与温度", systemImage: "thermometer.medium")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 固定字段模板始终存在，数据回来后原位更新，避免面板突然改变结构。
            detailRow("最高温度", maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--")
            detailRow("电压", voltage.map { String(format: "%.2f V", $0) } ?? "--")
            detailRow("电流", current.map { String(format: "%.2f A", $0) } ?? "--")
            detailRow("功率", power.map { String(format: "%.1f W", $0) } ?? "--")
            detailRow("电量", capacity.map { "\($0)%" } ?? "--")
            detailRow("外部供电", online.map { $0 ? "已连接" : "未连接" } ?? "--")
            detailRow("系统状态", statusText ?? "--")

            Divider()

            Text("传感器明细")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 9) {
                    if readings.isEmpty {
                        detailRow("读取状态", systemPower == nil ? "等待模块连接" : "暂不支持读取")
                    } else {
                        ForEach(readings) { reading in
                            detailRow(reading.name, readingText(reading))
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        // 弹层内容视图按官方文档使用普通材质，自定义玻璃背景只留给真正的控制元素。
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func readingText(_ reading: SystemPowerReading) -> String {
        var values: [String] = []
        if let value = reading.temperatureC { values.append(String(format: "%.0f°C", value)) }
        if let value = reading.voltageV { values.append(String(format: "%.2fV", value)) }
        if let value = reading.currentA { values.append(String(format: "%.2fA", value)) }
        if let value = reading.powerW { values.append(String(format: "%.1fW", value)) }
        if let value = reading.capacityPercent { values.append("\(value)%") }
        if let value = reading.online { values.append(value ? "在线" : "离线") }
        if let value = reading.status, !value.isEmpty { values.append(value) }
        return values.isEmpty ? "--" : values.joined(separator: " · ")
    }

    private var readings: [SystemPowerReading] {
        guard systemPower?.supported == true else { return [] }
        return systemPower?.readings ?? []
    }

    private var maximumTemperature: Double? { readings.compactMap(\.temperatureC).max() }
    private var voltage: Double? { readings.compactMap(\.voltageV).first }
    private var current: Double? { readings.compactMap(\.currentA).first }
    private var power: Double? { readings.compactMap(\.powerW).first }
    private var capacity: Int? { readings.compactMap(\.capacityPercent).first }
    private var online: Bool? { readings.compactMap(\.online).first }
    private var statusText: String? { readings.compactMap(\.status).first(where: { !$0.isEmpty }) }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ESIMDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    let onDownload: (String, String, String, String, String) async -> Void
    @State private var smdp = ""
    @State private var matchingID = ""
    @State private var confirmationCode = ""
    @State private var imei = ""
    @State private var aid = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("SM-DP+ 地址", text: $smdp).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Matching ID（可选）", text: $matchingID)
                    TextField("确认码（可选）", text: $confirmationCode)
                    TextField("IMEI（必填）", text: $imei).keyboardType(.numberPad)
                    TextField("AID（可选）", text: $aid).textInputAutocapitalization(.characters)
                } footer: {
                    Text("Profile 写入期间不要拔出模块。")
                }
            }
            .navigationTitle(L10n.t("下载新 Profile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始下载") {
                        busy = true
                        Task { await onDownload(smdp, matchingID, confirmationCode, imei, aid); busy = false; dismiss() }
                    }
                    .disabled(busy || smdp.isEmpty || imei.isEmpty)
                }
            }
        }
    }
}

/// 保存铃声偏好并通过同一套合成器试听，确保实际来电与设置页声音一致。
private struct RingtoneSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("djonehub.ringtone") private var ringtone = "Hero"
    private let tones = ["Hero", "Signal", "Beacon", "系统默认"]

    var body: some View {
        List(tones, id: \.self) { tone in
            Button {
                ringtone = tone
                model.audio.previewRingtone(named: tone)
            } label: {
                HStack {
                    Text(tone)
                    Spacer()
                    if ringtone == tone { Image(systemName: "checkmark") }
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .disabled(model.activeCall != nil)
        }
        .navigationTitle("来电铃声")
        .onDisappear { model.audio.stopRingtonePreview() }
    }
}

