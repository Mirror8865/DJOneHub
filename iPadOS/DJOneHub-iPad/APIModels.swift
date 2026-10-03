import Foundation

// MARK: - 通话与短信

/// 模块侧返回的单次通话记录。
struct CallRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let direction: String
    let state: String
    let number: String?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?
    let missed: Bool

    enum CodingKeys: String, CodingKey {
        case id, index, direction, state, number, missed
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
    }
}

/// 通话轮询结果；额外音频诊断字段由专门接口读取。
struct CallStatus: Codable, Sendable {
    let active: CallRecord?
    let history: [CallRecord]?
    let polling: Bool
    let eventDriven: Bool?
    let pollIntervalSeconds: Int
    let lastPollError: String

    enum CodingKeys: String, CodingKey {
        case active, history, polling
        case eventDriven = "event_driven"
        case pollIntervalSeconds = "poll_interval_s"
        case lastPollError = "last_poll_error"
    }
}

/// 模块本地事件桥的单次响应；修订号用于断线续接和去重。
struct CallEventEnvelope: Codable, Sendable {
    let revision: UInt64
    let active: CallRecord?
    let heartbeat: Bool
}

enum SMSDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

struct SMSMessage: Codable, Equatable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date
    /// 模块交付队列的确认标识；仅用于清理模块副本，不影响本地短信去重。
    var deliveryID: String?
    /// 模块只上报收到的短信；已发送短信由 App 在发送成功后写入本机历史。
    /// 保持可选以兼容没有 `direction` 字段的旧模块和既有本地记录。
    var direction: SMSDirection?

    var isOutgoing: Bool { direction == .outgoing }

    /// 后端短信没有独立 ID，以稳定字段组合生成列表标识。
    var id: String { "\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
    }
}

extension SMSMessage {
    /// 合法的分段长度：
    /// - UCS2：单段 70、带 UDH 联合 67（本模块自己就按 70 个 UCS2 单元切）；
    /// - GSM-7：单段 160、带 UDH 联合 153；
    /// - 部分固件按 UTF-8 每个数据单元 140 字节切，中文一段只有 46 个字符。
    /// 实际边界会因四字节补位（emoji 等代理对）少 1～4 个单元，所以前后各放宽一档。
    static let fragmentBoundaries: Set<Int> = [
        46, 45, 44, 47,
        67, 66, 68, 69, 70, 71,
        134, 140,
        152, 153, 154, 158, 159, 160, 161
    ]
    /// 上一段正好落在已知分段边界上时，容忍较长的入库间隔
    /// （模块收到多段短信后会分几次写入 ME 存储）。
    static let fragmentBoundaryJoinWindow: TimeInterval = 300
    /// 分段长度不在已知边界上（固件切分方案不同）时用更短的窗口，避免误合两条独立短信。
    static let fragmentHeuristicJoinWindow: TimeInterval = 30
    /// 上一段至少有这么长，才认为它是「被切断的一段」。
    static let fragmentMinimumLength = 40
    /// 一段短信不会超过 160 个单元；更长的上一段说明它本身已经是完整短信。
    static let fragmentMaximumLength = 200

    /// 模块 `delivery_id` 形如 `ME-12-<digest>`：前缀是「存储介质-槽位」。
    /// 一条长短信被模块拆成多条记录时，各段占用**连续槽位**，槽位号就是分段的
    /// 真实先后——比时间戳可靠得多（各段时间戳常常完全相同）。
    var storageSlot: (memory: String, index: Int)? {
        guard let deliveryID else { return nil }
        let parts = deliveryID.split(separator: "-")
        guard parts.count >= 2, let index = Int(parts[1]) else { return nil }
        return (String(parts[0]), index)
    }

    /// 把同发件人、同方向、时间相邻、且上一段看起来是「被切断的一段」的连续记录合回一条。
    ///
    /// 模块侧一条长短信会被拆成多条独立短信（发送按 70 个 UCS2 单元切段，
    /// 收到的多段短信在 ME 存储里也各占一条），不合并就会把一条长短信显示成一串气泡。
    /// 合并后沿用最后一段的 id / 时间 / 交付标识，因此列表选中、滚动定位与本机删除
    /// 仍然指向真实记录。
    ///
    /// **顺序必须是确定的全序**：同一条长短信各段的时间戳往往一模一样，之前靠
    /// 「输入方向」猜、再配合字典顺序与不稳定的 `sorted`，每次刷新都可能给出不同的
    /// 相对顺序——于是同一条短信会在「一个气泡」和「好几个气泡」之间来回跳，
    /// 聊天窗口的先后也会反。现在统一按（时间升序，模块存储槽位升序，内容）排
    /// 一次确定的顺序，输出恒为「旧 → 新」，与聊天窗口自上而下的渲染顺序一致。
    static func mergedFragments(_ messages: [SMSMessage]) -> [SMSMessage] {
        guard messages.count > 1 else { return messages }
        let ordered = messages.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            let leftSlot = lhs.storageSlot
            let rightSlot = rhs.storageSlot
            if let leftSlot, let rightSlot {
                if leftSlot.memory != rightSlot.memory { return leftSlot.memory < rightSlot.memory }
                if leftSlot.index != rightSlot.index { return leftSlot.index < rightSlot.index }
            } else if (leftSlot == nil) != (rightSlot == nil) {
                // 有槽位的排在没槽位的前面；旧版模块没有槽位，保持稳定即可。
                return rightSlot == nil
            }
            return lhs.content < rhs.content
        }

        var merged: [SMSMessage] = []
        for message in ordered {
            guard let last = merged.last,
                  last.sender == message.sender,
                  last.isOutgoing == message.isOutgoing,
                  isFragmentTail(last.content),
                  isSameFragmentRun(last, message),
                  message.timestamp.timeIntervalSince(last.timestamp) <= joinWindow(for: last.content) else {
                merged.append(message)
                continue
            }
            merged[merged.count - 1] = SMSMessage(
                sender: message.sender,
                content: last.content + message.content,
                code: last.code ?? message.code,
                timestamp: message.timestamp,
                deliveryID: message.deliveryID,
                direction: message.direction
            )
        }
        return merged
    }

    /// 两段是否属于同一条被拆开的长短信。
    ///
    /// 模块 `delivery_id` 带存储槽位时优先用槽位判断：一条长短信的各段占用
    /// **连续槽位**，而同一发件人先后发来的两条独立短信不会；这能挡掉「两条
    /// 各 50 字的独立短信被长度启发式误合成一条」。旧版模块没有槽位、
    /// 或两段时间戳完全相同（模块一次写入）时，退回原来的长度 / 时间窗口判断。
    private static func isSameFragmentRun(_ last: SMSMessage, _ next: SMSMessage) -> Bool {
        guard let lastSlot = last.storageSlot, let nextSlot = next.storageSlot else { return true }
        if last.timestamp == next.timestamp { return true }
        return lastSlot.memory == nextSlot.memory && nextSlot.index == lastSlot.index + 1
    }

    /// 上一段是否像「一条长短信被切断的前半段」。
    private static func isFragmentTail(_ content: String) -> Bool {
        let length = content.utf16.count
        if fragmentBoundaries.contains(length) { return true }
        return length >= fragmentMinimumLength && length <= fragmentMaximumLength
    }

    private static func joinWindow(for content: String) -> TimeInterval {
        fragmentBoundaries.contains(content.utf16.count)
            ? fragmentBoundaryJoinWindow
            : fragmentHeuristicJoinWindow
    }
}

struct SMSStatus: Codable, Sendable {
    let autoCleanupME: Bool
    let count: Int?
    let lastPollError: String?

    enum CodingKeys: String, CodingKey {
        case count
        case autoCleanupME = "auto_cleanup_me"
        case lastPollError = "last_poll_error"
    }
}

struct RejectResponse: Codable, Sendable { let rejected: Bool }
struct SMSSendResult: Codable, Sendable { let sent: Bool; let segments: Int? }
struct CallRecordingResponse: Codable, Sendable { let recording: Bool; let path: String? }
struct SIMIdentity: Codable, Sendable {
    let phoneNumber: String
    enum CodingKeys: String, CodingKey { case phoneNumber = "phone_number" }
}

// MARK: - 模块、网络与定位

struct ModemStatus: Codable, Sendable {
    let imei: String?
    let firmware: String?
    let iccid: String?
    let imsi: String?
    let operatorName: String?
    let simInserted: Bool?
    let signalDBM: Int?
    let networkMode: String?
    let radioBand: String?
    let registrationText: String?

    enum CodingKeys: String, CodingKey {
        case imei, firmware, iccid, imsi
        case operatorName = "operator"
        case simInserted = "sim_inserted"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
        case radioBand = "radio_band"
        case registrationText = "reg_status_text"
    }
}

struct NetworkTrafficSnapshot: Codable, Sendable {
    let available: Bool
    let interface: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let sessionRX: UInt64
    let sessionTX: UInt64
    let sessionTotal: UInt64
    let sampledAtMS: Int64
    let error: String?

    enum CodingKeys: String, CodingKey {
        case available, interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case sessionRX = "session_rx_bytes"
        case sessionTX = "session_tx_bytes"
        case sessionTotal = "session_total_bytes"
        case sampledAtMS = "sampled_at_ms"
    }
}

/// 模块从只读 Linux sysfs 接口采集的电源与温度数据。
/// 不包含任何调频、断电或风扇控制命令，避免监测功能干扰通话。
struct SystemPowerStatus: Codable, Sendable {
    let supported: Bool
    let readings: [SystemPowerReading]
    let sampledAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case supported, readings
        case sampledAtMS = "sampled_at_ms"
    }
}

struct SystemPowerReading: Codable, Sendable, Identifiable {
    let kind: String
    let name: String
    let path: String
    let voltageV: Double?
    let currentA: Double?
    let powerW: Double?
    let temperatureC: Double?
    let capacityPercent: Int?
    let online: Bool?
    let status: String?

    var id: String { "\(kind):\(path)" }

    enum CodingKeys: String, CodingKey {
        case kind, name, path, online, status
        case voltageV = "voltage_v"
        case currentA = "current_a"
        case powerW = "power_w"
        case temperatureC = "temperature_c"
        case capacityPercent = "capacity_percent"
    }
}

struct CellularPolicyStatus: Codable, Sendable {
    let forceOff: Bool
    let services: [String]?
    enum CodingKeys: String, CodingKey { case forceOff = "force_off"; case services }
}

struct USBProfileStatus: Codable, Sendable {
    let mode: String
    let uacEnabled: Bool
    let configuration: String
    let needsReconnect: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case mode, configuration, message
        case uacEnabled = "uac_enabled"
        case needsReconnect = "needs_reconnect"
    }
}

struct NetworkCheckResult: Codable, Sendable {
    let ok: Bool
    let summary: String?
    let detail: String?
}

struct GPSStatus: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    let lastError: String?
    enum CodingKeys: String, CodingKey {
        case enabled
        case lastFix = "last_fix"
        case lastError = "last_error"
    }
}

struct GPSFixSummary: Codable, Sendable {
    let latitude: String?
    let longitude: String?
    let hdop: String
    let satellites: String
}

struct GPSControlResponse: Codable, Sendable {
    let enabled: Bool
    let lastFix: GPSFixSummary?
    enum CodingKeys: String, CodingKey { case enabled; case lastFix = "last_fix" }
}

struct ATResult: Codable, Sendable { let response: String }

// MARK: - eSIM

struct ESIMOverview: Codable, Sendable {
    let cardType: String?
    let message: String?
    let chipInfo: ESIMChipInfo?
    let profiles: [ESIMProfileGroup]?

    enum CodingKeys: String, CodingKey {
        case message, profiles
        case cardType = "card_type"
        case chipInfo = "chip_info"
    }
}

struct ESIMChipInfo: Codable, Sendable {
    let skuName: String?
    let serialNumber: String?
    let firmware: String?
    let eids: [ESIMEID]?

    enum CodingKeys: String, CodingKey {
        case firmware, eids
        case skuName = "sku_name"
        case serialNumber = "serial_number"
    }
}

struct ESIMEID: Codable, Sendable, Identifiable {
    let eid: String?
    let aid: String?
    let freeNvram: String?
    let firmware: String?
    let specGuess: String?

    var id: String { eid ?? aid ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case eid, aid, firmware
        case freeNvram = "free_nvram"
        case specGuess = "spec_guess"
    }
}

struct ESIMProfileGroup: Codable, Sendable {
    let eid: String?
    let aidHex: String?
    let profiles: [ESIMProfile]?
    enum CodingKeys: String, CodingKey { case eid, profiles; case aidHex = "aid_hex" }
}

struct ESIMProfile: Codable, Sendable, Identifiable {
    let iccid: String?
    let name: String?
    let serviceProviderName: String?
    let state: Int?
    let stateText: String?

    var id: String { iccid ?? name ?? UUID().uuidString }
    var enabled: Bool { state == 1 }
    var displayName: String { name ?? serviceProviderName ?? iccid ?? "未命名 Profile" }

    enum CodingKeys: String, CodingKey {
        case iccid, name, state
        case serviceProviderName = "service_provider_name"
        case stateText = "state_text"
    }
}

struct ESIMHealth: Codable, Sendable {
    let ok: Bool?
    let message: String?
    let activeProfile: ESIMProfile?
    let moduleICCID: String?
    let registration: String?
    let registered: Bool?
    let signalDBM: Int?
    let networkMode: String?

    enum CodingKeys: String, CodingKey {
        case ok, message, registration, registered
        case activeProfile = "active_profile"
        case moduleICCID = "module_iccid"
        case signalDBM = "signal_dbm"
        case networkMode = "network_mode"
    }
}

struct ESIMSwitchResult: Codable, Sendable {
    let switchAccepted: Bool?
    let phase: String?
    let targetICCID: String?
    let recoveryPending: Bool?
    let moduleRebootRequested: Bool?
    let reconnectWaitSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case phase
        case switchAccepted = "switch_accepted"
        case targetICCID = "target_iccid"
        case recoveryPending = "recovery_pending"
        case moduleRebootRequested = "module_reboot_requested"
        case reconnectWaitSeconds = "reconnect_wait_seconds"
    }
}

struct ESIMNote: Codable, Sendable { let label: String?; let phone: String?; let tags: String? }
struct ESIMNotesResponse: Codable, Sendable { let notes: [String: ESIMNote] }
struct ESIMDownloadResult: Codable, Sendable { let message: String? }

struct ESIMPhonebookProbe: Codable, Sendable {
    let storageSupported: Bool?
    let storageSelected: Bool?
    let readSupported: Bool?
    let writeSupported: Bool?
    let storageStatus: String?

    enum CodingKeys: String, CodingKey {
        case storageSupported = "storage_supported"
        case storageSelected = "storage_selected"
        case readSupported = "read_supported"
        case writeSupported = "write_supported"
        case storageStatus = "storage_status"
    }
}

// MARK: - 诊断与语音运行时

struct ModuleDebugSnapshot: Codable, Sendable {
    let debug: ModuleDebugBufferStatus
    let agent: ModuleDebugAgentStatus
    let at: ModuleDebugATStatus
    let usb: [String: String]
    let traffic: ModuleDebugTrafficStatus
    let modem: ModemStatus
    let calls: ModuleDebugCallStatus
    let sms: ModuleDebugSMSStatus
    let voice: VoiceRuntimeStatus
    let events: [ModuleDebugEvent]
}

struct ModuleDebugBufferStatus: Codable, Sendable {
    let latestSequence: UInt64
    let returnedEvents: Int
    let storedBytes: Int
    let maxEvents: Int
    let maxStoredBytes: Int

    enum CodingKeys: String, CodingKey {
        case latestSequence = "latest_sequence"
        case returnedEvents = "returned_events"
        case storedBytes = "stored_bytes"
        case maxEvents = "max_events"
        case maxStoredBytes = "max_stored_bytes"
    }
}

struct ModuleDebugAgentStatus: Codable, Sendable {
    let version: String
    let uptimeSeconds: Int
    let goroutines: Int
    let heapBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case version, goroutines
        case uptimeSeconds = "uptime_seconds"
        case heapBytes = "heap_bytes"
    }
}

struct ModuleDebugATStatus: Codable, Sendable {
    let device: String
    let lastSuccessAt: String?
    let consecutiveFailures: Int
    let reopenCount: Int

    enum CodingKeys: String, CodingKey {
        case device
        case lastSuccessAt = "last_success_at"
        case consecutiveFailures = "consecutive_failures"
        case reopenCount = "reopen_count"
    }
}

struct ModuleDebugTrafficStatus: Codable, Sendable {
    let interface: String?
    let rxBytes: UInt64?
    let txBytes: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }
}

struct ModuleDebugCallStatus: Codable, Sendable {
    let active: CallRecord?
    let historyCount: Int
    let eventDriven: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case active
        case historyCount = "history_count"
        case eventDriven = "event_driven"
        case lastError = "last_error"
    }
}

struct ModuleDebugSMSStatus: Codable, Sendable {
    let count: Int
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case count
        case lastError = "last_error"
    }
}

struct ModuleDebugEvent: Codable, Sendable, Identifiable {
    let sequence: UInt64
    let timestamp: String
    let category: String
    let direction: String?
    let summary: String
    let payload: String?
    let fields: [String: String]?

    var id: UInt64 { sequence }
}

struct NetworkDiagnostic: Codable, Sendable {
    let usbnetMode: String?
    let usbcfg: String?
    let pdpContexts: [PDPContext]?
    let activeContexts: [Int]?
    let pdpAddresses: [String]?
    let interfaces: [NetworkInterface]?
    let defaultRoute: NetworkDefaultRoute?
    let usbNetworkPresent: Bool
    let usbDevice: USBDeviceStatus?
    let errors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case usbcfg, errors
        case usbnetMode = "usbnet_mode"
        case pdpContexts = "pdp_contexts"
        case activeContexts = "active_contexts"
        case pdpAddresses = "pdp_addresses"
        // 后端为兼容 Mac 版保留了旧字段名。
        case interfaces = "mac_interfaces"
        case defaultRoute = "default_route"
        case usbNetworkPresent = "usb_network_present"
        case usbDevice = "usb_device"
    }
}

struct PDPContext: Codable, Sendable { let id: Int?; let pdn: String?; let apn: String? }
struct NetworkInterface: Codable, Sendable {
    let name: String?; let status: String?; let ipv4: String?; let mac: String?; let kind: String?
}
struct NetworkDefaultRoute: Codable, Sendable { let interface: String?; let gateway: String? }
struct USBDeviceStatus: Codable, Sendable {
    let vendor: String?; let product: String?; let vendorID: String?; let productID: String?; let mode: String?
    enum CodingKeys: String, CodingKey {
        case vendor, product, mode
        case vendorID = "vendor_id"
        case productID = "product_id"
    }
}

struct ModuleSetupStatus: Codable, Sendable {
    let state: String
    let summary: String
    let detail: String?
    let canInitialize: Bool
    let requiresConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case state, summary, detail
        case canInitialize = "can_initialize"
        case requiresConfirmation = "requires_confirmation"
    }
}

struct VoiceRuntimeStatus: Codable, Sendable {
    let ready: Bool
    let runtimeInstalled: Bool
    let runtimeSource: String?
    let runtimeDetail: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case ready
        case runtimeInstalled = "runtime_installed"
        case runtimeSource = "runtime_source"
        case runtimeDetail = "runtime_detail"
        case lastError = "last_error"
    }
}

struct ModuleUpdateStatus: Codable, Sendable {
    let supported: Bool
    let formatVersion: Int?
    let platform: String?
    let installedVersion: String?
    let publicKeyID: String?

    enum CodingKeys: String, CodingKey {
        case supported, platform
        case formatVersion = "format_version"
        case installedVersion = "installed_version"
        case publicKeyID = "public_key_id"
    }
}

struct ModuleUpdateResult: Codable, Sendable {
    let updated: Bool
    let version: String?
    let restartRequired: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case updated, version, message
        case restartRequired = "restart_required"
    }
}

struct MaVoAudioHostConfig: Codable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
    let routeReady: Bool
    let routeSessionReady: Bool?
    let routeError: String?
    let routeRunning: Bool?
    let helperPID: Int?
    let sessionStartedAt: String?
    let statisticsAvailable: Bool?
    let statistics: VoicePCMStatistics?
    let diagnosticLog: String?
    let logTail: [String]?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case locationID = "location_id"
        case routeReady = "route_ready"
        case routeSessionReady = "route_session_ready"
        case routeError = "route_error"
        case routeRunning = "route_running"
        case helperPID = "helper_pid"
        case sessionStartedAt = "session_started_at"
        case statisticsAvailable = "statistics_available"
        case statistics
        case diagnosticLog = "diagnostic_log"
        case logTail = "log_tail"
    }
}

/// 模块语音桥的累计 PCM 统计；峰值为 PCM16 绝对幅度，0 代表纯静音。
struct VoicePCMStatistics: Codable, Sendable {
    let uplinkBytes: UInt64
    let uplinkFrames: UInt64
    let uplinkPeak: UInt64
    let downlinkBytes: UInt64
    let downlinkFrames: UInt64
    let downlinkPeak: UInt64
    let downlinkDroppedFrames: UInt64

    enum CodingKeys: String, CodingKey {
        case uplinkBytes = "uplink_bytes"
        case uplinkFrames = "uplink_frames"
        case uplinkPeak = "uplink_peak"
        case downlinkBytes = "downlink_bytes"
        case downlinkFrames = "downlink_frames"
        case downlinkPeak = "downlink_peak"
        case downlinkDroppedFrames = "downlink_dropped_frames"
    }
}
