import SwiftUI

/// DJOneHub iPhone/iPad 原生入口；运行时只连接模块内代理，不依赖 Mac 后台。
@main
struct DJOneHubIPadApp: App {
    @UIApplicationDelegateAdaptor(DJOneHubNotificationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

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
