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

    /// Storage slot of a module text-mode record. The delivery id is shaped
    /// `SM-3-1a2b...`, so its middle field is the slot the modem kept the record in.
    ///
    /// The slot follows arrival order, which is the only stable way to put the records
    /// of one long SMS back into reading order: the module hands a concatenated SMS back
    /// as one record per segment and all of those share one SCTS. PDU assembled messages
    /// carry no delivery id and answer nil here.
    var deliverySlotIndex: Int? {
        guard let deliveryID else { return nil }
        let parts = deliveryID.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    /// 后端短信没有独立 ID，以稳定字段组合生成列表标识。
    var id: String { "\(sender)\u{0}\(timestamp.timeIntervalSince1970)\u{0}\(content)\u{0}\(direction?.rawValue ?? SMSDirection.incoming.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case sender, content, code, timestamp, direction
        case deliveryID = "delivery_id"
    }
}

extension SMSMessage {
    /// 把同一会话的记录排成「旧 → 新」。
    ///
    /// 长短信的拼接已经在 `SMSDecoder` 里按 3GPP TS 23.040 的 UDH 完成，
    /// 这里不再做任何「按长度猜分段」的合并：旧实现按内容长度和模块存储槽
    /// 猜测分段边界，每次刷新的分组和顺序都可能不同，正是「一条长短信时而
    /// 一个气泡、时而多个气泡」以及顺序错乱的根因。
    static func chronological(_ messages: [SMSMessage]) -> [SMSMessage] {
        messages.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            // Every segment of one long SMS carries the same SCTS, so the tie has to be
            // broken by the module storage slot, which is arrival order. Breaking it with
            // `id` compared the body text instead, which scrambled the paragraph order
            // inside the bubble.
            let left = lhs.deliverySlotIndex
            let right = rhs.deliverySlotIndex
            if let left, let right, left != right { return left < right }
            if left != nil, right == nil { return true }
            if left == nil, right != nil { return false }
            return lhs.id < rhs.id
        }
    }
}

/// 模块短信存储区里的一条记录：`+CMGL` 表头 + 紧随其后的十六进制 PDU。
struct SMSListingEntry: Sendable {
    let memory: String
    let index: Int
    let status: Int
    let pdu: [UInt8]
}

/// `SMSDecoder.assemble` 的产出：可以放进消息列表的完整短信，
/// 以及已经被完整消费、可以从模块存储里删掉的原始记录。
///
/// 两者必须分开返回：分段还没收齐的长短信不能交付，它的那些分段也就**不能删**，
/// 否则后面的分段到了也拼不起来，短信会永远缺一段。
struct SMSAssembly: Sendable {
    let messages: [SMSMessage]
    let consumed: [SMSListingEntry]
}

/// 一条 SMS-DELIVER 的解码结果；带 UDH 时给出拼接用的参考号、总段数与段序号。
struct SMSDecodedDelivery: Sendable {
    let sender: String
    let text: String
    let timestamp: Date
    let reference: Int?
    let total: Int?
    let sequence: Int?
}

/// 解析 PDU 模式的 `AT+CMGL=4` 列表，并把长短信按 UDH 拼回完整内容。
///
/// 模块自带的 `/api/sms` 走文本模式（`AT+CMGF=1` + `AT+CMGL="ALL"`）：基带按
/// 存储记录逐条返回，UDH 被丢掉，于是一条长短信会变成多条独立记录，顺序等于
/// 基带存储位置（删除后槽位还会复用），既不是到达顺序也没有段序号可用。
/// 所以在 App 侧改用 PDU 读取：UDH 里的参考号/总段数/段序号让拼接完全确定。
enum SMSDecoder {
    /// 自家模块发送长短信时按 70 个 UTF-16 单元切段且不写 UDH，
    /// 接收侧只能靠这个固定长度把分段重聚回一条。
    static let unsegmentedFragmentUnits = 70
    /// 无 UDH 分段重聚的时间窗：模块发送的多段几乎同时到达。
    static let unsegmentedJoinWindow: TimeInterval = 60
    /// 判定「下一条记录是这条长短信的后续分段」的间隔：同一条长短信的各段
    /// 几乎同时到达，间隔再大就当成两条独立短信，不再拼在一起。
    static let unsegmentedSiblingWindow: TimeInterval = 30
    // Widened from 8 seconds: network jitter sometimes spreads the segments of a single
    // SMS over more than eight seconds, and a run cut in half was delivered as a second
    // bubble even though both halves belonged to one message.
    /// 带 UDH 的长短信长时间收不齐时的兜底时长：超过它就先把已到的部分交出来，
    /// 宁可显示「半条」也不整条吞掉；正常情况远早于此就收齐了。
    static let incompleteGroupTimeout: TimeInterval = 90
    /// A concatenation reference is only 8 bits wide and the network recycles it. Parts
    /// further apart than this cannot belong to the same message, so they are assembled
    /// as separate groups instead of being joined into one scrambled body.
    static let groupClusterGap: TimeInterval = 300

    /// Capacity in UTF-16 units of one segment of a long SMS that carries no UDH.
    ///
    /// The module splits its own long SMS at 70 UTF-16 units, while a segment that came
    /// through a real network carries a 6 octet UDH and leaves 134 octets for UCS-2 text,
    /// that is 67 UTF-16 units. Measuring a 67 unit segment against 70 declared every
    /// segment of a received long Chinese SMS to be a complete message, so one SMS turned
    /// into one bubble per segment.
    static func unsegmentedSegmentUnits(for text: String) -> Int {
        text.unicodeScalars.contains { $0.value > 0x7F } ? 67 : unsegmentedFragmentUnits
    }

    /// 解析一个存储区的 `AT+CMGL=4` 响应。
    static func parseListing(_ response: String, memory: String) -> [SMSListingEntry] {
        let lines = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var entries: [SMSListingEntry] = []
        var position = 0
        while position < lines.count {
            let header = lines[position]
            guard header.hasPrefix("+CMGL:") else {
                position += 1
                continue
            }
            let fields = header
                .dropFirst("+CMGL:".count)
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let index = Int(fields[0]), let status = Int(fields[1]) else {
                position += 1
                continue
            }
            var pduLine = position + 1
            while pduLine < lines.count, lines[pduLine].isEmpty { pduLine += 1 }
            guard pduLine < lines.count, let pdu = hexBytes(lines[pduLine]) else {
                position = pduLine + 1
                continue
            }
            entries.append(SMSListingEntry(memory: memory, index: index, status: status, pdu: pdu))
            position = pduLine + 1
        }
        return entries
    }

    /// 把一段十六进制字符串转成字节，非法输入返回 nil。
    static func hexBytes(_ value: String) -> [UInt8]? {
        let digits = value.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// 把本次读到的所有存储记录拼成完整短信（只产出收到的消息）。
    ///
    /// 关键点是**只交付收齐的长短信**：分段短信是逐条到达的，以前来一段就拼一段，
    /// 于是同一条长短信在消息窗口里先裂成几条、补齐后又合成一条，反复变化。
    /// 现在段数不齐的分组先压住不交付（它的分段也不会被删），收齐后再一次给出。
    static func assemble(_ entries: [SMSListingEntry], now: Date = Date()) -> SMSAssembly {
        // 记住每条记录在入参里的下标，用来回传「可以删除」的模块记录。
        var groups: [String: [(offset: Int, index: Int, delivery: SMSDecodedDelivery)]] = [:]
        var singles: [(offset: Int, index: Int, delivery: SMSDecodedDelivery)] = []
        for (offset, entry) in entries.enumerated() {
            guard let delivery = decode(entry.pdu) else { continue }
            if let reference = delivery.reference, delivery.sequence != nil {
                // The total segment count is deliberately not part of the key: some
                // networks write 0 into the last segment to mean "unknown", and that one
                // segment would then form a group of its own and reach the chat as a
                // complete message, cutting the body short.
                groups["\(delivery.sender)|\(reference)", default: []]
                    .append((offset, entry.index, delivery))
            } else {
                singles.append((offset, entry.index, delivery))
            }
        }

        var deliveries: [SMSDecodedDelivery] = []
        var consumedOffsets: [Int] = []
        // The network recycles the concatenation reference, so an unfinished group left in
        // storage can be picked up by a later, unrelated message that happens to reuse the
        // same number, joining two messages into one scrambled body. The parts of one
        // message always arrive within the same short window, so split each key into
        // arrival clusters and assemble every cluster on its own.
        var clusters: [String: [(offset: Int, index: Int, delivery: SMSDecodedDelivery)]] = [:]
        for (key, parts) in groups {
            let orderedParts = parts.sorted { lhs, rhs in
                let left = lhs.delivery.sequence ?? 0
                let right = rhs.delivery.sequence ?? 0
                if left != right { return left < right }
                return lhs.index < rhs.index
            }
            var cluster = 0
            var previous: Date?
            for part in orderedParts {
                if let previous,
                   part.delivery.timestamp.timeIntervalSince(previous) > groupClusterGap {
                    cluster += 1
                }
                previous = part.delivery.timestamp
                clusters["\(key)|\(cluster)", default: []].append(part)
            }
        }
        groups = clusters
        for parts in groups.values {
            let ordered = parts.sorted { lhs, rhs in
                let left = lhs.delivery.sequence ?? 0
                let right = rhs.delivery.sequence ?? 0
                if left != right { return left < right }
                return lhs.index < rhs.index
            }
            guard let last = ordered.last else { continue }
            // Trust the totals the segments declare. A 0 there means "unknown", so one
            // zero on the last segment must not make it look like a complete message.
            let total = ordered.map { $0.delivery.total }.compactMap { $0 }.filter { $0 > 0 }.max()
                ?? ordered.count
            let present = Set(ordered.compactMap(\.delivery.sequence))
            // 收齐了才交付；长时间收不齐（丢段）时兜底先交已到的部分，绝不整条吞掉。
            guard present.count >= total
                    || now.timeIntervalSince(last.delivery.timestamp) > incompleteGroupTimeout else { continue }
            deliveries.append(
                SMSDecodedDelivery(
                    sender: last.delivery.sender,
                    text: ordered.map(\.delivery.text).joined(),
                    timestamp: last.delivery.timestamp,
                    reference: last.delivery.reference,
                    total: last.delivery.total,
                    sequence: last.delivery.sequence
                )
            )
            consumedOffsets += ordered.map(\.offset)
        }

        let rejoined = rejoinUnsegmented(
            singles.map { (delivery: $0.delivery, index: $0.index) },
            now: now
        )
        deliveries += rejoined.deliveries
        consumedOffsets += rejoined.consumedPositions.map { singles[$0].offset }

        let messages = deliveries
            .sorted { $0.timestamp < $1.timestamp }
            .map { delivery in
                SMSMessage(
                    sender: delivery.sender,
                    content: delivery.text,
                    code: verificationCode(in: delivery.text),
                    timestamp: delivery.timestamp,
                    deliveryID: nil,
                    direction: .incoming
                )
            }
        return SMSAssembly(
            messages: messages,
            consumed: consumedOffsets.sorted().map { entries[$0] }
        )
    }

    /// 解码一条 SMS-DELIVER PDU；其它类型（状态报告等）返回 nil。
    static func decode(_ bytes: [UInt8]) -> SMSDecodedDelivery? {
        var offset = 0
        guard offset < bytes.count else { return nil }
        // TP-SMSC：第一个字节是地址长度（含 TON 字节），先整体跳过。
        let smscLength = Int(bytes[offset])
        offset += 1
        guard offset + smscLength <= bytes.count else { return nil }
        offset += smscLength

        guard offset < bytes.count else { return nil }
        let firstOctet = bytes[offset]
        offset += 1
        // 只处理 SMS-DELIVER（MTI=00）。
        guard firstOctet & 0x03 == 0 else { return nil }
        let hasUserDataHeader = firstOctet & 0x40 != 0

        guard offset < bytes.count else { return nil }
        let addressLength = Int(bytes[offset])
        offset += 1
        let addressOctets = (addressLength + 1) / 2
        guard offset + 1 + addressOctets + 2 + 7 + 1 <= bytes.count else { return nil }
        // TON ?????? bit6-4?bit7 ?????0x91 ????????
        let typeOfNumber = (bytes[offset] >> 4) & 0x07
        offset += 1
        let addressBytes = Array(bytes[offset..<(offset + addressOctets)])
        offset += addressOctets
        let sender = decodeAddress(typeOfNumber: typeOfNumber, semiOctets: addressBytes, length: addressLength)

        offset += 1 // TP-PID
        let dataCodingScheme = bytes[offset]
        offset += 1

        guard let timestamp = decodeTimestamp(Array(bytes[offset..<(offset + 7)])) else { return nil }
        offset += 7

        guard offset < bytes.count else { return nil }
        let userDataLength = Int(bytes[offset])
        offset += 1
        let userData = Array(bytes[offset...])

        var reference: Int?
        var total: Int?
        var sequence: Int?
        var headerOctets = 0
        if hasUserDataHeader, !userData.isEmpty {
            let headerLength = Int(userData[0])
            headerOctets = min(1 + headerLength, userData.count)
            var cursor = 1
            while cursor + 1 < headerOctets {
                let identifier = userData[cursor]
                let infoLength = Int(userData[cursor + 1])
                cursor += 2
                guard cursor + infoLength <= headerOctets else { break }
                let payload = Array(userData[cursor..<(cursor + infoLength)])
                if identifier == 0x00, payload.count >= 3 {
                    reference = Int(payload[0])
                    total = Int(payload[1])
                    sequence = Int(payload[2])
                } else if identifier == 0x08, payload.count >= 4 {
                    reference = Int(payload[0]) << 8 | Int(payload[1])
                    total = Int(payload[2])
                    sequence = Int(payload[3])
                }
                cursor += infoLength
            }
        }

        let payload = Array(userData.dropFirst(headerOctets))
        let coding = (dataCodingScheme >> 2) & 0x03
        let text: String
        if coding == 0x02 {
            text = decodeUTF16(payload)
        } else if coding == 0x01 {
            text = String(data: Data(payload), encoding: .utf8) ?? ""
        } else {
            // 7 位编码按 septet 计数，UDH 占掉的字节要换算成 septet 再扣掉，
            // 文本位流从 UDH 之后的字节边界开始。
            let headerSeptets = hasUserDataHeader ? Int(ceil(Double(headerOctets) * 8 / 7)) : 0
            text = decodeGSM7(userData, septets: max(0, userDataLength - headerSeptets), startBit: headerOctets * 8)
        }

        return SMSDecodedDelivery(
            sender: sender,
            text: text,
            timestamp: timestamp,
            reference: reference,
            total: total,
            sequence: sequence
        )
    }

    /// 把没有 UDH 的「70 个 UTF-16 单元」分段重聚回一条。
    ///
    /// 自家模块发送长短信时按 70 个 UCS2 单元切段、且没有写 UDH，接收侧
    /// 拿到的是互相独立的短信。第 1..n-1 段长度必然正好 70，因此用这个固定
    /// 长度加一个短时间窗把它们接回去；真实手机发的长短信一定带 UDH，
    /// 走的是上面的确定性拼接，不会误判。
    /// 重聚结果：可交付的记录，以及**已经完整消费、可以从模块删除**的入参下标。
    struct UnsegmentedRejoin {
        let deliveries: [SMSDecodedDelivery]
        /// 已完整消费的入参**下标**（调用方据此把模块记录删掉）。
        let consumedPositions: [Int]
    }

    /// - Parameter index: 该记录在模块存储区里的槽位号，用来给段序兜底。
    ///   段序只能靠「到达顺序」推：模块发送长短信时不写 UDH，各段的 SCTS
    ///   往往完全相同，只按时间戳排序时 Swift 的 `sorted` 并不稳定，段序会
    ///   随每次刷新变化——那正是「同一条长短信时而一条、时而多条，内容顺序
    ///   还被打乱」的根因。槽位号随到达顺序递增，是可靠的决胜键。
    static func rejoinUnsegmented(
        _ singles: [(delivery: SMSDecodedDelivery, index: Int)],
        now: Date = Date()
    ) -> UnsegmentedRejoin {
        // 带上下标分组，才能把「已完整消费」的位置回传给调用方去删模块副本。
        var grouped: [String: [(position: Int, delivery: SMSDecodedDelivery, index: Int)]] = [:]
        for (position, item) in singles.enumerated() {
            grouped[item.delivery.sender, default: []]
                .append((position, item.delivery, item.index))
        }

        var result: [SMSDecodedDelivery] = []
        var consumed: [Int] = []
        for list in grouped.values {
            let ordered = list.sorted { lhs, rhs in
                if lhs.delivery.timestamp != rhs.delivery.timestamp {
                    return lhs.delivery.timestamp < rhs.delivery.timestamp
                }
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                return lhs.position < rhs.position
            }
            var cursor = 0
            while cursor < ordered.count {
                var run = [ordered[cursor]]
                // 只有「最后一段长度不足一整段」才说明这条长短信已经收齐。
                // 原先只要 run 里有两条就直接交付，于是长短信的各段还在分批到达时，
                // 半条短信会被当成完整短信交付并从模块里删掉，剩下的分段
                // 再拼成第二个气泡——这就是「一条短信被分割成多条、顺序还乱」的来源。
                var complete = ordered[cursor].delivery.text.utf16.count
                    < unsegmentedSegmentUnits(for: ordered[cursor].delivery.text)
                while !complete,
                      let tail = run.last,
                      cursor + 1 < ordered.count,
                      ordered[cursor + 1].delivery.timestamp
                        .timeIntervalSince(tail.delivery.timestamp) <= unsegmentedSiblingWindow {
                    cursor += 1
                    run.append(ordered[cursor])
                    complete = ordered[cursor].delivery.text.utf16.count
                        < unsegmentedSegmentUnits(for: ordered[cursor].delivery.text)
                }
                defer { cursor += 1 }
                guard let last = run.last else { continue }

                // 还没收齐、又还在等待窗口内：整段留在模块里等后续分段，
                // 既不交付也不确认删除（删了就永远拼不完整）。
                let stale = now.timeIntervalSince(last.delivery.timestamp) > unsegmentedJoinWindow
                guard complete || stale else { continue }

                if run.count > 1 {
                    result.append(
                        SMSDecodedDelivery(
                            sender: last.delivery.sender,
                            text: run.map(\.delivery.text).joined(),
                            timestamp: last.delivery.timestamp,
                            reference: nil,
                            total: nil,
                            sequence: nil
                        )
                    )
                } else {
                    result.append(last.delivery)
                }
                consumed += run.map(\.position)
            }
        }
        return UnsegmentedRejoin(deliveries: result, consumedPositions: consumed)
    }

    /// 解出地址字段；TON=5 是字母数字（GSM 7 位打包）发件人，其余按 BCD 数字处理。
    static func decodeAddress(typeOfNumber: UInt8, semiOctets: [UInt8], length: Int) -> String {
        if typeOfNumber == 0x05 {
            return decodeGSM7(semiOctets, septets: length * 4 / 7, startBit: 0)
        }
        var digits = ""
        let nibbles = semiOctets.flatMap { [$0 & 0x0F, $0 >> 4] }
        for index in 0..<length {
            guard index < nibbles.count else { break }
            switch nibbles[index] {
            case 0...9: digits.append(String(nibbles[index]))
            case 0x0A: digits.append("*")
            case 0x0B: digits.append("#")
            case 0x0C: digits.append("a")
            case 0x0D: digits.append("b")
            case 0x0E: digits.append("c")
            default: break
            }
        }
        return typeOfNumber == 0x01 || typeOfNumber == 0x03 ? "+" + digits : digits
    }

    /// 解析 7 字节的 TP-SCTS（BCD 半字节交换，时区以 15 分钟为单位并带符号位）。
    static func decodeTimestamp(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 7 else { return nil }
        // ??????????????????????0x49 -> 94??
        // ? Android gsmBcdByteToInt ??????????????????
        func bcd(_ value: UInt8) -> Int { Int(value & 0x0F) * 10 + Int(value >> 4) }
        let year = bcd(bytes[0])
        let month = bcd(bytes[1])
        let day = bcd(bytes[2])
        let hour = bcd(bytes[3])
        let minute = bcd(bytes[4])
        let second = bcd(bytes[5])
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            return nil
        }
        let zone = bytes[6]
        let negative = zone & 0x08 != 0
        let quarters = Int(zone & 0x07) * 10 + Int((zone >> 4) & 0x07)
        var components = DateComponents()
        components.year = 2000 + year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: (negative ? -quarters : quarters) * 900) ?? .current
        return calendar.date(from: components)
    }

    static func decodeUTF16(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 解 GSM 03.38 的 7 位默认字母表；`startBit` 用于跳过 UDH 占用的位。
    static func decodeGSM7(_ bytes: [UInt8], septets: Int, startBit: Int) -> String {
        guard septets > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        var septet = 0
        var escaped = false
        while septet < septets {
            let bitIndex = startBit + septet * 7
            let byteIndex = bitIndex / 8
            let shift = bitIndex % 8
            guard byteIndex < bytes.count else { break }
            var value = Int(bytes[byteIndex]) >> shift
            if shift > 1, byteIndex + 1 < bytes.count {
                value |= Int(bytes[byteIndex + 1]) << (8 - shift)
            }
            value &= 0x7F
            septet += 1

            if escaped {
                escaped = false
                if let scalar = gsm7Extension[value] { scalars.append(scalar) }
                continue
            }
            if value == 0x1B {
                escaped = true
                continue
            }
            if let scalar = gsm7Basic[value] { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// 与模块 `parseTextModeSMS` 相同的验证码识别，保证两种通道行为一致。
    static func verificationCode(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[^0-9])([0-9]{4,8})(?:[^0-9]|$)") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 2,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    /// GSM 03.38 默认字母表 0x00-0x7F。
    private static let gsm7Basic: [UnicodeScalar?] = {
        let table = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
        var scalars = table.unicodeScalars.map { Optional($0) }
        while scalars.count < 128 { scalars.append(nil) }
        return Array(scalars.prefix(128))
    }()

    /// GSM 03.38 扩展表（0x1B 转义之后）。
    private static let gsm7Extension: [Int: UnicodeScalar] = [
        0x0A: "\u{0C}".unicodeScalars.first!,
        0x14: "^".unicodeScalars.first!,
        0x28: "{".unicodeScalars.first!,
        0x29: "}".unicodeScalars.first!,
        0x2F: "\\".unicodeScalars.first!,
        0x3C: "[".unicodeScalars.first!,
        0x3D: "~".unicodeScalars.first!,
        0x3E: "]".unicodeScalars.first!,
        0x40: "|".unicodeScalars.first!,
        0x65: "€".unicodeScalars.first!
    ]
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
