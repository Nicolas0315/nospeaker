// trackpad-sounds: a tiny local server that lets a web page drive the MacBook trackpad's haptic motor as a speaker.
//
//   browser page  --WebSocket (localhost only)-->  this helper  --MultitouchSupport-->  haptic motor
//
// The motor part follows the approach of os6/nospeaker (private MultitouchSupport framework, resolved at run time).
// Safari/Chrome have no API for this, so the page needs this helper; it serves the page itself so everything is
// same-origin on http://localhost:PORT.

import Foundation
import Network
import CryptoKit
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// MARK: - Options

var port: UInt16 = 8765
var webDir = (Bundle.main.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ".") + "/web"
var openBrowser = false
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--port": if let v = it.next(), let p = UInt16(v) { port = p }
        case "--web": if let v = it.next() { webDir = v }
        case "--open": openBrowser = true
        case "-h", "--help":
            print("usage: trackpad-sounds [--port 8765] [--web DIR] [--open]")
            exit(0)
        default: break
        }
    }
}

// MARK: - The haptic motor (MultitouchSupport, private, resolved at run time)

let mtLib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mtLib, let p = dlsym(mtLib, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

let createList = sym("MTDeviceCreateList", CreateList.self)
let getID = sym("MTDeviceGetDeviceID", GetID.self)
let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

var deviceList: CFArray?   // keep alive: the actuator refers to these devices
var motorRef: CFTypeRef?
var motorPtr: UnsafeMutableRawPointer?
var motorInfo = ""

/// Opens the haptic motor of the built-in trackpad (or a Magic Trackpad). Returns false, with `motorInfo` saying why.
func openMotor() -> Bool {
    guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil else {
        motorInfo = "この macOS には必要なトラックパッド関数がありません"
        return false
    }
    guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
        motorInfo = "トラックパッドが見つかりません"
        return false
    }
    deviceList = list
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
            motorRef = ref
            motorPtr = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
            motorInfo = d.builtIn ? "内蔵トラックパッド" : "外付けトラックパッド"
            return true
        }
    }
    motorInfo = "トラックパッドは見つかりましたが、触覚モーター(Force Touch)がありません"
    return false
}

/// One actuation: sine tones (Hz, relative strength) played together for `ms`, at overall `level` (0…1).
/// Strengths are normalised to sum to 1; going past that is louder but makes the driver stall.
func playBurst(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) {
    guard let motorPtr, !tones.isEmpty else { return }
    let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
    let shape: [String: Any] = [
        "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
        "Tones": tones.map { ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000] },
    ]
    guard let act = actuationCreate!(shape as CFDictionary, 0) else { return }
    _ = actuationPlay!(act, motorPtr, 0, min(1, max(0, level)), 0)
    Unmanaged<AnyObject>.fromOpaque(act).release()
}

// MARK: - Sustained synth: the page sets "what should sound now"; a thread keeps the motor fed

final class Synth {
    private let lock = NSLock()
    private var tones: [(hz: Double, amp: Double)] = []
    private var level: Float = 0
    private var updated = 0.0

    func set(_ t: [(hz: Double, amp: Double)], level l: Float) {
        lock.lock(); defer { lock.unlock() }
        tones = t; level = l; updated = now()
    }
    func keep() { lock.lock(); updated = now(); lock.unlock() }
    func stop() { lock.lock(); tones = []; level = 0; lock.unlock() }
    func snapshot() -> (tones: [(hz: Double, amp: Double)], level: Float, updated: Double) {
        lock.lock(); defer { lock.unlock() }
        return (tones, level, updated)
    }
}
let synth = Synth()

/// Feeds the motor in segments of whole periods of the lead tone (so segment joins don't click), paced on the clock.
func synthLoop() {
    var start = 0.0, t = 0.0, running = false
    while true {
        let s = synth.snapshot()
        // Dead-man switch: if the page stops talking for 1.5 s (closed tab, crash), fall silent.
        let active = !s.tones.isEmpty && s.level > 0.001 && now() - s.updated < 1.5
        if !active { running = false; usleep(2000); continue }
        if !running { running = true; start = now(); t = 0 }
        let f = s.tones[0].hz
        let seg = max(1, (0.025 * f).rounded()) / f
        playBurst(s.tones, ms: seg * 1000, level: s.level)
        t += seg
        let wait = start + t - now() - 0.002
        if wait > 0 { usleep(UInt32(wait * 1e6)) } else if wait < -0.05 { start = now(); t = 0 }
    }
}

// MARK: - Tiny HTTP + WebSocket server (localhost only)

let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
let allowedHosts: Set<String> = ["localhost:\(port)", "127.0.0.1:\(port)"]
let allowedOrigins: Set<String> = ["http://localhost:\(port)", "http://127.0.0.1:\(port)"]
let netQueue = DispatchQueue(label: "net")
var clients: [ObjectIdentifier: Client] = [:]
var motorOK = false

final class Client {
    let conn: NWConnection
    var buf: [UInt8] = []
    var upgraded = false
    var closed = false

    init(_ c: NWConnection) { conn = c }

    func start() {
        conn.start(queue: netQueue)
        read()
    }

    func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, err in
            if let data { buf.append(contentsOf: data); upgraded ? parseFrames() : parseHTTP() }
            if done || err != nil { close(); return }
            if !closed { read() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if upgraded { synth.stop() }
        conn.cancel()
        clients.removeValue(forKey: ObjectIdentifier(self))
    }

    func send(_ bytes: [UInt8], thenClose: Bool = false) {
        conn.send(content: Data(bytes), contentContext: thenClose ? .finalMessage : .defaultMessage, isComplete: thenClose,
                  completion: .contentProcessed { [self] _ in if thenClose { close() } })
    }

    func respond(_ status: String, type: String = "text/plain; charset=utf-8", body: [UInt8]) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        send(Array(head.utf8) + body, thenClose: true)
    }

    // MARK: HTTP

    func parseHTTP() {
        guard let end = findHeaderEnd() else { if buf.count > 16384 { close() }; return }
        let text = String(decoding: buf[0..<end], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let reqLine = lines.removeFirst().split(separator: " ")
        var h: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard reqLine.count >= 2, reqLine[0] == "GET" else { return respond("405 Method Not Allowed", body: Array("GET only".utf8)) }
        // Anti DNS-rebinding: only our own host names.
        guard let host = h["host"], allowedHosts.contains(host) else { return respond("403 Forbidden", body: Array("bad host".utf8)) }
        let path = String(reqLine[1].split(separator: "?").first ?? "/")

        if path == "/ws", h["upgrade"]?.lowercased() == "websocket", let key = h["sec-websocket-key"] {
            // Anti cross-site: another website must not be able to drive your trackpad.
            guard let origin = h["origin"], allowedOrigins.contains(origin) else { return respond("403 Forbidden", body: Array("bad origin".utf8)) }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + wsGUID).utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            upgraded = true
            buf.removeSubrange(0..<end + 4)
            send(Array(resp.utf8))
            sendText("{\"t\":\"hello\",\"motor\":\(motorOK),\"info\":\"\(motorInfo)\"}")
            return
        }
        if path == "/" || path == "/index.html" {
            if let d = FileManager.default.contents(atPath: webDir + "/index.html") {
                return respond("200 OK", type: "text/html; charset=utf-8", body: [UInt8](d))
            }
            return respond("404 Not Found", body: Array("web/index.html not found in \(webDir)".utf8))
        }
        respond("404 Not Found", body: Array("not found".utf8))
    }

    func findHeaderEnd() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 { return i }
        return nil
    }

    // MARK: WebSocket

    func sendText(_ s: String) {
        let p = Array(s.utf8)
        var f: [UInt8] = [0x81]
        if p.count < 126 { f.append(UInt8(p.count)) }
        else { f.append(126); f.append(UInt8(p.count >> 8)); f.append(UInt8(p.count & 0xff)) }
        send(f + p)
    }

    func parseFrames() {
        while !closed {
            guard buf.count >= 2 else { return }
            let opcode = buf[0] & 0x0f
            let masked = buf[1] & 0x80 != 0
            var len = Int(buf[1] & 0x7f)
            var off = 2
            if len == 126 {
                guard buf.count >= 4 else { return }
                len = Int(buf[2]) << 8 | Int(buf[3]); off = 4
            } else if len == 127 {
                close(); return   // we never expect huge frames
            }
            guard masked else { close(); return }
            guard buf.count >= off + 4 + len else { return }
            let mask = Array(buf[off..<off + 4])
            var payload = Array(buf[off + 4..<off + 4 + len])
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            buf.removeFirst(off + 4 + len)
            switch opcode {
            case 1: handle(payload)
            case 8: close(); return
            case 9: send([0x8a, UInt8(min(payload.count, 125))] + payload.prefix(125))
            default: break
            }
        }
    }

    func handle(_ payload: [UInt8]) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any], let type = obj["t"] as? String else { return }
        switch type {
        case "tones":
            let level = Float((obj["level"] as? Double) ?? 1)
            var tones: [(hz: Double, amp: Double)] = []
            for t in (obj["tones"] as? [[String: Any]] ?? []).prefix(3) {
                guard let hz = t["hz"] as? Double else { continue }
                tones.append((min(4500, max(60, hz)), max(0.01, (t["amp"] as? Double) ?? 1)))
            }
            tones.isEmpty ? synth.stop() : synth.set(tones, level: level)
        case "keep": synth.keep()
        case "stop": synth.stop()
        default: break
        }
    }
}

// MARK: - Main

motorOK = openMotor()
print(motorOK ? "motor: \(motorInfo)" : "motor: unavailable (\(motorInfo)) — the page will fall back to browser audio")
if motorOK { Thread.detachNewThread(synthLoop) }

let params = NWParameters.tcp
params.requiredInterfaceType = .loopback
params.allowLocalEndpointReuse = true
guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
    print("cannot listen on port \(port)"); exit(1)
}
listener.stateUpdateHandler = { state in
    if case .failed(let e) = state { print("listener failed: \(e) (port \(port) in use?)"); exit(1) }
    if case .ready = state { print("open  http://localhost:\(port)   (Ctrl-C to quit)") }
}
listener.newConnectionHandler = { c in
    let cl = Client(c)
    clients[ObjectIdentifier(cl)] = cl
    cl.start()
}
listener.start(queue: netQueue)
if openBrowser {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["http://localhost:\(port)"]
    try? p.run()
}
signal(SIGINT) { _ in exit(0) }
dispatchMain()
