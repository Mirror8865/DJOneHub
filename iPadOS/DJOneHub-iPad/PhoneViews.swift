import SwiftUI
import UIKit
import PhotosUI
import Contacts
import ContactsUI
import Speech
import AVFoundation

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

    @State private var newMessageRecipient: String?
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
            ZStack {
                // 灰底在列最底层，贯穿整个 sidebar（含状态栏/导航栏），顶部无白色留白。
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                sidebar
                    // 导航栏透明，让底层灰贯穿；搜索栏浮于灰底之上。
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            // iPad 左栏加宽（原生 iMessage 全屏约 320-340）。
            .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 430)
            // 搜索框在列表内部（不使用 searchable），避免系统搜索栏背景阻断灰底贯穿状态栏。
            .toolbar { sidebarToolbar }
            // compact 窄窗（Slide Over/Split View）下 NavigationLink 由此 destination push 聊天页。
            .navigationDestination(for: String.self) { sender in
                if let conversation = allConversations.first(where: { $0.sender == sender }) {
                    MessageThreadView(
                        sender: sender,
                        messages: conversation.messages,
                        displayName: displayName(for: sender),
                        photoData: photoData(for: sender)
                    )
                } else {
                    EmptyStateView(title: L10n.t("选择信息开始聊天"), systemImage: "message")
                }
            }
                .task { await model.refreshMessages(silently: true) }
                .onChange(of: pendingRecipient) { recipient in
                    // iMessage 流程：直接进入右侧新消息线程（不弹小窗口）。
                    if let recipient, !recipient.isEmpty { newMessageRecipient = recipient }
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
            if let draft = newMessageRecipient {
                // iMessage 新消息流程：右侧直接是收件人+消息线程，发送后左栏新建会话。
                NewMessageThread(
                    initialRecipient: draft,
                    onCancel: {
                        newMessageRecipient = nil
                        pendingRecipient = nil
                    },
                    onSend: { recipient, body in
                        Task { _ = await model.sendSMS(to: recipient, content: body) }
                        newMessageRecipient = nil
                        pendingRecipient = nil
                        selection = recipient
                    }
                )
            } else if let sender = selection, let conversation = allConversations.first(where: { $0.sender == sender }) {
                MessageThreadView(
                    sender: sender,
                    messages: conversation.messages,
                    displayName: displayName(for: sender),
                    photoData: photoData(for: sender)
                )
            } else {
                // 无会话占位页（设置已在顶层 tab，此处不再放设置图标）。
                EmptyStateView(title: L10n.t("选择信息开始聊天"), systemImage: "message")
            }
        }
    }

    private var sidebar: some View {
        // List(selection:)：regular 双栏下选中驱动右栏；compact 窄窗（Slide Over/Split View）
        // 下 NavigationLink 自动 push 详情，保证小窗可点进聊天。
        List(selection: $selection) {
            searchRow
            if isSelecting {
                selectionModeContent
            } else if filteredConversations.isEmpty {
                EmptyStateView(title: L10n.t(category.emptyTitle), systemImage: category == .inbox ? "message" : "tray")
                    .listRowBackground(Color.clear)
            } else {
                if !pinnedConversations.isEmpty {
                    Section(L10n.t("置顶")) {
                        ForEach(pinnedConversations, id: \.sender) { conversation in
                            conversationLink(conversation)
                        }
                    }
                }
                Section {
                    ForEach(unpinnedConversations, id: \.sender) { conversation in
                        conversationLink(conversation)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // 选中块随 selection 缓慢淡入。
        .animation(.easeOut(duration: 0.2), value: selection)
    }

    /// 列表内搜索框（玻璃灰胶囊，带麦克风语音输入）。
    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(L10n.t("搜索"), text: $search)
                .textFieldStyle(.plain)
                .font(.subheadline)
            Spacer()
            DictationButton { text in search = text }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowBackground(Color.clear)
    }

    /// 选择模式：按"连续选中 / 连续未选中"把行分组，连续选中行融为一个大蓝色圆角矩形。
    private enum RowGroup {
        case selectedGroup([(sender: String, messages: [SMSMessage])])
        case plainGroup([(sender: String, messages: [SMSMessage])])
    }

    private var selectionGroups: [RowGroup] {
        var groups: [RowGroup] = []
        var currentSelected: [(sender: String, messages: [SMSMessage])] = []
        var currentPlain: [(sender: String, messages: [SMSMessage])] = []
        for conversation in filteredConversations {
            if selectedSenders.contains(conversation.sender) {
                if !currentPlain.isEmpty { groups.append(.plainGroup(currentPlain)); currentPlain = [] }
                currentSelected.append(conversation)
            } else {
                if !currentSelected.isEmpty { groups.append(.selectedGroup(currentSelected)); currentSelected = [] }
                currentPlain.append(conversation)
            }
        }
        if !currentSelected.isEmpty { groups.append(.selectedGroup(currentSelected)) }
        if !currentPlain.isEmpty { groups.append(.plainGroup(currentPlain)) }
        return groups
    }

    @ViewBuilder
    private var selectionModeContent: some View {
        ForEach(Array(selectionGroups.enumerated()), id: \.offset) { _, group in
            switch group {
            case .selectedGroup(let items):
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.sender) { idx, conversation in
                        selectableRow(conversation, inBlue: true, isLast: idx == items.count - 1)
                    }
                }
                .background(
                    // 融合块：一个大蓝色连续圆角矩形（圆角 20pt）。
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(uiColor: .systemBlue))
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                .listRowBackground(Color.clear)
            case .plainGroup(let items):
                ForEach(items, id: \.sender) { conversation in
                    selectableRow(conversation, inBlue: false, isLast: true)
                }
            }
        }
    }

    /// 选择模式单行。inBlue：位于融合蓝块内（白色 check 圆 + 白字 + 组内细分割线）。
    @ViewBuilder
    private func selectableRow(_ conversation: (sender: String, messages: [SMSMessage]), inBlue: Bool, isLast: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                if selectedSenders.contains(conversation.sender) {
                    selectedSenders.remove(conversation.sender)
                } else {
                    selectedSenders.insert(conversation.sender)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: inBlue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(inBlue ? Color.white : Color(uiColor: .systemGray3))
                MessageConversationRow(
                    sender: conversation.sender,
                    messages: conversation.messages,
                    displayName: displayName(for: conversation.sender),
                    photoData: photoData(for: conversation.sender),
                    isPinned: isPinned(conversation.sender),
                    highlighted: inBlue
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                // 融合块内行间细分割线（半透明白，缩进对齐文字）。
                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 0.5)
                        .padding(.leading, 46)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// 普通模式行：NavigationLink（compact 自动 push），选中蓝块由 listRowBackground 呈现。
    @ViewBuilder
    private func conversationLink(_ conversation: (sender: String, messages: [SMSMessage])) -> some View {
        NavigationLink(value: conversation.sender) {
            MessageConversationRow(
                sender: conversation.sender,
                messages: conversation.messages,
                displayName: displayName(for: conversation.sender),
                photoData: photoData(for: conversation.sender),
                isPinned: isPinned(conversation.sender),
                highlighted: selection == conversation.sender
            )
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(selection == conversation.sender ? Color(uiColor: .systemBlue) : Color.clear)
        )
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
                .tint(Color.primary)
            }
            // 新建信息：iMessage 流程，右侧直接进入新消息线程（系统自动玻璃圆形按钮）。
            ToolbarItem(placement: .topBarTrailing) {
                Button { newMessageRecipient = "" } label: {
                    Image(systemName: "square.and.pencil")
                }
                .tint(Color.primary)
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
                .tint(Color.primary)
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
                                .foregroundStyle(isPinned(conversation.sender) ? Color(uiColor: .systemBlue) : .secondary)
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
        var highlighted: Bool = false

        var body: some View {
            HStack(spacing: 12) {
                InitialAvatar(name: displayName, photoData: photoData)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayName).font(.body.weight(.semibold)).lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill").font(.caption2)
                                .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
                        }
                    }
                    Text(messages.last?.content ?? "")
                        .font(.subheadline)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                // 右侧最近消息时间：今天时分、本周星期几、更早日期（iMessage 规则）。
                Text(rowTimestampText(messages.last?.timestamp ?? .now))
                    .font(.caption2)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.vertical, 4)
        }

        /// 行右侧时间：今天显示时分；本周显示星期几；更早显示日期（与 iMessage 一致）。
        private func rowTimestampText(_ date: Date) -> String {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return date.formatted(date: .omitted, time: .shortened)
            }
            if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date()),
               weekInterval.contains(date) {
                return date.formatted(.dateTime.weekday(.wide))
            }
            return date.formatted(.dateTime.year().month().day())
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
    @State private var reply = ""
    @State private var showContactInfo = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                if #available(iOS 26.0, *) {
                    // 液态玻璃必须在 GlassEffectContainer 内才渲染真实玻璃材质（iOS 26 官方文档），
                    // 气泡、输入栏置于同一容器中相互融合，与 iMessage 一致。
                    GlassEffectContainer { threadContent }
                } else {
                    threadContent
                }
            }
            if showContactInfo {
                // 联系人信息面板从右侧滑出（结构严格按原生 iMessage）。
                ContactInfoPanel(
                    displayName: displayName,
                    photoData: photoData,
                    phone: sender,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showContactInfo = false }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var threadContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        // 头像+名字头部位于内容顶部（避开顶部全局控件，随内容滚动）。
                        threadHeader
                            .padding(.top, 10)
                            .padding(.bottom, 8)
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if let header = dateHeader(for: message.timestamp, previous: index > 0 ? messages[index - 1].timestamp : nil) {
                                // 日期分隔居中显示（今天/昨天/具体日期），位于 ScrollView 内跟随滚动。
                                Text(header)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 48) }
                                // 气泡直接在 Text 上调用官方 glassEffect；气泡下方不显示时间。
                                Text(message.content)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .modifier(MessageBubbleGlass(isOutgoing: message.isOutgoing))
                                    .foregroundStyle(message.isOutgoing ? .white : .primary)
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
                        .foregroundStyle(Color(uiColor: .systemBlue))
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
            // 名字玻璃胶囊可点（内含 chevron），点击右侧滑出联系人信息面板。
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showContactInfo = true }
            } label: {
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
            .buttonStyle(.plain)
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
}

// MARK: - 联系人信息面板（原生 iMessage 右侧滑出）

/// 联系人信息面板：结构严格按原生 iMessage——顶部 xmark/编辑、头像名字、
/// 电话/FaceTime/邮件三圆钮、资料/背景分段、资料卡、新建/添加联系人、
/// 三个开关、屏蔽联系人、联系人密钥验证、端到端加密说明小字。
private struct ContactInfoPanel: View {
    let displayName: String
    let photoData: Data?
    let phone: String
    let onClose: () -> Void

    @State private var selectedSegment = 0
    @State private var blockedSenders: Set<String> = Set(
        (try? JSONDecoder().decode([String].self,
            from: Data((UserDefaults.standard.string(forKey: "djonehub.blocked-senders") ?? "").utf8))) ?? []
    )
    @State private var showingExistingPicker = false
    @State private var showingKeyVerification = false
    @State private var saveNotice = ""

    private var isBlocked: Bool { blockedSenders.contains(phone) }

    var body: some View {
        // GeometryReader 强制面板靠右对齐（不依赖 ZStack 推断），宽度固定 360，
        // 窄窗（compact）时宽度自适应为窗口宽度。
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                panel
                    .frame(width: min(360, geo.size.width))
            }
        }
        .tint(Color(uiColor: .systemBlue))
    }

    private var panel: some View {
        ScrollView {
            VStack(spacing: 14) {
                InitialAvatar(name: displayName, photoData: photoData, size: 100)
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // 电话 / FaceTime / 邮件三圆钮。
                HStack(spacing: 22) {
                    Button {
                        if let url = URL(string: "tel:\(phone)") { UIApplication.shared.open(url) }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 19))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color(uiColor: .systemGray5)))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("电话"))

                    // FaceTime：本 app 不支持，灰圆禁用态。
                    Image(systemName: "video.fill")
                        .font(.system(size: 19))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color(uiColor: .systemGray5)))
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                        .accessibilityLabel("FaceTime")

                    // 邮件：无邮件地址，黑圆禁用态（与蓝本视觉一致）。
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 18))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color(uiColor: .label)))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .accessibilityLabel(L10n.t("邮件"))
                }

                // 资料 / 背景分段。
                Picker("", selection: $selectedSegment) {
                    Text(L10n.t("资料")).tag(0)
                    Text(L10n.t("背景")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)

                if selectedSegment == 0 {
                    infoSection
                } else {
                    // 背景分段：iMessage 共享背景，本 app 不支持，空状态。
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(L10n.t("暂无共享背景"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            // 顶部为绝对定位的关闭/编辑按钮预留空间。
            .padding(.top, 58)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        // 关闭按钮：overlay 绝对定位在左上角（保证任何布局下可见可点）。
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .modifier(PanelCircleGlass())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 10)
            .accessibilityLabel(L10n.t("关闭"))
        }
        // 编辑按钮：overlay 绝对定位在右上角。
        .overlay(alignment: .topTrailing) {
            Button {
                Task {
                    let ok = await ContactWriter.newContact(phone: phone)
                    saveNotice = ok ? L10n.t("已新建联系人") : L10n.t("需要通讯录权限")
                }
            } label: {
                Text(L10n.t("编辑"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .modifier(PanelCapsuleGlass())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 10)
        }
        .sheet(isPresented: $showingExistingPicker) {
            ExistingContactPicker { identifier in
                Task {
                    let ok = await ContactWriter.add(to: identifier, phone: phone)
                    saveNotice = ok ? L10n.t("已添加到联系人") : L10n.t("保存失败")
                    showingExistingPicker = false
                }
            }
            .presentationSizingIfAvailable()
        }
        .alert(L10n.t("联系人密钥验证"), isPresented: $showingKeyVerification) {
            Button(L10n.t("好"), role: .cancel) {}
        } message: {
            Text("DJOneHub 短信经模块蜂窝网络传输，不支持 iMessage 联系人密钥验证。")
        }
        .alert("", isPresented: Binding(get: { !saveNotice.isEmpty }, set: { if !$0 { saveNotice = "" } })) {
            Button(L10n.t("好"), role: .cancel) { saveNotice = "" }
        } message: {
            Text(saveNotice)
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        // 电话资料卡。
        infoCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("电话"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(phone)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "phone.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }

        // 新建联系人 / 添加到现有联系人。
        infoCard {
            VStack(spacing: 0) {
                Button {
                    Task {
                        let ok = await ContactWriter.newContact(phone: phone)
                        saveNotice = ok ? L10n.t("已新建联系人") : L10n.t("需要通讯录权限")
                    }
                } label: {
                    HStack {
                        Text(L10n.t("新建联系人"))
                        Spacer()
                    }
                }
                .padding(.vertical, 10)
                Divider()
                Button {
                    showingExistingPicker = true
                } label: {
                    HStack {
                        Text(L10n.t("添加到现有联系人"))
                        Spacer()
                    }
                }
                .padding(.vertical, 10)
            }
        }

        // 三个开关（隐藏提醒 / 发送已读回执 / 共享专注模式状态）。
        infoCard {
            ContactToggleCard(phone: phone)
        }

        // 屏蔽联系人（红字）。
        infoCard {
            Button {
                var set = blockedSenders
                if set.contains(phone) { set.remove(phone) } else { set.insert(phone) }
                blockedSenders = set
                if let data = try? JSONEncoder().encode(Array(set)) {
                    UserDefaults.standard.set(String(decoding: data, as: UTF8.self),
                                             forKey: "djonehub.blocked-senders")
                }
            } label: {
                HStack {
                    Text(isBlocked ? L10n.t("取消屏蔽联系人") : L10n.t("屏蔽联系人"))
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }

        // 打开联系人密钥验证（蓝字）。
        infoCard {
            Button {
                showingKeyVerification = true
            } label: {
                HStack {
                    Text(L10n.t("打开联系人密钥验证"))
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }

        // 端到端加密说明小字（DJOneHub 版本文案）。
        Text("所有DJOneHub信息对话均未采用安全的端对端加密，在设备间发送时可能被读取。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.top, 2)
    }

    private func infoCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .systemGray5))
            )
    }
}

/// 三开关卡片：隐藏提醒 / 发送已读回执 / 共享专注模式状态（按号码持久化）。
private struct ContactToggleCard: View {
    let phone: String

    @AppStorage private var hideAlerts: Bool
    @AppStorage private var sendReadReceipts: Bool
    @AppStorage private var shareFocus: Bool

    init(phone: String) {
        self.phone = phone
        _hideAlerts = AppStorage(wrappedValue: false, "djonehub.contact.\(phone).hide-alerts")
        _sendReadReceipts = AppStorage(wrappedValue: false, "djonehub.contact.\(phone).send-read-receipts")
        _shareFocus = AppStorage(wrappedValue: false, "djonehub.contact.\(phone).share-focus")
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle(L10n.t("隐藏提醒"), isOn: $hideAlerts)
                .padding(.vertical, 4)
            Divider()
            Toggle(L10n.t("发送已读回执"), isOn: $sendReadReceipts)
                .padding(.vertical, 4)
            Divider()
            Toggle(L10n.t("共享专注模式状态"), isOn: $shareFocus)
                .padding(.vertical, 4)
        }
    }
}

/// 现有联系人选择列表（添加到现有联系人）。
private struct ExistingContactPicker: View {
    @EnvironmentObject private var model: AppModel
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { contact in
                    Button {
                        onPick(contact.id)
                    } label: {
                        HStack(spacing: 12) {
                            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 40)
                            Text(contact.name).font(.body)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("添加到现有联系人"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L10n.t("搜索"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("取消")) { dismiss() }
                }
            }
            .task { await model.contacts.loadIfNeeded() }
        }
    }

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}

/// 联系人写入工具（系统通讯录 CNContactStore）。
@MainActor
private enum ContactWriter {
    /// 新建仅含该号码的联系人。
    static func newContact(phone: String) async -> Bool {
        let store = CNContactStore()
        do {
            let granted = try await requestAccess(store)
            guard granted else { return false }
            let contact = CNMutableContact()
            contact.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))
            ]
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try store.execute(request)
            return true
        } catch {
            return false
        }
    }

    /// 把号码追加到指定现有联系人。
    static func add(to identifier: String, phone: String) async -> Bool {
        let store = CNContactStore()
        do {
            let granted = try await requestAccess(store)
            guard granted else { return false }
            let keys: [CNKeyDescriptor] = [CNContactPhoneNumbersKey as CNKeyDescriptor]
            guard let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
                .mutableCopy() as? CNMutableContact else { return false }
            var numbers = contact.phoneNumbers
            numbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain,
                                          value: CNPhoneNumber(stringValue: phone)))
            contact.phoneNumbers = numbers
            let request = CNSaveRequest()
            request.update(contact)
            try store.execute(request)
            return true
        } catch {
            return false
        }
    }

    private static func requestAccess(_ store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

/// 面板顶部圆形玻璃按钮（xmark）。
private struct PanelCircleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(Circle().fill(.regularMaterial))
        }
    }
}

/// 面板顶部胶囊玻璃按钮（编辑）。
private struct PanelCapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(Capsule().fill(.regularMaterial))
        }
    }
}

// MARK: - iMessage 式新消息线程

/// iMessage 式新消息线程：右侧直接输入收件人与消息，发送后左栏新建会话（不弹小窗口）。
private struct NewMessageThread: View {
    @EnvironmentObject private var model: AppModel
    let initialRecipient: String
    let onCancel: () -> Void
    let onSend: (String, String) -> Void

    @State private var recipient = ""
    @State private var bodyText = ""

    private var trimmedRecipient: String {
        recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收件人解析：匹配联系人则用其号码，否则直接使用输入文本。
    private var resolvedRecipient: String? {
        let text = trimmedRecipient
        guard !text.isEmpty else { return nil }
        if let contact = model.contacts.contacts.first(where: { contact in
            contact.phones.contains(text) || contact.name.localizedCaseInsensitiveContains(text)
        }) {
            return contact.phones.first ?? text
        }
        return text
    }

    private var matches: [ContactStore.Contact] {
        let text = trimmedRecipient
        guard !text.isEmpty else { return [] }
        return Array(model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(text)
                || contact.phones.contains { $0.contains(text) }
        }.prefix(4))
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer { content }
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 仅保留左上角“取消”（iMessage 新消息页一致）。
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.t("取消"), action: onCancel)
                    .tint(Color.primary)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 收件人玻璃胶囊（与下方短信输入栏一致的液态玻璃）。
            HStack(spacing: 8) {
                Text(L10n.t("收件人"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("输入号码或姓名"), text: $recipient)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(InputBarGlass())
            .padding(.horizontal)
            .padding(.top, 10)
            // 匹配联系人列表。
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { contact in
                        Button {
                            recipient = contact.phones.first ?? contact.name
                        } label: {
                            HStack(spacing: 12) {
                                InitialAvatar(name: contact.name, photoData: contact.photoData, size: 38)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(contact.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(contact.phones.first ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Spacer()
            // 消息输入栏（收件人未解析时禁用发送）。
            HStack(alignment: .center, spacing: 4) {
                TextField(L10n.t("短信内容"), text: $bodyText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Button {
                    guard let r = resolvedRecipient else { return }
                    let b = bodyText
                    bodyText = ""
                    onSend(r, b)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Color(uiColor: .systemBlue))
                }
                .buttonStyle(.plain)
                .disabled(resolvedRecipient == nil || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.t("发送"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(InputBarGlass())
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onAppear {
            if recipient.isEmpty { recipient = initialRecipient }
        }
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
                isOutgoing ? .regular.tint(Color(uiColor: .systemBlue)) : .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isOutgoing ? Color(uiColor: .systemBlue) : Color(uiColor: .secondarySystemBackground))
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

/// 联系人：原生双栏（与系统“联系人”app 一致）。
/// 左栏：侧栏切换按钮、新建按钮、列表内搜索框（带麦克风）、我的名片、联系人列表；
/// 右栏：CNContactViewController 原生详情（大头像、信息/电话/FaceTime/邮件圆钮、资料行、编辑）。
/// 窄窗（Slide Over/Split View）下自动 stack：列表 push 详情，详情可返回。
struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    @State private var search = ""
    @State private var selection: String?
    @State private var showNewContact = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var meIdentifier: String?

    private let cnStore = CNContactStore()

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.contains(search) }
        }
    }

    /// 按 identifier 重新拉取完整 CNContact（CNContactViewController 要求完整 keys）。
    private func fetchCNContact(_ identifier: String) -> CNContact? {
        try? cnStore.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: [CNContactViewController.descriptorForRequiredKeys()]
        )
    }

    private func loadMeIdentifier() {
        guard meIdentifier == nil else { return }
        meIdentifier = try? cnStore.unifiedMeContact(
            withKeysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
        ).identifier
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                contactSidebar
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 430)
            .toolbar { contactSidebarToolbar }
            // compact 窄窗下 push 原生联系人详情。
            .navigationDestination(for: String.self) { identifier in
                if let cnContact = fetchCNContact(identifier) {
                    ContactNativeDetail(
                        contact: cnContact,
                        contactStore: cnStore,
                        onCall: onCall,
                        onMessage: onMessage
                    )
                } else {
                    EmptyStateView(title: L10n.t("选择联系人查看详情"), systemImage: "person.crop.circle")
                }
            }
            .task {
                await model.contacts.loadIfNeeded()
                loadMeIdentifier()
            }
        } detail: {
            NavigationStack {
                if let selection, let cnContact = fetchCNContact(selection) {
                    ContactNativeDetail(
                        contact: cnContact,
                        contactStore: cnStore,
                        onCall: onCall,
                        onMessage: onMessage
                    )
                } else {
                    EmptyStateView(title: L10n.t("选择联系人查看详情"), systemImage: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showNewContact, onDismiss: {
            Task { await model.contacts.requestAccessAndLoad() }
        }) {
            ContactNativeNew(contactStore: cnStore)
        }
    }

    private var contactSidebar: some View {
        List(selection: $selection) {
            // 搜索框（列表内，带麦克风语音输入）。
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("搜索"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                Spacer()
                DictationButton { text in search = text }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            .listRowBackground(Color.clear)

            // 我的名片。
            if let meIdentifier, let me = model.contacts.contacts.first(where: { $0.id == meIdentifier }) {
                contactLink(me, isMe: true)
            }

            // 联系人列表（我的名片不重复显示）。
            ForEach(filtered.filter { $0.id != meIdentifier }) { contact in
                contactLink(contact, isMe: false)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.easeOut(duration: 0.2), value: selection)
    }

    @ViewBuilder
    private func contactLink(_ contact: ContactStore.Contact, isMe: Bool) -> some View {
        NavigationLink(value: contact.id) {
            HStack(spacing: 12) {
                InitialAvatar(name: contact.name, photoData: contact.photoData)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(isMe ? L10n.t("我的名片") : (contact.phones.first ?? ""))
                        .font(.caption)
                        .foregroundStyle(selection == contact.id ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(selection == contact.id ? Color(uiColor: .systemBlue) : Color.clear)
        )
    }

    @ToolbarContentBuilder
    private var contactSidebarToolbar: some ToolbarContent {
        // 左上：侧栏显隐切换（系统联系人 app 同款 sidebar 按钮）。
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .tint(Color.primary)
            .accessibilityLabel(L10n.t("显示或隐藏列表"))
        }
        // 右上：新建联系人（弹出系统原生新建窗口）。
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNewContact = true } label: {
                Image(systemName: "plus")
            }
            .tint(Color.primary)
            .accessibilityLabel(L10n.t("新建联系人"))
        }
    }
}

/// CNContactViewController 原生联系人详情（SwiftUI 包装）。
/// 自动渲染系统头像、信息/电话/FaceTime/邮件圆钮、资料行与右上角编辑按钮。
private struct ContactNativeDetail: UIViewControllerRepresentable {
    let contact: CNContact
    let contactStore: CNContactStore
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    func makeUIViewController(context: Context) -> CNContactViewController {
        let vc = CNContactViewController(for: contact)
        vc.contactStore = contactStore
        vc.delegate = context.coordinator
        vc.allowsEditing = true
        vc.allowsActions = true
        return vc
    }

    func updateUIViewController(_ vc: CNContactViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCall: onCall, onMessage: onMessage)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onCall: (String) -> Void
        let onMessage: (String) -> Void

        init(onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) {
            self.onCall = onCall
            self.onMessage = onMessage
        }

        /// 拦截电话/信息属性动作，改走本 app 模块；其余动作走系统默认。
        func contactViewController(
            _ viewController: CNContactViewController,
            shouldPerformDefaultActionFor property: CNContactProperty
        ) -> Bool {
            if let phone = property.value as? CNPhoneNumber {
                onCall(phone.stringValue)
                return false
            }
            return true
        }
    }
}

/// CNContactViewController 原生新建联系人（modal 中央窗口，系统自动渲染
/// X/✓ 按钮、头像与“添加照片”、姓氏/名字/公司、添加电话/电子邮件等）。
private struct ContactNativeNew: UIViewControllerRepresentable {
    let contactStore: CNContactStore

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CNContactViewController(forNewContact: nil)
        vc.contactStore = contactStore
        vc.delegate = context.coordinator
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(contactStore: contactStore)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let contactStore: CNContactStore

        init(contactStore: CNContactStore) {
            self.contactStore = contactStore
        }

        /// 点 ✓：系统回传填写好的联系人，由本方法执行真实保存；点取消：contact 为 nil。
        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            if let contact, let mutable = contact.mutableCopy() as? CNMutableContact {
                let request = CNSaveRequest()
                request.add(mutable, toContainerWithIdentifier: nil)
                try? contactStore.execute(request)
            }
            viewController.dismiss(animated: true)
        }
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var size: CGFloat = 44

    // 系统联系人 / iMessage 默认 monogram 灰色渐变（使用系统灰阶动态色，
    // 浅色/深色模式自动适配，视觉等同系统原生默认头像背景）。
    private static let lightTop = UIColor(red: 0.72, green: 0.75, blue: 0.80, alpha: 1)
    private static let lightBottom = UIColor(red: 0.53, green: 0.57, blue: 0.64, alpha: 1)
    private static let darkTop = UIColor(red: 0.38, green: 0.42, blue: 0.50, alpha: 1)
    private static let darkBottom = UIColor(red: 0.25, green: 0.29, blue: 0.37, alpha: 1)

    private static func dynamicColor(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    /// 姓名 monogram：中文取首字；英文取姓/名首字母（最多 2 字符）；无有效姓名返回 nil（显示小人）。
    private var monogram: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first?.isASCII == true {
            let parts = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if parts.count >= 2 {
                return String(parts[0].prefix(1) + parts[parts.count - 1].prefix(1)).uppercased()
            }
            return String(trimmed.prefix(2)).uppercased()
        }
        return String(trimmed.prefix(1))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // 默认头像：系统灰色渐变圆 + 白色 monogram（或 person.fill 小人）。
                // 渐变与白色均为显式着色，不受选中蓝块的 foregroundStyle 影响。
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(Self.dynamicColor(Self.lightTop, Self.darkTop)),
                                Color(Self.dynamicColor(Self.lightBottom, Self.darkBottom))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if let monogram {
                            Text(monogram)
                                .font(.system(size: size * 0.42, weight: .medium))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.48, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
                    // 控制列始终居中不动（compact / regular 同一结构）。
                    callControlsColumn
                        .frame(minHeight: geometry.size.height)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)

                // 拨号键盘：悬浮窗形式居中弹出（不贴右、不贴下、不参与布局、
                // 不挤压/移动控制列），弹簧缩放+淡入，键盘自带关闭按钮。
                if showingKeypad {
                    DTMFKeypadPanel {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showingKeypad = false
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .center)))
                }
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
                        // 悬浮窗式弹出（弹簧缩放+淡入），不是滑出。
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showingKeypad.toggle()
                        }
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
    // 紧凑系统键盘尺寸：面板宽度约 220-240pt，居中悬浮不占位过大。
    private var keySize: CGFloat { isCompact ? 56 : 60 }
    private var keySpacing: CGFloat { isCompact ? 12 : 14 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    private var digitFont: Font { .system(size: isCompact ? 22 : 24, weight: .regular, design: .rounded) }
    private var lettersFont: Font { .system(size: isCompact ? 9 : 10, weight: .semibold) }

    var body: some View {
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
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        // 关闭按钮在面板右上角（不额外占标题行，压缩整体高度）。
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(L10n.t("关闭"))
        }
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        // 固定面板宽度（网格宽+内边距），防止卡片被撑成又宽又扁。
        .frame(width: keypadWidth + 32)
    }
}

/// 麦克风语音输入按钮（Speech 框架，识别结果实时回调填入搜索框）。
/// 录音中按钮变红；再次点击结束。
struct DictationButton: View {
    let onText: (String) -> Void

    @State private var recognizer: SFSpeechRecognizer?
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    @State private var isRecording = false

    var body: some View {
        Button {
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            Image(systemName: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRecording ? Color(uiColor: .systemRed) : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("语音输入"))
    }

    private func startRecording() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { return }
                beginRecognition()
            }
        }
    }

    @MainActor
    private func beginRecognition() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            return
        }

        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { result, _ in
            if let result {
                onText(result.bestTranscription.formattedString)
            }
        }
        isRecording = true
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
