//
//  RAOPClient.swift
//  Radiola
//
//  Created by kentron on 20.11.2026.
//
//  Minimal AirPlay 1 (RAOP) sender: RTSP control connection, unencrypted
//  uncompressed ALAC audio over UDP, timing replies, sync packets and resends.
//

import CryptoKit
import Darwin
import dnssd
import Foundation

final class RAOPClient: @unchecked Sendable {
    static let sampleRate = 44100
    static let channels = 2
    static let framesPerPacket = 352

    /// We send audio this many frames ahead of what the receiver is playing.
    private static let leadFrames: UInt32 = 88200 // 2 s
    private static let syncLatency: UInt32 = 11025
    private static let historySize = 1024

    let device: AirPlayDevice
    private let rtsp: RTSPConnection
    private let host: String

    private let audioFD: Int32
    private let controlFD: Int32
    private let timingFD: Int32
    private var audioAddr = sockaddr_in()
    private var controlAddr = sockaddr_in()

    private var seq = UInt16.random(in: 0 ... UInt16.max)
    private let rtp0 = UInt32.random(in: 0 ... UInt32.max / 2)
    private let ssrc = UInt32.random(in: 0 ... UInt32.max)
    private var packetIndex: UInt32 = 0

    private var history = [Data?](repeating: nil, count: RAOPClient.historySize)
    private let historyLock = NSLock()
    private let closed = AtomicBool()

    /* ****************************************
     * Connects, authenticates and starts a RECORD session.
     * ****************************************/
    init(device: AirPlayDevice) throws {
        self.device = device

        let (host, port) = try RAOPClient.resolve(device)
        self.host = host
        rtsp = try RTSPConnection(host: host, port: port)

        let sockets = try (0 ..< 3).map { _ in try udpSocket() }
        audioFD = sockets[0]
        controlFD = sockets[1]
        timingFD = sockets[2]

        // The receiver sends timing requests right after SETUP and does not answer
        // RECORD until we reply, so these threads must run before the handshake.
        startTimingThread()
        startControlThread()

        do {
            try handshake()
        } catch {
            // The timing and control threads close their own sockets when they see `closed`
            closed.value = true
            Darwin.close(audioFD)
            rtsp.close()
            throw error
        }
    }

    /* ****************************************
     *
     * ****************************************/
    deinit {
        close()
    }

    /* ****************************************
     *
     * ****************************************/
    private func handshake() throws {
        // OPTIONS, with Digest authentication when the receiver asks for it
        var previousFailed = false
        while true {
            let resp = try rtsp.request("OPTIONS", uri: "*")
            if resp.status == 200 { break }

            guard resp.status == 401, let challenge = resp.headers["www-authenticate"] else {
                throw raopError("OPTIONS failed with status \(resp.status)")
            }

            if previousFailed || rtsp.password == nil {
                guard let password = AirPlayPasswords.password(for: device, previousFailed: previousFailed) else {
                    throw NSError(code: .airPlayAuthError,
                                  message: String(format: NSLocalizedString("A password is required to play on “%@”.", comment: "Player error message. %@ is AirPlay device name"), device.name),
                                  debug: "AirPlay password was not provided")
                }
                rtsp.password = password
            }
            rtsp.challenge = challenge
            previousFailed = true
        }

        let sdp = [
            "v=0",
            "o=iTunes \(UInt32.random(in: 1 ... UInt32.max)) 0 IN IP4 \(rtsp.localIP)",
            "s=iTunes",
            "c=IN IP4 \(host)",
            "t=0 0",
            "m=audio 0 RTP/AVP 96",
            "a=rtpmap:96 AppleLossless",
            "a=fmtp:96 \(RAOPClient.framesPerPacket) 0 16 40 10 14 2 255 0 0 \(RAOPClient.sampleRate)",
        ].joined(separator: "\r\n") + "\r\n"

        var resp = try rtsp.request("ANNOUNCE", body: sdp, contentType: "application/sdp")
        guard resp.status == 200 else { throw raopError("ANNOUNCE failed with status \(resp.status)") }

        resp = try rtsp.request("SETUP", headers: [("Transport",
                                                     "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(boundPort(controlFD));timing_port=\(boundPort(timingFD))")])
        guard resp.status == 200, let transport = resp.headers["transport"] else {
            throw raopError("SETUP failed with status \(resp.status)")
        }
        rtsp.session = resp.headers["session"]

        func port(_ key: String) -> UInt16? {
            for part in transport.split(separator: ";") where part.hasPrefix(key + "=") {
                return UInt16(part.dropFirst(key.count + 1))
            }
            return nil
        }
        guard let serverPort = port("server_port") else { throw raopError("No server_port in Transport: \(transport)") }
        audioAddr = sockaddrIn(host, serverPort)
        controlAddr = sockaddrIn(host, port("control_port") ?? serverPort + 1)

        resp = try rtsp.request("RECORD", headers: [("Range", "npt=0-"), ("RTP-Info", "seq=\(seq);rtptime=\(rtp0)")])
        guard resp.status == 200 else { throw raopError("RECORD failed with status \(resp.status)") }

        debug("[AirPlay] Connected to \(device.serviceName) at \(host), \(transport)")
    }

    /* ****************************************
     * Volume 0…1, the same scale as the local player.
     * ****************************************/
    func setVolume(_ volume: Float) {
        let db: Float = volume <= 0 ? -144 : max(-30, 20 * log10(min(volume, 1)))
        _ = try? rtsp.request("SET_PARAMETER", body: String(format: "volume: %.6f\r\n", db), contentType: "text/parameters")
    }

    /* ****************************************
     * Sends one packet of 352 interleaved stereo frames.
     * ****************************************/
    func sendAudio(_ pcm: [Int16]) {
        let n = packetIndex
        let ts = rtp0 &+ n &* UInt32(RAOPClient.framesPerPacket)

        // A sync packet about once per second, and before the first audio packet
        if n % 125 == 0 {
            sendSync(rtpNow: ts &- RAOPClient.leadFrames, first: n == 0)
        }

        var pkt = Data([0x80, n == 0 ? 0xE0 : 0x60])
        pkt.be16(seq)
        pkt.be32(ts)
        pkt.be32(ssrc)
        pkt.append(alacRawFrame(pcm))
        sendUDP(audioFD, pkt, to: audioAddr)

        historyLock.lock()
        history[Int(seq) % RAOPClient.historySize] = pkt
        historyLock.unlock()

        seq &+= 1
        packetIndex &+= 1
    }

    /* ****************************************
     *
     * ****************************************/
    private func sendSync(rtpNow: UInt32, first: Bool) {
        var p = Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        p.be32(rtpNow &- RAOPClient.syncLatency)
        p.be64(ntpNow())
        p.be32(rtpNow)
        sendUDP(controlFD, p, to: controlAddr)
    }

    /* ****************************************
     *
     * ****************************************/
    func close() {
        guard !closed.value else { return }
        closed.value = true
        _ = try? rtsp.request("TEARDOWN")
        rtsp.close()
        // The timing and control threads close their own sockets when they see `closed`
        Darwin.close(audioFD)
        debug("[AirPlay] Disconnected from \(device.serviceName)")
    }

    /* ****************************************
     * The receiver asks us for our clock (0xD2), we answer with 0xD3.
     * ****************************************/
    private func startTimingThread() {
        let fd = timingFD
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 128)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            defer { Darwin.close(fd) }
            while let self, !self.closed.value {
                len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 && errno != EAGAIN && errno != EINTR { return }
                guard n >= 32, buf[1] & 0x7F == 0x52 else { continue }

                let receiveTime = ntpNow()
                var reply = Data([0x80, 0xD3, 0x00, 0x07, 0, 0, 0, 0])
                reply.append(contentsOf: buf[24 ..< 32]) // reference time = their send time
                reply.be64(receiveTime)
                reply.be64(ntpNow())
                sendUDP(fd, reply, to: from)
            }
        }
        thread.name = "AirPlayTiming"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /* ****************************************
     * Resend requests (0xD5) from the receiver.
     * ****************************************/
    private func startControlThread() {
        let fd = controlFD
        let thread = Thread { [weak self] in
            defer { Darwin.close(fd) }
            var buf = [UInt8](repeating: 0, count: 2048)
            while let self, !self.closed.value {
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0 && errno != EAGAIN && errno != EINTR { return }
                guard n >= 8, buf[1] & 0x7F == 0x55 else { continue }

                let first = UInt16(buf[4]) << 8 | UInt16(buf[5])
                let count = UInt16(buf[6]) << 8 | UInt16(buf[7])
                self.resend(from: first, count: count)
            }
        }
        thread.name = "AirPlayControl"
        thread.start()
    }

    private func resend(from first: UInt16, count: UInt16) {
        historyLock.lock()
        defer { historyLock.unlock() }

        for i in 0 ..< min(count, UInt16(RAOPClient.historySize)) {
            let s = first &+ i
            guard let pkt = history[Int(s) % RAOPClient.historySize], pkt.count > 4,
                  UInt16(pkt[2]) << 8 | UInt16(pkt[3]) == s else { continue }
            var p = Data([0x80, 0xD6, 0x00, 0x01])
            p.append(pkt)
            sendUDP(controlFD, p, to: controlAddr)
        }
    }

    /* ****************************************
     * Bonjour service name -> IPv4 address and port.
     * DNSServiceResolve gives the host name and port, getaddrinfo the IPv4 address.
     * ****************************************/
    private static func resolve(_ device: AirPlayDevice) throws -> (String, UInt16) {
        func failure(_ why: String) -> NSError {
            NSError(code: .airPlayConnectError,
                    message: String(format: NSLocalizedString("Cannot connect to AirPlay device “%@”.", comment: "Player error message. %@ is AirPlay device name"), device.name),
                    debug: "Resolve \(device.serviceName) failed: \(why)")
        }

        final class Reply {
            var host: String?
            var port: UInt16 = 0
            var error = DNSServiceErrorType(kDNSServiceErr_NoError)
        }
        let reply = Reply()

        var ref: DNSServiceRef?
        let err = DNSServiceResolve(&ref, 0, 0, device.serviceName, "_raop._tcp", "local.", { _, _, _, error, _, hostTarget, port, _, _, context in
            let reply = Unmanaged<Reply>.fromOpaque(context!).takeUnretainedValue()
            reply.error = error
            if error == kDNSServiceErr_NoError, let hostTarget {
                reply.host = String(cString: hostTarget)
                reply.port = UInt16(bigEndian: port)
            }
        }, Unmanaged.passUnretained(reply).toOpaque())

        guard err == kDNSServiceErr_NoError, let ref else { throw failure("DNSServiceResolve error \(err)") }
        defer { DNSServiceRefDeallocate(ref) }

        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var pfd = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
        while reply.host == nil && reply.error == kDNSServiceErr_NoError {
            let remaining = Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000)
            guard remaining > 0 else { throw failure("timeout") }
            if poll(&pfd, 1, remaining) > 0 {
                DNSServiceProcessResult(ref)
            }
        }
        guard let host = reply.host else { throw failure("DNSServiceResolve reply error \(reply.error)") }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, nil, &hints, &info)
        guard gai == 0, let info, let sa = info.pointee.ai_addr else {
            throw failure("getaddrinfo \(host): \(String(cString: gai_strerror(gai)))")
        }
        defer { freeaddrinfo(info) }

        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: buf)

        debug("[AirPlay] Resolved \(device.serviceName) -> \(host) \(ip):\(reply.port)")
        return (ip, reply.port)
    }

    private func raopError(_ debugMessage: String) -> NSError {
        NSError(code: .airPlayConnectError,
                message: String(format: NSLocalizedString("Cannot connect to AirPlay device “%@”.", comment: "Player error message. %@ is AirPlay device name"), device.name),
                debug: "[AirPlay] \(device.serviceName): \(debugMessage)")
    }
}

// MARK: - RTSPConnection

private final class RTSPConnection {
    private let fd: Int32
    private let url: String
    private let lock = NSLock()
    private var cseq = 0
    private let clientInstance = (0 ..< 8).map { _ in String(format: "%02X", UInt8.random(in: 0 ... 255)) }.joined()
    private let activeRemote = String(UInt32.random(in: 1 ... UInt32.max))

    let localIP: String
    var session: String?
    var challenge: String?
    var password: String?

    struct Response {
        let status: Int
        let headers: [String: String]
    }

    init(host: String, port: UInt16) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw rtspError("socket() failed: \(String(cString: strerror(errno)))") }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddrIn(host, port)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(sock)
            throw rtspError("connect \(host):\(port) failed: \(msg)")
        }

        fd = sock
        localIP = localAddress(sock)
        url = "rtsp://\(localIP)/\(UInt32.random(in: 1 ... UInt32.max))"
    }

    private var isClosed = false

    deinit {
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    func request(_ method: String, uri: String? = nil, headers: [(String, String)] = [], body: String = "", contentType: String? = nil) throws -> Response {
        lock.lock()
        defer { lock.unlock() }

        cseq += 1
        let target = uri ?? url
        var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: iTunes/7.6.2 (Windows; N;)",
                     "Client-Instance: \(clientInstance)", "DACP-ID: \(clientInstance)", "Active-Remote: \(activeRemote)"]
        if let session { lines.append("Session: \(session)") }
        if let challenge { lines.append("Authorization: " + digest(challenge, method: method, uri: target)) }
        lines.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if !body.isEmpty { lines.append("Content-Length: \(body.utf8.count)") }

        let raw = Array((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        guard send(fd, raw, raw.count, 0) == raw.count else { throw rtspError("\(method): send failed") }

        let resp = try readResponse(method)
        debug("[AirPlay] \(method) -> \(resp.status)")
        return resp
    }

    private func digest(_ challenge: String, method: String, uri: String) -> String {
        func field(_ name: String) -> String {
            guard let r = challenge.range(of: "\(name)=\"") else { return "" }
            let rest = challenge[r.upperBound...]
            return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)])
        }
        let realm = field("realm"), nonce = field("nonce"), user = "iTunes"
        let ha1 = md5hex("\(user):\(realm):\(password ?? "")")
        let ha2 = md5hex("\(method):\(uri)")
        let response = md5hex("\(ha1):\(nonce):\(ha2)")
        return "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    private func readResponse(_ method: String) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buf.range(of: separator) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw rtspError("\(method): connection closed or timed out") }
            buf.append(contentsOf: chunk[0 ..< n])
        }

        let split = buf.range(of: separator)!
        var lines = String(decoding: buf[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ").dropFirst().first ?? "") ?? 0

        var headers: [String: String] = [:]
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }

        // Drain the body, we don't use it
        var bodyCount = buf.count - split.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while bodyCount < length {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            bodyCount += n
        }

        return Response(status: status, headers: headers)
    }
}

// MARK: - ALAC

/// Wraps interleaved stereo Int16 PCM in an uncompressed ("escape") ALAC frame.
func alacRawFrame(_ pcm: [Int16]) -> Data {
    var out = [UInt8]()
    out.reserveCapacity(pcm.count * 2 + 16)
    var acc: UInt64 = 0
    var nbits = 0

    func put(_ value: UInt32, _ bits: Int) {
        acc = (acc << UInt64(bits)) | (UInt64(value) & ((UInt64(1) << UInt64(bits)) - 1))
        nbits += bits
        while nbits >= 8 {
            nbits -= 8
            out.append(UInt8((acc >> UInt64(nbits)) & 0xFF))
        }
    }

    put(1, 3) // ID_CPE: stereo channel pair element
    put(0, 4) // element instance tag
    put(0, 12) // unused
    put(1, 1) // hasSize: the sample count follows
    put(0, 2) // bytes shifted
    put(1, 1) // escape flag: samples are stored uncompressed
    put(UInt32(pcm.count / 2), 32)
    for s in pcm {
        put(UInt32(UInt16(bitPattern: s)), 16)
    }
    put(7, 3) // ID_END
    if nbits > 0 {
        out.append(UInt8((acc << UInt64(8 - nbits)) & 0xFF))
    }
    return Data(out)
}

// MARK: - Helpers

private func rtspError(_ debugMessage: String) -> NSError {
    NSError(code: .airPlayConnectError,
            message: NSLocalizedString("Cannot connect to AirPlay device.", comment: "Player error message"),
            debug: "[AirPlay] RTSP: \(debugMessage)")
}

private func md5hex(_ s: String) -> String {
    Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// NTP timestamp: seconds since 1900 in the high 32 bits, fraction in the low 32 bits.
private func ntpNow() -> UInt64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    let sec = UInt64(tv.tv_sec) + 2_208_988_800
    let frac = (UInt64(tv.tv_usec) << 32) / 1_000_000
    return (sec << 32) | frac
}

private extension Data {
    mutating func be16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func be32(_ v: UInt32) { be16(UInt16(v >> 16)); be16(UInt16(v & 0xFFFF)) }
    mutating func be64(_ v: UInt64) { be32(UInt32(v >> 32)); be32(UInt32(v & 0xFFFF_FFFF)) }
}

private func sockaddrIn(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &a.sin_addr)
    return a
}

private func boundPort(_ fd: Int32) -> UInt16 {
    var a = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return UInt16(bigEndian: a.sin_port)
}

private func localAddress(_ fd: Int32) -> String {
    var a = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &a.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

private func udpSocket() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw rtspError("UDP socket() failed: \(String(cString: strerror(errno)))") }
    var tv = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddrIn("0.0.0.0", 0)
    let r = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard r == 0 else {
        let msg = String(cString: strerror(errno))
        Darwin.close(fd)
        throw rtspError("UDP bind failed: \(msg)")
    }
    return fd
}

private func sendUDP(_ fd: Int32, _ data: Data, to addr: sockaddr_in) {
    var a = addr
    _ = data.withUnsafeBytes { buf in
        withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
