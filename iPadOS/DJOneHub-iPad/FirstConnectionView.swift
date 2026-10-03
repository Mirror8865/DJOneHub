import SwiftUI
import UIKit

/// 首次接入只展示可执行状态；所有修复动作由 AppModel 串行完成。
struct FirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var runStarted = false
    /// 手动申请权限后的反馈：系统没有弹面板 / 已被拒绝时告诉用户下一步。
    @State private var permissionHint: String?
    /// 正在等待系统面板回应的那一项，避免重复点击。
    @State private var requestingPermission: AppPermission?
    /// 正在按顺序一次性申请全部权限；逐项申请期间整张列表显示进度。
    @State private var isRequestingAllPermissions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "ipad.and.iphone")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("连接 DJOneHub")
                            .font(.largeTitle.weight(.bold))
                        Text(model.setupStage.title)
                            .font(.headline)
                            .foregroundStyle(model.setupStage == .ready ? .green : .secondary)
                    }

                    // 权限申请流程放在最前面：首次安装打开 App 先看到并处理权限列表。
                    permissionSection

                    VStack(spacing: 0) {
                        setupRow("模块连接", icon: "cable.connector", active: [.connecting, .updating].contains(model.setupStage), complete: model.isOnline)
                        Divider()
                        setupRow("模块通信", icon: "antenna.radiowaves.left.and.right", active: model.setupStage == .initializing, complete: [.checkingAudio, .ready].contains(model.setupStage))
                        Divider()
                        setupRow("通话音频", icon: "waveform", active: model.setupStage == .checkingAudio, complete: model.setupStage == .ready)
                    }
                    .padding(.horizontal, 4)

                    // iOS/iPadOS 不公开 ADB、任意 USB 控制或内核写入能力；把这个边界
                    // 写在首次页中，避免未部署模块被误判为普通网络离线。
                    VStack(alignment: .leading, spacing: 8) {
                        Label("第一次使用需要先连接 Mac", systemImage: "laptopcomputer.and.iphone")
                            .font(.headline)
                        Text("全新模块必须先在 Mac 上使用 DJOneHub QDC507 首次部署包完成一次刷写。完成后插回 iPhone 或 iPad，App 会自动检查版本、初始化并修复手机直连模式。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("移动端不能直接执行 ADB、写入内核组件或替代 Mac 刷写；这不是权限没开，而是系统安全限制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    // 首次部署提示属于内容层，按官方文档使用普通材质而非液态玻璃。
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if case let .failed(message) = model.setupStage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Text("如果这是全新模块，请先完成 Mac 首次刷写；如果已刷写，请重新插拔并确认“以太网”已连接后再检测。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 引导页期间顶层不再弹错误弹窗（会与这个 fullScreenCover 抢呈现），
                    // 模块/链路错误改在页内直接显示，并能就地关掉。
                    if let message = model.errorMessage, !message.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L10n.t("知道了")) { model.errorMessage = nil }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(spacing: 12) {
                        Button {
                            runStarted = true
                            Task { await model.prepareModuleForFirstConnection() }
                        } label: {
                            Label(model.preparingModule ? "正在检测" : "重新检测", systemImage: model.preparingModule ? "hourglass" : "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.preparingModule)

                        if case .failed = model.setupStage {
                            Button("打开 DJOneHub 设置") {
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            }
                            .buttonStyle(.bordered)
                        }

                        if model.setupStage == .ready {
                            Button("完成") { dismiss() }
                                .buttonStyle(.bordered)
                        } else if !runStarted {
                            Text("系统权限已在上方列出；已完成 Mac 首次刷写后，插入模块再点按检测。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(horizontalSizeClass == .compact ? 18 : 24)
            }
            .navigationTitle("首次接入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { dismiss() }
                }
            }
            .task {
                // 引导页是用户第一个看到的界面：先把全部系统权限状态读出来。
                // 权限申请一律由用户点按触发——系统授权面板要求从用户手势所在的
                // 前台上下文弹出；App 自己在启动瞬间连弹五个面板时，系统会把它们
                // 排队甚至直接丢弃，之后用户再点「申请」就什么都不会发生。
                await model.refreshPermissionStates()
                guard !runStarted else { return }
                runStarted = true
                await model.prepareModuleForFirstConnection()
            }
            .onChange(of: scenePhase) { phase in
                // 从系统设置改完权限回来要立刻反映到列表。
                guard phase == .active else { return }
                Task { await model.refreshPermissionStates() }
            }
        }
    }

    /// 首次安装打开 App 就在引导页列出全部需要的系统权限：
    /// 已允许的打勾；未获取的可以再点申请，被永久拒绝时直接跳系统设置
    /// （iOS 不允许 App 自己改权限）。所有申请都由用户点按触发。
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.t("系统权限"), systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer(minLength: 8)
                // 有权限还没拿到时，可以在这里一键按顺序申请一遍。
                if isRequestingAllPermissions {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("全部申请")) { requestAllPermissions() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canRequestAnyPermission)
                }
            }
            Text(L10n.t("把下面几项一次授权完，来电、短信与保活才能正常工作。"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(AppPermission.allCases.enumerated()), id: \.element.id) { index, permission in
                    if index > 0 { Divider().padding(.leading, 40) }
                    permissionRow(permission)
                }
            }

            if let permissionHint {
                VStack(alignment: .leading, spacing: 8) {
                    Label(permissionHint, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.t("打开系统设置")) { openSystemSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        // 引导页内容层按官方文档使用普通材质而非液态玻璃。
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 状态还没读回来之前不显示按钮：避免用户点了一个「其实已经授权」的申请。
    private var canRequestAnyPermission: Bool {
        model.permissionStatesLoaded
            && AppPermission.allCases.contains { model.permissionState(for: $0) == .notDetermined }
    }

    private func permissionRow(_ permission: AppPermission) -> some View {
        let state = model.permissionState(for: permission)
        return HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .frame(width: 28)
                .foregroundStyle(state == .granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.permissionStatesLoaded || isRequestingAllPermissions || requestingPermission == permission {
                // 状态还没读回来 / 正在等待系统面板：显示进度，让「点按有反应」可见。
                ProgressView().controlSize(.small)
            } else {
                // 不再因为「已拒绝」就禁用按钮：禁用会让点按毫无反应。
                // 已拒绝时按钮文案是「去设置」，点按直接跳系统设置。
                Button {
                    requestPermission(permission)
                } label: {
                    Text(permissionButtonTitle(for: state))
                }
                .buttonStyle(.bordered)
                .disabled(state == .granted)
            }
        }
        .padding(.vertical, 10)
    }

    private func permissionButtonTitle(for state: PermissionState) -> String {
        switch state {
        case .granted: return L10n.t("已允许")
        case .denied: return L10n.t("去设置")
        default: return L10n.t("申请")
        }
    }

    private func requestPermission(_ permission: AppPermission) {
        // 已被永久拒绝时系统不会再弹窗，只能去系统设置里打开；
        // 但依旧要先给出文字反馈——点了完全没动静才是真正的问题。
        if model.permissionState(for: permission) == .denied {
            permissionHint = L10n.t("「\(permission.title)」在系统里被拒绝了：请到「设置 › DJOneHub」手动打开。")
            openSystemSettings()
            return
        }
        permissionHint = nil
        requestingPermission = permission
        Task {
            _ = await model.requestPermission(permission)
            requestingPermission = nil
            reportPermissionOutcome(permission)
        }
    }

    /// 一次把所有还没问过的权限按顺序申请（用户点按触发，面板一定在前台弹出）。
    private func requestAllPermissions() {
        permissionHint = nil
        isRequestingAllPermissions = true
        Task {
            await model.requestAllMissingPermissions()
            isRequestingAllPermissions = false
            if let missing = AppPermission.allCases.first(where: { model.permissionState(for: $0) != .granted }) {
                reportPermissionOutcome(missing)
            } else {
                permissionHint = nil
            }
        }
    }

    /// 申请结束后给出明确反馈：系统没有弹面板（已经问过 / 本地网络没有查询 API）
    /// 或者用户在系统里拒绝了，都直接引导去系统设置，而不是让按钮看起来没反应。
    private func reportPermissionOutcome(_ permission: AppPermission) {
        switch model.permissionState(for: permission) {
        case .granted:
            permissionHint = nil
        case .denied:
            permissionHint = L10n.t("「\(permission.title)」在系统里被拒绝了：请到「设置 › DJOneHub」手动打开。")
        case .notDetermined:
            permissionHint = L10n.t("系统没有为「\(permission.title)」弹出面板：请到「设置 › DJOneHub」手动打开。")
        }
    }

    private func openSystemSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    private func setupRow(_ title: String, icon: String, active: Bool, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(complete ? .green : .secondary)
            Text(title)
            Spacer()
            if complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView()
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 14)
    }
}
