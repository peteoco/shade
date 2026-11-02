import Cocoa
import CoreAudio
import IOKit

// MARK: - Monitor volume over DDC/CI (optional, off by default)
// macOS can't change the volume of audio sent to a monitor over DisplayPort or HDMI.
// This module asks the monitor itself to change volume (VCP code 0x62) over DDC/CI,
// using Apple silicon's private IOAVService I2C calls, the way MonitorControl does.
// Nothing here runs until the user turns on "Monitor Volume Keys".

private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private func sym<T>(_ name: String, _: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
}
private let avCreate = sym("IOAVServiceCreateWithService", AVCreate.self)
private let avRead = sym("IOAVServiceReadI2C", AVI2C.self)
private let avWrite = sym("IOAVServiceWriteI2C", AVI2C.self)

/// One external monitor reachable over DDC.
final class DDCMonitor {
    let service: CFTypeRef
    init(_ s: CFTypeRef) { service = s }
    private static let volumeCode: UInt8 = 0x62

    private func write(_ bytes: [UInt8]) -> Bool {
        guard let avWrite else { return false }
        var packet = bytes; packet.append(bytes.reduce(0x6E ^ 0x51, ^))   // DDC checksum
        return packet.withUnsafeMutableBytes { avWrite(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) } == kIOReturnSuccess
    }
    /// (current, max) or nil if the monitor didn't answer or doesn't support volume.
    /// Replies are often empty or shifted on Apple silicon, so every byte of the reply is checked, checksum included.
    func readVolume() -> (Int, Int)? {
        guard let avRead else { return nil }
        for _ in 0..<5 {
            guard write([0x82, 0x01, Self.volumeCode]) else { usleep(20_000); continue }
            usleep(40_000)
            var r = [UInt8](repeating: 0, count: 11)
            let ok = r.withUnsafeMutableBytes { avRead(service, 0x37, 0x51, $0.baseAddress!, 11) } == kIOReturnSuccess
            if ok, r[0] == 0x6E, r[1] == 0x88, r[2] == 0x02, r[3] == 0, r[4] == Self.volumeCode, r[0..<10].reduce(0x50, ^) == r[10] {
                let mx = Int(r[6]) << 8 | Int(r[7]), cur = Int(r[8]) << 8 | Int(r[9])
                if mx > 0, cur <= mx { return (cur, mx) }
            }
            usleep(30_000)
        }
        return nil
    }
    /// Writes, then reads back to confirm the monitor took it. False when it didn't.
    func setVolume(_ v: Int) -> Bool {
        let p: [UInt8] = [0x84, 0x03, Self.volumeCode, UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        guard write(p) else { return false }
        usleep(30_000); _ = write(p)   // some monitors drop the first packet
        usleep(60_000)
        guard let (cur, _) = readVolume() else { return false }
        return cur == v
    }

    /// Every external display service the system exposes (Apple silicon only).
    static func all() -> [DDCMonitor] {
        guard let avCreate else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var found: [DDCMonitor] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = avCreate(kCFAllocatorDefault, s)?.takeRetainedValue() { found.append(DDCMonitor(av)) }
        }
        return found
    }
}

/// True when the Mac is sending sound to a monitor (DisplayPort or HDMI), the case macOS can't control.
func audioGoesToMonitor() -> Bool {
    var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
    var t: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyTransportType
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t) == noErr else { return false }
    return t == kAudioDeviceTransportTypeDisplayPort || t == kAudioDeviceTransportTypeHDMI
}

enum VolumeStatus: Equatable {
    case ok, searching, noMonitor, noReply, writeRefused, notMonitorAudio
    var message: String {
        switch self {
        case .ok: return ""
        case .searching: return "Looking for the monitor…"
        case .noMonitor: return "No external monitor over DDC"
        case .noReply: return "Not supported: the monitor didn't answer (turn on DDC/CI in its menu)"
        case .writeRefused: return "Not supported: the monitor ignored the volume change"
        case .notMonitorAudio: return "Sound isn't going to the monitor. Pick it in Sound settings"
        }
    }
}

final class VolumeController: NSObject {
    private(set) var status: VolumeStatus = .searching
    private var pending: Int?   // the slider sends many values; only the newest one is written
    private let queue = DispatchQueue(label: "shade.ddc")   // DDC is slow; never block the menu or the keys
    private var monitors: [DDCMonitor] = []
    private(set) var level: (cur: Int, max: Int)?
    var onChange: (() -> Void)?
    var hasMonitor: Bool { !monitors.isEmpty }
    private var mutedLevel: Int?
    private var tap: CFMachPort?
    var enabled: Bool { defaults.bool(forKey: "ddcVolume") }
    var available: Bool { avCreate != nil && avWrite != nil }

    func start() { if enabled { refresh(); startTap() } }

    /// Re-find monitors and read the current volume (after display changes, or when the menu opens).
    func refresh() {
        guard enabled, available else { return }
        queue.async {
            let ms = DDCMonitor.all(), lv = ms.first?.readVolume()
            let toMonitor = audioGoesToMonitor()
            DispatchQueue.main.async {
                self.monitors = ms
                if let lv { self.level = (lv.0, lv.1) }
                if ms.isEmpty { self.status = .noMonitor }
                else if lv == nil { self.status = .noReply }
                else if !toMonitor { self.status = .notMonitorAudio }
                else if self.status != .writeRefused { self.status = .ok }
                self.onChange?()
                blog.notice("ddc: \(ms.count, privacy: .public) external monitor(s), volume \(lv.map { "\($0.0)/\($0.1)" } ?? "unreadable", privacy: .public)")
            }
        }
    }

    func set(_ v: Int) {
        guard let m = monitors.first, let lv = level else { return }
        let nv = min(max(v, 0), lv.max)
        level = (nv, lv.max); onChange?()
        let first = pending == nil
        pending = nv
        guard first else { return }
        queue.async {
            var last: Int?; var ok = true
            while true {
                let v: Int? = DispatchQueue.main.sync { let p = self.pending; if p == last { self.pending = nil; return nil }; return p }
                guard let v else { break }
                last = v; ok = m.setVolume(v)
            }
            DispatchQueue.main.async {
                if !ok { self.status = .writeRefused; blog.error("ddc: monitor ignored volume \(last ?? -1, privacy: .public)") }
                else if self.status == .writeRefused { self.status = .ok }
                blog.notice("ddc: volume set \(last ?? -1, privacy: .public): \(ok ? "confirmed" : "not confirmed", privacy: .public)")
                self.onChange?()
            }
        }
    }
    func step(up: Bool) {
        guard let lv = level else { refresh(); return }
        if let m = mutedLevel { mutedLevel = nil; set(m) }
        set(lv.cur + (up ? 1 : -1) * max(1, lv.max / 16))
    }
    func toggleMute() {
        guard let lv = level else { return }
        if let m = mutedLevel { mutedLevel = nil; set(m) } else { mutedLevel = lv.cur; set(0) }
    }

    // MARK: Volume keys (and knobs that send them, like NuPhy's): needs Accessibility permission
    private func startTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            blog.notice("ddc: waiting for Accessibility permission for volume keys"); return
        }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media keys
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<VolumeController>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            guard me.enabled, me.level != nil, me.status == .ok, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let key = (ns.data1 & 0xFFFF0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0xA
            guard [0, 1, 7].contains(key), audioGoesToMonitor() else { return Unmanaged.passUnretained(event) }   // 0 up, 1 down, 7 mute
            if down { DispatchQueue.main.async { key == 7 ? me.toggleMute() : me.step(up: key == 0) } }
            return nil   // swallow: macOS would only show "can't change volume"
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { blog.error("ddc: event tap failed"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        blog.notice("ddc: volume keys active")
    }
    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
    }

    // MARK: Panel
    func toggleEnabled() {
        defaults.set(!enabled, forKey: "ddcVolume")
        if enabled { refresh(); startTap() } else { stopTap(); level = nil }
        onChange?()
    }
    func userSet(_ v: Int) { mutedLevel = nil; set(v) }
    func ensureTap() { if enabled && tap == nil { startTap() } }
}

/// `Shade volume` prints the monitor's volume; `Shade volume 30` sets it. Works whether or not the menu option is on.
func runVolumeCLI(_ value: String?) -> Int32 {
    guard let m = DDCMonitor.all().first else { fputs("Shade: no external monitor reachable over DDC.\n", stderr); return 5 }
    guard let (cur, mx) = m.readVolume() else { fputs("Shade: the monitor didn't report a volume (DDC/CI may be off in its menu).\n", stderr); return 5 }
    guard let value else { print("\(cur)/\(mx)"); return 0 }
    guard let v = Int(value), (0...mx).contains(v) else { fputs("Shade: volume must be 0-\(mx).\n", stderr); return 2 }
    if m.setVolume(v) { return 0 }
    fputs("Shade: the monitor didn't confirm the change.\n", stderr); return 1
}
