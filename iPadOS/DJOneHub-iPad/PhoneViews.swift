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

/// 姓名 monogram：中文取首字；英文取首尾两段的首字母（最多 2 字符）；无有效姓名返回 nil。
enum Monogram {
    static func text(for name: String) -> String? {
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
}

/// 按联系人稳定派生色相：系统通讯录会为每个联系人挑一种固定配色，这里用同名稳定散列模拟。
/// 不能使用 `hashValue`（每个进程随机加盐），否则同一联系人每次启动颜色都不同。
enum ContactPalette {
    static func hue(for seed: String) -> Double {
        var value: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            value = (value &* 33) &+ UInt64(scalar.value)
        }
        return Double(value % 360) / 360.0
    }

    static func gradient(for seed: String) -> LinearGradient {
        let hue = hue(for: seed)
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.98),
                Color(hue: hue, saturation: 0.80, brightness: 0.62)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 视觉辅助

/// 系统 iOS 26 液态玻璃圆钮；旧系统回退为系统填充圆。
struct GlassCircle: ViewModifier {
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

extension View {
    func glassCircle(tint: Color? = nil) -> some View {
        modifier(GlassCircle(tint: tint))
    }

    /// 移除系统自动插入的侧栏切换按钮：我们要用与系统「联系人」App 相同位置的
    /// 自绘切换按钮，避免顶栏出现两个功能相同的按钮。
    @ViewBuilder
    func removingDefaultSidebarToggle() -> some View {
        if #available(iOS 17.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

/// 拨号键盘上的一枚按键：iOS 26 用系统玻璃圆，旧系统用系统填充圆。
private struct DialKeyBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        } else {
            content
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                .contentShape(Circle())
        }
    }
}

/// 拨号浮层的卡片底：iOS 26 液态玻璃，旧系统用系统分组背景。
private struct DialPadCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
    }
}

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
                        if let monogram = Monogram.text(for: name) {
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
struct EmptyStateView: View {
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
        case "clock", "phone": return "完成通话后，记录会显示在这里。"
        case "person.crop.circle": return "联系人会从系统通讯录同步。"
        default: return "完成连接或授权后即可使用。"
        }
    }
}

/// 详情页的圆形动作钮（参考图四 / 图五 的四个圆钮）：圆形底 + 图标 + 下方标题。
struct DetailActionCircle: View {
    let title: String
    let systemImage: String
    var foreground: Color = .primary
    var background: Color = Color(uiColor: .secondarySystemFill)
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(foreground)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(background))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 66)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }
}
// MARK: - 拨号键盘

/// 拨号键盘的按键布局，和系统「电话」App 的键盘完全一致。
let dialPadRows: [[(String, String)]] = [
    [("1", ""), ("2", "ABC"), ("3", "DEF")],
    [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
    [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
    [("*", ""), ("0", "+"), ("#", "")],
]

/// 拨号键盘浮层：由通话页顶栏的拨号按钮呼出，
/// 点击键盘以外的任何区域（背景遮罩）都会关闭键盘。
/// 拨号键盘浮层：由通话页顶栏的拨号按钮呼出。
///
/// 键盘是一块小尺寸卡片（不铺满整屏），在通话页里从右上角圆形拨号按钮的位置
/// 放大展开；点键盘以外的任意区域都会关闭键盘（遮罩由通话页提供）。
struct DialPadOverlay: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onDismiss: () -> Void

    @State private var deleteRepeatTask: Task<Void, Never>?

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var keySize: CGFloat { isCompact ? 58 : 62 }
    private var keySpacing: CGFloat { isCompact ? 20 : 24 }
    private var rowSpacing: CGFloat { isCompact ? 8 : 10 }
    private var matchedName: String? {
        model.contacts.contact(for: model.numberInput)?.name
    }
    private var callDisabled: Bool {
        model.numberInput.isEmpty || model.isBusy || !model.isOnline
    }

    var body: some View {
        card
            .padding(.horizontal, 24)
            .onDisappear { stopDeleteRepeat() }
    }

    private var card: some View {
        VStack(spacing: isCompact ? 10 : 12) {
            numberDisplay
            keypad
            callRow
        }
        .padding(.horizontal, isCompact ? 16 : 20)
        .padding(.vertical, isCompact ? 14 : 18)
        .frame(maxWidth: 320)
        .modifier(DialPadCardBackground())
    }

    private var numberDisplay: some View {
        VStack(spacing: 2) {
            Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                .font(.system(size: isCompact ? 26 : 30, weight: .regular, design: .rounded))
                .foregroundStyle(model.numberInput.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            if let matchedName {
                Text(matchedName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var keypad: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(dialPadRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        DialKey(
                            digit: key.0,
                            letters: key.1,
                            size: keySize,
                            onDigit: { model.numberInput.append($0) },
                            onLongPressZero: { model.numberInput.append("+") }
                        )
                    }
                }
            }
        }
    }

    private var callRow: some View {
        HStack(spacing: keySpacing) {
            Color.clear.frame(width: keySize, height: keySize)

            Button {
                guard !callDisabled else { return }
                close()
                Task { await model.dial() }
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: keySize * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: keySize, height: keySize)
                    .background(
                        Circle().fill(callDisabled ? Color(uiColor: .systemGray3) : Color(uiColor: .systemGreen))
                    )
            }
            .buttonStyle(.plain)
            .disabled(callDisabled)
            .accessibilityLabel(L10n.t("呼叫"))

            Button {
                startDeleteRepeat()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: keySize * 0.30, weight: .regular))
                    .foregroundStyle(model.numberInput.isEmpty ? Color.clear : Color.primary)
                    .frame(width: keySize, height: keySize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.numberInput.isEmpty)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in startDeleteRepeat() }
            )
            .accessibilityLabel(L10n.t("删除"))
        }
    }

    private func close() {
        stopDeleteRepeat()
        onDismiss()
    }

    /// 长按删除：先删一位，然后连续删除直到松手或号码清空。
    private func startDeleteRepeat() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
        stopDeleteRepeat()
        deleteRepeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while !Task.isCancelled {
                guard !model.numberInput.isEmpty else { break }
                model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func stopDeleteRepeat() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }
}

/// 单枚拨号按键。长按 0 输入「+」，和系统电话 App 一致。
private struct DialKey: View {
    let digit: String
    let letters: String
    let size: CGFloat
    let onDigit: (String) -> Void
    let onLongPressZero: () -> Void

    @State private var longPressFired = false

    var body: some View {
        Button {
            if longPressFired {
                longPressFired = false
                return
            }
            onDigit(digit)
        } label: {
            VStack(spacing: 1) {
                Text(digit)
                    .font(.system(size: size * 0.40, weight: .regular, design: .rounded))
                Text(letters)
                    .font(.system(size: size * 0.17, weight: .semibold))
                    .tracking(1.3)
            }
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .modifier(DialKeyBackground())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard digit == "0" else { return }
                longPressFired = true
                onLongPressZero()
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }
}

// MARK: - 列表通用控件

/// 搜索栏：与系统 App 顶栏下方的搜索栏一致（灰色圆角矩形 + 放大镜 + 麦克风）。
///
/// 这里不用 `.searchable`：搜索栏挂在导航栏上时会横跨整个窗口宽度，
/// iPad 分栏下就比左列列表宽出一截（用户反馈「搜索框过长」）。
/// 把它放进左列内部后，宽度天然与列表等长。
struct PhoneSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("清除"))
            }
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
    }
}

/// 顶栏「编辑 / 完成」按钮：浅色下黑字、深色下白字，不使用强调色蓝。
/// 自己画而不是直接用 `EditButton`，是为了让三个板块共用同一套多选删除逻辑。
struct PhoneEditToggle: View {
    let isEditing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isEditing ? L10n.t("完成") : L10n.t("编辑"))
                .fontWeight(isEditing ? .semibold : .regular)
        }
        .tint(Color.primary)
        .accessibilityLabel(isEditing ? L10n.t("完成") : L10n.t("编辑"))
    }
}

/// 编辑态左侧的圆形复选框：选中为系统蓝实心对勾，未选中为灰色空心圈。
struct PhoneSelectionCircle: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(
                isSelected
                    ? Color(uiColor: .systemBlue)
                    : Color(uiColor: .tertiaryLabel)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 通话（拨号 + 通话记录合并）

/// 「通话」板块：左侧通话记录，右侧通话详情；顶栏左侧「编辑 + 分类」、
/// 右侧「拨号键盘 + 搜索」，与参考图四的信息层级一致。
/// 点拨号按钮呼出拨号键盘浮层，点键盘外任意区域即可关闭。
///
/// iPad 用页内分栏（`HStack`）而不是 `NavigationSplitView`：
/// 顶层已有 tab 栏，再嵌一层分栏会多出整条导航栏和重复的侧栏按钮；
/// 页内分栏只有一条顶栏，左「编辑 / 分类」、右「拨号 / 搜索」都在同一条上。
struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onMessage: (String) -> Void

    @State private var selection: String?
    @State private var search = ""
    @State private var showsMissedOnly = false
    @State private var showingKeypad = false
    @State private var isEditing = false
    @State private var checkedIDs = Set<String>()

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var filteredCalls: [CallRecord] {
        model.callHistory.filter { call in
            if showsMissedOnly && !call.missed { return false }
            guard !search.isEmpty else { return true }
            let name = model.contacts.displayName(for: call.number)
            return name.localizedCaseInsensitiveContains(search) || (call.number ?? "").contains(search)
        }
    }

    private var selectedCall: CallRecord? {
        guard let selection else { return nil }
        return model.callHistory.first { $0.id == selection }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isRegular { regularBody } else { compactBody }
            }
            .navigationTitle(isEditing ? L10n.t("已选择 \(checkedIDs.count) 项") : L10n.t("通话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { callsToolbar }
            .immersiveBars()
            .navigationDestination(for: String.self) { identifier in
                if let call = model.callHistory.first(where: { $0.id == identifier }) {
                    CallDetailPane(call: call, onMessage: onMessage, onCall: dialNumber)
                } else {
                    EmptyStateView(title: L10n.t("暂无通话记录"), systemImage: "clock")
                }
            }
            .overlay {
                if showingKeypad {
                    ZStack {
                        // 点键盘以外的任意区域即可关闭键盘。
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { dismissKeypad() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        // 圆形的拨号按钮放大成小尺寸拨号键盘。
                        DialPadOverlay(onDismiss: dismissKeypad)
                            .transition(
                                .scale(scale: 0.06, anchor: .topTrailing)
                                    .combined(with: .opacity)
                            )
                    }
                }
            }
        }
        .task { await model.contacts.loadIfNeeded() }
    }

    @ToolbarContentBuilder
    private var callsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            PhoneEditToggle(isEditing: isEditing) { toggleEditing() }
            if !isEditing { filterMenu }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isEditing {
                Button(role: .destructive) {
                    deleteCheckedCalls()
                } label: {
                    Image(systemName: "trash")
                }
                .tint(Color.red)
                .disabled(checkedIDs.isEmpty)
                .accessibilityLabel(L10n.t("删除"))
            } else {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        showingKeypad = true
                    }
                } label: {
                    Image(systemName: "circle.grid.3x3.fill")
                }
                .tint(Color.primary)
                .accessibilityLabel(L10n.t("拨号键盘"))
            }
        }
    }

    // MARK: iPad 页内双栏（只有一条顶栏）

    private var regularBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                List {
                    callsRows
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(width: 380)

            Divider()

            Group {
                if let call = selectedCall {
                    CallDetailPane(call: call, onMessage: onMessage, onCall: dialNumber)
                } else {
                    EmptyStateView(title: L10n.t("选择通话记录查看详情"), systemImage: "phone")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: iPhone 单栏（点按进入详情）

    private var compactBody: some View {
        List {
            PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            compactCallsRows
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 子视图

    @ViewBuilder
    private var callsRows: some View {
        if filteredCalls.isEmpty {
            emptyCallsRow
        } else {
            ForEach(filteredCalls) { call in
                Button {
                    if isEditing {
                        toggleCheck(call.id)
                    } else {
                        selection = call.id
                    }
                } label: {
                    RecentsRow(
                        call: call,
                        onCall: dialNumber,
                        isSelected: !isEditing && selection == call.id,
                        isEditing: isEditing,
                        isChecked: checkedIDs.contains(call.id)
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
    }

    @ViewBuilder
    private var compactCallsRows: some View {
        if filteredCalls.isEmpty {
            emptyCallsRow
        } else {
            ForEach(filteredCalls) { call in
                if isEditing {
                    Button {
                        toggleCheck(call.id)
                    } label: {
                        RecentsRow(
                            call: call,
                            onCall: dialNumber,
                            isEditing: true,
                            isChecked: checkedIDs.contains(call.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } else {
                    NavigationLink(value: call.id) {
                        RecentsRow(call: call, onCall: dialNumber, isSelected: false)
                    }
                }
            }
        }
    }

    private var emptyCallsRow: some View {
        EmptyStateView(
            title: showsMissedOnly ? L10n.t("暂无未接来电") : L10n.t("暂无通话记录"),
            systemImage: "clock"
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// 三条杠分类按钮：与系统信息 App 的筛选菜单保持一致。
    private var filterMenu: some View {
        Menu {
            Picker(L10n.t("筛选"), selection: $showsMissedOnly) {
                Text(L10n.t("全部")).tag(false)
                Text(L10n.t("未接来电")).tag(true)
            }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .tint(Color.primary)
        .accessibilityLabel(L10n.t("筛选"))
    }

    private func toggleEditing() {
        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    private func deleteCheckedCalls() {
        let ids = checkedIDs
        guard !ids.isEmpty else { return }
        model.deleteCalls(ids: ids)
        if let selection, ids.contains(selection) { self.selection = nil }
        checkedIDs.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }

    private func dismissKeypad() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showingKeypad = false }
    }

    private func dialNumber(_ number: String) {
        model.numberInput = number
        Task { await model.dial() }
    }
}

/// 通话记录行：头像 + 姓名 + 类型 + 时间，右侧是系统蓝的快捷呼叫圆钮。
/// 选中态用系统列表选择的浅灰胶囊，和系统「电话」App 的最近通话一致。
private struct RecentsRow: View {
    @EnvironmentObject private var model: AppModel
    let call: CallRecord
    let onCall: (String) -> Void
    var isSelected: Bool = false
    var isEditing: Bool = false
    var isChecked: Bool = false

    private var name: String { model.contacts.displayName(for: call.number) }
    private var photo: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked)
            }

            InitialAvatar(name: name, photoData: photo, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(call.missed ? Color.red : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(RecentCallTimeFormatter.string(for: call.updatedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !isEditing, let number = call.number {
                Button { onCall(number) } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(uiColor: .systemBlue).opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("呼叫"))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isEditing ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isEditing { return isChecked ? Color(uiColor: .secondarySystemFill) : Color.clear }
        return isSelected ? Color(uiColor: .secondarySystemFill) : Color.clear
    }

    private var subtitle: String {
        if call.missed { return L10n.t("未接来电") }
        return call.direction == "incoming" ? L10n.t("呼入") : L10n.t("呼出")
    }
}

/// 通话记录详情：严格按参考图四右栏——整块渐变背景铺满全屏，
/// 头像、姓名、四个动作圆钮、分组信息全部落在这块渐变背景里。
struct CallDetailPane: View {
    @EnvironmentObject private var model: AppModel
    let call: CallRecord
    let onMessage: (String) -> Void
    let onCall: (String) -> Void

    @State private var showingAddName = false

    private var name: String { model.contacts.displayName(for: call.number) }
    private var photo: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }
    private var hueSeed: String { call.number ?? call.id }

    var body: some View {
        ZStack {
            ContactPalette.gradient(for: hueSeed)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    hero
                    infoCards
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .immersiveBars()
        .monochromeBarControls()
        .sheet(isPresented: $showingAddName) {
            ContactNativeNew(contactStore: CNContactStore())
                .ignoresSafeArea()
        }
    }

    /// 图四大卡片：大头像 + 姓名 + 四个动作圆钮。
    private var hero: some View {
        VStack(spacing: 14) {
            InitialAvatar(name: name, photoData: photo, size: 124)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))

            VStack(spacing: 4) {
                Text(name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                if let number = call.number, number != name {
                    Text(number)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(directionText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 18) {
                DetailActionCircle(
                    title: L10n.t("信息"),
                    systemImage: "message.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: call.number != nil
                ) {
                    if let number = call.number { onMessage(number) }
                }
                DetailActionCircle(
                    title: L10n.t("呼叫"),
                    systemImage: "phone.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: call.number != nil
                ) {
                    if let number = call.number { onCall(number) }
                }
                DetailActionCircle(
                    title: L10n.t("视频"),
                    systemImage: "video.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: false
                ) {}
                DetailActionCircle(
                    title: L10n.t("邮件"),
                    systemImage: "envelope.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: false
                ) {}
            }
            .padding(.top, 2)
        }
    }

    /// 图四的分组信息：通话记录 / 添加姓名 / 电话 / 共享联系人。
    private var infoCards: some View {
        VStack(spacing: 14) {
            InfoCard {
                InfoCardRow(
                    title: L10n.t("通话记录"),
                    value: nil,
                    systemImage: nil,
                    showsChevron: true,
                    isInteractive: false
                ) {}
                InfoCardDivider()
                InfoCardRow(
                    title: directionText,
                    value: timeAndDurationText,
                    systemImage: nil,
                    showsChevron: false,
                    isInteractive: false
                ) {}
            }

            InfoCard {
                InfoCardRow(
                    title: L10n.t("添加姓名"),
                    value: nil,
                    systemImage: nil,
                    showsChevron: true
                ) {
                    showingAddName = true
                }
            }

            if let number = call.number {
                InfoCard {
                    InfoCardRow(
                        title: L10n.t("电话"),
                        value: number,
                        systemImage: "phone.fill"
                    ) {
                        onCall(number)
                    }
                }
            }

            InfoCard {
                InfoCardRow(
                    title: L10n.t("共享联系人"),
                    value: nil,
                    systemImage: nil,
                    showsChevron: true,
                    isInteractive: false
                ) {}
                InfoCardDivider()
                InfoCardRow(
                    title: L10n.t("添加到个人收藏"),
                    value: nil,
                    systemImage: nil,
                    showsChevron: true,
                    isInteractive: false
                ) {}
            }

            ShareLink(item: shareText) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                    Text(L10n.t("共享"))
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
            }
        }
    }

    private var directionText: String {
        if call.missed { return L10n.t("未接来电") }
        return call.direction == "incoming" ? L10n.t("呼入") : L10n.t("呼出")
    }

    private var timeAndDurationText: String {
        let stamp = call.startedAt.formatted(date: .abbreviated, time: .shortened)
        if let duration = durationText {
            return stamp + " · " + duration
        }
        return stamp
    }

    private var durationText: String? {
        guard let ended = call.endedAt ?? (call.state == "ended" ? call.updatedAt : nil) else { return nil }
        let total = max(0, Int(ended.timeIntervalSince(call.startedAt)))
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var shareText: String {
        if let number = call.number { return "\(name) \(number)" }
        return name
    }
}
// MARK: - 联系人

/// 「联系人」板块：左侧联系人列表（顶栏「新建联系人」按钮、下方搜索框），
/// 右侧联系人详情（参考图五：整块渐变底 + 大 monogram + 四个动作圆钮 + 分组信息）。
/// iPad 用页内分栏，避免再嵌一层 NavigationSplitView 造成重复的侧栏按钮。
struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    @State private var selection: String?
    @State private var search = ""
    @State private var showingNewContact = false
    @State private var isEditing = false
    @State private var checkedIDs = Set<String>()

    private var isRegular: Bool { horizontalSizeClass == .regular }
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

    private var selectedContact: ContactStore.Contact? {
        guard let selection else { return nil }
        return contacts.first { $0.id == selection }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isRegular { regularBody } else { compactBody }
            }
            .navigationTitle(isEditing ? L10n.t("已选择 \(checkedIDs.count) 项") : L10n.t("联系人"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { contactsToolbar }
            .immersiveBars()
            .navigationDestination(for: String.self) { identifier in
                if let contact = contacts.first(where: { $0.id == identifier }) {
                    ContactDetailPane(contact: contact, onCall: onCall, onMessage: onMessage)
                } else {
                    EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.crop.circle")
                }
            }
        }
        .task { await model.contacts.loadIfNeeded() }
        .sheet(isPresented: $showingNewContact) {
            ContactNativeNew(contactStore: CNContactStore()) {
                Task { await model.contacts.requestAccessAndLoad() }
            }
            .ignoresSafeArea()
        }
    }

    @ToolbarContentBuilder
    private var contactsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditing {
                PhoneEditToggle(isEditing: true) { toggleEditing() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isEditing {
                Button(role: .destructive) {
                    deleteCheckedContacts()
                } label: {
                    Image(systemName: "trash")
                }
                .tint(Color.red)
                .disabled(checkedIDs.isEmpty)
                .accessibilityLabel(L10n.t("删除"))
            } else {
                Button {
                    showingNewContact = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(Color.primary)
                .accessibilityLabel(L10n.t("新建联系人"))
            }
        }
    }

    private var regularBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                List {
                    contactRows(linkRows: false)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(width: 380)

            Divider()

            Group {
                if let contact = selectedContact {
                    ContactDetailPane(
                        contact: contact,
                        onCall: onCall,
                        onMessage: onMessage,
                        showsEditButton: !isEditing
                    )
                } else {
                    EmptyStateView(title: L10n.t("选择联系人查看详情"), systemImage: "person.crop.circle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactBody: some View {
        List {
            PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            contactRows(linkRows: !isEditing)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func contactRows(linkRows: Bool) -> some View {
        if sections.isEmpty {
            EmptyStateView(title: L10n.t("通讯录为空"), systemImage: "person.crop.circle")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(sections) { section in
                Section(section.id) {
                    ForEach(section.contacts) { contact in
                        if isEditing {
                            Button {
                                toggleCheck(contact.id)
                            } label: {
                                ContactRow(
                                    contact: contact,
                                    isEditing: true,
                                    isChecked: checkedIDs.contains(contact.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        } else if linkRows {
                            NavigationLink(value: contact.id) {
                                ContactRow(contact: contact)
                            }
                        } else {
                            Button {
                                selection = contact.id
                            } label: {
                                ContactRow(contact: contact, isSelected: selection == contact.id)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                }
            }
        }
    }

    private func toggleEditing() {
        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    /// 多选删除：系统通讯录的删除是真实删除，成功后本机副本同步更新。
    private func deleteCheckedContacts() {
        let ids = checkedIDs
        guard !ids.isEmpty else { return }
        Task {
            let removed = await model.contacts.delete(ids: ids)
            guard removed else { return }
            if let selection, ids.contains(selection) { self.selection = nil }
            checkedIDs.removeAll()
            withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
        }
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

/// 联系人列表分组模型。
private struct ContactSection: Identifiable {
    let id: String
    let contacts: [ContactStore.Contact]
}

/// 联系人行：头像 + 姓名；选中态用系统列表选择的浅灰胶囊。
private struct ContactRow: View {
    let contact: ContactStore.Contact
    var isSelected: Bool = false
    var isEditing: Bool = false
    var isChecked: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked)
            }
            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 40)
            Text(contact.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isEditing ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isEditing { return isChecked ? Color(uiColor: .secondarySystemFill) : Color.clear }
        return isSelected ? Color(uiColor: .secondarySystemFill) : Color.clear
    }
}

/// 联系人详情：图五版式——整块渐变底、大 monogram、四个动作圆钮、
/// 以及系统通讯录式的信息分组。
struct ContactDetailPane: View {
    @EnvironmentObject private var model: AppModel
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    /// 列表进入多选删除时收起本页的「编辑」，避免顶栏同时出现两个编辑按钮。
    var showsEditButton: Bool = true

    @State private var showingEditor = false

    private var primaryPhone: String? { contact.phones.first }
    private var primaryEmail: String? { contact.emails.first }
    private var monogram: String { Monogram.text(for: contact.name) ?? "" }

    var body: some View {
        ZStack {
            ContactPalette.gradient(for: contact.id)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    actionRow
                    infoCards
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pinnedScrollEdgeEffect()
        }
        .navigationBarTitleDisplayMode(.inline)
        .immersiveBars()
        .monochromeBarControls()
        .toolbar {
            if showsEditButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("编辑")) { showingEditor = true }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showingEditor, onDismiss: reloadContacts) {
            NativeContactCard(
                identifier: contact.id,
                showsNavigationBar: true,
                showsDoneButton: true,
                allowsEditing: true,
                startsInEditMode: true
            ) { _ in } onMessage: { _ in }
            .presentationSizingIfAvailable()
            .presentationDragIndicator(.visible)
        }
    }

    /// 系统联系人卡片改完（或取消）后重新读取通讯录，本页显示的字段立即同步。
    private func reloadContacts() {
        Task { await model.contacts.requestAccessAndLoad() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Group {
                if let photoData = contact.photoData, let image = UIImage(data: photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(monogram)
                        .font(.system(size: 92, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.35)
                        .lineLimit(1)
                }
            }
            .frame(width: 188, height: 188)
            .background(Circle().fill(Color.white.opacity(0.12)))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))

            Text(contact.name)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            DetailActionCircle(
                title: L10n.t("信息"),
                systemImage: "message.fill",
                foreground: .white,
                background: .white.opacity(0.22),
                enabled: primaryPhone != nil
            ) {
                if let phone = primaryPhone { onMessage(phone) }
            }
            DetailActionCircle(
                title: L10n.t("呼叫"),
                systemImage: "phone.fill",
                foreground: .white,
                background: .white.opacity(0.22),
                enabled: primaryPhone != nil
            ) {
                if let phone = primaryPhone { onCall(phone) }
            }
            DetailActionCircle(
                title: L10n.t("视频"),
                systemImage: "video.fill",
                foreground: .white,
                background: .white.opacity(0.22),
                enabled: false
            ) {}
            DetailActionCircle(
                title: L10n.t("邮件"),
                systemImage: "envelope.fill",
                foreground: .white,
                background: .white.opacity(0.22),
                enabled: primaryEmail != nil
            ) {
                if let email = primaryEmail, let url = URL(string: "mailto:\(email)") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private var infoCards: some View {
        VStack(spacing: 14) {
            InfoCard {
                InfoCardRow(
                    title: L10n.t("共享的姓名和照片"),
                    value: L10n.t("共享已关闭"),
                    systemImage: nil,
                    showsChevron: true,
                    leadingAvatar: contact.photoData,
                    isInteractive: false
                ) {}
            }

            if !contact.emails.isEmpty {
                InfoCard {
                    ForEach(Array(contact.emails.enumerated()), id: \.offset) { index, email in
                        if index > 0 { InfoCardDivider() }
                        InfoCardRow(
                            title: L10n.t("电子邮件"),
                            value: email,
                            systemImage: "envelope.fill"
                        ) {
                            if let url = URL(string: "mailto:\(email)") {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }

            if !contact.phones.isEmpty {
                InfoCard {
                    ForEach(Array(contact.phones.enumerated()), id: \.offset) { index, phone in
                        if index > 0 { InfoCardDivider() }
                        InfoCardRow(
                            title: L10n.t("电话"),
                            value: phone,
                            systemImage: "phone.fill"
                        ) {
                            onCall(phone)
                        }
                    }
                }
            }

            InfoCard {
                InfoCardRow(title: L10n.t("备注"), value: nil, systemImage: nil, showsChevron: false, isInteractive: false) {}
            }

            InfoCard {
                InfoCardRow(title: L10n.t("共享联系人"), value: nil, systemImage: nil, showsChevron: true, isInteractive: false) {}
                InfoCardDivider()
                InfoCardRow(title: L10n.t("添加到个人收藏"), value: nil, systemImage: nil, showsChevron: true, isInteractive: false) {}
            }
        }
    }
}

/// 联系人详情里的半透明信息卡（图五的橙色卡片）。
private struct InfoCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InfoCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

private struct InfoCardRow: View {
    let title: String
    var value: String? = nil
    var systemImage: String? = nil
    var showsChevron: Bool = false
    var leadingAvatar: Data? = nil
    var isInteractive: Bool = true
    let action: () -> Void

    var body: some View {
        Group {
            if isInteractive {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            if let leadingAvatar, let image = UIImage(data: leadingAvatar) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.85))
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
// MARK: - 信息（iMessage 版式）

/// 会话模型：iMessage 按对端号码分组。
private struct Conversation: Identifiable {
    let id: String
    let messages: [SMSMessage]
    var last: SMSMessage? { messages.last }
}

/// 「信息」板块：左侧消息列表（顶栏「三条杠分类 + 编辑」，下方搜索框），
/// 右侧聊天窗口（左上角新消息按钮、正上方头像与昵称、下方输入框）。
/// 点聊天窗口里的联系人名称会显示对方详细信息面板。
///
/// iPad 用两列各自的 `NavigationStack`（与系统「信息」App 一致）：
/// 左列顶栏放「分类 / 编辑 / 搜索」，右列顶栏放「新信息 / 视频」，
/// 两条顶栏等高并排，不会出现重复按钮。
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var pendingRecipient: String?

    @State private var selection: String?
    @State private var search = ""
    @State private var showsUnknownOnly = false
    @State private var showingCompose = false
    @State private var composeRecipient = ""
    @State private var isEditing = false
    @State private var checkedIDs = Set<String>()

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var allConversations: [Conversation] {
        let grouped = Dictionary(grouping: model.messages) { $0.sender }
        return grouped
            .map { Conversation(id: $0.key, messages: $0.value.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { ($0.last?.timestamp ?? .distantPast) > ($1.last?.timestamp ?? .distantPast) }
    }

    private var filteredConversations: [Conversation] {
        allConversations.filter { conversation in
            if showsUnknownOnly && model.contacts.contact(for: conversation.id) != nil { return false }
            guard !search.isEmpty else { return true }
            let name = model.contacts.contact(for: conversation.id)?.name ?? conversation.id
            if name.localizedCaseInsensitiveContains(search) { return true }
            if conversation.id.contains(search) { return true }
            return conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        Group {
            if isRegular { regularBody } else { compactBody }
        }
        .task { await model.contacts.loadIfNeeded() }
        .onChange(of: pendingRecipient) { value in
            guard let value, !value.isEmpty else { return }
            selection = value
            composeRecipient = value
            pendingRecipient = nil
        }
        .sheet(isPresented: $showingCompose) {
            NewMessageSheet(initialRecipient: composeRecipient) { recipient in
                selection = recipient
            }
            .presentationSizingIfAvailable()
        }
    }

    // MARK: iPad 双列

    private var regularBody: some View {
        HStack(spacing: 0) {
            NavigationStack {
                VStack(spacing: 0) {
                    PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    List {
                        conversationRows(linkRows: false)
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.interactively)
                }
                .navigationTitle(isEditing ? L10n.t("已选择 \(checkedIDs.count) 项") : L10n.t("信息"))
                .navigationBarTitleDisplayMode(.inline)
                // 左列顶栏只有分类 / 编辑；右列顶栏是新信息 / 视频，与系统「信息」App 一致。
                .toolbar { listToolbar(showsCompose: false) }
                .immersiveBars()
            }
            .frame(width: 380)

            Divider()

            Group {
                if let handle = selection {
                    NavigationStack {
                        ChatPane(handle: handle) {
                            composeRecipient = ""
                            showingCompose = true
                        }
                    }
                } else {
                    EmptyStateView(title: L10n.t("选择信息开始聊天"), systemImage: "message")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: iPhone 单栏

    private var compactBody: some View {
        NavigationStack {
            List {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                conversationRows(linkRows: !isEditing)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? L10n.t("已选择 \(checkedIDs.count) 项") : L10n.t("信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { listToolbar(showsCompose: true) }
            .immersiveBars()
            .navigationDestination(for: String.self) { handle in
                ChatPane(handle: handle) {
                    composeRecipient = ""
                    showingCompose = true
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func listToolbar(showsCompose: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if !isEditing { filterMenu }
            PhoneEditToggle(isEditing: isEditing) { toggleEditing() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isEditing {
                Button(role: .destructive) {
                    deleteCheckedConversations()
                } label: {
                    Image(systemName: "trash")
                }
                .tint(Color.red)
                .disabled(checkedIDs.isEmpty)
                .accessibilityLabel(L10n.t("删除"))
            } else if showsCompose {
                composeButton
            }
        }
    }

    private var composeButton: some View {
        Button {
            composeRecipient = ""
            showingCompose = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .tint(Color.primary)
        .accessibilityLabel(L10n.t("新信息"))
    }

    @ViewBuilder
    private func conversationRows(linkRows: Bool) -> some View {
        if filteredConversations.isEmpty {
            EmptyStateView(title: L10n.t("暂无短信"), systemImage: "message")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(filteredConversations) { conversation in
                if isEditing {
                    Button {
                        toggleCheck(conversation.id)
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            isEditing: true,
                            isChecked: checkedIDs.contains(conversation.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } else if linkRows {
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation)
                    }
                } else {
                    Button {
                        selection = conversation.id
                    } label: {
                        ConversationRow(conversation: conversation, isSelected: selection == conversation.id)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
    }

    /// 三条杠分类按钮：只看陌生发件人 / 全部会话。
    private var filterMenu: some View {
        Menu {
            Picker(L10n.t("筛选"), selection: $showsUnknownOnly) {
                Text(L10n.t("全部信息")).tag(false)
                Text(L10n.t("未知发件人")).tag(true)
            }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .tint(Color.primary)
        .accessibilityLabel(L10n.t("筛选"))
    }

    private func toggleEditing() {
        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    /// 删除整个会话：把该号码名下所有短信一起删除（与系统「信息」App 一致）。
    private func deleteCheckedConversations() {
        var ids = Set<String>()
        for conversation in allConversations where checkedIDs.contains(conversation.id) {
            ids.formUnion(conversation.messages.map(\.id))
        }
        guard !ids.isEmpty else { return }
        model.deleteMessages(ids: ids)
        if let selection, checkedIDs.contains(selection) { self.selection = nil }
        checkedIDs.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }
}

/// 会话行：头像 + 姓名 + 预览 + 右侧时间。
/// 选中态是系统蓝胶囊（与系统「信息」App 一致）；编辑态左侧显示圆形复选框。
private struct ConversationRow: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    var isSelected: Bool = false
    var isEditing: Bool = false
    var isChecked: Bool = false

    private var displayName: String {
        model.contacts.contact(for: conversation.id)?.name ?? conversation.id
    }

    private var photoData: Data? {
        model.contacts.contact(for: conversation.id)?.photoData
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked)
            }

            InitialAvatar(name: displayName, photoData: photoData, size: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(conversation.last?.content ?? "")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let timestamp = conversation.last?.timestamp {
                Text(Self.rowTimestampText(timestamp))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isEditing ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isEditing { return isChecked ? Color(uiColor: .secondarySystemFill) : Color.clear }
        return isSelected ? Color(uiColor: .systemBlue) : Color.clear
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

/// 聊天窗口：正上方是联系人头像与昵称（点名称进入对方信息面板），
/// 下方是消息与输入框。名称与输入框都是 iOS 26 的长条液态玻璃胶囊，
/// 消息列表不画分割线；输入条固定在窗口底部，不随输入法键盘上移。
struct ChatPane: View {
    @EnvironmentObject private var model: AppModel
    let handle: String
    let onCompose: () -> Void

    @State private var draft = ""
    @State private var showingContactInfo = false

    private var messages: [SMSMessage] {
        model.messages
            .filter { $0.sender == handle }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var displayName: String {
        model.contacts.contact(for: handle)?.name ?? handle
    }

    private var photoData: Data? {
        model.contacts.contact(for: handle)?.photoData
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        header
                            .padding(.bottom, 10)
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if let day = dayHeader(for: message.timestamp, previous: index > 0 ? messages[index - 1].timestamp : nil) {
                                Text(day)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            MessageBubble(message: message)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 76)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToLast(proxy, animated: false) }
                .onChange(of: messages.count) { _ in scrollToLast(proxy, animated: true) }
            }

            composer
        }
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                }
                .tint(Color.primary)
                .accessibilityLabel(L10n.t("新信息"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "video")
                }
                .tint(Color.primary)
                .disabled(true)
                .accessibilityLabel(L10n.t("视频"))
            }
        }
        .immersiveBars()
        .navigationDestination(isPresented: $showingContactInfo) {
            ChatContactInfoPanel(handle: handle)
        }
    }

    /// 正上方居中的大头像 + 长条液态玻璃昵称胶囊（胶囊下缘压住头像），点它进入对方信息面板。
    private var header: some View {
        Button { showingContactInfo = true } label: {
            VStack(spacing: -24) {
                InitialAvatar(name: displayName, photoData: photoData, size: 104)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 1))

                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .modifier(GlassCapsuleBackground())

                    Text(L10n.t("iMessage 信息"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .zIndex(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("联系人信息"))
    }

    /// 底部输入条：整条液态玻璃胶囊，发送 / 语音按钮在胶囊内部；
    /// 没有文字时显示语音输入，有文字时显示发送。输入条固定在窗口底部，不随输入法键盘上移。
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button {
                    Task { await model.refreshMessages() }
                } label: {
                    Label(L10n.t("刷新"), systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    model.clearLocalMessages()
                } label: {
                    Label(L10n.t("清空全部短信"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("更多"))

            HStack(alignment: .bottom, spacing: 4) {
                TextField(L10n.t("iMessage 信息"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.leading, 16)
                    .padding(.vertical, 8)

                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DictationButton { recognized in
                        draft = recognized
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color(uiColor: .systemBlue)))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .padding(.bottom, 3)
                    .accessibilityLabel(L10n.t("发送"))
                }
            }
            .modifier(GlassCapsuleBackground())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { _ = await model.sendSMS(to: handle, content: text) }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func dayHeader(for date: Date, previous: Date?) -> String? {
        let calendar = Calendar.current
        if let previous, calendar.isDate(previous, inSameDayAs: date) { return nil }
        if calendar.isDateInToday(date) { return L10n.t("今天") }
        if calendar.isDateInYesterday(date) { return L10n.t("昨天") }
        return date.formatted(.dateTime.year().month().day().weekday(.wide))
    }
}

/// 长条液态玻璃胶囊底：iOS 26 用系统 glassEffect，旧系统用系统填充色。
private struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(Capsule(style: .continuous).fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}

/// 消息气泡：自己发的在右侧系统蓝底，对方发的在左侧系统灰底。
private struct MessageBubble: View {
    let message: SMSMessage

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                message.isOutgoing
                                    ? Color(uiColor: .systemBlue)
                                    : Color(uiColor: .secondarySystemBackground)
                            )
                    )
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .id(message.id)
    }
}
/// 对方详细信息面板（参考图三）：× / 编辑、大头像、号码/邮箱、三个圆钮、
/// 「资料 / 背景」分段、电子邮件、新建联系人、开关组、屏蔽与密钥验证说明。
/// 带颜色的背景铺满全屏，所有内容都落在这块背景里。
struct ChatContactInfoPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let handle: String

    @State private var tab = 0
    @State private var hideAlerts = false
    @State private var sendReadReceipts = true
    @State private var shareFocusStatus = true
    @State private var blocked = false
    @State private var showingEditor = false
    @State private var showingNewContact = false

    private var contact: ContactStore.Contact? { model.contacts.contact(for: handle) }
    private var displayName: String { contact?.name ?? handle }
    private var photoData: Data? { contact?.photoData }

    var body: some View {
        ZStack {
            ContactPalette.gradient(for: handle)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header

                    Picker("", selection: $tab) {
                        Text(L10n.t("资料")).tag(0)
                        Text(L10n.t("背景")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if tab == 0 {
                        detailsTab
                    } else {
                        EmptyStateView(title: L10n.t("暂无共享背景"), systemImage: "photo")
                            .frame(height: 180)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .immersiveBars()
        .monochromeBarControls()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L10n.t("关闭"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("编辑")) { showingEditor = true }
                    .fontWeight(.semibold)
            }
        }
.sheet(isPresented: $showingEditor) {
            if let contact {
                NativeContactCard(
                    identifier: contact.id,
                    showsNavigationBar: true,
                    showsDoneButton: true,
                    allowsEditing: true,
                    startsInEditMode: true
                ) { _ in } onMessage: { _ in }
                .presentationSizingIfAvailable()
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingNewContact) {
            ContactNativeNew(contactStore: CNContactStore()) {
                Task { await model.contacts.requestAccessAndLoad() }
            }
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            InitialAvatar(name: displayName, photoData: photoData, size: 110)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            Text(displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)

            HStack(spacing: 24) {
                DetailActionCircle(
                    title: L10n.t("电话"),
                    systemImage: "phone.fill",
                    foreground: .white,
                    background: .white.opacity(0.22)
                ) {
                    if let phone = contact?.phones.first {
                        model.numberInput = phone
                        Task { await model.dial() }
                    }
                }
                DetailActionCircle(
                    title: L10n.t("视频"),
                    systemImage: "video.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: false
                ) {}
                DetailActionCircle(
                    title: L10n.t("邮件"),
                    systemImage: "envelope.fill",
                    foreground: .white,
                    background: .white.opacity(0.22),
                    enabled: contact?.emails.isEmpty == false
                ) {
                    if let email = contact?.emails.first, let url = URL(string: "mailto:\(email)") {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var detailsTab: some View {
        VStack(spacing: 14) {
            InfoCard {
                if let emails = contact?.emails, !emails.isEmpty {
                    ForEach(Array(emails.enumerated()), id: \.offset) { index, email in
                        if index > 0 { InfoCardDivider() }
                        InfoCardRow(
                            title: L10n.t("电子邮件"),
                            value: email,
                            systemImage: "envelope.fill"
                        ) {
                            if let url = URL(string: "mailto:\(email)") {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else {
                    InfoCardRow(
                        title: L10n.t("电子邮件"),
                        value: handle,
                        systemImage: "envelope.fill",
                        isInteractive: false
                    ) {}
                }
            }

            InfoCard {
                InfoCardRow(title: L10n.t("新建联系人"), value: nil, systemImage: nil, showsChevron: true) {
                    showingNewContact = true
                }
                if contact != nil {
                    InfoCardDivider()
                    InfoCardRow(title: L10n.t("添加到现有联系人"), value: nil, systemImage: nil, showsChevron: true) {
                        showingEditor = true
                    }
                }
            }

            InfoCard {
                InfoCardToggleRow(title: L10n.t("隐藏提醒"), isOn: $hideAlerts)
                InfoCardDivider()
                InfoCardToggleRow(title: L10n.t("发送已读回执"), isOn: $sendReadReceipts)
                InfoCardDivider()
                InfoCardToggleRow(title: L10n.t("共享专注模式状态"), isOn: $shareFocusStatus)
            }

            InfoCard {
                Button {
                    blocked.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(blocked ? L10n.t("取消屏蔽联系人") : L10n.t("屏蔽联系人"))
                            .font(.body)
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            InfoCard {
                InfoCardRow(
                    title: L10n.t("打开联系人密钥验证"),
                    value: nil,
                    systemImage: nil,
                    showsChevron: true
                ) {}
                InfoCardDivider()
                Text("所有 iMessage 信息对话均采用安全的端对端加密，以便其在设备间发送时无法被读取。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }
}

/// 渐变信息卡里的开关行（系统设置式右对齐开关）。
private struct InfoCardToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body)
                .foregroundStyle(.white)
        }
        .tint(Color(uiColor: .systemGreen))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 新信息撰写表：收件人 + 内容，发送后切到对应会话。
struct NewMessageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initialRecipient: String
    let onSent: (String) -> Void

    @State private var recipient = ""
    @State private var content = ""
    @State private var isSending = false

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("收件人"), text: $recipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField(L10n.t("短信内容"), text: $content, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t("新信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .tint(Color.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("发送")) { send() }
                        .disabled(!canSend)
                        .fontWeight(.semibold)
                        .tint(Color.primary)
                }
            }
        }
        .onAppear {
            if recipient.isEmpty { recipient = initialRecipient }
        }
    }

    private func send() {
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !body.isEmpty else { return }
        isSending = true
        Task {
            let sent = await model.sendSMS(to: target, content: body)
            isSending = false
            if sent {
                onSent(target)
                dismiss()
            }
        }
    }
}

/// 麦克风语音输入按钮（Speech 框架，识别结果实时回调填入输入位置）。
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
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isRecording ? Color(uiColor: .systemRed) : Color.secondary)
                .frame(width: 32, height: 32)
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
// MARK: - 系统联系人卡片封装

/// 系统原生联系人卡片（CNContactViewController）。
/// 传入通讯录 identifier 时直接展示该联系人；否则按号码构造临时卡片。
/// 号码动作交给系统选择器，用户可明确「发信息 / 拨打电话」，不会被误路由成拨号。
private struct NativeContactCard: UIViewControllerRepresentable {
    var contact: CNContact? = nil
    var identifier: String? = nil
    var phone: String? = nil
    var showsNavigationBar: Bool = true
    var showsDoneButton: Bool = false
    var allowsEditing: Bool = false
    /// 直接以编辑态呈现：避免用户点了「编辑」后系统卡片仍停在查看态，还要再点一次。
    var startsInEditMode: Bool = false
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

        let controller = CNContactViewController(for: resolved)
        controller.contactStore = store
        controller.delegate = context.coordinator
        // 只有通讯录里真实存在的联系人才能进入编辑态；陌生号码的临时卡片不可编辑。
        let canEdit = allowsEditing && (contact != nil || identifier != nil)
        controller.allowsEditing = canEdit
        controller.allowsActions = true
        context.coordinator.contactViewController = controller

        if canEdit, startsInEditMode {
            // `setEditing` 是 UIKit 公开 API，系统卡片的「编辑」按钮走的也是它，
            // 因此这里可以让卡片一出现就是编辑态，不再套一层查看页。
            DispatchQueue.main.async {
                controller.setEditing(true, animated: false)
            }
        }

        // 不要导航栏时直接返回卡片本身：多包一层 UINavigationController 会
        // 在详情列里多出一条空导航栏（顶部留白 + 两个返回按钮）。
        guard showsNavigationBar else { return controller }
        let nav = UINavigationController(rootViewController: controller)
        nav.navigationBar.prefersLargeTitles = false
        if showsDoneButton {
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
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

        /// 编辑保存（或取消）后收起卡片，由 SwiftUI 侧的 onDismiss 触发通讯录刷新。
        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            viewController.dismiss(animated: true)
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
struct ContactNativeNew: UIViewControllerRepresentable {
    let contactStore: CNContactStore
    var onFinish: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(forNewContact: nil)
        controller.contactStore = contactStore
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(contactStore: contactStore, onFinish: onFinish)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let contactStore: CNContactStore
        let onFinish: (() -> Void)?

        init(contactStore: CNContactStore, onFinish: (() -> Void)?) {
            self.contactStore = contactStore
            self.onFinish = onFinish
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
            onFinish?()
            viewController.dismiss(animated: true)
        }
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

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var keySize: CGFloat { isCompact ? 64 : 74 }
    private var keySpacing: CGFloat { isCompact ? 22 : 30 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }

    var body: some View {
        VStack(spacing: 20) {
            keypadRows
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
            ForEach(Array(dialPadRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        Button {
                            Task { await model.sendDTMF(key.0) }
                        } label: {
                            dtmfLabel(digit: key.0, letters: key.1)
                                .modifier(DialKeyBackground())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key.1.isEmpty ? key.0 : "\(key.0) \(key.1)")
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
