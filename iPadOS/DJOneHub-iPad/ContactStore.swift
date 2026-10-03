import Contacts
import Foundation

/// 非主线程联系人读取器，避免在 Swift 6 下跨线程持有 CNContactStore。
struct ContactFetcher: Sendable {
    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func fetchAll() throws -> [ContactStore.Contact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [ContactStore.Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let cjkName = Self.containsCJK(contact.givenName + contact.familyName)
            let nameParts = cjkName
                ? [contact.familyName, contact.givenName]
                : [contact.givenName, contact.familyName]
            let separator = cjkName ? "" : " "
            let name = nameParts.filter { !$0.isEmpty }.joined(separator: separator)
            let phones = contact.phoneNumbers
                .map { ContactStore.normalized($0.value.stringValue) }
                .filter { !$0.isEmpty }
            guard !name.isEmpty, !phones.isEmpty else { return }
            contacts.append(.init(
                id: contact.identifier,
                name: name,
                phones: phones,
                emails: contact.emailAddresses.map { $0.value as String },
                photoData: contact.thumbnailImageData
            ))
        }
        return contacts
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
final class ContactStore: ObservableObject {
    struct Contact: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
        let photoData: Data?
    }

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var isAuthorized = false
    @Published var errorMessage: String?
    private let cache = ContactCacheStore()

    init() {
        // 联系人属于手机数据，启动时直接恢复本机副本，不能等待模块插入或网络连接。
        contacts = cache.load()
        refreshAuthorizationStatus()
    }
    nonisolated static func normalized(_ phone: String) -> String {
        var value = phone.filter { $0.isNumber || $0 == "+" }
        if value.hasPrefix("+86") {
            value.removeFirst(3)
        } else if value.hasPrefix("86"), value.count > 11 {
            value.removeFirst(2)
        }
        return value
    }

    /// 首次接入页展示用的通讯录授权状态；不触发系统弹窗。
    var permissionState: PermissionState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), status == .limited { return .granted }
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        default:
            return .notDetermined
        }
    }

    func requestAccessAndLoad() async {
        do {
            // Contacts 的授权与枚举 API 会执行同步工作，必须离开主线程。
            // 每个任务内部创建独立 CNContactStore，避免跨并发域传递非 Sendable 对象。
            let authorized = try await Task.detached(priority: .userInitiated) {
                try await ContactFetcher().requestAccess()
            }.value
            isAuthorized = authorized
            guard isAuthorized else {
                errorMessage = "未获得通讯录访问权限"
                return
            }
            contacts = try await Task.detached(priority: .userInitiated) {
                try ContactFetcher().fetchAll()
            }.value
            guard cache.save(contacts) else {
                // 本次读取结果仍可使用，只提示用户本机缓存没有落盘。
                errorMessage = "通讯录已读取，但保存到本机失败"
                return
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 仅在首次授权后还没有本机缓存时读取系统通讯录。
    /// 模块插拔不会触发这个方法；用户下拉刷新才会执行完整重新读取。
    func loadIfNeeded() async {
        refreshAuthorizationStatus()
        // 手机重启后 App 可能在首次解锁前被后台唤醒，此时受数据保护的缓存暂时不可读。
        // 回到前台必须重读一次，不能因为文件存在就把首次得到的空数组当成最终结果。
        let cachedContacts = cache.load()
        if !cachedContacts.isEmpty {
            contacts = cachedContacts
        }
        guard isAuthorized, contacts.isEmpty else { return }
        await loadAuthorizedContacts()
    }

    private func refreshAuthorizationStatus() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), status == .limited {
            isAuthorized = true
        } else {
            isAuthorized = status == .authorized
        }
    }

    private func loadAuthorizedContacts() async {
        do {
            contacts = try await Task.detached(priority: .userInitiated) {
                try ContactFetcher().fetchAll()
            }.value
            if !cache.save(contacts) {
                errorMessage = "通讯录已读取，但保存到本机失败"
                return
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除系统通讯录里的联系人（列表多选删除）。
    /// 删除请求必须在后台线程执行，成功后同步刷新本机副本与缓存。
    @discardableResult
    func delete(ids: Set<String>) async -> Bool {
        guard !ids.isEmpty else { return false }
        let removed = await Task.detached(priority: .userInitiated) { () -> Bool in
            let store = CNContactStore()
            let request = CNSaveRequest()
            var hasTarget = false
            for identifier in ids {
                guard let contact = try? store.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                ), let mutable = contact.mutableCopy() as? CNMutableContact else { continue }
                request.delete(mutable)
                hasTarget = true
            }
            guard hasTarget else { return false }
            do {
                try store.execute(request)
                return true
            } catch {
                return false
            }
        }.value
        guard removed else {
            errorMessage = "无法删除联系人，请检查通讯录权限后重试"
            return false
        }
        let remaining = contacts.filter { !ids.contains($0.id) }
        contacts = remaining
        if !cache.save(remaining) {
            errorMessage = "联系人已删除，但更新本机副本失败"
        } else {
            errorMessage = nil
        }
        return true
    }

    func contact(for number: String) -> Contact? {
        let target = Self.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = contacts.first(where: { $0.phones.contains(target) }) { return exact }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }
    }

    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "未知号码" }
        return contact(for: number)?.name ?? number
    }
}

/// 通讯录缓存只保存在 App 沙盒内，不会同步到模块，也不会参与模块刷写包。
private final class ContactCacheStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let directory = durableRoot.appendingPathComponent("DJOneHub", isDirectory: true)
        fileURL = directory.appendingPathComponent("contacts.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var exists: Bool { fileManager.fileExists(atPath: fileURL.path) }

    func load() -> [ContactStore.Contact] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ContactStore.Contact].self, from: data)
        } catch {
            Self.log("读取通讯录缓存失败：\(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func save(_ contacts: [ContactStore.Contact]) -> Bool {
        do {
            let data = try JSONEncoder().encode(contacts)
            // 原子写入保证插拔模块或 App 被系统回收时不会留下半份通讯录缓存。
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            Self.log("保存通讯录缓存失败：\(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[DJOneHub Contacts] \(message)")
#endif
    }
}
