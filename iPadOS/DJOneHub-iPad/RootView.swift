import SwiftUI

/// 顶层导航的四个板块：通话 / 联系人 / 信息 / 设置。
/// 命名与顺序对齐系统 App（「电话」「联系人」「信息」「设置」），
/// 拨号与通话记录合并到同一个「通话」板块，符合 iOS 26 电话 App 的信息层级。
enum PhoneTab: String, CaseIterable, Identifiable {
    case calls
    case contacts
    case messages
    case settings

    var id: String { rawValue }

    /// HIG：tab 标签尽量用单个词，便于快速读取。
    var tabTitle: String {
        switch self {
        case .calls: return L10n.t("通话")
        case .contacts: return L10n.t("联系人")
        case .messages: return L10n.t("信息")
        case .settings: return L10n.t("设置")
        }
    }

    /// HIG：tab bar 图标优先使用填充变体，和系统 App 保持一致。
    var icon: String {
        switch self {
        case .calls: return "phone.fill"
        case .contacts: return "person.crop.circle.fill"
        case .messages: return "message.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// App 外壳：只负责 tab 导航、沉浸式背景和前台通话覆盖层。
///
/// 顶部导航栏由系统渲染并常驻置顶（iPadOS 26 会把 tab bar 与 toolbar 合并到同一条顶栏），
/// 下方内容始终全屏铺到屏幕边缘，并自动为顶栏留出安全区；
/// 顶栏背景取自其下方滚动的功能内容，顶端是系统的滚动边缘渐变模糊
/// （scroll edge effect），与系统「设置」App 顶部的效果一致。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("djonehub.selected-tab") private var selectedTabRawValue = PhoneTab.calls.rawValue
    @AppStorage("djonehub.first-connection-complete") private var firstConnectionComplete = false
    @State private var pendingSMSRecipient: String?
    /// 系统通话界面正在承载这通电话时，App 不抢回前台显示自己的通话页。
    @State private var inAppCallUISuppressed = false

    var body: some View {
        ZStack {
            // 沉浸式：内容一直铺到屏幕边缘，顶栏不画不透明底板，
            // 由系统滚动边缘效果在顶端做渐变模糊。
            TabView(selection: selectedTabBinding) {
                CallsView(onMessage: composeMessage)
                    .tag(PhoneTab.calls)
                    .tabItem { Label(PhoneTab.calls.tabTitle, systemImage: PhoneTab.calls.icon) }

                ContactsView(onCall: dial, onMessage: composeMessage)
                    .tag(PhoneTab.contacts)
                    .tabItem { Label(PhoneTab.contacts.tabTitle, systemImage: PhoneTab.contacts.icon) }

                MessagesView(pendingRecipient: $pendingSMSRecipient)
                    .tag(PhoneTab.messages)
                    .tabItem { Label(PhoneTab.messages.tabTitle, systemImage: PhoneTab.messages.icon) }

                SettingsView()
                    .tag(PhoneTab.settings)
                    .tabItem { Label(PhoneTab.settings.tabTitle, systemImage: PhoneTab.settings.icon) }
            }
            .phoneTabBarMinimizeOnScroll()
            .immersiveBars()
            // 强调色固定系统蓝：不能再把 tint 设成 primary，
            // 否则列表选中行会被描上黑（深色下为白）边，与系统 App 不一致。
            .tint(Color(uiColor: .systemBlue))

            // 前台通话界面：
            // 1) App 内发起的呼出立即铺满通话页；
            // 2) 由系统 CallKit 呼入并接通的电话不要抢回前台（isInAppCallUISuppressed），
            //    只有用户自己回到 App（桌面 / 切回本 App）时才恢复 App 内通话页。
            if let call = model.activeCall,
               !call.hasEndedState,
               scenePhase == .active,
               !inAppCallUISuppressed {
                ActiveCallView(call: call)
                    .transition(.opacity)
            }
        }
        .background(PhoneBackdrop())
        .onChange(of: model.activeCall?.id) { newValue in
            // 呼入电话交给系统 CallKit 界面承载：App 不抢前台显示自己的通话页，
            // 只有用户自己回到 App（回桌面 / 切换其它 App 再切回）时才恢复。
            // 呼出电话是用户在 App 内主动拨的，立即显示 App 内通话页。
            if model.activeCall?.direction == "incoming" {
                inAppCallUISuppressed = true
            } else if newValue == nil {
                inAppCallUISuppressed = false
            } else {
                inAppCallUISuppressed = false
            }
        }
        .onChange(of: model.locallyDismissedCallID) { newValue in
            if newValue != nil { inAppCallUISuppressed = true }
        }
        .onChange(of: scenePhase) { phase in
            // 用户返回本 App（从桌面或其它 App 切回来）后，恢复 App 内通话页。
            if phase == .active { inAppCallUISuppressed = false }
        }
        // 沉浸式：状态栏保持可见（HIG 不主张永久隐藏），但内容一直铺到屏幕边缘。
        .statusBarHidden(false)
        .persistentSystemOverlays(.automatic)
        .animation(.easeInOut(duration: 0.2), value: model.activeCall?.id)
        .animation(.easeInOut(duration: 0.2), value: model.callKitManagesCall)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: firstConnectionBinding) {
            FirstConnectionView()
                .environmentObject(model)
        }
        .onAppear {
            guard !firstConnectionComplete else { return }
            Task { await model.prepareModuleForFirstConnection() }
        }
        .alert(L10n.t("错误"), isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            // 引导页（fullScreenCover）没关掉之前绝不弹这个顶层错误弹窗：
            // SwiftUI 让「正在呈现 fullScreenCover 的视图」再去呈现 alert 时，
            // 两个呈现会互相打架，协调器卡住后引导页里的按钮会全部点不动。
            // 引导页期间的错误由 FirstConnectionView 在页内自己显示。
            get: { firstConnectionComplete && model.errorMessage?.isEmpty == false },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var firstConnectionBinding: Binding<Bool> {
        Binding(
            get: { !firstConnectionComplete },
            set: { if !$0 { firstConnectionComplete = true } }
        )
    }

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .calls },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .calls }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private func dial(_ number: String) {
        model.numberInput = number
        selectedTab = .calls
        Task { await model.dial() }
    }

    private func composeMessage(_ number: String) {
        pendingSMSRecipient = number
        selectedTab = .messages
    }
}

/// 与系统 App 对齐：只使用系统背景色（浅色纯白、深色纯黑）并铺满安全区。
/// 不额外自绘底色——自绘底色在深色下会和系统导航栏、状态栏、键盘底色对不上。
struct PhoneBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}

extension View {
    /// iOS 18 及以后以表单尺寸呈现弹层；旧系统保持大尺寸弹层。
    @ViewBuilder
    func presentationSizingIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.form)
        } else {
            self
        }
    }

    /// iOS 26 的滚动收缩 tab bar；旧系统保持常显（HIG：不要隐藏 tab bar）。
    @ViewBuilder
    func phoneTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// 沉浸式顶栏：导航栏与 tab bar 都不再画不透明底板，内容一直滚动到屏幕最顶端，
    /// 顶端交给系统的滚动边缘效果（scroll edge effect）做渐变模糊，
    /// 和系统「设置」App 顶部那种「内容透到模糊里」的效果一致。
    @ViewBuilder
    func immersiveBars() -> some View {
        if #available(iOS 26.0, *) {
            self
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarBackgroundVisibility(.hidden, for: .tabBar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else if #available(iOS 18.0, *) {
            self
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarBackgroundVisibility(.hidden, for: .tabBar)
        } else {
            self.toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    /// 内容区顶部的滚动边缘渐变模糊（HIG 的 scroll edge effect）。
    func pinnedScrollEdgeEffect() -> some View {
        immersiveBars()
    }

    /// 顶栏小按钮统一用系统单色：浅色黑、深色白，而不是强调色蓝。
    func monochromeBarControls() -> some View {
        self.tint(Color.primary)
    }
}

extension CallRecord {
    /// 通话已经结束的状态；这些状态下 App 内通话页必须立刻退出。
    var hasEndedState: Bool {
        ["ended", "failed", "cancelled", "rejected", "disconnected"].contains(state)
    }
}