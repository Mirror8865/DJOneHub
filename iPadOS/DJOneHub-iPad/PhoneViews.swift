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
                    .modifier(GlassCircle(tint: background))
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
    private var keySize: CGFloat { isCompact ? 52 : 56 }
    private var keySpacing: CGFloat { isCompact ? 16 : 20 }
    private var rowSpacing: CGFloat { isCompact ? 6 : 8 }
    private var matchedName: String? {
        model.contacts.contact(for: model.numberInput)?.name
    }
    private var callDisabled: Bool {
        model.numberInput.isEmpty || model.isBusy || !model.isOnline
    }

    var body: some View {
        card
            .onDisappear { stopDeleteRepeat() }
    }

    private var card: some View {
        VStack(spacing: isCompact ? 10 : 12) {
            numberDisplay
            keypad
            callRow
        }
        .padding(.horizontal, isCompact ? 14 : 18)
        .padding(.vertical, isCompact ? 12 : 16)
        .frame(maxWidth: 268)
        .modifier(DialPadCardBackground())
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        // 点击卡片内任意非按键区域也能退出键盘。
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .onTapGesture { close() }
    }

    private var numberDisplay: some View {
        VStack(spacing: 2) {
            Text(model.numberInput.isEmpty ? L10n.t("输入号码") : model.numberInput)
                .font(.system(size: isCompact ? 22 : 26, weight: .regular, design: .rounded))
                .foregroundStyle(model.numberInput.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
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

    /// 获得焦点时系统会给搜索框描一圈强调色圆角边（iOS 26 文本输入焦点样式）。
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFocused)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("清除"))
            }
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        // iOS 26 标准搜索框：两端纯圆胶囊 + 交互式液态玻璃（按住有回弹），聚焦时弹簧放大。
        .modifier(GlassSearchFieldBackground())
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    isFocused ? Color(uiColor: .systemBlue) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Capsule(style: .continuous))
        .modifier(GlassFocusBounce(isActive: isFocused))
    }
}

/// 顶栏「编辑 / 完成」按钮：浅色下黑字、深色下白字，不使用强调色蓝。
/// 自己画而不是直接用 `EditButton`，是为了让三个板块共用同一套多选删除逻辑。
struct PhoneEditToggle: View {
    let isEditing: Bool
    /// 进入多选时显示的标题；联系人页用「选择」，避免与详情页的「编辑」撞名。
    var enterTitle: String = L10n.t("编辑")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isEditing ? L10n.t("完成") : enterTitle)
                .fontWeight(isEditing ? .semibold : .regular)
        }
        .tint(Color.primary)
        .accessibilityLabel(isEditing ? L10n.t("完成") : enterTitle)
    }
}

/// 编辑态左侧的圆形复选框：选中为系统蓝实心对勾，未选中为灰色空心圈。
/// 行本身已经是蓝底时（onHighlight）自动换成白色，避免蓝底上看不见蓝色对勾。
///
/// 勾选 / 取消勾选是即时状态，不做任何补间：`List` 回收单元格时，过渡动画会留下
/// 画了一半的圆环（看起来像复选框被遮住、显示不全）；而且系统「信息 / 通讯录 / 电话」
/// 的多选勾选本身就是立刻切换、不带动画的。
struct PhoneSelectionCircle: View {
    let isSelected: Bool
    var onHighlight: Bool = false

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(selectionColor)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private var selectionColor: Color {
        if isSelected { return onHighlight ? Color.white : Color(uiColor: .systemBlue) }
        return onHighlight ? Color.white.opacity(0.75) : Color(uiColor: .tertiaryLabel)
    }
}

/// 列表选中 / 勾选高亮：系统蓝圆角矩形。行本身用 listRowInsets 左右各内缩 16pt，
/// 所以高亮比列表容器窄一圈，左右边缘与左列顶部的搜索框对齐（iOS 26 列表选中样式）。
struct PhoneSelectionHighlight: View {
    var isActive: Bool
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isActive ? Color(uiColor: .systemBlue) : Color.clear)
    }
}

/// 多选合并高亮：相邻选中行只保留整块外侧的圆角，
/// 视觉上并成一个大的蓝色圆角矩形（圆角半径不变）。
struct PhoneMergedSelectionHighlight: View {
    var isActive: Bool
    var isFirst: Bool = true
    var isLast: Bool = true
    var cornerRadius: CGFloat = 20

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? cornerRadius : 0,
            bottomLeadingRadius: isLast ? cornerRadius : 0,
            bottomTrailingRadius: isLast ? cornerRadius : 0,
            topTrailingRadius: isFirst ? cornerRadius : 0,
            style: .continuous
        )
        .fill(isActive ? Color(uiColor: .systemBlue) : Color.clear)
    }
}

/// 多选合并高亮：判断当前行是否为选中块的首行（上一行未选中或已到顶）。
func mergedSelectionIsFirst(_ index: Int, ids: [String], checked: Set<String>) -> Bool {
    index == 0 || !checked.contains(ids[index - 1])
}

/// 多选合并高亮：判断当前行是否为选中块的末行（下一行未选中或已到底）。
func mergedSelectionIsLast(_ index: Int, ids: [String], checked: Set<String>) -> Bool {
    index == ids.count - 1 || !checked.contains(ids[index + 1])
}

/// 侧栏点选是**即时**状态：选中高亮与右侧内容都直接切换，不做任何过渡动画。
///
/// 系统「电话 / 联系人 / 信息 / 设置」的侧栏点选本身都没有过渡；
/// SwiftUI 的 `Button` / `List` 会带一段自己的默认动画，把「立刻变蓝」
/// 渲染成一段渐变。这里用显式 transaction 把整棵子树的补间关掉。
@inline(__always)
func withoutAnimations(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

/// 搜索框底：iOS 26 两端纯圆的交互式液态玻璃胶囊；旧系统回退系统填充色胶囊。
struct GlassSearchFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            content.background(
                Capsule(style: .continuous).fill(Color(uiColor: .tertiarySystemFill))
            )
        }
    }
}

/// 输入控件的「q 弹」反馈：聚焦 / 失焦时按弹簧曲线轻微放大再回弹（iOS 26 交互式玻璃手感）。
struct GlassFocusBounce: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive ? 1.015 : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.52), value: isActive)
    }
}

/// 详情页大头像底：iOS 26 液态玻璃圆；旧系统回退半透明白圆。
struct GlassAvatarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(Circle().fill(Color.white.opacity(0.16)))
        }
    }
}

/// 详情页大头像：液态玻璃圆底 + 照片 / 白色 monogram / 人像。
struct GlassAvatar: View {
    let name: String
    var photoData: Data? = nil
    var size: CGFloat = 110

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let monogram = Monogram.text(for: name) {
                Text(monogram)
                    .font(.system(size: size * 0.40, weight: .medium))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .modifier(GlassAvatarBackground())
    }
}

/// 分栏版式左列：系统灰底（列表区），与系统 App 的双栏左列一致。
struct PhoneSplitListColumn<Content: View>: View {
    /// 会话自定义壁纸：设了本列就压一层系统材质（模糊身后那张壁纸）。
    var wallpaper: UIImage? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if let wallpaper {
                    // 本列在 `NavigationStack` 里面，所以这里画出来的图一定看得见；
                    // 再压一层系统材质把它磨砂掉，左列就是「模糊壁纸侧栏」。
                    // 只压材质不画图是看不到东西的——分栏容器底下那层会被
                    // `NavigationStack` 的不透明底色整块盖住。
                    ChatWallpaperFill(image: wallpaper, dim: 0.16)
                        .ignoresSafeArea()
                        .overlay {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .ignoresSafeArea()
                        }
                } else {
                    // 左列比右列更深一档（systemGray5：浅色 #E5E5EA / 深色 #2C2C2E），
                    // 与右列的系统白 / 纯黑形成系统设置 App 那种层次。
                    Color(uiColor: .systemGray5).ignoresSafeArea()
                }
            }
    }
}

/// 四个板块共用的分栏尺寸。
///
/// 抽成常量是为了让「会话壁纸」也能用同一套规则算出左列宽度：
/// 壁纸必须知道右列在窗口里的起点，才能让左右两列显示同一张图的连续裁切。
enum PhoneSplitLayout {
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 560

    /// 左列上限：右列至少保留 360pt。
    static func limit(containerWidth: CGFloat) -> CGFloat {
        max(minWidth, min(maxWidth, containerWidth - 360))
    }

    /// 按持久宽度算出实际左列宽度（与 `PhoneSplitContainer` 内部完全一致）。
    static func leftWidth(stored: Double, containerWidth: CGFloat) -> CGFloat {
        min(max(CGFloat(stored), minWidth), limit(containerWidth: containerWidth))
    }
}

/// 会话壁纸的「一次铺满」绘制：`scaledToFill` 到所在视图的完整尺寸，永远不留白。
///
/// 关键用法约束：**必须画在 `NavigationStack` 的内容里面**。分栏两列各自的
/// `NavigationStack` 会盖上一层不透明底色，把壁纸画在分栏容器底下（含根视图那一层）
/// 会被整块盖住，表现就是「设了背景却完全看不到」。`PhoneSplitListColumn`
/// 与 `ChatPane` 都在 `NavigationStack` 内部，所以它们才画得出这张图。
struct ChatWallpaperFill: View {
    let image: UIImage
    /// 压一层黑色，保证气泡与文字在任意照片上都有对比度。
    var dim: Double = 0

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(Color.black.opacity(dim))
        }
    }
}

/// 根视图层的会话壁纸：整窗铺满（含状态栏 / 顶部导航栏 / 底部导航栏）。
///
/// 这一层是「兜底」：只要标签容器在那些带子上是透的，它就把壁纸补到边；
/// 真正保证内容区一定能看到壁纸的，是每一列 `NavigationStack` 内部各自画的那一层。
struct ChatWallpaperRootLayer: View {
    let image: UIImage

    var body: some View {
        ChatWallpaperFill(image: image)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 四个板块（通话 / 联系人 / 信息 / 设置）共用的双栏容器。
///
/// 左列宽度由用户拖动中间的分栏手柄调节，并写入同一个 `AppStorage` 键，
/// 因此四个板块始终共用同一宽度。手柄静止时完全不可见（列表之间没有分割线）。
///
/// 拖动期间两列**实时**跟随手指改宽度，做法遵循 SwiftUI 官方规范：
/// - 瞬时位移放在 `@GestureState` 里（手势结束由 SwiftUI 自动归零，无需手写清理，
///   也不会在拖动中反复写 `@State`）；只有松手提交持久宽度时才写 `@Binding`。
/// - 宽度不取整：整点量化会造成 1pt 跳变，正是「抽搐」的来源。
/// - 宽度变化这条链路上显式 `.animation(nil, value:)`，把隐式补间关掉，
///   列表只会随宽度重排，不会被补间来回插值成闪烁。
/// - 每一行的行高与宽度无关（行内文本 lineLimit + 固定头像尺寸），
///   所以改宽度只会触发水平重排，不会引起行高变化。
/// - 手柄本身会跟着手指移动，所以手势坐标必须挂在一个静止的命名空间上。
private let splitDragCoordinateSpace = "djonehub.split.drag"

struct PhoneSplitContainer<Left: View, Right: View>: View {
    @Binding var leftWidth: Double
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    /// 手柄命中区宽度：比可见指示线宽，便于用手指或触控板抓住。
    private let handleWidth: CGFloat = 20

    /// 拖动位移：手势期间实时参与左列布局，手势结束自动归零。
    @GestureState private var dragOffset: CGFloat = 0
    /// 是否正在拖动：同样交给手势状态驱动，手势被取消也能自动复位。
    @GestureState private var isDragging = false
    @State private var isHoveringHandle = false

    var body: some View {
        GeometryReader { proxy in
            // 右列至少保留 360pt，窗口变窄时左列自动收紧上限。
            let limit = PhoneSplitLayout.limit(containerWidth: proxy.size.width)
            let width = min(max(CGFloat(leftWidth) + dragOffset, PhoneSplitLayout.minWidth), limit)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    left
                        .frame(width: width, alignment: .leading)
                        .frame(maxHeight: .infinity)
                    right
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                handle(limit: limit)
                    .offset(x: width - handleWidth / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 宽度与拖动状态都不做补间：两侧列表的宽度变化必须是逐帧直出的，
            // 一旦被隐式动画插值，列表重排就会表现为抖动 / 闪烁。
            .animation(nil, value: width)
            .animation(nil, value: isDragging)
            // 拖动期间按官方 transaction 做法把整棵子树的隐式动画全部关掉：
            // 行内容里只要有一处隐式动画（状态圆点、选中高亮、材质过渡），
            // 都会在逐帧改宽度时被反复插值成闪一下，这里统一禁掉。
            .transaction { transaction in
                if isDragging {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
        .coordinateSpace(name: splitDragCoordinateSpace)
    }

    private func handle(limit: CGFloat) -> some View {
        ZStack {
            // 透明命中区：静止时看不到任何分割线。
            Color.clear.contentShape(Rectangle())
            Capsule(style: .continuous)
                .fill(Color(uiColor: .separator))
                .frame(width: 2)
                .opacity(isHoveringHandle || isDragging ? 1 : 0)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            // 不加补间：手柄会随指针微动，补间反而让指示线反复闪烁。
            isHoveringHandle = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(splitDragCoordinateSpace))
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.width
                }
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onEnded { value in
                    let target = CGFloat(leftWidth) + value.translation.width
                    leftWidth = Double(min(max(target, PhoneSplitLayout.minWidth), limit))
                }
        )
        .accessibilityLabel(L10n.t("调整分栏宽度"))
    }
}

/// 分栏版式右列：系统白底（详情区）。
struct PhoneSplitDetailColumn<Content: View>: View {
    var isTranslucent: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 半透明时不画自己的底色，交给外层统一铺会话背景，
                // 避免和左列各自绘一层导致两侧明暗不一致。
                if !isTranslucent {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                }
            }
    }
}

/// 详情页信息卡底：iOS 26 液态玻璃；旧系统回退为半透明卡片。
struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 22
    /// 可点击的卡片（如「共享」）需要交互式玻璃，按下时会有回弹。
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
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
    /// 四个板块共用左列宽度：拖动中间手柄后写入同一个 AppStorage 键。
    @AppStorage("djonehub.split.left-width") private var splitLeftWidth: Double = 360

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
            .overlay(alignment: .topTrailing) {
                if showingKeypad {
                    ZStack(alignment: .topTrailing) {
                        // 悬浮浮窗不压暗整屏：透明层只负责「点任意位置退出」。
                        Color.clear
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { dismissKeypad() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        // 悬浮在右上角拨号按钮旁边的小浮窗，不再全屏居中独占窗口。
                        DialPadOverlay(onDismiss: dismissKeypad)
                            .padding(.top, 6)
                            .padding(.trailing, 18)
                            .transition(
                                .scale(scale: 0.10, anchor: .topTrailing)
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
        // 左列系统灰底（列表）、右列系统白底（详情），与系统设置 App 的分栏一致。
        PhoneSplitContainer(leftWidth: $splitLeftWidth) {
            PhoneSplitListColumn {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                List {
                    callsRows
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                // 列表里的选中高亮必须"点下即亮"：整棵列表子树关掉补间，
                // 连 UIKit 那层单元格更新一起走 performWithoutAnimation，
                // 与系统「电话 / 联系人 / 信息 / 设置」的侧栏点选完全一致。
                .transaction { transaction in transaction.disablesAnimations = true }
            }
        } right: {
            PhoneSplitDetailColumn {
                if let call = selectedCall {
                    CallDetailPane(call: call, onMessage: onMessage, onCall: dialNumber)
                } else {
                    EmptyStateView(title: L10n.t("选择通话记录查看详情"), systemImage: "phone")
                }
            }
        }
        // 点选即时生效：选中高亮与右侧内容都直接切换，不做过渡动画。
        .animation(nil, value: selection)
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
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 子视图

    @ViewBuilder
    private var callsRows: some View {
        if filteredCalls.isEmpty {
            emptyCallsRow
        } else {
            let ids = filteredCalls.map(\.id)
            ForEach(Array(filteredCalls.enumerated()), id: \.element.id) { index, call in
                Button {
                    if isEditing {
                        toggleCheck(call.id)
                    } else {
                        withoutAnimations { selection = call.id }
                    }
                } label: {
                    RecentsRow(
                        call: call,
                        onCall: dialNumber,
                        isSelected: !isEditing && selection == call.id,
                        isEditing: isEditing,
                        isChecked: checkedIDs.contains(call.id),
                        isSelectionFirst: mergedSelectionIsFirst(index, ids: ids, checked: checkedIDs),
                        isSelectionLast: mergedSelectionIsLast(index, ids: ids, checked: checkedIDs)
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(rowInsets)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isEditing {
                        Button(role: .destructive) {
                            model.deleteCalls(ids: Set([call.id]))
                            if selection == call.id { selection = nil }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                            .tint(Color.red)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var compactCallsRows: some View {
        if filteredCalls.isEmpty {
            emptyCallsRow
        } else {
            let ids = filteredCalls.map(\.id)
            ForEach(Array(filteredCalls.enumerated()), id: \.element.id) { index, call in
                if isEditing {
                    Button {
                        toggleCheck(call.id)
                    } label: {
                        RecentsRow(
                            call: call,
                            onCall: dialNumber,
                            isEditing: true,
                            isChecked: checkedIDs.contains(call.id),
                            isSelectionFirst: mergedSelectionIsFirst(index, ids: ids, checked: checkedIDs),
                            isSelectionLast: mergedSelectionIsLast(index, ids: ids, checked: checkedIDs)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                } else {
                    NavigationLink(value: call.id) {
                        RecentsRow(call: call, onCall: dialNumber, isSelected: false)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.deleteCalls(ids: Set([call.id]))
                            if selection == call.id { selection = nil }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                            .tint(Color.red)
                        }
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
        // 进入 / 退出编辑是即时状态，不做过渡动画：系统「电话 / 通讯录 / 信息」
        // 的编辑态切换本身就是瞬间完成。
        isEditing.toggle()
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        // 勾选同理：状态直接切换，蓝色复选框立刻出现，不做补间。
        withoutAnimations {
            if checkedIDs.contains(id) {
                checkedIDs.remove(id)
            } else {
                checkedIDs.insert(id)
            }
        }
    }

    /// 编辑态去掉行间留白，让相邻选中行的高亮连成一整块。
    private var rowInsets: EdgeInsets {
        isEditing
            ? EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            : EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    }

    private func deleteCheckedCalls() {
        let ids = checkedIDs
        guard !ids.isEmpty else { return }
        model.deleteCalls(ids: ids)
        if let selection, ids.contains(selection) { self.selection = nil }
        checkedIDs.removeAll()
        isEditing = false
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
    /// 多选合并高亮：本行是否为选中块的首 / 末行，只有外侧保留圆角。
    var isSelectionFirst: Bool = true
    var isSelectionLast: Bool = true

    private var name: String { model.contacts.displayName(for: call.number) }
    private var photo: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    /// 蓝底高亮：普通选中与多选勾选共用同一套蓝底白字。
    private var isHighlighted: Bool { isSelected || isChecked }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked, onHighlight: isHighlighted)
            }

            InitialAvatar(name: name, photoData: photo, size: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(isHighlighted ? Color.white : (call.missed ? Color.red : Color.primary))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(RecentCallTimeFormatter.string(for: call.updatedAt))
                .font(.subheadline)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)

            if !isEditing, let number = call.number {
                Button { onCall(number) } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(
                                isHighlighted
                                    ? Color.white
                                    : Color(uiColor: .systemBlue).opacity(0.14)
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("呼叫"))
            }
        }
        .frame(minHeight: 54)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(
            PhoneMergedSelectionHighlight(
                isActive: isHighlighted,
                isFirst: isSelectionFirst,
                isLast: isSelectionLast,
                cornerRadius: 20
            )
        )
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        // 用户主动拒接的来电在模块侧仍是 missed，本机按「已拒绝」显示。
        if model.isDeclinedCall(call) { return L10n.t("已拒绝") }
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
            // 大头像同样走液态玻璃圆底（与联系人详情 / 短信人详情一致）。
            GlassAvatar(name: name, photoData: photo, size: 124)
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
                .modifier(GlassCardBackground(cornerRadius: 14, interactive: true))
            }
        }
    }

    private var directionText: String {
        // 用户主动拒接的来电在模块侧仍是 missed，本机按「已拒绝」显示。
        if model.isDeclinedCall(call) { return L10n.t("已拒绝") }
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
    /// 四个板块共用左列宽度：拖动中间手柄后写入同一个 AppStorage 键。
    @AppStorage("djonehub.split.left-width") private var splitLeftWidth: Double = 360

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var contacts: [ContactStore.Contact] { model.contacts.contacts }

    /// 通讯录变化的本地重绘标记：`ContactStore` 是 AppModel 里嵌套的
    /// ObservableObject，只观察 model 的视图不会因为通讯录本身变化而重绘，
    /// 「新建联系人后列表不实时刷新」就是这个原因。见 body 里的 `onReceive`。
    @State private var contactsRevision = 0

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
        // 订阅通讯录存储自身的变更通知：新建 / 编辑 / 删除联系人后，
        // 左侧列表与右侧详情立刻重绘，不用再切换列表或点别的联系人去「带」出刷新。
        .onReceive(model.contacts.objectWillChange) { _ in contactsRevision &+= 1 }
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
            PhoneEditToggle(isEditing: isEditing, enterTitle: L10n.t("选择")) { toggleEditing() }
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
        // 左列系统灰底（列表）、右列系统白底（详情），与系统设置 App 的分栏一致。
        PhoneSplitContainer(leftWidth: $splitLeftWidth) {
            PhoneSplitListColumn {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                List {
                    contactRows(linkRows: false)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                // 列表里的选中高亮必须"点下即亮"：整棵列表子树关掉补间，
                // 连 UIKit 那层单元格更新一起走 performWithoutAnimation，
                // 与系统「电话 / 联系人 / 信息 / 设置」的侧栏点选完全一致。
                .transaction { transaction in transaction.disablesAnimations = true }
            }
        } right: {
            PhoneSplitDetailColumn {
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
        }
        // 点选即时生效：选中高亮与右侧内容都直接切换，不做过渡动画。
        .animation(nil, value: selection)
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
        .scrollContentBackground(.hidden)
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
                    let ids = section.contacts.map(\.id)
                    ForEach(Array(section.contacts.enumerated()), id: \.element.id) { index, contact in
                        if isEditing {
                            Button {
                                toggleCheck(contact.id)
                            } label: {
                                ContactRow(
                                    contact: contact,
                                    isEditing: true,
                                    isChecked: checkedIDs.contains(contact.id),
                                    isSelectionFirst: mergedSelectionIsFirst(index, ids: ids, checked: checkedIDs),
                                    isSelectionLast: mergedSelectionIsLast(index, ids: ids, checked: checkedIDs)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(rowInsets)
                        } else if linkRows {
                            NavigationLink(value: contact.id) {
                                ContactRow(contact: contact)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(rowInsets)
                        } else {
                            Button {
                                withoutAnimations { selection = contact.id }
                            } label: {
                                ContactRow(contact: contact, isSelected: selection == contact.id)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(rowInsets)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        let removed = await model.contacts.delete(ids: Set([contact.id]))
                                        guard removed else { return }
                                        if selection == contact.id { selection = nil }
                                    }
                                } label: {
                                    Label(L10n.t("删除"), systemImage: "trash")
                                    .tint(Color.red)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleEditing() {
        // 进入 / 退出编辑是即时状态，不做过渡动画：系统「电话 / 通讯录 / 信息」
        // 的编辑态切换本身就是瞬间完成。
        isEditing.toggle()
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        // 勾选同理：状态直接切换，蓝色复选框立刻出现，不做补间。
        withoutAnimations {
            if checkedIDs.contains(id) {
                checkedIDs.remove(id)
            } else {
                checkedIDs.insert(id)
            }
        }
    }

    /// 编辑态去掉行间留白，让相邻选中行的高亮连成一整块。
    private var rowInsets: EdgeInsets {
        isEditing
            ? EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            : EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
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
            isEditing = false
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
    /// 多选合并高亮：本行是否为选中块的首 / 末行，只有外侧保留圆角。
    var isSelectionFirst: Bool = true
    var isSelectionLast: Bool = true

    private var isHighlighted: Bool { isSelected || isChecked }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked, onHighlight: isHighlighted)
            }
            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 54)
            Text(contact.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 54)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(
            PhoneMergedSelectionHighlight(
                isActive: isHighlighted,
                isFirst: isSelectionFirst,
                isLast: isSelectionLast,
                cornerRadius: 20
            )
        )
        .contentShape(Rectangle())
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
            backdrop

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
                        // 顶栏文字按钮统一系统单色（浅色黑 / 深色白），不用强调色蓝。
                        .tint(Color.primary)
                }
            }
        }
        .sheet(isPresented: $showingEditor, onDismiss: reloadContacts) {
            NativeContactCard(
                identifier: contact.id,
                phone: primaryPhone,
                showsNavigationBar: true,
                showsDoneButton: true,
                allowsEditing: true,
                startsInEditMode: true
            ) { _ in } onMessage: { _ in }
            // 系统联系人卡片是 UIKit 控制器，给它一个确定的最小尺寸；
            // 用 `presentationSizing(.form)` 会让它在首次布局拿到 0 尺寸而整页空白。
            .frame(minWidth: 340, minHeight: 520)
            .presentationDragIndicator(.visible)
        }
    }

    /// 背景：按联系人派生的「海报渐变」铺满整屏，与系统联系人卡片的置身观感一致。
    private var backdrop: some View {
        // 自定义海报底：用按联系人稳定派生的渐变当「海报颜色」铺满整屏（含顶栏与状态栏），
        // 不再用照片放大 + 模糊 + 暗化（那种观感与系统联系人卡片不一致）。
        ContactPalette.gradient(for: contact.id).ignoresSafeArea()
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
            // 照片是 `scaledToFill` 的，必须自己裁成圆形：少了这一句，
            // 换过头像的联系人在详情页就是一个正方形照片 + 一个圆形描边
            // （看起来像「正方形里套了个头像框」），与系统联系人卡片不一致。
            .clipShape(Circle())
            .modifier(GlassAvatarBackground())
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
        .modifier(GlassCardBackground(cornerRadius: 22))
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
            if let leadingAvatar {
                // 共享控件等前置头像统一液态玻璃圆底（iOS 26）。
                GlassAvatar(name: title, photoData: leadingAvatar, size: 38)
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
    /// 用于显示的消息列表：同一条长短信的各段已经合回一个气泡（输出恒为「旧 → 新」）。
    let messages: [SMSMessage]
    /// 这些气泡背后的**本机原始记录** ID。删除时必须按真实记录打墓碑：
    /// 合并后的气泡 ID 是拼出来的，直接拿它去删，墓碑里记不到原始记录，
    /// 模块下一轮刷新就会把同一批分段原样回传，表现为「长短信删不掉」。
    let recordIDs: Set<String>
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
    /// 单栏（iPhone / iPad 窄分栏）导航路径：只用来同步会话壁纸。
    @State private var compactPath: [String] = []
    /// 四个板块共用左列宽度：拖动中间手柄后写入同一个 AppStorage 键。
    @AppStorage("djonehub.split.left-width") private var splitLeftWidth: Double = 360

    /// 会话背景（iOS 26「信息」的会话背景）：整窗铺满，
    /// 左列列表也透出同一张图，由左列自己叠系统材质做满模糊。
    @StateObject private var chatBackgrounds = ChatBackgroundStore.shared

    private var isRegular: Bool { horizontalSizeClass == .regular }

    /// 当前选中会话的自定义背景图；没设就为 nil，回到系统默认底色。
    private var conversationBackdrop: UIImage? {
        guard let handle = selection, let image = chatBackgrounds.image(for: handle) else { return nil }
        return image
    }

    private var allConversations: [Conversation] {
        let grouped = Dictionary(grouping: model.messages) { $0.sender }
        return grouped
            // 列表预览也要用合并后的完整内容，否则只能看到最后一段。
            .map { entry in
                Conversation(
                    id: entry.key,
                    messages: SMSMessage.chronological(entry.value),
                    recordIDs: Set(entry.value.map(\.id))
                )
            }
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
            withoutAnimations { selection = value }
            composeRecipient = value
            pendingRecipient = nil
        }
        .sheet(isPresented: $showingCompose) {
            NewMessageSheet(initialRecipient: composeRecipient) { recipient in
                withoutAnimations { selection = recipient }
            }
            .presentationSizingIfAvailable()
        }
    }

    // MARK: iPad 双列

    private var regularBody: some View {
        GeometryReader { _ in
            let backdrop = conversationBackdrop
            ZStack {
                PhoneSplitContainer(leftWidth: $splitLeftWidth) {
                    NavigationStack {
                        PhoneSplitListColumn(wallpaper: backdrop) {
                            PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                                .padding(.bottom, 8)
                            List {
                                conversationRows(linkRows: false)
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                            // 列表里的选中高亮必须"点下即亮"：整棵列表子树关掉补间。
                            .transaction { transaction in transaction.disablesAnimations = true }
                        }
                        .navigationTitle(isEditing ? L10n.t("已选择 \(checkedIDs.count) 项") : L10n.t("信息"))
                        .navigationBarTitleDisplayMode(.inline)
                        // 左列顶栏只有分类 / 编辑；右列顶栏是新信息 / 视频，与系统「信息」App 一致。
                        .toolbar { listToolbar(showsCompose: false) }
                        .immersiveBars()
                    }
                } right: {
                    PhoneSplitDetailColumn(isTranslucent: backdrop != nil) {
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
                }
            }
            // 选中态即时切换：详情区不做任何渐变 / 过渡动画。
            .animation(nil, value: selection)
            // 选中的会话同时决定根视图那一层会话壁纸。这个同步必须由「信息」板块
            // 自己负责，而不是交给会话页：打开联系人信息面板后会话页不再重建视图，
            // 由它发布壁纸就会「换完背景没反应」。
            .onAppear { chatBackgrounds.presentedHandle = selection }
            .onChange(of: selection) { newValue in
                chatBackgrounds.presentedHandle = newValue
            }
        }
    }

    // MARK: iPhone 单栏

    private var compactBody: some View {
        // 显式路径：单栏下「正在看哪个会话」由它决定，退出聊天要把会话壁纸撤掉。
        NavigationStack(path: $compactPath) {
            List {
                PhoneSearchField(placeholder: L10n.t("搜索"), text: $search)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                conversationRows(linkRows: !isEditing)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        // 单栏路径变化即「进入 / 退出聊天」：进入铺该会话壁纸，退出撤掉。
        .onAppear { chatBackgrounds.presentedHandle = compactPath.last }
        .onChange(of: compactPath) { path in
            chatBackgrounds.presentedHandle = path.last
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
            let ids = filteredConversations.map(\.id)
            ForEach(Array(filteredConversations.enumerated()), id: \.element.id) { index, conversation in
                if isEditing {
                    Button {
                        toggleCheck(conversation.id)
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            isEditing: true,
                            isChecked: checkedIDs.contains(conversation.id),
                            isSelectionFirst: mergedSelectionIsFirst(index, ids: ids, checked: checkedIDs),
                            isSelectionLast: mergedSelectionIsLast(index, ids: ids, checked: checkedIDs)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                } else if linkRows {
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                } else {
                    Button {
                        withoutAnimations { selection = conversation.id }
                    } label: {
                        ConversationRow(conversation: conversation, isSelected: selection == conversation.id)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.deleteMessages(ids: conversation.recordIDs)
                            if selection == conversation.id { selection = nil }
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                            .tint(Color.red)
                        }
                    }
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
        // 进入 / 退出编辑是即时状态，不做过渡动画：系统「电话 / 通讯录 / 信息」
        // 的编辑态切换本身就是瞬间完成。
        isEditing.toggle()
        if !isEditing { checkedIDs.removeAll() }
    }

    private func toggleCheck(_ id: String) {
        // 勾选同理：状态直接切换，蓝色复选框立刻出现，不做补间。
        withoutAnimations {
            if checkedIDs.contains(id) {
                checkedIDs.remove(id)
            } else {
                checkedIDs.insert(id)
            }
        }
    }

    /// 编辑态去掉行间留白，让相邻选中行的高亮连成一整块。
    private var rowInsets: EdgeInsets {
        isEditing
            ? EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            : EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
    }

    /// 删除整个会话：把该号码名下所有短信一起删除（与系统「信息」App 一致）。
    private func deleteCheckedConversations() {
        var ids = Set<String>()
        for conversation in allConversations where checkedIDs.contains(conversation.id) {
            ids.formUnion(conversation.recordIDs)
        }
        guard !ids.isEmpty else { return }
        model.deleteMessages(ids: ids)
        if let selection, checkedIDs.contains(selection) { self.selection = nil }
        checkedIDs.removeAll()
        isEditing = false
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
    /// 多选合并高亮：本行是否为选中块的首 / 末行，只有外侧保留圆角。
    var isSelectionFirst: Bool = true
    var isSelectionLast: Bool = true

    private var displayName: String {
        model.contacts.contact(for: conversation.id)?.name ?? conversation.id
    }

    private var photoData: Data? {
        model.contacts.contact(for: conversation.id)?.photoData
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                PhoneSelectionCircle(isSelected: isChecked, onHighlight: isHighlighted)
            }

            InitialAvatar(name: displayName, photoData: photoData, size: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(conversation.last?.content ?? "")
                    .font(.subheadline)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            // 行高不能随列宽变化：否则拖动分栏时预览文字在 1/2 行
            // 之间来回跳，整个 List 的内容高度也跟着不停地抖动。
            .frame(height: 56, alignment: .leading)
            Spacer(minLength: 8)
            if let timestamp = conversation.last?.timestamp {
                Text(Self.rowTimestampText(timestamp))
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .frame(minHeight: 54)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(
            PhoneMergedSelectionHighlight(
                isActive: isHighlighted,
                isFirst: isSelectionFirst,
                isLast: isSelectionLast,
                cornerRadius: 20
            )
        )
        .contentShape(Rectangle())
    }

    private var isHighlighted: Bool { isSelected || isChecked }

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
    @State private var showingMoreActions = false
    /// 顶层标签页选中项：会话页嵌在分栏里，切回「信息」板块时不一定每次
    /// 都能收到 `onAppear`，用这个共享键当作「重新可见」的确定性信号。
    @AppStorage("djonehub.selected-tab") private var selectedTabRaw = PhoneTab.calls.rawValue
    /// 会话内容最底部的固定锚点 id：贴底一律滚到它而不是最后一条气泡。
    private static let bottomAnchorID = "djonehub.chat.bottom"

    /// 会话背景（iOS 26「信息」的会话背景）：气泡的液态玻璃会折射背景内容。
    @StateObject private var chatBackgrounds = ChatBackgroundStore.shared

    /// 显式 init：保证尾随闭包始终绑定 `onCompose`，
    /// 不受后面那些带默认值的 `@State` 存储属性影响。
    init(
        handle: String,
        onCompose: @escaping () -> Void
    ) {
        self.handle = handle
        self.onCompose = onCompose
    }

    private var messages: [SMSMessage] {
        // 一条长短信在模块侧是多条独立记录（发送按 70 个 UCS2 单元切段，
        // 收到的多段短信在 ME 存储里也各占一条），这里合回一个气泡。
        SMSMessage.chronological(model.messages.filter { $0.sender == handle })
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
                    // 官方 Liquid Glass 规范：同一屏里的多个玻璃视图要放进同一个
                    // GlassEffectContainer，系统才会一次渲染整组玻璃、并允许相邻气泡融合；
                    // 逐个裸套 glassEffect 会各自渲一层，观感与性能都不符合规范。
                    BubbleGlassContainer {
                        // 用 VStack 而不是 LazyVStack：会话内容的总高必须在第一次布局
                        // 时就完全确定，`scrollTo` 才能算出精确的贴底位置。LazyVStack
                        // 只实例化当前可视行，「切标签回来」的那一刻贴底会按尚未实例化
                        // 行的估算高度落位，整个会话（头像 + 名字 + 气泡）就会往下挪
                        // 一点，直到用户再点一下 / 滑一下触发重排才被纠正。
                        VStack(spacing: 4) {
                            header
                                .padding(.bottom, 10)
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if let separator = timeSeparator(
                                    for: message.timestamp,
                                    previous: index > 0 ? messages[index - 1].timestamp : nil
                                ) {
                                    Text(separator)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                // iMessage 规则：同一发件人连续多条时，只有最后一条带小角。
                                MessageBubble(message: message, hasTail: isLastOfRun(at: index))
                            }
                            // 给浮在底部的输入条让位：这 76pt 留在内容最底部，贴底时
                            // 最新一条消息就停在输入条上方，不会被输入条挡住。
                            Color.clear
                                .frame(height: 76)
                            // 内容最底部的固定锚点：贴底一律滚到它，而不是最后一条
                            // 气泡。气泡高度随文字换行变化，锚点高度恒为 1pt，落位
                            // 只由内容总高决定；它排在让位段之后，所以贴底一定贴到
                            // 真正的底部。
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { anchorToBottomAfterLayout(proxy) }
                .onChange(of: selectedTabRaw) { value in
                    guard value == PhoneTab.messages.rawValue else { return }
                    anchorToBottomAfterLayout(proxy)
                }
                // 分栏下切换会话时 ChatPane 视图会被复用、onAppear 不会重跑，
                // 必须显式重新贴底，否则新会话会沿用上一条的滚动位置（同样表现为错位）。
                .onChange(of: handle) { _ in anchorToBottomAfterLayout(proxy) }
                .onChange(of: messages.count) { _ in scrollToLast(proxy, animated: true) }
            }

            composer
        }
        .background { conversationBackground }
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
        // 让通知层知道用户当前正开在哪个会话里：只有这个会话的新短信不再打扰。
        .onAppear {
            model.openConversationHandle = handle
            chatBackgrounds.presentedHandle = handle
        }
        .onDisappear {
            // 只回收「正在聊天」这个通知去重标记，壁纸不在这里撤：
            // 打开联系人信息面板同样会走到 onDisappear，在这里撤壁纸正是
            // 旧版本「在那个面板里换背景没反应」的原因。
            if model.openConversationHandle == handle { model.openConversationHandle = nil }
        }
        .onChange(of: handle) { newValue in
            model.openConversationHandle = newValue
            chatBackgrounds.presentedHandle = newValue
        }
        .navigationDestination(isPresented: $showingContactInfo) {
            ChatContactInfoPanel(handle: handle)
        }
    }

    /// 会话背景：设了背景照片时本视图保持**透明**——壁纸由根视图
    /// 那一层统一铺满整窗（含状态栏 / 顶部导航栏 / 底部导航栏），
    /// 这里再各画一层只会上下留白、两侧明暗不一致。
    /// 没设就保持系统背景色，与系统「信息」默认会话一致。
    @ViewBuilder
    private var conversationBackground: some View {
        if let image = chatBackgrounds.image(for: handle) {
            // 会话页在 `NavigationStack` 内部，只有画在这里才看得见；
            // 根视图那一层会被 `NavigationStack` 的不透明底色盖掉。
            ChatWallpaperFill(image: image, dim: 0.16)
                .ignoresSafeArea()
        } else {
            Color(uiColor: .systemBackground).ignoresSafeArea()
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
        // + 号与发送 / 语音按钮都在同一条液态玻璃胶囊内部：+ 贴左侧垂直居中，
        // 输入框在中间，发送 / 语音在右侧，整条胶囊固定在窗口底部不上移。
        HStack(alignment: .center, spacing: 6) {
            // 用普通 Button + 确认对话框，而不是 Menu：iOS 26 会给 Menu 标签自动套
            // 一层玻璃底板，看起来像浮在输入框外面，和系统「信息」App 不一致。
            Button {
                showingMoreActions = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("更多"))
            .confirmationDialog(
                L10n.t("更多"),
                isPresented: $showingMoreActions,
                titleVisibility: .hidden
            ) {
                Button(L10n.t("刷新")) { Task { await model.refreshMessages() } }
                Button(L10n.t("清空全部短信"), role: .destructive) { model.clearLocalMessages() }
                Button(L10n.t("取消"), role: .cancel) {}
            }

            TextField(L10n.t("iMessage 信息"), text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.leading, 2)
                .padding(.vertical, 10)

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DictationButton { recognized in
                    draft = recognized
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(uiColor: .systemBlue)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("发送"))
            }
        }
        .frame(minHeight: 46)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        // 输入条与搜索框同高（实心胶囊，不在键盘上方上移）。
        .modifier(GlassCapsuleBackground())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { _ = await model.sendSMS(to: handle, content: text) }
    }

    /// 该条是否是「同一发件人连续多条」的最后一条。
    ///
    /// 与系统「信息」App 一致：连续的气泡只有最后一条带小角，整段消息看起来
    /// 是一个连贯的块；换人（收发方向变了）或隔了时间分隔就重新起一段。
    private func isLastOfRun(at index: Int) -> Bool {
        guard index + 1 < messages.count else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        guard next.isOutgoing == current.isOutgoing else { return true }
        return timeSeparator(for: next.timestamp, previous: current.timestamp) != nil
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool) {
        // 滚到内容底部的固定锚点，而不是最后一条气泡：气泡高度随文字换行变化，
        // 锚点高度恒为 1pt，落位只由内容总高决定。还没有任何消息时锚点同样存在
        // （它和 header 一样无条件渲染），所以不需要因为 messages 为空而提前返回。
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// 切到别的板块再切回来时，`onAppear` 会在新布局落定之前触发；此刻立刻
    /// `scrollTo` 会按旧的安全区 / 内容尺寸算出一个偏低的位置并把它锁住，
    /// 表现为整个会话（头像 + 名字 + 气泡）一起往下挪一点，直到用户再点 /
    /// 滑一下才被纠正。推迟到下一轮主线程布局之后再贴底即可避开这段错位。
    private func anchorToBottomAfterLayout(_ proxy: ScrollViewProxy) {
        // 切标签回来时 onAppear 会赶在新布局 / 安全区落定之前触发，此刻贴底会
        // 按旧尺寸算出一个偏低的位置并锁住。这里跨两轮主线程布局各贴一次底：
        // 第二轮的时机一定晚于安全区最终值；若第一轮已经落位正确，第二轮是无
        // 副作用的重复调用（同一位置再 scrollTo 一次不会产生任何可见变化）。
        DispatchQueue.main.async {
            scrollToLast(proxy, animated: false)
            DispatchQueue.main.async { scrollToLast(proxy, animated: false) }
        }
    }

    /// 时间分隔：与日期同款，居中显示在消息窗口正中间。
    /// 跨天显示「日期 + 时分」，同一天超过 5 分钟的空档显示时分，否则不显示。
    private func timeSeparator(for date: Date, previous: Date?) -> String? {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let previous else { return time }
        if !calendar.isDate(previous, inSameDayAs: date) {
            if calendar.isDateInToday(date) { return L10n.t("今天") + " " + time }
            if calendar.isDateInYesterday(date) { return L10n.t("昨天") + " " + time }
            return date.formatted(.dateTime.weekday(.wide)) + " " + time
        }
        if date.timeIntervalSince(previous) > 300 { return time }
        return nil
    }
}

/// 会话背景图存储：iOS 26「信息」支持给单个会话设置背景照片，气泡的液态玻璃
/// 会折射背景内容。图片按对端号码存进沙盒，不依赖任何权限，也不会上传。
final class ChatBackgroundStore: ObservableObject {
    static let shared = ChatBackgroundStore()
    /// 背景变更计数：@Published 让正在显示的会话立刻换成新背景。
    @Published private(set) var revision = 0
    /// 当前正在展示的会话（由「信息」板块写入）。根视图据此决定铺哪张壁纸。
    ///
    /// 壁纸不再由会话页「发布」：会话页在打开联系人信息面板后可能不再重建视图，
    /// 那种情形下发布调用根本不会发生，背景就会「换完没反应」。
    /// 现在只记录「正在看哪个会话」，壁纸从已存图片实时推导：
    /// 图片一变（`revision` 触发一次对象变更通知），根视图那层立刻就是新图。
    @Published var presentedHandle: String?

    /// 根视图 `ChatWallpaperRootLayer` 要铺的那张图，由 `presentedHandle` 推导。
    ///
    /// 为什么要放到根视图：分栏版式下壁纸必须盖住
    /// 状态栏 / 顶部导航栏 / 底部导航栏——那几条带子在标签内容区之外，
    /// 会话页自己怎么 `.ignoresSafeArea()` 都够不到，只有根视图做得到。
    var activeWallpaper: UIImage? {
        guard let handle = presentedHandle else { return nil }
        return image(for: handle)
    }

    private var cache: [String: UIImage] = [:]

    private lazy var directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DJOneHub/ChatBackgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    func image(for handle: String) -> UIImage? {
        if let cached = cache[handle] { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: handle)),
              let image = UIImage(data: data) else { return nil }
        cache[handle] = image
        return image
    }

    func setImage(_ data: Data?, for handle: String) {
        let target = fileURL(for: handle)
        if let data, let image = UIImage(data: data) {
            // 背景只要铺满一屏：先缩到 2048pt 长边再落盘，避免几 MB 的原图长期占内存。
            let scaled = image.preparingThumbnail(of: CGSize(width: 2048, height: 2048)) ?? image
            cache[handle] = scaled
            try? scaled.jpegData(compressionQuality: 0.9)?.write(to: target, options: .atomic)
        } else {
            cache[handle] = nil
            try? FileManager.default.removeItem(at: target)
            // 壁纸是从 `presentedHandle` 实时推导的：清掉缓存并删除磁盘文件后，
            // 下面的 `revision` 变化就会让根视图那一层跟着撤掉，不必再写状态。
        }
        revision &+= 1
    }

    private func fileURL(for handle: String) -> URL {
        let name = String(handle.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return directory.appendingPathComponent(name + ".jpg")
    }
}


/// 信息卡里的纯标签行：用于 PhotosPicker 这类必须由系统控件触发的入口，
/// 排版与 InfoCardRow 完全一致，保证「背景」分段的卡片风格统一。
private struct InfoCardActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(isDestructive ? Color(uiColor: .systemRed) : Color.white)
            Spacer(minLength: 8)
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// 长条液态玻璃胶囊底：iOS 26 用交互式系统 glassEffect，旧系统用系统填充色。
private struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            content.background(Capsule(style: .continuous).fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}

/// 消息气泡：自己发的在右侧系统蓝底，对方发的在左侧系统灰底。
private struct MessageBubble: View {
    let message: SMSMessage
    /// 是否是「同一发件人连续多条」的最后一条；只有它带 iMessage 的小角。
    let hasTail: Bool

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            Text(message.content)
                .font(.body)
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .modifier(MessageBubbleBackground(isOutgoing: message.isOutgoing, hasTail: hasTail))
                .textSelection(.enabled)

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
        .id(message.id)
    }
}

/// iMessage 同款气泡轮廓：四角连续圆角，发件人一侧的下角在需要时收成小角（小尾巴）。
///
/// 直接用系统公开 API `UnevenRoundedRectangle`（iOS 16 起）逐角指定半径，
/// 不再自绘 `Path`：小尾巴是「把该角半径收小」而不是另画一个尖角，
/// 带角与不带角的气泡外框尺寸完全一致，整段消息对齐，
/// 形状也永远跟随系统圆角风格（不会随 SDK 变化而过时）。
/// 与系统「信息」App 的规则一致：连续同向的气泡只有最后一条带小尾巴，
/// 其余保持纯圆角，整段消息看起来才是连贯的一块。
private struct MessageBubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool

    /// 气泡本体的连续大圆角。
    private var corner: CGFloat { 20 }
    /// 小尾巴半径：明显小于本体圆角，形成 iMessage 那种「一个小尾巴」的观感。
    private var tailCorner: CGFloat { 6 }

    func path(in rect: CGRect) -> Path {
        // 发件人的小尾巴在右下、收件人的在左下（与系统「信息」一致）。
        let small = hasTail ? tailCorner : corner
        return UnevenRoundedRectangle(
            topLeadingRadius: corner,
            bottomLeadingRadius: isOutgoing ? corner : small,
            bottomTrailingRadius: isOutgoing ? small : corner,
            topTrailingRadius: corner,
            style: .continuous
        ).path(in: rect)
    }
}

/// 气泡组容器：iOS 26 用官方 `GlassEffectContainer`，让整组玻璃一次渲染，
/// 相邻气泡可以互相融合；旧的系统没有这个容器，直接原样返回（气泡回退成实心底）。
/// 本 App 最低支持 iOS 16.1，所以必须做可用性分支，不能直接写 GlassEffectContainer。
private struct BubbleGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content }
        } else {
            content
        }
    }
}

/// iMessage 同款气泡底：iOS 26 液态玻璃（发送方带系统蓝着色），旧系统回退为实心气泡。
private struct MessageBubbleBackground: ViewModifier {
    let isOutgoing: Bool
    let hasTail: Bool

    func body(content: Content) -> some View {
        let shape = MessageBubbleShape(isOutgoing: isOutgoing, hasTail: hasTail)
        if #available(iOS 26.0, *) {
            if isOutgoing {
                content.glassEffect(.regular.tint(Color(uiColor: .systemBlue)), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content.background(
                shape.fill(
                    isOutgoing
                        ? Color(uiColor: .systemBlue)
                        : Color(uiColor: .secondarySystemBackground)
                )
            )
        }
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
    /// 会话背景选择：PhotosPicker 由用户主动选图，不需要相册权限。
    @State private var backgroundItem: PhotosPickerItem?
    @StateObject private var chatBackgrounds = ChatBackgroundStore.shared
    private var contact: ContactStore.Contact? { model.contacts.contact(for: handle) }
    private var displayName: String { contact?.name ?? handle }
    private var photoData: Data? { contact?.photoData }

    var body: some View {
        ZStack {
            ContactPalette.gradient(for: handle).ignoresSafeArea()

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
                        backgroundTab
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
        // 返回按钮已由系统导航栏提供，
        // 不再重复放一个功能相同的关闭按钮（HIG：同一操作只留一个入口）。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("编辑")) { showingEditor = true }
                    .fontWeight(.semibold)
                    // 顶栏文字按钮统一系统单色（浅色黑 / 深色白），不用强调色蓝。
                    .tint(Color.primary)
            }
        }
.sheet(isPresented: $showingEditor) {
            if let contact {
                NativeContactCard(
                    identifier: contact.id,
                    phone: handle,
                    showsNavigationBar: true,
                    showsDoneButton: true,
                    allowsEditing: true,
                    startsInEditMode: true
                ) { _ in } onMessage: { _ in }
                // 同上：系统卡片需要确定尺寸，不能用 form 弹层尺寸。
                .frame(minWidth: 340, minHeight: 520)
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: showingEditor) { isShowing in
            // 编辑保存（或取消）后重新读取通讯录，本页立即同步新资料。
            guard !isShowing else { return }
            Task { await model.contacts.requestAccessAndLoad() }
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
            GlassAvatar(name: displayName, photoData: photoData, size: 110)
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

    /// 「背景」分段：iOS 26「信息」允许给单个会话设置背景照片，液态玻璃气泡会
    /// 折射背景内容。选图走系统 PhotosPicker，由用户主动选择，不需要相册权限。
    @ViewBuilder
    private var backgroundTab: some View {
        VStack(spacing: 14) {
            if let image = chatBackgrounds.image(for: handle) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                EmptyStateView(title: L10n.t("暂无共享背景"), systemImage: "photo")
                    .frame(height: 180)
            }

            InfoCard {
                PhotosPicker(selection: $backgroundItem, matching: .images) {
                    InfoCardActionLabel(
                        title: chatBackgrounds.image(for: handle) == nil
                            ? L10n.t("选取背景照片")
                            : L10n.t("更换背景照片"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)
                if chatBackgrounds.image(for: handle) != nil {
                    InfoCardDivider()
                    Button {
                        chatBackgrounds.setImage(nil, for: handle)
                    } label: {
                        InfoCardActionLabel(title: L10n.t("移除背景"), isDestructive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: backgroundItem) { item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self) {
                    chatBackgrounds.setImage(data, for: handle)
                }
                backgroundItem = nil
            }
        }
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

    /// 解析系统联系人卡片要展示的 `CNContact`。
    ///
    /// 通讯录里被合并过的联系人（iCloud / 本机 / 企业多来源）本地 identifier 与
    /// unified identifier 并不相同，只用 `unifiedContact(withIdentifier:)` 会取不到，
    /// 卡片便退化成一张没有任何字段的临时联系人——这正是「点编辑弹出空白窗口」的根因。
    /// 因此按 identifier → 号码逐级回退，任一命中都返回真实联系人。
    private static func lookupStoredContact(
        in store: CNContactStore,
        identifier: String?,
        phone: String?,
        keys: [CNKeyDescriptor]
    ) -> CNContact? {
        if let identifier, !identifier.isEmpty {
            if let unified = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys) {
                return unified
            }
            if let results = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [identifier]),
                keysToFetch: keys
            ), let matched = results.first {
                return matched
            }
        }
        if let phone, !phone.isEmpty {
            let digits = phone.filter { $0.isNumber }
            for candidate in [phone, digits] where !candidate.isEmpty {
                if let results = try? store.unifiedContacts(
                    matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: candidate)),
                    keysToFetch: keys
                ), let matched = results.first {
                    return matched
                }
            }
        }
        return nil
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]
        let resolved: CNContact
        var matchedStoredContact = false
        if let contact {
            resolved = contact
            matchedStoredContact = true
        } else if let fetched = Self.lookupStoredContact(
            in: store,
            identifier: identifier,
            phone: phone,
            keys: keys
        ) {
            resolved = fetched
            matchedStoredContact = true
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
        let canEdit = allowsEditing && matchedStoredContact
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
        // 系统卡片的顶栏按钮也要遵守同一套单色规范：浅色黑、深色白，而不是强调色蓝。
        nav.navigationBar.tintColor = .label
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
        let nav = UINavigationController(rootViewController: controller)
        // 新建联系人的 X / ✓ 也用系统单色（浅色黑 / 深色白）。
        nav.navigationBar.tintColor = .label
        return nav
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
            if showingKeypad {
                // 点键盘以外的任意位置退出通话中键盘。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) { showingKeypad = false }
                    }
                    .accessibilityHidden(true)
            }
            VStack(spacing: isCompact ? 16 : 24) {
                Spacer(minLength: 20)
                header
                Spacer(minLength: 8)
                if showingKeypad {
                    // 通话中的键盘贴底悬浮，不再居中遮挡姓名与状态。
                    Spacer(minLength: 0)
                    DTMFKeypadPanel {
                        withAnimation(.easeInOut(duration: 0.22)) { showingKeypad = false }
                    }
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                } else {
                    controls
                    Spacer(minLength: 20)
                }
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
        case "dialing", "alerting": return L10n.t("正在呼叫")
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
    private var keySize: CGFloat { isCompact ? 54 : 60 }
    private var keySpacing: CGFloat { isCompact ? 16 : 22 }
    private var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }

    var body: some View {
        VStack(spacing: 14) {
            keypadRows
                .frame(width: keypadWidth)

            Button(action: onClose) {
                Text(L10n.t("隐藏键盘"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.t("隐藏键盘"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .modifier(DialPadCardBackground())
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        // 点击卡片内任意非按键区域即可退出键盘。
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .onTapGesture { onClose() }
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
