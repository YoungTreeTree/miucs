import Foundation
import Darwin
import IOKit
import IOKit.serial


public enum HardwareSerialError: LocalizedError {
    case message(String)
    case cardChanged(DeskIsleCard)
    case petRejected(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .cardChanged: "桌屿卡片规格已更新"
        case .petRejected(let code): "小屏未能运行桌宠皮肤（\(code)）"
        }
    }
}

/// Owns the descriptor off the UI thread and serializes all writes.
public actor HardwareSerial {
    private static let responseTimeout = 3.0
    private var descriptor: Int32 = -1
    private var input = Data()
    private var screen: HardwareScreen?
    private var alphaCardID: UInt16?
    private var pet: DeskIslePetCapability?
    private var pendingPetInput: (first: UInt32, last: UInt32, deadline: Double)?

    public init() {}
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    public func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1; input.removeAll(keepingCapacity: true)
        screen = nil
        alphaCardID = nil
        pet = nil
        pendingPetInput = nil
    }

    public func close(clearing expected: HardwareScreen?, sequence: UInt32) {
        guard !Task.isCancelled else { return }
        defer { close() }
        if let expected, let pet = expected.card?.pet, pet.version >= 3 {
            let packet = HardwareFrame.nativePet(.clear, payload: Data(), sequence: sequence, id: pet.id)
            _ = try? send(packet, sequence: sequence, screen: expected, nativePet: true)
        }
    }

    @discardableResult
    public func connect(path: String, unixSocket: Bool = false) throws -> HardwareScreen {
        close()
        do {
            if unixSocket {
                try connectRelay(path: path)
            } else {
                try connectSerial(path: path)
            }
            return try handshake()
        } catch { close(); throw error }
    }

    /// Takes ownership of a host-configured native CDC or in-process channel descriptor.
    @discardableResult
    public func connect(takingOwnershipOf fd: Int32) throws -> HardwareScreen {
        close()
        descriptor = fd
        do { return try handshake() } catch { close(); throw error }
    }

    private func handshake() throws -> HardwareScreen {
            let deadline = ProcessInfo.processInfo.systemUptime + 3.5
            while ProcessInfo.processInfo.systemUptime < deadline {
                let line = try readLine(deadline: deadline)
                if line == "MIUCS_DISPLAY 1 720 1280 262144" {
                    screen = .miucs
                    return .miucs
                }
                if let card = cardAnnouncement(line) {
                    screen = .deskIsle(card)
                    return .deskIsle(card)
                }
            }
            throw HardwareSerialError.message("没有收到屏幕握手，请检查固件和 USB 接口")
    }

    private func connectSerial(path: String) throws {
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw HardwareSerialError.message("无法打开屏幕：\(String(cString: strerror(errno)))") }
        guard ioctl(descriptor, TIOCEXCL) == 0 else { throw HardwareSerialError.message("屏幕端口正在被其他程序使用") }
        var config = termios()
        guard tcgetattr(descriptor, &config) == 0 else { throw HardwareSerialError.message("无法读取屏幕端口配置") }
        cfmakeraw(&config)
        config.c_cflag |= tcflag_t(CLOCAL | CREAD)
        config.c_cflag &= ~tcflag_t(HUPCL)
        cfsetspeed(&config, speed_t(B115200)) // CDC line coding; native USB transfer is not baud limited.
        guard tcsetattr(descriptor, TCSANOW, &config) == 0 else { throw HardwareSerialError.message("无法设置屏幕端口") }
    }

    private func connectRelay(path: String) throws {
        let unavailable = HardwareSerialError.message("桌屿的 CH343 连接暂不可用")
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw unavailable }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw unavailable }
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw unavailable
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard result == 0, getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { throw unavailable }
    }
    public func send(_ packet: Data, sequence: UInt32, screen expected: HardwareScreen = .miucs,
              nativePet: Bool = false) throws -> Int {
        guard descriptor >= 0, let screen else { throw HardwareSerialError.message("屏幕已断开") }
        // This command starts a new operation. Ignore replies from the previous input stream.
        pendingPetInput = nil
        do {
            if screen.card != nil {
                // Announcements may arrive between frames, including while the card is idle.
                try readInput()
                while let line = popLine() { updateCard(from: line) }
            }
            try checkScreen(expected)
            let deadline = ProcessInfo.processInfo.systemUptime + Self.responseTimeout
            try writePacket(packet, deadline: deadline)
            while true {
                let line = try readLine(deadline: deadline)
                updateCard(from: line)
                let fields = line.split(separator: " ")
                let prefix = screen.card == nil ? "MIUCS_ACK" : "DESKISLE_ACK"
                guard fields.count == 4, fields[0] == prefix, UInt32(fields[1]) == sequence else { continue }
                try checkScreen(expected)
                if nativePet && fields[2] != "0" { throw HardwareSerialError.petRejected(String(fields[2])) }
                guard fields[2] == "0", let ms = Int(fields[3]) else { throw HardwareSerialError.message("屏幕未能显示此帧（\(fields[2])）") }
                return ms
            }
        } catch HardwareSerialError.cardChanged(let card) {
            throw HardwareSerialError.cardChanged(card)
        } catch HardwareSerialError.petRejected(let code) {
            throw HardwareSerialError.petRejected(code)
        } catch { close(); throw error }
    }

    public func sendPetInput(_ packet: Data, sequence: UInt32, screen expected: HardwareScreen) throws {
        guard descriptor >= 0 else { throw HardwareSerialError.message("屏幕已断开") }
        do {
            // Drain whatever has already arrived. A missing reply leaves the writer free to continue.
            try readInput()
            var rejection: String?
            while let line = popLine() {
                updateCard(from: line)
                guard let pending = pendingPetInput, line.hasPrefix("DESKISLE_ACK ") else { continue }
                let fields = line.split(separator: " ")
                guard fields.count == 4, let ack = UInt32(fields[1]), Int(fields[3]) != nil,
                      ack &- pending.first <= pending.last &- pending.first else { continue }
                if fields[2] != "0", rejection == nil { rejection = String(fields[2]) }
                pendingPetInput = ack == pending.last ? nil :
                    (ack &+ 1, pending.last, ProcessInfo.processInfo.systemUptime + Self.responseTimeout)
            }
            try checkScreen(expected)
            if let rejection { throw HardwareSerialError.petRejected(rejection) }

            let now = ProcessInfo.processInfo.systemUptime
            if let pending = pendingPetInput, now >= pending.deadline {
                throw HardwareSerialError.message("屏幕响应超时，正在重新连接")
            }
            try writePacket(packet, deadline: now + Self.responseTimeout)
            if pendingPetInput == nil {
                pendingPetInput = (sequence, sequence, now + Self.responseTimeout)
            } else {
                pendingPetInput?.last = sequence
            }
        } catch HardwareSerialError.cardChanged(let card) {
            pendingPetInput = nil
            throw HardwareSerialError.cardChanged(card)
        } catch HardwareSerialError.petRejected(let code) {
            pendingPetInput = nil
            throw HardwareSerialError.petRejected(code)
        } catch { close(); throw error }
    }

    private func writePacket(_ packet: Data, deadline: Double) throws {
        var offset = 0
        try packet.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try wait(POLLOUT, deadline: deadline)
                let n = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno != EAGAIN && errno != EINTR { throw HardwareSerialError.message("USB 发送中断") }
            }
        }
    }

    private func updateCard(from line: String) {
        guard screen?.card != nil, let card = cardAnnouncement(line) else { return }
        screen = .deskIsle(card)
    }
    private func cardAnnouncement(_ line: String) -> DeskIsleCard? {
        if line.hasPrefix("DESKISLE_ALPHA ") {
            let fields = line.split(separator: " ")
            if fields.count == 3, fields[1] == "1", let id = UInt16(fields[2]), id > 0 {
                alphaCardID = id
            }
            return nil
        }
        if let capability = DeskIslePetCapability(line) {
            if capability.version >= (pet?.version ?? 0) { pet = capability }
            return nil
        }
        return DeskIsleCard(announcement: line, alphaCardID: alphaCardID, pet: pet)
    }
    private func checkScreen(_ expected: HardwareScreen) throws {
        guard screen != expected else { return }
        if let card = screen?.card { throw HardwareSerialError.cardChanged(card) }
        throw HardwareSerialError.message("屏幕协议已变化，正在重新连接")
    }
    private func wait(_ events: Int32, deadline: Double) throws {
        while true {
            try Task.checkCancellation()
            guard descriptor >= 0 else { throw HardwareSerialError.message("屏幕已断开") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HardwareSerialError.message("屏幕响应超时，正在重新连接") }
            var descriptors = [pollfd(fd: descriptor, events: Int16(events), revents: 0)]
            let result = HardwareIO.wait(&descriptors, milliseconds: 20)
            if result < 0 && errno != EINTR { throw HardwareSerialError.message("USB 连接错误") }
            if result > 0 {
                if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw HardwareSerialError.message("屏幕已断开") }
                if descriptors[0].revents & Int16(events) != 0 { return }
            }
        }
    }
    private func readLine(deadline: Double) throws -> String {
        while true {
            if let line = popLine() { return line }
            try wait(POLLIN, deadline: deadline)
            try readInput()
        }
    }
    private func popLine() -> String? {
        guard let end = input.firstIndex(of: 10) else { return nil }
        let line = String(decoding: input[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        input.removeSubrange(...end)
        return line
    }
    private func readInput() throws {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(descriptor, &buffer, buffer.count)
        if n > 0 {
            input.append(contentsOf: buffer.prefix(n))
            if input.count > 8192 { throw HardwareSerialError.message("屏幕返回了无效数据") }
        } else if n == 0 { throw HardwareSerialError.message("屏幕已断开") }
        else if n < 0 && errno != EAGAIN && errno != EINTR {
            throw HardwareSerialError.message("USB 接收中断")
        }
    }
}
