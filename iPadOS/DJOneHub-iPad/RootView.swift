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

    var body: some View {
        ZStack {
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
            // 强调色固定系统蓝：不能再把 tint 设成 primary，
            // 否则列表选中行会被描上黑（深色下为白）边，与系统 App 不一致。
            .tint(Color(uiColor: .systemBlue))

            // 系统 CallKit 只负责锁屏、后台与状态栏那一层通话界面；
            // App 在前台时必须自己把通话页铺满，否则呼出后屏幕上没有通话 UI。
            // 退到后台后本视图自然消失，系统通话界面接管。
            if let call = model.activeCall, scenePhase != .background {
                ActiveCallView(call: call)
                    .transition(.opacity)
            }
        }
        .background(PhoneBackdrop())
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
            get: { model.errorMessage?.isEmpty == false },
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

    /// 顶部导航栏的滚动边缘效果：栏底取自下方滚动的内容，并在顶端做渐变模糊。
    /// HIG 建议优先用 automatic；这里按需求显式使用软渐变（soft），
    /// 让顶栏像系统「设置」App 那样把内容柔和地渐隐到模糊里。
    @ViewBuilder
    func pinnedScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}