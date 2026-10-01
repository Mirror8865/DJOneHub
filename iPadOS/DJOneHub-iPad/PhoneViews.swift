import SwiftUI
import UIKit
import PhotosUI

/// 仅在当天显示具体时分；更早的记录显示日期，避免长列表全部挤成相同的时间。
enum RecentCallTimeFormatter {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        if day == currentDay {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "昨天"
        }
        if day.year == currentDay.year {
            return String(format: "%02d/%02d", day.month ?? 0, day.day ?? 0)
        }
        return String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

/// 点击记录前统一校验号码，防止异常历史记录触发空号码拨号。
enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

/// 拨号盘删除保持单字符语义，避免长按时因输入为空触发越界删除。
enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

// MARK: - 拨号

struct DialPadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onSettings: () -> Void
    @State private var deleteRepeatTask: Task<Void, Never>?
    @State private var zeroWasLongPressed = false
    @State private var showingModuleStatus = false
    @State private var moduleStatusPopoverPresented = false
    @State private var moduleStatusFeedback = UIImpactFeedbackGenerator(style: .medium)
    @State private var moduleStatusPillPressed = false
    @State private var dialKeyFeedback = DialKeyFeedback()

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var matchedName: String? {
        model.contacts.contact(for: model.numberInput)?.name
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }
    // 三列按键共用固定轨道，避免窄屏时拨号、删除与数字键的中心线错位。
    private var keySize: CGFloat { isCompact ? 82 : 90 }
    private var keySpacing: CGFloat { isCompact ? 24 : 30 }
    private var rowSpacing: CGFloat { isCompact ? 14 : 18 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }

    var body: some View {
        NavigationStack {
            // 背景作为 ZStack 的第一层铺满整屏，iPad 上不会再出现安全区或导航栏外的黑边。
            ZStack {
                PhoneBackdrop()
                ScrollView {
                    VStack(spacing: isCompact ? 16 : 22) {
                        dialPageHeader
                            // 弹窗需盖在号码输入区之上，不能被后续的拨号盘视图遮住。
                            .zIndex(showingModuleStatus ? 1 : 0)

                        VStack(spacing: 2) {
                            Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                                .font(.system(size: isCompact ? 36 : 42, weight: .light, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(model.numberInput.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.45)
                                .frame(height: 50)

                            Text(matchedName ?? " ")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                                .frame(height: 22)
                        }
                        .padding(.horizontal, 12)

                        // 多个玻璃键放进系统容器，玻璃会正确采样背景并合并渲染（官方文档模式）。
                        // 官方文档：容器间距若大于内部 HStack/VStack 间距，静止时玻璃会提前相融，
                        // 因此容器间距取 0，按键在静止时保持独立的纯圆形态。
                        Group {
                            if #available(iOS 26.0, *) {
                                GlassEffectContainer(spacing: 0) {
                                    VStack(spacing: rowSpacing) {
                                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                            HStack(spacing: keySpacing) {
                                                ForEach(row, id: \.0) { digit, letters in
                                                    DialKey(digit: digit, letters: letters)
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                VStack(spacing: rowSpacing) {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                        HStack(spacing: keySpacing) {
                                            ForEach(row, id: \.0) { digit, letters in
                                                DialKey(digit: digit, letters: letters)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: keypadWidth)

                        HStack(spacing: keySpacing) {
                            Color.clear.frame(width: keySize, height: keySize)
                            Button {
                                Task { await model.dial() }
                            } label: {
                                // 主操作键：绿色 tint 的交互式液态玻璃圆（官方文档组合 .regular.tint().interactive()）。
                                Image(systemName: "phone.fill")
                                    .font(.system(size: isCompact ? 27 : 30, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: keySize, height: keySize)
                                    .modifier(GlassCircle(tint: .green))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.numberInput.isEmpty || model.isBusy || !model.isOnline)
                            .opacity(model.numberInput.isEmpty || !model.isOnline ? 0.4 : 1)

                            Image(systemName: "delete.left")
                                .font(.system(size: isCompact ? 22 : 24))
                                .foregroundStyle(.secondary)
                                .frame(width: keySize, height: keySize)
                                .contentShape(Rectangle())
                                // minimumDistance 为零可在手指落下时立即响应，避免长按识别造成迟滞。
                                .gesture(deleteGesture)
                                .allowsHitTesting(!model.numberInput.isEmpty)
                                .opacity(model.numberInput.isEmpty ? 0.4 : 1)
                                .accessibilityLabel(L10n.t("删除"))
                                .accessibilityHint(L10n.t("轻点删除一位，长按连续删除"))
                                .accessibilityAddTraits(.isButton)
                        }
                        // 与数字键使用同一列距，视觉与点击位置都更接近系统电话。
                        .frame(width: keypadWidth)
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                // 只在背景普通点击时收起，避免与状态标签的长按结束事件发生竞争。
                .onTapGesture { dismissModuleStatusPopover() }
            }
            // 导航栏只承担设置入口；标题和状态放在页面内容区，避免窄屏互相挤压。
            .navigationBarTitleDisplayMode(.inline)
            .settingsToolbarButton {
                // 设置入口与状态弹窗属于同一页面状态；跳转前收起，返回拨号页时不会残留。
                dismissModuleStatusPopover()
                onSettings()
            }
            .onDisappear(perform: stopRepeatingDelete)
        }
    }

    private func deleteLastDigit() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    private func playDialKeySound() {
        // 使用 iOS 原生输入点击音；通话静音时不发声，且仍服从系统“键盘反馈”设置。
        guard !model.isMuted else { return }
        dialKeyFeedback.play()
    }

    private func beginDeleting() {
        guard deleteRepeatTask == nil, !model.numberInput.isEmpty else { return }
        // 手指落下就删除一位；仍按住超过 0.35 秒才开始连续删除，短按不会多删。
        deleteLastDigit()
        deleteRepeatTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            while !Task.isCancelled, !model.numberInput.isEmpty {
                deleteLastDigit()
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            deleteRepeatTask = nil
        }
    }

    private func stopRepeatingDelete() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private func dismissModuleStatusPopover() {
        guard showingModuleStatus else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            moduleStatusPopoverPresented = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190))
            guard !moduleStatusPopoverPresented else { return }
            showingModuleStatus = false
        }
    }

    private var deleteGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginDeleting() }
            .onEnded { _ in stopRepeatingDelete() }
    }

    private var dialPageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.t("拨号"))
                .font(.system(size: isCompact ? 32 : 36, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            dialStatusPill
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dialStatusPill: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isOnline ? "antenna.radiowaves.left.and.right" : "cable.connector.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isOnline ? .green : .red)

            Text(model.isOnline ? L10n.t("模块在线") : L10n.t("模块离线"))
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isOnline ? .green : .red)
                .lineLimit(1)

            Circle()
                .fill(model.isOnline ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            (model.isOnline ? Color.green : Color.red).opacity(0.12),
            in: Capsule()
        )
        .contentShape(Capsule())
        // 现代设备不再提供压力值，用短按压缩放加触感模拟系统的 Haptic Touch。
        .scaleEffect(moduleStatusPillPressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: moduleStatusPillPressed)
        .onLongPressGesture(
            // 缩短触发时间并允许轻微手指漂移，保证单手操作也能稳定识别。
            minimumDuration: 0.18,
            maximumDistance: 36,
            perform: {
                moduleStatusFeedback.impactOccurred()
                moduleStatusFeedback.prepare()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showingModuleStatus = true
                }
            },
            onPressingChanged: { pressing in
                moduleStatusPillPressed = pressing
                if pressing { moduleStatusFeedback.prepare() }
            }
        )
        // 弹窗锚定在标签本身下方，避免 iPhone 将 popover 自动转换成底部大面板。
        .overlay(alignment: .topTrailing) {
            if showingModuleStatus {
                ModuleStatusPopover(onDismiss: dismissModuleStatusPopover)
                    .environmentObject(model)
                    // 与功率详情保持一致：从状态标签下方轻微上浮并回弹。
                    .scaleEffect(moduleStatusPopoverPresented ? 1 : 0.92, anchor: .topTrailing)
                    .offset(y: moduleStatusPopoverPresented ? 44 : 58)
                    .opacity(moduleStatusPopoverPresented ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            moduleStatusPopoverPresented = true
                        }
                    }
                    .zIndex(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.isOnline ? L10n.t("模块在线") : L10n.t("模块离线"))
        .accessibilityHint("按住查看模块状态")
    }

    @ViewBuilder
    private func DialKey(digit: String, letters: String) -> some View {
        Button {
            // 长按 0 已输入加号；抬手时忽略 Button 的默认点击，避免得到“0+”。
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            model.numberInput.append(digit)
            playDialKeySound()
        } label: {
            Group {
                if #available(iOS 26.0, *) {
                    VStack(spacing: 1) {
                        Text(digit).font(.system(size: isCompact ? 33 : 36, weight: .regular, design: .rounded))
                        Text(letters).font(.system(size: isCompact ? 10 : 11, weight: .semibold)).tracking(1.4)
                    }
                    .foregroundStyle(.primary)
                    .frame(width: keySize, height: keySize)
                    // 系统液态玻璃按键：regular + interactive 让自定义键拥有和系统按钮一致的按压反馈。
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
                } else {
                    VStack(spacing: 1) {
                        Text(digit).font(.system(size: isCompact ? 33 : 36, weight: .regular, design: .rounded))
                        Text(letters).font(.system(size: isCompact ? 10 : 11, weight: .semibold)).tracking(1.4)
                    }
                    .foregroundStyle(.primary)
                    .frame(width: keySize, height: keySize)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .contentShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if digit == "0" {
                    zeroWasLongPressed = true
                    model.numberInput.append("+")
                }
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }
}

/// 复用系统输入点击音，避免自定义音频会话干扰正在进行的通话路由。
private final class DialKeyFeedback {
    func play() {
        UIDevice.current.playInputClick()
    }
}

/// 圆形液态玻璃控件修饰器（官方文档组合：.regular.tint().interactive() + in: Circle()）。
/// tint 为 nil 时使用无着色的交互式玻璃；iOS 26 以下回退为系统填充圆。
private struct GlassCircle: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content
                    .glassEffect(.regular.tint(tint).interactive(), in: Circle())
                    .contentShape(Circle())
            } else {
                content
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
        } else {
            content
                .background(Circle().fill(tint ?? Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
    }
}

// MARK: - 模块状态

private struct ModuleStatusPopover: View {
    @EnvironmentObject private var model: AppModel
    let onDismiss: () -> Void

    private var modem: ModemStatus? { model.modemStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: model.isOnline ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.isOnline ? .green : .red)
                Text("模块状态")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("关闭"))
            }

            Text(connectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            statusRow("Agent", model.agentVersion ?? (model.isOnline ? "读取中" : "--"))
            statusRow(L10n.t("运营商"), modem?.operatorName ?? "--")
            statusRow(L10n.t("网络模式"), modem?.networkMode ?? "--")
            statusRow(L10n.t("信号强度"), modem?.signalDBM.map { "\($0) dBm" } ?? "--")
            statusRow(L10n.t("SIM 卡"), modem?.simInserted == true ? "已接入" : "未接入")

        }
        .padding(16)
        .frame(width: 286, alignment: .leading)
        // 弹层内容视图按官方文档不再叠加自定义玻璃背景，交给系统弹层材质呈现。
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var connectionDescription: String {
        guard !model.isOnline else { return "USB ECM 已连接，状态会自动刷新" }
        return model.connectionMessage ?? "请检查模块连接与 USB ECM 网络"
    }


    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - 最近通话

struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.callHistory.isEmpty {
                    EmptyStateView(
                        title: L10n.t("暂无通话记录"),
                        systemImage: "phone.arrow.up.right"
                    )
                } else {
                    List(model.callHistory) { call in
                        // 点击整条记录直接回拨；没有号码的异常记录仍保持只读显示。
                        Button {
                            if let number = RecentCallDialPolicy.numberToDial(call.number) {
                                onCall(number)
                            }
                        } label: {
                                CallHistoryRow(call: call)
                                    .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(RecentCallDialPolicy.numberToDial(call.number) == nil)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let number = call.number {
                                Button { onMessage(number) } label: {
                                    Label(L10n.t("短信"), systemImage: "message.fill")
                                }
                                .tint(.blue)
                                Button { onCall(number) } label: {
                                    Label(L10n.t("拨号"), systemImage: "phone.fill")
                                }
                                .tint(.green)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("最近通话"))
            .settingsToolbarButton(action: onSettings)
        }
    }

    private struct CallHistoryRow: View {
        @EnvironmentObject private var model: AppModel
        let call: CallRecord

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: call.direction == "incoming" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                    .foregroundStyle(call.missed ? .red : .green)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.contacts.displayName(for: call.number))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(call.missed ? .red : .primary)
                    Text(call.missed ? L10n.t("未接") : (call.direction == "incoming" ? L10n.t("呼入") : L10n.t("呼出")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 最近通话显示发生时刻；跨天时改为日期，避免用户误把旧记录当作今天。
                Text(RecentCallTimeFormatter.string(for: call.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
    }
}

// MARK: - 短信

/// iMessage 风格分类（与信息 App 的“三条杠”筛选菜单一致）。
private enum MessagesCategory: String, CaseIterable, Identifiable {
    case inbox = "信息"
    case unknown = "未知发件人"
    case junk = "垃圾信息"
    case recentlyDeleted = "最近删除"

    var id: String { rawValue }

    var emptyTitle: String {
        switch self {
        case .inbox: return "暂无短信"
        case .unknown: return "暂无未知发件人"
        case .junk: return "暂无垃圾信息"
        case .recentlyDeleted: return "暂无最近删除"
        }
    }
}

/// 会话列表 + 聊天详情：iPad 上用 NavigationSplitView 双栏呈现（iMessage 布局），
/// 左侧为搜索框 + 编辑菜单 + 分类三条杠的会话列表，右侧为具体聊天界面。
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var pendingRecipient: String?
    let onSettings: () -> Void

    @State private var showingComposer = false
    @State private var showingClearConfirmation = false
    @State private var showingDeleteSelectionConfirmation = false
    @State private var search = ""
    @State private var category: MessagesCategory = .inbox
    @State private var selection: String?
    @State private var isSelecting = false
    @State private var selectedSenders = Set<String>()
    @State private var showingPinEditor = false
    @State private var showingNamePhotoEditor = false
    @AppStorage("djonehub.pinned-senders") private var pinnedSendersData = ""
    @AppStorage("djonehub.display-name-overrides") private var displayNameOverridesData = ""
    @AppStorage("djonehub.photo-overrides") private var photoOverridesData = ""

    private var allConversations: [(sender: String, messages: [SMSMessage])] {
        Dictionary(grouping: model.messages, by: \.sender)
            .map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    /// 分类 + 搜索过滤后的会话（垃圾信息/最近删除模块暂不追踪，按 iMessage 显示为空状态）。
    private var filteredConversations: [(sender: String, messages: [SMSMessage])] {
        guard category != .junk, category != .recentlyDeleted else { return [] }
        var list = allConversations
        if !search.isEmpty {
            list = list.filter { conversation in
                let name = displayName(for: conversation.sender)
                return name.localizedCaseInsensitiveContains(search)
                    || conversation.sender.localizedCaseInsensitiveContains(search)
            }
        }
        if category == .unknown {
            list = list.filter { model.contacts.contact(for: $0.sender) == nil }
        }
        return list
    }

    private var pinnedConversations: [(sender: String, messages: [SMSMessage])] {
        filteredConversations.filter { isPinned($0.sender) }
    }

    private var unpinnedConversations: [(sender: String, messages: [SMSMessage])] {
        filteredConversations.filter { !isPinned($0.sender) }
    }

    private var pinnedSenders: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(pinnedSendersData.utf8))) ?? [])
    }

    private var displayNameOverrides: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(displayNameOverridesData.utf8))) ?? [:]
    }

    private var photoOverrides: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(photoOverridesData.utf8))) ?? [:]
    }

    private func displayName(for sender: String) -> String {
        if let override = displayNameOverrides[sender], !override.isEmpty { return override }
        return model.contacts.displayName(for: sender)
    }

    private func photoData(for sender: String) -> Data? {
        guard let base64 = photoOverrides[sender], let data = Data(base64Encoded: base64) else { return nil }
        return data
    }

    private func isPinned(_ sender: String) -> Bool { pinnedSenders.contains(sender) }

    private func togglePin(_ sender: String) {
        var pins = pinnedSenders
        if pins.contains(sender) { pins.remove(sender) } else { pins.insert(sender) }
        if let data = try? JSONEncoder().encode(Array(pins)) {
            pinnedSendersData = String(decoding: data, as: UTF8.self)
        }
    }

    private func deleteSelectedConversations() {
        model.messages.removeAll { selectedSenders.contains($0.sender) }
        if let selection, !model.messages.contains(where: { $0.sender == selection }) {
            self.selection = nil
        }
        selectedSenders.removeAll()
        isSelecting = false
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                // 灰色背景贯穿整个左栏（含顶部导航栏区域），与原生 iMessage 一致。
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                // iPad 左栏宽度（原生 iMessage 约 280-320）。
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 400)
                // toolbar 自动玻璃按钮的着色：浅色黑、深色白，禁止蓝色 accent。
                .tint(.primary)
                .searchable(text: $search, prompt: L10n.t("搜索"))
                .toolbar { sidebarToolbar }
                .task { await model.refreshMessages(silently: true) }
                .onChange(of: pendingRecipient) { recipient in
                    if recipient != nil { showingComposer = true }
                }
                .sheet(isPresented: $showingComposer, onDismiss: { pendingRecipient = nil }) {
                    MessageComposer(initialRecipient: pendingRecipient ?? "")
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showingPinEditor) { pinEditorSheet }
                .sheet(isPresented: $showingNamePhotoEditor) {
                    if let sender = selection ?? allConversations.first?.sender {
                        NamePhotoEditor(
                            sender: sender,
                            displayNameOverrides: $displayNameOverridesData,
                            photoOverrides: $photoOverridesData
                        )
                    }
                }
                .confirmationDialog(L10n.t("删除所选会话"), isPresented: $showingDeleteSelectionConfirmation, titleVisibility: .visible) {
                    Button(L10n.t("删除"), role: .destructive) { deleteSelectedConversations() }
                    Button(L10n.t("取消"), role: .cancel) {}
                } message: {
                    Text("将删除选中的 \(selectedSenders.count) 条会话及其短信记录。")
                }
                .confirmationDialog(L10n.t("清空全部短信"), isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                    Button(L10n.t("删除"), role: .destructive) {
                        Task {
                            try? await model.api.clearModuleSMS()
                            model.clearLocalMessages()
                        }
                    }
                    Button(L10n.t("取消"), role: .cancel) {}
                } message: {
                    Text("这会删除本机短信以及尚未交付的模块短信，无法恢复。")
                }
        } detail: {
            if let sender = selection, let conversation = allConversations.first(where: { $0.sender == sender }) {
                MessageThreadView(
                    sender: sender,
                    messages: conversation.messages,
                    displayName: displayName(for: sender),
                    photoData: photoData(for: sender),
                    onSettings: onSettings
                )
            } else {
                // 无会话占位页：设置按钮仍固定在右上角。
                EmptyStateView(title: L10n.t("选择信息开始聊天"), systemImage: "message")
                    .tint(.primary)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onSettings) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel(L10n.t("设置"))
                        }
                    }
            }
        }
    }

    private var sidebar: some View {
        List {
            if filteredConversations.isEmpty {
                EmptyStateView(title: L10n.t(category.emptyTitle), systemImage: category == .inbox ? "message" : "tray")
                    .listRowBackground(Color.clear)
            } else {
                if !pinnedConversations.isEmpty {
                    Section(L10n.t("置顶")) {
                        ForEach(pinnedConversations, id: \.sender) { conversation in
                            conversationRow(conversation)
                        }
                    }
                }
                Section {
                    ForEach(unpinnedConversations, id: \.sender) { conversation in
                        conversationRow(conversation)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func conversationRow(_ conversation: (sender: String, messages: [SMSMessage])) -> some View {
        Group {
            if isSelecting {
                Button {
                    if selectedSenders.contains(conversation.sender) {
                        selectedSenders.remove(conversation.sender)
                    } else {
                        selectedSenders.insert(conversation.sender)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedSenders.contains(conversation.sender) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedSenders.contains(conversation.sender) ? Color.accentColor : .secondary)
                        MessageConversationRow(
                            sender: conversation.sender,
                            messages: conversation.messages,
                            displayName: displayName(for: conversation.sender),
                            photoData: photoData(for: conversation.sender),
                            isPinned: isPinned(conversation.sender)
                        )
                    }
                }
                .buttonStyle(.plain)
            } else {
                // 选中行：蓝色大圆角块在 label 内部，左右各留 10pt 边距（不贴列边缘，iMessage 图二）。
                Button {
                    selection = conversation.sender
                } label: {
                    MessageConversationRow(
                        sender: conversation.sender,
                        messages: conversation.messages,
                        displayName: displayName(for: conversation.sender),
                        photoData: photoData(for: conversation.sender),
                        isPinned: isPinned(conversation.sender)
                    )
                    .foregroundStyle(selection == conversation.sender ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selection == conversation.sender ? Color.accentColor : Color.clear)
                    )
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .tag(conversation.sender)
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.t("取消")) {
                    isSelecting = false
                    selectedSenders.removeAll()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { showingDeleteSelectionConfirmation = true } label: {
                    Text(selectedSenders.isEmpty ? L10n.t("删除") : "\(L10n.t("删除")) (\(selectedSenders.count))")
                }
                .disabled(selectedSenders.isEmpty)
                .foregroundStyle(.red)
            }
        } else {
            // 编辑按钮：选择信息 / 编辑置顶 / 设置姓名与照片（iMessage 编辑菜单）。
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isSelecting = true
                        selectedSenders.removeAll()
                    } label: {
                        Label(L10n.t("选择信息"), systemImage: "checkmark.circle")
                    }
                    Button { showingPinEditor = true } label: {
                        Label(L10n.t("编辑置顶"), systemImage: "pin")
                    }
                    Button { showingNamePhotoEditor = true } label: {
                        Label(L10n.t("设置姓名与照片"), systemImage: "person.crop.circle.badge.plus")
                    }
                    Divider()
                    Button { Task { await model.refreshMessages() } } label: {
                        Label(L10n.t("刷新"), systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { showingClearConfirmation = true } label: {
                        Label(L10n.t("清空全部短信"), systemImage: "trash")
                    }
                } label: {
                    // iOS 26 自动给 toolbar 按钮套单层液态玻璃（文字=胶囊），无需手动 glassEffect。
                    Text(L10n.t("编辑"))
                }
            }
            // 新建信息：右上角（系统自动玻璃圆形按钮）。
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingComposer = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel(L10n.t("新信息"))
            }
            // 分类三条杠：信息 / 未知发件人 / 垃圾信息 / 最近删除（系统自动玻璃胶囊）。
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: $category) {
                        ForEach(MessagesCategory.allCases) { category in
                            Text(L10n.t(category.rawValue)).tag(category)
                        }
                    } label: {
                        Text(L10n.t("筛选"))
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel(L10n.t("筛选"))
            }
        }
    }

    private var pinEditorSheet: some View {
        NavigationStack {
            List {
                ForEach(allConversations, id: \.sender) { conversation in
                    Button { togglePin(conversation.sender) } label: {
                        HStack(spacing: 12) {
                            InitialAvatar(name: displayName(for: conversation.sender), photoData: photoData(for: conversation.sender), size: 40)
                            Text(displayName(for: conversation.sender))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: isPinned(conversation.sender) ? "pin.fill" : "pin")
                                .foregroundStyle(isPinned(conversation.sender) ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("编辑置顶"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { showingPinEditor = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private struct MessageConversationRow: View {
        let sender: String
        let messages: [SMSMessage]
        let displayName: String
        let photoData: Data?
        let isPinned: Bool

        var body: some View {
            HStack(spacing: 12) {
                InitialAvatar(name: displayName, photoData: photoData)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayName).font(.body.weight(.semibold)).lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(messages.last?.content ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(messages.last?.timestamp ?? .now, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// 聊天详情：正中间上方为 iMessage 式名称（长条形液态玻璃背景），聊天气泡用原版 .glass 材质。
private struct MessageThreadView: View {
    @EnvironmentObject private var model: AppModel
    let sender: String
    let messages: [SMSMessage]
    let displayName: String
    let photoData: Data?
    let onSettings: () -> Void
    @State private var reply = ""

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                // 液态玻璃必须在 GlassEffectContainer 内才渲染真实玻璃材质（iOS 26 官方文档），
                // 气泡、输入栏置于同一容器中相互融合，与 iMessage 一致。
                GlassEffectContainer { threadContent }
            } else {
                threadContent
            }
        }
        // detail 列 toolbar 自动玻璃按钮着色：浅色黑、深色白（气泡/发送键用显式色不受影响）。
        .tint(.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 正中间上方：头像在上、名字玻璃胶囊在头像下方并部分重叠（iMessage 图三/图四）。
            ToolbarItem(placement: .principal) {
                threadHeader
            }
            // 设置入口固定在聊天页右上角（系统自动玻璃圆形，着色跟随 tint primary）。
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.t("设置"))
            }
        }
    }

    private var threadContent: some View {
        VStack(spacing: 0) {
            // iMessage 式头部信息：消息流上方居中显示最后消息时间（如“周四 13:42”）。
            if let last = messages.last {
                Text(headerSubtitle(last.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if let header = dateHeader(for: message.timestamp, previous: index > 0 ? messages[index - 1].timestamp : nil) {
                                // iMessage 风格日期分隔头：跨天时居中显示“今天 / 昨天 / 具体日期”。
                                Text(header)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 48) }
                                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                                    // 直接在 Text 上调用官方 glassEffect（与通话功能键同一可靠范式），
                                    // 发出消息 tint 强调色、收到消息常规玻璃；文字完整多行显示。
                                    Text(message.content)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .modifier(MessageBubbleGlass(isOutgoing: message.isOutgoing))
                                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                                    // iMessage 风格时间戳：气泡下方小字，发出消息显示“已发送 · 时间”，收到消息只显示时间。
                                    Text(message.isOutgoing
                                        ? "\(L10n.t("已发送")) · \(messageTimestamp(message.timestamp))"
                                        : messageTimestamp(message.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if !message.isOutgoing { Spacer(minLength: 48) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear { if let id = messages.last?.id { proxy.scrollTo(id) } }
            }
            // iMessage 风格输入栏：直接在输入栏上调用官方 glassEffect，
            // interactive() 使玻璃在触摸时具备 Q 弹高光反应，胶囊两端全圆角。
            HStack(alignment: .center, spacing: 4) {
                TextField(L10n.t("短信内容"), text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Button {
                    let body = reply
                    reply = ""
                    Task { _ = await model.sendSMS(to: sender, content: body) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.t("发送"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(InputBarGlass())
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// iMessage 式会话头部：仅名称文字，带长条形（胶囊）液态玻璃背景，位置居中。
    /// iMessage 式会话头部：头像在上，名字玻璃胶囊在头像下方并与头像底部部分重叠。
    private var threadHeader: some View {
        VStack(spacing: -14) {
            // 头像在名字上方，尺寸 72（原生 iMessage 比例），名字胶囊与头像底部重叠。
            InitialAvatar(name: displayName, photoData: photoData, size: 72)
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .modifier(HeaderNameGlass())
        }
    }

    /// iMessage 风格日期分隔头：与上一条消息不同天时返回分隔文案（今天/昨天/本地化日期），否则返回 nil。
    private func dateHeader(for date: Date, previous: Date?) -> String? {
        let calendar = Calendar.current
        if let previous, calendar.isDate(date, inSameDayAs: previous) { return nil }
        if calendar.isDateInToday(date) { return L10n.t("今天") }
        if calendar.isDateInYesterday(date) { return L10n.t("昨天") }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")
        return formatter.string(from: date)
    }

    /// iMessage 风格时间戳：跟随系统本地化（如中文“上午 9:41”、英文“9:41 AM”）。
    private func messageTimestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// iMessage 式头部时间：如中文“星期六 22:11”、英文“Sat 22:11”。
    private func headerSubtitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

// MARK: - 液态玻璃复用修饰器（iOS 26 官方 glassEffect，旧系统材质回退）

/// 头部名字长条玻璃胶囊。
private struct HeaderNameGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
    }
}

/// 聊天气泡玻璃：发出消息 tint 强调色，收到消息常规玻璃。
private struct MessageBubbleGlass: ViewModifier {
    let isOutgoing: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                isOutgoing ? .regular.tint(Color.accentColor) : .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isOutgoing ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
            )
        }
    }
}

/// 输入栏玻璃：interactive() 提供触摸 Q 弹高光反应。
private struct InputBarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
    }
}

/// “设置姓名与照片”：为会话覆盖显示姓名与头像（仅本应用内生效）。
private struct NamePhotoEditor: View {
    @Environment(\.dismiss) private var dismiss
    let sender: String
    @Binding var displayNameOverrides: String
    @Binding var photoOverrides: String
    @State private var name: String
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoData: Data? = nil

    init(sender: String, displayNameOverrides: Binding<String>, photoOverrides: Binding<String>) {
        self.sender = sender
        _displayNameOverrides = displayNameOverrides
        _photoOverrides = photoOverrides
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(displayNameOverrides.wrappedValue.utf8))) ?? [:]
        _name = State(initialValue: names[sender] ?? "")
        let photos = (try? JSONDecoder().decode([String: String].self, from: Data(photoOverrides.wrappedValue.utf8))) ?? [:]
        if let base64 = photos[sender], let data = Data(base64Encoded: base64) {
            _photoData = State(initialValue: data)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        InitialAvatar(name: name.isEmpty ? sender : name, photoData: photoData, size: 60)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(L10n.t("选择照片"), systemImage: "photo")
                        }
                        if photoData != nil {
                            Button(L10n.t("清除照片")) { photoData = nil }
                        }
                    }
                }
                Section {
                    TextField(L10n.t("姓名"), text: $name)
                } footer: {
                    Text("仅在本应用中显示，会覆盖通讯录里的名称。")
                }
            }
            .navigationTitle(L10n.t("设置姓名与照片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) { save(); dismiss() }
                }
            }
            .onChange(of: selectedPhotoItem) { _ in
                Task {
                    if let item = selectedPhotoItem,
                       let data = try? await item.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
        }
    }

    private func save() {
        var names = (try? JSONDecoder().decode([String: String].self, from: Data(displayNameOverrides.utf8))) ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: sender)
        } else {
            names[sender] = trimmed
        }
        if let data = try? JSONEncoder().encode(names) {
            displayNameOverrides = String(decoding: data, as: UTF8.self)
        }
        var photos = (try? JSONDecoder().decode([String: String].self, from: Data(photoOverrides.utf8))) ?? [:]
        if let photoData {
            photos[sender] = photoData.base64EncodedString()
        } else {
            photos.removeValue(forKey: sender)
        }
        if let data = try? JSONEncoder().encode(photos) {
            photoOverrides = String(decoding: data, as: UTF8.self)
        }
    }
}

private struct MessageComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var recipient: String
    @State private var content = ""
    @State private var sending = false

    init(initialRecipient: String) { _recipient = State(initialValue: initialRecipient) }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("收件人"), text: $recipient)
                    .keyboardType(.phonePad)
                TextField(L10n.t("短信内容"), text: $content, axis: .vertical)
                    .lineLimit(5...12)
            }
            .navigationTitle(L10n.t("新信息"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("发送")) {
                        sending = true
                        Task {
                            if await model.sendSMS(to: recipient, content: content) { dismiss() }
                            sending = false
                        }
                    }
                    .disabled(sending || recipient.isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 通讯录

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    let onSettings: () -> Void
    @State private var search = ""

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.contains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: L10n.t("授权访问通讯录"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: L10n.t("授权访问通讯录")
                    ) {
                        Task { await model.contacts.requestAccessAndLoad() }
                    }
                } else if filtered.isEmpty {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.2")
                } else {
                    List(filtered) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
                        } label: {
                            HStack(spacing: 12) {
                                InitialAvatar(name: contact.name, photoData: contact.photoData)
                                VStack(alignment: .leading) {
                                    Text(contact.name).font(.body.weight(.semibold))
                                    Text(contact.phones.first ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(L10n.t("通讯录")) · \(model.contacts.contacts.count)")
            .settingsToolbarButton(action: onSettings)
            .searchable(text: $search, prompt: L10n.t("搜索姓名或号码"))
            .task { await model.contacts.loadIfNeeded() }
            .refreshable { await model.contacts.requestAccessAndLoad() }
        }
    }
}

private struct ContactDetailView: View {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        InitialAvatar(name: contact.name, photoData: contact.photoData, size: 82)
                        Text(contact.name).font(.title2.weight(.semibold))
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(contact.phones, id: \.self) { phone in
                    HStack {
                        Text(phone)
                        Spacer()
                        Button { onMessage(phone) } label: { Image(systemName: "message.fill") }
                            .buttonStyle(.borderless)
                        Button { onCall(phone) } label: { Image(systemName: "phone.fill") }
                            .buttonStyle(.borderless).tint(.green)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Color.green.opacity(0.18)).overlay {
                    Text(String(name.prefix(1))).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.green)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

extension View {
    /// 所有主页面复用同一个设置入口，避免设置页在不同页面里位置不一致。
    func settingsToolbarButton(action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: action) {
                    // 跟随系统内容色：浅色模式黑色、深色模式白色，不再使用默认蓝色强调色。
                    Image(systemName: "gearshape")
                        .foregroundStyle(.primary)
                        .tint(.primary)
                }
                .accessibilityLabel(L10n.t("设置"))
            }
        }
    }
}

/// 新系统使用原生 ContentUnavailableView，iOS 16 保留等价回退。
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(emptyStateDescription)
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "收到和发出的短信都会显示在这里。"
        case "phone.arrow.up.right": return "完成通话后，记录会显示在这里。"
        case "person.2": return "联系人会从系统通讯录同步。"
        case "tray": return "这里暂时没有内容。"
        default: return "完成连接或授权后即可使用。"
        }
    }
}

// MARK: - 通话覆盖层

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let call: CallRecord
    @State private var showingKeypad = false

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var avatarSize: CGFloat { isCompact ? 88 : 120 }
    private var controlSize: CGFloat { isCompact ? 62 : 76 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            LinearGradient(
                colors: [Color.green.opacity(0.13), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            GeometryReader { geometry in
                // 小屏或大字体下允许纵向滚动，保证接听、静音和挂断始终可达。
                ScrollView {
                    if isCompact {
                        // 紧凑布局：拨号键盘在控制区下方同屏展开，不占全屏、不影响上方按钮。
                        VStack(spacing: isCompact ? 18 : 26) {
                            callControlsColumn
                            if showingKeypad {
                                DTMFKeypadPanel { showingKeypad = false }
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .frame(minHeight: geometry.size.height)
                        .frame(maxWidth: .infinity)
                    } else {
                        // iPad 常规布局：控制列始终居中不动，拨号键盘以 overlay 在右侧覆盖弹出，
                        // 不参与布局、不挤压按钮（避免按钮错位/重复）。
                        ZStack(alignment: .trailing) {
                            callControlsColumn
                                .frame(minHeight: geometry.size.height)
                                .frame(maxWidth: .infinity)
                            if showingKeypad {
                                DTMFKeypadPanel { showingKeypad = false }
                                    .padding(.trailing, 24)
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showingKeypad)
    }

    private var callControlsColumn: some View {
        VStack(spacing: isCompact ? 16 : 26) {
            Spacer()
            InitialAvatar(name: model.contacts.displayName(for: call.number), size: avatarSize)
            VStack(spacing: 6) {
                Text(model.contacts.displayName(for: call.number))
                    .font(isCompact ? .title.weight(.semibold) : .largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                Text(statusText).font(.headline).foregroundStyle(.secondary)
                if call.state == "active" {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let audioError = model.audio.errorMessage, !audioError.isEmpty {
                    Text(audioError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }

            if call.direction == "incoming" && ["incoming", "waiting"].contains(call.state) {
                HStack(spacing: isCompact ? 54 : 84) {
                    CallCircleButton(title: L10n.t("拒接"), icon: "phone.down.fill", color: .red, isActive: true, size: controlSize) {
                        Task { await model.reject() }
                    }
                    CallCircleButton(title: L10n.t("接听"), icon: "phone.fill", color: .green, isActive: true, size: controlSize) {
                        Task { await model.answer() }
                    }
                }
            } else {
                HStack(spacing: isCompact ? 12 : 28) {
                    CallCircleButton(
                        title: model.isMuted ? L10n.t("取消静音") : L10n.t("静音"),
                        icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                        color: .orange,
                        isActive: model.isMuted,
                        size: controlSize
                    ) {
                        Task { await model.toggleMute() }
                    }
                    CallCircleButton(
                        title: L10n.t("扬声器"),
                        icon: model.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                        color: .blue,
                        isActive: model.isSpeakerEnabled,
                        size: controlSize
                    ) {
                        model.toggleSpeaker()
                    }
                    CallCircleButton(
                        title: "键盘",
                        icon: "circle.grid.3x3.fill",
                        color: .blue,
                        isActive: showingKeypad,
                        size: controlSize
                    ) {
                        showingKeypad.toggle()
                    }
                    CallCircleButton(
                        title: model.isRecording ? L10n.t("停止录音") : L10n.t("录音"),
                        icon: "record.circle",
                        color: .red,
                        isActive: model.isRecording,
                        size: controlSize
                    ) {
                        Task { await model.toggleRecording() }
                    }
                }
                CallCircleButton(title: L10n.t("挂断"), icon: "phone.down.fill", color: .red, isActive: true, size: controlSize) {
                    Task { await model.hangup() }
                }
            }
            Spacer()
        }
        .padding()
    }

    private var statusText: String {
        switch call.state {
        case "active": return L10n.t("通话中")
        case "incoming", "waiting": return L10n.t("等待接听")
        case "held": return "通话保持"
        default: return call.state
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(call.startedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct CallCircleButton: View {
    let title: String
    let icon: String
    let color: Color
    var isActive: Bool = false
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                // 液态玻璃圆：激活状态用 tint 着色 + 白色符号，未激活用无着色玻璃 + 系统内容色。
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isActive ? .white : .primary)
                    .frame(width: size, height: size)
                    .modifier(GlassCircle(tint: isActive ? color : nil))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: size)
        }
        .buttonStyle(.plain)
    }
}

private struct DTMFKeypadPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onClose: () -> Void

    private struct DTMFKey: Identifiable {
        let digit: String
        let letters: String
        var id: String { digit }
    }

    private let rows: [[DTMFKey]] = [
        [DTMFKey(digit: "1", letters: ""), DTMFKey(digit: "2", letters: "ABC"), DTMFKey(digit: "3", letters: "DEF")],
        [DTMFKey(digit: "4", letters: "GHI"), DTMFKey(digit: "5", letters: "JKL"), DTMFKey(digit: "6", letters: "MNO")],
        [DTMFKey(digit: "7", letters: "PQRS"), DTMFKey(digit: "8", letters: "TUV"), DTMFKey(digit: "9", letters: "WXYZ")],
        [DTMFKey(digit: "*", letters: ""), DTMFKey(digit: "0", letters: "+"), DTMFKey(digit: "#", letters: "")],
    ]

    private var isCompact: Bool { horizontalSizeClass == .compact }
    // 比旧的全屏弹层紧凑：按键回归系统拨号键盘尺寸，面板宽度约 240-270pt，在 iPad 上作为侧边面板。
    private var keySize: CGFloat { isCompact ? 56 : 64 }
    private var keySpacing: CGFloat { isCompact ? 12 : 16 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    private var digitFont: Font { .system(size: isCompact ? 22 : 26, weight: .regular, design: .rounded) }
    private var lettersFont: Font { .system(size: isCompact ? 9 : 10, weight: .semibold) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("键盘")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("关闭"))
            }
            // 多个玻璃键放入系统容器（容器间距取 0，静止时保持独立纯圆，官方文档模式）。
            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: keySpacing) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: keySpacing) {
                                    ForEach(row) { key in
                                        Button {
                                            Task { await model.sendDTMF(key.digit) }
                                        } label: {
                                            VStack(spacing: 1) {
                                                Text(key.digit).font(digitFont)
                                                if !key.letters.isEmpty {
                                                    Text(key.letters).font(lettersFont).tracking(1.2)
                                                }
                                            }
                                            .foregroundStyle(.primary)
                                            .frame(width: keySize, height: keySize)
                                            .glassEffect(.regular.interactive(), in: Circle())
                                            .contentShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(key.letters.isEmpty ? key.digit : "\(key.digit) \(key.letters)")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: keySpacing) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: keySpacing) {
                                ForEach(row) { key in
                                    Button {
                                        Task { await model.sendDTMF(key.digit) }
                                    } label: {
                                        VStack(spacing: 1) {
                                            Text(key.digit).font(digitFont)
                                            if !key.letters.isEmpty {
                                                Text(key.letters).font(lettersFont).tracking(1.2)
                                            }
                                        }
                                        .foregroundStyle(.primary)
                                        .frame(width: keySize, height: keySize)
                                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                                        .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(key.letters.isEmpty ? key.digit : "\(key.digit) \(key.letters)")
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: keypadWidth)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        // 固定面板宽度（网格宽+内边距），防止标题行 Spacer 把卡片撑成又宽又扁。
        .frame(width: keypadWidth + 36)
    }
}
