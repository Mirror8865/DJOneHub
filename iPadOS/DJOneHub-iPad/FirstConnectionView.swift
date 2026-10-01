import SwiftUI
import UIKit

/// 首次接入只展示可执行状态；所有修复动作由 AppModel 串行完成。
struct FirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var runStarted = false

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
                    .background { nativeGlass(cornerRadius: 14) }

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
                            Text("已完成 Mac 首次刷写后，插入模块再点按检测；系统权限只需首次允许。")
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
                guard !runStarted else { return }
                runStarted = true
                await model.prepareModuleForFirstConnection()
            }
        }
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
