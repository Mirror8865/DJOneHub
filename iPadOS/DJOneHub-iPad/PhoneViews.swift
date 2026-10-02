import SwiftUI
import UIKit
import CoreFoundation
import PhotosUI
import Contacts
import ContactsUI
import Speech
import AVFoundation

// MARK: - 纯逻辑辅助

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
            return L10n.t("昨天")
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

/// 系统 iOS 26 液态玻璃圆钮；旧系统回退为系统填充圆。
/// 组合取自官方文档：`.regular[.tint(...)].interactive()` + `in: Circle()`。
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

// MARK: - 拨号

/// 拨号键盘：版式严格对齐系统「电话」App 键盘页——大号号码、3×4 圆键、
/// 绿色呼叫键与删除键同一行。没有自绘顶栏，导航栏由系统渲染，
/// iPad 窗口左上角的关闭/最大化/最小化控件不会与任何内容重叠。
struct DialPadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var deleteRepeatTask: Task<Void, Never>?
    @State private var deletePressed = false
    @State private var zeroWasLongPressed = false
    @State private var showingModuleStatus = false

    private let rows: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var keySize: CGFloat { isCompact ? 74 : 84 }
    private var keySpacing: CGFloat { isCompact ? 26 : 34 }
    private var rowSpacing: CGFloat { isCompact ? 12 : 16 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    private var matchedName: String? { model.contacts.contact(for: model.numberInput)?.name }
    private var callDisabled: Bool { model.numberInput.isEmpty || model.isBusy || !model.isOnline }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.isOnline {
                    offlineBanner
                }
                Spacer(minLength: 8)
                numberDisplay
                Spacer(minLength: 10)
                keypad
                callRow
                    .padding(.top, rowSpacing + 4)
                Spacer(minLength: 12)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle(L10n.t("拨号"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingModuleStatus = true
                    } label: {
                        Image(systemName: model.isOnline ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    }
                    .accessibilityLabel(L10n.t("模块状态"))
                }
            }
        }
        .sheet(isPresented: $showingModuleStatus) {
            ModuleStatusSheet()
                .environmentObject(model)
        }
    }

    /// 离线时才出现的提示条：说明为什么拨号不可用，并提供去设置页的入口。
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(model.connectionMessage ?? L10n.t("模块未连接，请检查 USB 与网络"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var numberDisplay: some View {
        VStack(spacing: 2) {
            Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                .font(.system(size: isCompact ? 36 : 42, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.numberInput.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(height: 50)

            Text(matchedName ?? " ")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.green)
                .lineLimit(1)
                .frame(height: 20)
        }
        .padding(.horizontal, 16)
    }

    private var keypad: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    keypadRows
                }
            } else {
                keypadRows
            }
        }
        .frame(width: keypadWidth)
    }

    private var keypadRows: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(row, id: \.0) { digit, letters in
                        dialKey(digit: digit, letters: letters)
                    }
                }
            }
        }
    }

    private var callRow: some View {
        HStack(spacing: keySpacing) {
            Color.clear.frame(width: keySize, height: keySize)

            Button {
                Task { await model.dial() }
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: isCompact ? 26 : 29, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: keySize, height: keySize)
                    .modifier(GlassCircle(tint: .green))
            }
            .buttonStyle(.plain)
            .disabled(callDisabled)
            .opacity(callDisabled ? 0.4 : 1)
            .accessibilityLabel(L10n.t("呼叫"))

            deleteControl
        }
        .frame(width: keypadWidth)
    }

    private var deleteControl: some View {
        Image(systemName: "delete.left")
            .font(.system(size: isCompact ? 22 : 24))
            .foregroundStyle(.primary)
            .frame(width: keySize, height: keySize)
            .contentShape(Rectangle())
            .opacity(model.numberInput.isEmpty ? 0.35 : 1)
            .allowsHitTesting(!model.numberInput.isEmpty)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !deletePressed else { return }
                        deletePressed = true
                        deleteOnce()
                        deleteRepeatTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(420))
                            while !Task.isCancelled, !model.numberInput.isEmpty {
                                deleteOnce()
                                try? await Task.sleep(for: .milliseconds(90))
                            }
                        }
                    }
                    .onEnded { _ in
                        deletePressed = false
                        deleteRepeatTask?.cancel()
                        deleteRepeatTask = nil
                    }
            )
            .accessibilityLabel(L10n.t("删除"))
            .accessibilityHint(L10n.t("轻点删除一位，长按连续删除"))
            .accessibilityAddTraits(.isButton)
    }

    private func deleteOnce() {
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    @ViewBuilder
    private func dialKey(digit: String, letters: String) -> some View {
        Button {
            // 长按 0 已输入加号；抬手时忽略 Button 的默认点击，避免得到「0+」。
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            model.numberInput.append(digit)
            UIDevice.current.playInputClick()
        } label: {
            Group {
                if #available(iOS 26.0, *) {
                    keyLabel(digit: digit, letters: letters)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .contentShape(Circle())
                } else {
                    keyLabel(digit: digit, letters: letters)
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

    private func keyLabel(digit: String, letters: String) -> some View {
        VStack(spacing: 1) {
            Text(digit)
                .font(.system(size: isCompact ? 32 : 35, weight: .regular, design: .rounded))
            Text(letters)
                .font(.system(size: isCompact ? 10 : 11, weight: .semibold))
                .tracking(1.4)
        }
        .foregroundStyle(.primary)
        .frame(width: keySize, height: keySize)
    }
}

// MARK: - 模块状态

/// 模块状态弹层：系统设置式分组表单，不再自绘玻璃卡片。
struct ModuleStatusSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var modem: ModemStatus? { model.modemStatus }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(L10n.t("模块代理")) {
                        Text(model.isOnline ? L10n.t("在线") : L10n.t("离线"))
                            .foregroundStyle(model.isOnline ? Color.green : Color.red)
                    }
                    LabeledContent("Agent", value: model.agentVersion ?? (model.isOnline ? L10n.t("读取中") : "--"))
                } footer: {
                    if !model.isOnline, let message = model.connectionMessage, !message.isEmpty {
                        Text(message)
                    }
                }
                Section(L10n.t("网络")) {
                    LabeledContent(L10n.t("运营商"), value: modem?.operatorName ?? "--")
                    LabeledContent(L10n.t("网络模式"), value: modem?.networkMode ?? "--")
                    LabeledContent(L10n.t("信号强度"), value: modem?.signalDBM.map { "\($0) dBm" } ?? "--")
                    LabeledContent(L10n.t("SIM 卡"), value: modem?.simInserted == true ? L10n.t("已接入") : L10n.t("未接入"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("模块状态"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
// MARK: - 最近通话

/// 最近通话：系统「电话」App 版式——顶部分段控件（全部 / 未接）、
/// 每行「图标 + 姓名 + 类型 + 时间 + ⓘ」，未接为红色。
struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    @State private var showsMissedOnly = false
    @State private var search = ""
    @State private var detailCall: CallRecord?

    private var filteredCalls: [CallRecord] {
        model.callHistory.filter { call in
            if showsMissedOnly && !call.missed { return false }
            guard !search.isEmpty else { return true }
            let name = model.contacts.displayName(for: call.number)
            return name.localizedCaseInsensitiveContains(search) || (call.number ?? "").contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredCalls.isEmpty {
                    EmptyStateView(
                        title: showsMissedOnly ? L10n.t("暂无未接来电") : L10n.t("暂无通话记录"),
                        systemImage: "clock"
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredCalls) { call in
                        callRow(call)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: Text(L10n.t("搜索")))
            .navigationTitle(L10n.t("最近通话"))
            .navigationBarTitleDisplayMode(.large)
            // 与系统电话 App 一致：分段控件固定在导航栏下方，列表在其下滚动。
            .safeAreaInset(edge: .top, spacing: 0) { filterPicker }
        }
        .sheet(item: $detailCall) { call in
            CallDetailSheet(call: call, onCall: onCall, onMessage: onMessage)
                .environmentObject(model)
        }
    }

    private var filterPicker: some View {
        Picker(L10n.t("通话筛选"), selection: $showsMissedOnly) {
            Text(L10n.t("全部")).tag(false)
            Text(L10n.t("未接")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func callRow(_ call: CallRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: call.direction == "incoming" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                .font(.body.weight(.medium))
                .foregroundStyle(call.missed ? Color.red : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.contacts.displayName(for: call.number))
                    .font(.body)
                    .foregroundStyle(call.missed ? Color.red : Color.primary)
                    .lineLimit(1)
                Text(subtitle(for: call))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(RecentCallTimeFormatter.string(for: call.updatedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                detailCall = call
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.t("信息"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let number = RecentCallDialPolicy.numberToDial(call.number) { onCall(number) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let number = call.number {
                Button { onMessage(number) } label: {
                    Label(L10n.t("短信"), systemImage: "message.fill")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let number = call.number {
                Button { onCall(number) } label: {
                    Label(L10n.t("呼叫"), systemImage: "phone.fill")
                }
                .tint(.green)
            }
        }
    }

    private func subtitle(for call: CallRecord) -> String {
        if call.missed { return L10n.t("未接来电") }
        return call.direction == "incoming" ? L10n.t("呼入") : L10n.t("呼出")
    }
}

/// 单条通话详情：系统电话 App 的「ⓘ」面板版式（头像 + 姓名 + 动作 + 信息分组）。
struct CallDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    private var name: String { model.contacts.displayName(for: call.number) }
    private var photo: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        InitialAvatar(name: name, photoData: photo, size: 78)
                        Text(name)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        if let number = call.number, number != name {
                            Text(number)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    HStack(spacing: 12) {
                        actionButton(L10n.t("短信"), icon: "message.fill", tint: .blue, enabled: call.number != nil) {
                            if let number = call.number { onMessage(number) }
                            dismiss()
                        }
                        actionButton(L10n.t("呼叫"), icon: "phone.fill", tint: .green, enabled: call.number != nil) {
                            if let number = call.number { onCall(number) }
                            dismiss()
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    LabeledContent(L10n.t("类型"), value: call.missed ? L10n.t("未接来电") : (call.direction == "incoming" ? L10n.t("呼入") : L10n.t("呼出")))
                    LabeledContent(L10n.t("时间"), value: call.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let endedAt = call.endedAt {
                        LabeledContent(L10n.t("时长"), value: durationText(from: call.startedAt, to: endedAt))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("通话详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(enabled ? 1 : 0.35), in: Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 短信

/// 短信：iPad 上为 NavigationSplitView 双栏（左会话列表、右聊天），
/// 布局与系统 iMessage 一致；iPhone 上自动折叠为「列表 → 聊天」栈式导航。
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var pendingRecipient: String?

    @State private var selection: String?
    @State private var search = ""
    @State private var isComposingNew = false
    @State private var draftRecipient = ""

    private var conversations: [(sender: String, messages: [SMSMessage])] {
        Dictionary(grouping: model.messages, by: \.sender)
            .map { ($0.key, $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { ($0.messages.last?.timestamp ?? .distantPast) > ($1.messages.last?.timestamp ?? .distantPast) }
    }

    private var filteredConversations: [(sender: String, messages: [SMSMessage])] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { conversation in
            displayName(for: conversation.sender).localizedCaseInsensitiveContains(search)
                || conversation.sender.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(L10n.t("短信"))
                .navigationBarTitleDisplayMode(.large)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 430)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { startNewMessage("") } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel(L10n.t("新信息"))
                    }
                }
                .navigationDestination(for: String.self) { sender in
                    MessageThreadView(
                        sender: sender,
                        displayName: displayName(for: sender),
                        photoData: photoData(for: sender)
                    )
                }
        } detail: {
            detail
        }
        .onChange(of: pendingRecipient) { recipient in
            guard let recipient, !recipient.isEmpty else { return }
            startNewMessage(recipient)
            pendingRecipient = nil
        }
        .onChange(of: selection) { sender in
            // 新建消息期间点开其它会话：退出草稿并切到该会话（iMessage 的操作逻辑）。
            if isComposingNew, sender != nil { isComposingNew = false }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if filteredConversations.isEmpty {
                EmptyStateView(title: L10n.t("暂无短信"), systemImage: "message")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredConversations, id: \.sender) { conversation in
                    NavigationLink(value: conversation.sender) {
                        ConversationRow(
                            displayName: displayName(for: conversation.sender),
                            preview: conversation.messages.last?.content ?? "",
                            timestamp: conversation.messages.last?.timestamp,
                            photoData: photoData(for: conversation.sender)
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: Text(L10n.t("搜索")))
        .tint(Color.accentColor)
    }

    @ViewBuilder
    private var detail: some View {
        if isComposingNew {
            NewMessageThread(
                initialRecipient: draftRecipient,
                onCancel: cancelNewMessage,
                onSend: { recipient, body in
                    Task { _ = await model.sendSMS(to: recipient, content: body) }
                    isComposingNew = false
                    selection = recipient
                },
                onRecipientChange: { draftRecipient = $0 }
            )
        } else if let sender = selection {
            MessageThreadView(
                sender: sender,
                displayName: displayName(for: sender),
                photoData: photoData(for: sender)
            )
        } else {
            EmptyStateView(title: L10n.t("选择信息开始聊天"), systemImage: "message")
        }
    }

    private func startNewMessage(_ recipient: String) {
        draftRecipient = recipient
        isComposingNew = true
        selection = nil
    }

    private func cancelNewMessage() {
        isComposingNew = false
        draftRecipient = ""
    }

    private func displayName(for sender: String) -> String {
        model.contacts.contact(for: sender)?.name ?? sender
    }

    private func photoData(for sender: String) -> Data? {
        model.contacts.contact(for: sender)?.photoData
    }
}

/// iMessage 会话行：头像 + 姓名 + 预览 + 右侧时间。
private struct ConversationRow: View {
    let displayName: String
    let preview: String
    let timestamp: Date?
    let photoData: Data?

    var body: some View {
        HStack(spacing: 12) {
            InitialAvatar(name: displayName, photoData: photoData, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let timestamp {
                Text(Self.rowTimestampText(timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// iMessage 规则：今天显示时分，本周显示星期几，更早显示日期。
    private static func rowTimestampText(_ date: Date) -> String {
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

/// 聊天详情：iMessage 版式——居中头像 + 名称、左右气泡、底部输入栏。
struct MessageThreadView: View {
    @EnvironmentObject private var model: AppModel
    let sender: String
    let displayName: String
    let photoData: Data?

    @State private var reply = ""
    @State private var showingContact = false

    private var messages: [SMSMessage] {
        model.messages.filter { $0.sender == sender }.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    header
                        .padding(.bottom, 10)
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let day = dayHeader(for: message.timestamp, previous: index > 0 ? messages[index - 1].timestamp : nil) {
                            Text(day)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        bubble(message)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollToLast(proxy, animated: false) }
            .onChange(of: messages.count) { _ in scrollToLast(proxy, animated: true) }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingContact = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.t("信息"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(isPresented: $showingContact) {
            NativeContactCard(
                identifier: model.contacts.contact(for: sender)?.id,
                phone: sender,
                showsNavigationBar: true,
                showsDoneButton: true,
                onCall: { number in
                    model.numberInput = number
                    Task { await model.dial() }
                },
                onMessage: { _ in }
            )
            .presentationSizingIfAvailable()
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            InitialAvatar(name: displayName, photoData: photoData, size: 64)
            Text(displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 6)
    }

    private func bubble(_ message: SMSMessage) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }
            Text(message.content)
                .font(.body)
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    message.isOutgoing ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .textSelection(.enabled)
            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .id(message.id)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.t("短信内容"), text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityLabel(L10n.t("短信内容"))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(L10n.t("发送"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let body = reply
        reply = ""
        Task { _ = await model.sendSMS(to: sender, content: body) }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    /// 与上一条消息不同天时返回分隔文案（今天/昨天/本地化日期），否则返回 nil。
    private func dayHeader(for date: Date, previous: Date?) -> String? {
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

/// 新消息：系统 iMessage 的「新信息」页——收件人 + 内容 + 取消/发送。
struct NewMessageThread: View {
    @EnvironmentObject private var model: AppModel
    let initialRecipient: String
    let onCancel: () -> Void
    let onSend: (String, String) -> Void
    let onRecipientChange: (String) -> Void

    @State private var recipient = ""
    @State private var message = ""

    private var suggestions: [ContactStore.Contact] {
        let query = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1, !query.allSatisfy(\.isNumber) else { return [] }
        return model.contacts.contacts
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("收件人"), text: $recipient)
                    .keyboardType(.phonePad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { contact in
                        Button {
                            recipient = contact.phones.first ?? recipient
                        } label: {
                            HStack(spacing: 12) {
                                InitialAvatar(name: contact.name, photoData: contact.photoData, size: 36)
                                Text(contact.name).foregroundStyle(Color.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section(L10n.t("短信内容")) {
                TextField(L10n.t("短信内容"), text: $message, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(L10n.t("新信息"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("取消"), action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("发送")) { onSend(recipient, message) }
                    .disabled(!canSend)
            }
        }
        .onAppear { recipient = initialRecipient }
        .onChange(of: recipient) { onRecipientChange($0) }
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
// MARK: - 联系人

/// 通讯录字母分组。
private struct ContactSection: Identifiable {
    let id: String
    let contacts: [ContactStore.Contact]
}

/// 通讯录：iPad 双栏（左列表 + 右详情），iPhone 折叠为栈式导航，
/// 与系统「通讯录」App 的层级和行样式保持一致。
struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    @State private var selection: String?
    @State private var search = ""

    private var contacts: [ContactStore.Contact] { model.contacts.contacts }

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return contacts }
        return contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(search)
                || contact.phones.contains { $0.contains(search) }
        }
    }

    private var sections: [ContactSection] {
        let groups = Dictionary(grouping: filtered) { Self.initialKey(for: $0.name) }
        return groups.keys
            .sorted { lhs, rhs in
                if lhs == "#" { return false }
                if rhs == "#" { return true }
                return lhs < rhs
            }
            .map { key in
                ContactSection(
                    id: key,
                    contacts: (groups[key] ?? []).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if filtered.isEmpty {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.crop.circle")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(sections) { section in
                        Section(section.id) {
                            ForEach(section.contacts) { contact in
                                NavigationLink(value: contact.id) {
                                    HStack(spacing: 12) {
                                        InitialAvatar(name: contact.name, photoData: contact.photoData, size: 40)
                                        Text(contact.name)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: Text(L10n.t("搜索")))
            .navigationTitle(L10n.t("联系人"))
            .navigationBarTitleDisplayMode(.large)
            .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 430)
            .navigationDestination(for: String.self) { identifier in
                if let contact = contacts.first(where: { $0.id == identifier }) {
                    ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
                }
            }
        } detail: {
            if let selection, let contact = contacts.first(where: { $0.id == selection }) {
                ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
            } else {
                EmptyStateView(title: L10n.t("选择联系人查看详情"), systemImage: "person.crop.circle")
            }
        }
        .task { await model.contacts.loadIfNeeded() }
    }

    /// 分组首字母：英文取首字母，中文转拼音取首字母，其余归入 #（与系统通讯录一致）。
    private static func initialKey(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }
        let latin = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        guard let first = latin.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

/// 联系人详情：系统「通讯录」版式——头像 + 姓名 + 四个动作圆钮 + 分组信息行。
/// 详情直接读本机缓存副本，点开即出，不再内嵌系统卡片（那会带来明显的加载等待）。
struct ContactDetailView: View {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    @State private var showingEditor = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    InitialAvatar(name: contact.name, photoData: contact.photoData, size: 110)
                    Text(contact.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                HStack(spacing: 8) {
                    ContactActionButton(title: L10n.t("短信"), icon: "message.fill", tint: .blue) {
                        if let phone = contact.phones.first { onMessage(phone) }
                    }
                    ContactActionButton(title: L10n.t("呼叫"), icon: "phone.fill", tint: .green) {
                        if let phone = contact.phones.first { onCall(phone) }
                    }
                    ContactActionButton(title: L10n.t("视频"), icon: "video.fill", tint: .blue, enabled: false) {}
                    ContactActionButton(title: L10n.t("邮件"), icon: "envelope.fill", tint: .blue, enabled: !contact.emails.isEmpty) {
                        guard let mail = contact.emails.first,
                              let url = URL(string: "mailto:\(mail)") else { return }
                        UIApplication.shared.open(url)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !contact.phones.isEmpty {
                Section(L10n.t("电话号码")) {
                    ForEach(contact.phones, id: \.self) { phone in
                        HStack(spacing: 12) {
                            Text(phone)
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            Button { onMessage(phone) } label: {
                                Image(systemName: "message.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("短信"))
                            Button { onCall(phone) } label: {
                                Image(systemName: "phone.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("呼叫"))
                        }
                    }
                }
            }

            if !contact.emails.isEmpty {
                Section(L10n.t("电子邮件")) {
                    ForEach(contact.emails, id: \.self) { mail in
                        Text(mail)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("编辑")) { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            // 只有编辑时才加载系统原生卡片；点开详情不再等待通讯录全字段读取。
            NativeContactCard(
                identifier: contact.id,
                showsNavigationBar: true,
                showsDoneButton: true,
                allowsEditing: true,
                onCall: onCall,
                onMessage: onMessage
            )
            .presentationSizingIfAvailable()
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ContactActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(enabled ? 1 : 0.35), in: Circle())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 跨线程搬运 CNContact（非 Sendable）的一次性容器：后台只写一次，主线程只读一次。
private final class NativeContactBox: @unchecked Sendable {
    let value: CNContact?

    init(value: CNContact?) {
        self.value = value
    }
}

/// 系统原生联系人卡片（CNContactViewController）。
/// 传入通讯录 identifier 时直接展示该联系人；否则按号码构造临时卡片。
/// 号码动作交给系统选择器，用户可明确「发信息 / 拨打电话」，不会被误路由成拨号。
private struct NativeContactCard: UIViewControllerRepresentable {
    /// 直接传入已取好的联系人时优先使用，避免 representable 在 main thread 重复读取通讯录。
    var contact: CNContact? = nil
    var identifier: String? = nil
    var phone: String? = nil
    var showsNavigationBar: Bool = true
    var showsDoneButton: Bool = false
    var allowsEditing: Bool = false
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let store = CNContactStore()
        let resolved: CNContact
        if let contact {
            resolved = contact
        } else if let identifier,
                  let fetched = try? store.unifiedContact(
                      withIdentifier: identifier,
                      keysToFetch: [CNContactViewController.descriptorForRequiredKeys()]
                  ) {
            resolved = fetched
        } else {
            // 号码不在通讯录时构造一张未保存的临时卡片（与 iMessage 展示陌生号码一致）。
            let draft = CNMutableContact()
            if let phone, !phone.isEmpty {
                draft.phoneNumbers = [
                    CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))
                ]
            }
            resolved = draft
        }

        let vc = CNContactViewController(for: resolved)
        vc.contactStore = store
        vc.delegate = context.coordinator
        // 只有通讯录里真实存在的联系人才能进入编辑态；陌生号码的临时卡片不可编辑。
        vc.allowsEditing = allowsEditing && (contact != nil || identifier != nil)
        vc.allowsActions = true
        context.coordinator.contactViewController = vc

        // 不要导航栏时直接返回卡片本身：多包一层 UINavigationController 会
        // 在详情列里多出一条空导航栏（顶部留白 + 两个返回按钮）。
        guard showsNavigationBar else { return vc }
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false
        if showsDoneButton {
            vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: L10n.t("完成"),
                style: .done,
                target: context.coordinator,
                action: #selector(Coordinator.dismissCard)
            )
        }
        return nav
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCall: onCall, onMessage: onMessage)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onCall: (String) -> Void
        let onMessage: (String) -> Void
        weak var contactViewController: UIViewController?

        init(onCall: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) {
            self.onCall = onCall
            self.onMessage = onMessage
        }

        @objc func dismissCard() {
            contactViewController?.dismiss(animated: true)
        }

        /// 号码动作先弹系统选择器：系统无法区分「呼叫 / 发信息」两个圆钮，
        /// 因此这里让用户明确选择，保证「发信息」不会再直接拨号。
        func contactViewController(
            _ viewController: CNContactViewController,
            shouldPerformDefaultActionFor property: CNContactProperty
        ) -> Bool {
            guard let number = property.value as? CNPhoneNumber else { return true }
            let phone = number.stringValue
            let sheet = UIAlertController(title: phone, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: L10n.t("发送信息"), style: .default) { [weak self] _ in
                self?.onMessage(phone)
            })
            sheet.addAction(UIAlertAction(title: L10n.t("拨打电话"), style: .default) { [weak self] _ in
                self?.onCall(phone)
            })
            sheet.addAction(UIAlertAction(title: L10n.t("取消"), style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = viewController.view
                popover.sourceRect = CGRect(
                    x: viewController.view.bounds.midX,
                    y: viewController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
            viewController.present(sheet, animated: true)
            return false
        }
    }
}

/// CNContactViewController 原生新建联系人（系统自动渲染 X/✓、头像与字段）。
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

// MARK: - 通用视图

/// 系统联系人 / iMessage 默认 monogram 头像（灰色渐变圆 + 白色首字母/小人）。
struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var size: CGFloat = 44

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
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "收到和发出的短信都会显示在这里。"
        case "clock": return "完成通话后，记录会显示在这里。"
        case "person.crop.circle": return "联系人会从系统通讯录同步。"
        default: return "完成连接或授权后即可使用。"
        }
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
                .foregroundStyle(isRecording ? Color(uiColor: .systemRed) : Color.secondary)
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

// MARK: - 通话覆盖层

/// 前台通话界面：系统「电话」App 通话页版式（头像 + 姓名 + 状态 + 计时 + 控件网格）。
/// 退到后台后本视图消失，由系统 CallKit 界面接管。
struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let call: CallRecord

    @State private var showingKeypad = false

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var avatarSize: CGFloat { isCompact ? 84 : 104 }
    private var controlSize: CGFloat { isCompact ? 62 : 74 }
    private var isRingingIncoming: Bool {
        call.direction == "incoming" && ["incoming", "waiting"].contains(call.state)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: isCompact ? 16 : 24) {
                Spacer(minLength: 20)
                header
                Spacer(minLength: 8)
                if showingKeypad {
                    DTMFKeypadPanel {
                        withAnimation(.easeInOut(duration: 0.22)) { showingKeypad = false }
                    }
                } else {
                    controls
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.22), value: showingKeypad)
    }

    private var header: some View {
        VStack(spacing: isCompact ? 12 : 16) {
            InitialAvatar(name: model.contacts.displayName(for: call.number), size: avatarSize)
            VStack(spacing: 4) {
                Text(model.contacts.displayName(for: call.number))
                    .font(isCompact ? .title.weight(.semibold) : .largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if call.state == "active" {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isRingingIncoming {
            HStack(spacing: isCompact ? 64 : 96) {
                CallControlButton(title: L10n.t("拒接"), icon: "phone.down.fill", color: .red, isActive: true, size: controlSize) {
                    Task { await model.reject() }
                }
                CallControlButton(title: L10n.t("接听"), icon: "phone.fill", color: .green, isActive: true, size: controlSize) {
                    Task { await model.answer() }
                }
            }
        } else {
            VStack(spacing: isCompact ? 18 : 24) {
                HStack(spacing: isCompact ? 20 : 32) {
                    CallControlButton(
                        title: model.isMuted ? L10n.t("取消静音") : L10n.t("静音"),
                        icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                        color: .orange,
                        isActive: model.isMuted,
                        size: controlSize
                    ) {
                        Task { await model.toggleMute() }
                    }
                    CallControlButton(
                        title: L10n.t("键盘"),
                        icon: "circle.grid.3x3.fill",
                        color: .blue,
                        isActive: showingKeypad,
                        size: controlSize
                    ) {
                        withAnimation(.easeInOut(duration: 0.22)) { showingKeypad = true }
                    }
                    CallControlButton(
                        title: L10n.t("扬声器"),
                        icon: model.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                        color: .blue,
                        isActive: model.isSpeakerEnabled,
                        size: controlSize
                    ) {
                        model.toggleSpeaker()
                    }
                }
                HStack(spacing: isCompact ? 20 : 32) {
                    CallControlButton(
                        title: model.isRecording ? L10n.t("停止录音") : L10n.t("录音"),
                        icon: "record.circle",
                        color: .red,
                        isActive: model.isRecording,
                        size: controlSize
                    ) {
                        Task { await model.toggleRecording() }
                    }
                }
                CallControlButton(title: L10n.t("挂断"), icon: "phone.down.fill", color: .red, isActive: true, size: controlSize + 6) {
                    Task { await model.hangup() }
                }
                .padding(.top, 4)
            }
        }
    }

    private var statusText: String {
        switch call.state {
        case "active": return L10n.t("通话中")
        case "incoming", "waiting": return L10n.t("等待接听")
        case "held": return L10n.t("通话保持")
        default: return call.state
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(call.startedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct CallControlButton: View {
    let title: String
    let icon: String
    let color: Color
    var isActive: Bool = false
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                    .frame(width: size, height: size)
                    .modifier(GlassCircle(tint: isActive ? color : nil))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(minWidth: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 通话中的 DTMF 键盘：整屏替换通话控件，底部提供「隐藏键盘」。
private struct DTMFKeypadPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onClose: () -> Void

    private let rows: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var keySize: CGFloat { isCompact ? 64 : 74 }
    private var keySpacing: CGFloat { isCompact ? 22 : 30 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }

    var body: some View {
        VStack(spacing: 20) {
            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 0) {
                        keypadRows
                    }
                } else {
                    keypadRows
                }
            }
            .frame(width: keypadWidth)

            Button(action: onClose) {
                Text(L10n.t("隐藏键盘"))
                    .font(.headline)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.t("隐藏键盘"))
        }
    }

    private var keypadRows: some View {
        VStack(spacing: isCompact ? 10 : 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(row, id: \.0) { digit, letters in
                        Button {
                            Task { await model.sendDTMF(digit) }
                        } label: {
                            Group {
                                if #available(iOS 26.0, *) {
                                    dtmfLabel(digit: digit, letters: letters)
                                        .glassEffect(.regular.interactive(), in: Circle())
                                        .contentShape(Circle())
                                } else {
                                    dtmfLabel(digit: digit, letters: letters)
                                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                                        .contentShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
                    }
                }
            }
        }
    }

    private func dtmfLabel(digit: String, letters: String) -> some View {
        VStack(spacing: 1) {
            Text(digit)
                .font(.system(size: isCompact ? 28 : 31, weight: .regular, design: .rounded))
            Text(letters)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
        }
        .foregroundStyle(.primary)
        .frame(width: keySize, height: keySize)
    }
}