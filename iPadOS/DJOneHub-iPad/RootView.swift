import SwiftUI

enum PhoneTab: String, CaseIterable, Identifiable {
    case dial = "拨号"
    case recents = "最近通话"
    case messages = "短信"
    case contacts = "通讯录"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dial: return "circle.grid.3x3"
        case .recents: return "clock"
        case .messages: return "message"
        case .contacts: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }

    var tabTitle: String {
        switch self {
        case .recents: return "最近"
        case .contacts: return "联系人"
        default: return rawValue
        }
    }
}

/// 四个高频目的地使用系统 TabView；低频设置入口固定在右上角导航层。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("djonehub.selected-tab") private var selectedTabRawValue = PhoneTab.dial.rawValue
    @State private var pendingSMSRecipient: String?
    @AppStorage("djonehub.first-connection-complete") private var firstConnectionComplete = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 设置与拨号/最近/短信/联系人同级，作为顶层 tab，位置统一。
            TabView(selection: selectedTabBinding) {
                DialPadView()
                    .tag(PhoneTab.dial)
                    .tabItem { Label(L10n.t(PhoneTab.dial.tabTitle), systemImage: PhoneTab.dial.icon) }

                RecentsView(onCall: dial, onMessage: composeMessage)
                    .tag(PhoneTab.recents)
                    .tabItem { Label(L10n.t(PhoneTab.recents.tabTitle), systemImage: PhoneTab.recents.icon) }

                MessagesView(pendingRecipient: $pendingSMSRecipient)
                    .tag(PhoneTab.messages)
                    .tabItem { Label(L10n.t(PhoneTab.messages.tabTitle), systemImage: PhoneTab.messages.icon) }

                ContactsView(onCall: dial, onMessage: composeMessage)
                    .tag(PhoneTab.contacts)
                    .tabItem { Label(L10n.t(PhoneTab.contacts.tabTitle), systemImage: PhoneTab.contacts.icon) }

                SettingsView()
                    .tag(PhoneTab.settings)
                    .tabItem { Label(L10n.t(PhoneTab.settings.tabTitle), systemImage: PhoneTab.settings.icon) }
            }
            .phoneTabBarMinimizeOnScroll()
            // tab 选中色：浅色黑、深色白（不用蓝色）。
            .tint(Color.primary)

            // 呼出与来电都优先交给系统 CallKit 界面承载；只有 CallKit 不可用
            // （例如个人侧载缺少权限）时才回退显示 App 内通话页。
            if let call = model.activeCall, !model.callKitManagesCall {
                ActiveCallView(call: call)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(PhoneBackdrop())
        .animation(.easeInOut(duration: 0.2), value: model.activeCall?.id)
        .animation(.easeInOut(duration: 0.2), value: model.callKitManagesCall)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: Binding(
            get: { !firstConnectionComplete },
            set: { if !$0 { firstConnectionComplete = true } }
        )) {
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

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .dial },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .dial }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private func dial(_ number: String) {
        model.numberInput = number
        selectedTab = .dial
        Task { await model.dial() }
    }

    private func composeMessage(_ number: String) {
        pendingSMSRecipient = number
        selectedTab = .messages
    }

}

/// 浅色模式使用系统电话式纯白底；深色模式才绘制深蓝黑底部环境光。
struct PhoneBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.008, green: 0.016, blue: 0.035)
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.018, green: 0.075, blue: 0.16).opacity(0.72),
                        Color(red: 0.025, green: 0.20, blue: 0.48).opacity(0.62),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.white
            }
        }
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

    @ViewBuilder
    func phoneTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
