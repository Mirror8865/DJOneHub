import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DJOneHubLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DJOneHubLiveActivityWidget()
    }
}

/// 灵动岛与锁屏共用同一通话状态，交互按钮仅在 iOS 17 及以上启用。
struct DJOneHubLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DJOneHubCallActivityAttributes.self) { context in
            lockScreenView(context.state.liveActivityDisplayState(isStale: context.isStale))
                .activityBackgroundTint(Color(uiColor: .systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state.liveActivityDisplayState(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbolName(for: state.phase))
                        .font(.title2)
                        .foregroundStyle(tint(for: state.phase))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.phase == .standby ? standbyHeadline(state) : state.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(state.phase.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .active {
                        Text(state.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                    } else if state.phase == .standby, let signal = state.signalDBM {
                        VStack(spacing: 1) {
                            Image(systemName: "cellularbars")
                            Text("\(signal) dBm")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase == .standby {
                        standbyRadioView(state)
                    } else {
                        actionButtons(state)
                    }
                }
            } compactLeading: {
                Image(systemName: state.phase == .standby ? "cellularbars" : symbolName(for: state.phase))
                    .foregroundStyle(tint(for: state.phase))
            } compactTrailing: {
                compactTrailingView(state)
            } minimal: {
                Image(systemName: state.phase == .standby ? "cellularbars" : symbolName(for: state.phase))
                    .foregroundStyle(tint(for: state.phase))
            }
            .keylineTint(tint(for: state.phase))
        }
    }

    private func lockScreenView(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName(for: state.phase))
                .font(.title2)
                .foregroundStyle(tint(for: state.phase))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == .standby ? standbyHeadline(state) : state.displayName)
                    .font(.headline).lineLimit(1)
                Text(state.phase.title).font(.caption).foregroundStyle(.secondary)
                if state.phase == .standby {
                    Text(standbyDetail(state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if state.phase == .active {
                Text(state.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
            }
            actionButtons(state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actionButtons(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            switch state.phase {
            case .incoming:
                HStack(spacing: 12) {
                    Button(intent: RejectDJOneHubCallIntent(callID: state.callID)) {
                        Label("拒绝", systemImage: "phone.down.fill")
                    }
                    .tint(.red)
                    Button(intent: AnswerDJOneHubCallIntent(callID: state.callID)) {
                        Label("接听", systemImage: "phone.fill")
                    }
                    .tint(.green)
                }
                .buttonStyle(.borderedProminent)
            case .active, .held:
                Button(intent: HangUpDJOneHubCallIntent(callID: state.callID)) {
                    Label("挂断", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .standby, .offline:
                EmptyView()
            }
        } else if state.phase == .incoming {
            Text("打开 DJOneHub 接听")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func standbyRadioView(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cellularbars")
            Text(standbyDetail(state))
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func compactTrailingView(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .active {
            Text(state.startedAt, style: .timer)
                .font(.caption2.monospacedDigit())
                .frame(width: 42)
        } else if state.phase == .incoming {
            Text("来电").font(.caption2.weight(.semibold))
        } else if state.phase == .standby, let signal = state.signalDBM {
            Text("\(signal)").font(.caption2.monospacedDigit())
        } else {
            Text(state.phase == .standby ? "待机" : "离线").font(.caption2)
        }
    }

    private func standbyHeadline(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> String {
        let carrier = state.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return carrier.isEmpty ? "模块待机" : carrier
    }

    private func standbyDetail(
        _ state: DJOneHubCallActivityAttributes.ContentState
    ) -> String {
        var parts: [String] = []
        if let mode = state.networkMode, !mode.isEmpty { parts.append(mode) }
        if let band = state.radioBand, !band.isEmpty { parts.append(band) }
        if let signal = state.signalDBM { parts.append("\(signal) dBm") }
        return parts.isEmpty ? "正在读取蜂窝网络" : parts.joined(separator: " · ")
    }

    private func symbolName(
        for phase: DJOneHubCallActivityAttributes.ContentState.Phase
    ) -> String {
        switch phase {
        case .standby: return "antenna.radiowaves.left.and.right"
        case .incoming: return "phone.arrow.down.left.fill"
        case .active: return "waveform"
        case .held: return "pause.fill"
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func tint(
        for phase: DJOneHubCallActivityAttributes.ContentState.Phase
    ) -> Color {
        switch phase {
        case .incoming, .active: return .green
        case .held: return .orange
        case .standby: return .cyan
        case .offline: return .secondary
        }
    }
}
