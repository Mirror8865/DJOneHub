import SwiftUI

/// DJOneHub iPhone/iPad 原生入口；运行时只连接模块内代理，不依赖 Mac 后台。
@main
struct DJOneHubIPadApp: App {
    @UIApplicationDelegateAdaptor(DJOneHubNotificationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 系统可能在后台（后台刷新任务）把 App 拉起，此时 SwiftUI 不一定渲染 body。
        // 主状态中心必须在这里就建好，保活与轮询才有依附；
        // 同时 CallKit 也要求尽早创建 CXProvider，否则系统无法把通话状态关联回本 App，
        // 用户要等锁屏重新点亮才能看到系统通话界面。
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.contacts)
                .environmentObject(model.audio)
                .environmentObject(settings)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                model.didBecomeActive()
            case .background:
                model.didEnterBackground()
            default:
                break
            }
        }
    }
}
