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
    func readVolume() -> (Int, Int)? {
        guard let avRead else { return nil }
        for _ in 0..<3 {
            guard write([0x82, 0x01, Self.volumeCode]) else { continue }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 12)
            let ok = r.withUnsafeMutableBytes { avRead(service, 0x37, 0x51, $0.baseAddress!, 12) } == kIOReturnSuccess
            if ok, r[2] == 0x02, r[3] == 0, r[4] == Self.volumeCode {
                let mx = Int(r[6]) << 8 | Int(r[7]), cur = Int(r[8]) << 8 | Int(r[9])
                if mx > 0 { return (cur, mx) }
            }
            usleep(20_000)
        }
        return nil
    }
    func setVolume(_ v: Int) -> Bool { write([0x84, 0x03, Self.volumeCode, UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }

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

final class VolumeController: NSObject {
    private let queue = DispatchQueue(label: "shade.ddc")   // DDC is slow; never block the menu or the keys
    private var monitors: [DDCMonitor] = []
    private var level: (cur: Int, max: Int)?
    private var mutedLevel: Int?
    private var tap: CFMachPort?
    private weak var slider: NSSlider?
    var enabled: Bool { defaults.bool(forKey: "ddcVolume") }
    var available: Bool { avCreate != nil && avWrite != nil }

    func start() { if enabled { refresh(); startTap() } }

    /// Re-find monitors and read the current volume (after display changes, or when the menu opens).
    func refresh() {
        guard enabled, available else { return }
        queue.async {
            let ms = DDCMonitor.all(), lv = ms.first?.readVolume()
            DispatchQueue.main.async {
                self.monitors = ms
                if let lv { self.level = (lv.0, lv.1); self.slider?.maxValue = Double(lv.1); self.slider?.integerValue = lv.0 }
                blog.notice("ddc: \(ms.count, privacy: .public) external monitor(s), volume \(lv.map { "\($0.0)/\($0.1)" } ?? "unreadable", privacy: .public)")
            }
        }
    }

    func set(_ v: Int) {
        guard let m = monitors.first, let lv = level else { return }
        let nv = min(max(v, 0), lv.max)
        level = (nv, lv.max); slider?.integerValue = nv
        queue.async { _ = m.setVolume(nv) }
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
            guard me.enabled, me.level != nil, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
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

    // MARK: Menu
    @objc func toggleEnabled() {
        defaults.set(!enabled, forKey: "ddcVolume")
        if enabled { refresh(); startTap() } else { stopTap(); level = nil }
    }
    @objc func sliderMoved(_ s: NSSlider) { mutedLevel = nil; set(s.integerValue) }

    func addMenuItems(to m: NSMenu) {
        guard available else { return }
        m.addItem(.separator())
        let t = NSMenuItem(title: "Monitor Volume Keys", action: #selector(toggleEnabled), keyEquivalent: "")
        t.target = self; t.state = enabled ? .on : .off
        t.toolTip = "Control an external monitor's own volume over DDC. Needs Accessibility permission for the volume keys."
        m.addItem(t)
        guard enabled else { return }
        if tap == nil { startTap() }
        refresh()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let icon = NSImageView(frame: NSRect(x: 18, y: 6, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Monitor volume")
        let s = NSSlider(value: Double(level?.cur ?? 0), minValue: 0, maxValue: Double(level?.max ?? 100), target: self, action: #selector(sliderMoved(_:)))
        s.frame = NSRect(x: 42, y: 5, width: 160, height: 20); s.isContinuous = true
        s.isEnabled = !monitors.isEmpty || level != nil
        view.addSubview(icon); view.addSubview(s); slider = s
        let si = NSMenuItem(); si.view = view; m.addItem(si)
        if monitors.isEmpty && level == nil {
            let n = NSMenuItem(title: "No DDC monitor found", action: nil, keyEquivalent: ""); n.isEnabled = false; m.addItem(n)
        }
    }
}

/// `Shade volume` prints the monitor's volume; `Shade volume 30` sets it. Works whether or not the menu option is on.
func runVolumeCLI(_ value: String?) -> Int32 {
    guard let m = DDCMonitor.all().first else { fputs("Shade: no external monitor reachable over DDC.\n", stderr); return 5 }
    guard let (cur, mx) = m.readVolume() else { fputs("Shade: the monitor didn't report a volume (DDC/CI may be off in its menu).\n", stderr); return 5 }
    guard let value else { print("\(cur)/\(mx)"); return 0 }
    guard let v = Int(value), (0...mx).contains(v) else { fputs("Shade: volume must be 0-\(mx).\n", stderr); return 2 }
    return m.setVolume(v) ? 0 : 1
}
