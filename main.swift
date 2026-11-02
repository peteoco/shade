import Cocoa
import Carbon
import ServiceManagement
import os

let blog = Logger(subsystem: "com.peteoconnell.shade", category: "display")
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

// MARK: - Private API, looked up at runtime so a macOS change can't crash us

typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let configureEnabled: ConfigureEnabledFn? = {
    let handles = [UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                   dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)]
    for h in handles { if let p = dlsym(h, "CGSConfigureDisplayEnabled") { return unsafeBitCast(p, to: ConfigureEnabledFn.self) } }
    return nil
}()

// MARK: - Display helpers

func displayList(_ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
    var c: UInt32 = 0; _ = get(0, nil, &c)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(c)); _ = get(c, &ids, &c)
    return Array(ids.prefix(Int(c)))
}
func onlineIDs() -> [CGDirectDisplayID] { displayList(CGGetOnlineDisplayList) }
func activeIDs() -> Set<CGDirectDisplayID> { Set(displayList(CGGetActiveDisplayList)) }
func uuid(_ id: CGDirectDisplayID) -> String? {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, u) as String
}

// MARK: - Armed marker: ~/Library/Application Support/Shade/disabled.json
// Exists only while some display is off. If we crash or get SIGKILLed, the next
// launch (or login, via launch at login) sees it and turns everything back on.

struct OffDisplay: Codable { var uuid: String; var lastID: UInt32; var name: String }

enum Marker {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let url: URL = {
        let dir = support.appendingPathComponent("Shade")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("disabled.json")
    }()
    /// Marker left by the app's old name (Blackout 1.0-1.2). Read for recovery, then removed.
    static let legacy = support.appendingPathComponent("Blackout/disabled.json")
    static func read(_ u: URL) -> [OffDisplay] { (try? JSONDecoder().decode([OffDisplay].self, from: Data(contentsOf: u))) ?? [] }
    static func load() -> [OffDisplay] { read(url) }
    static var armed: Bool { !load().isEmpty || !read(legacy).isEmpty }
    static func save(_ l: [OffDisplay]) {
        if l.isEmpty { try? FileManager.default.removeItem(at: url) }
        else if let d = try? JSONEncoder().encode(l) { try? d.write(to: url, options: .atomic) }
    }
}

func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
    guard let fn = configureEnabled else { return false }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
    if fn(cfg, id, on) == .success {
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        blog.notice("display \(id, privacy: .public) \(on ? "on" : "off", privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
        return ok
    }
    CGCancelDisplayConfiguration(cfg); blog.error("display \(id, privacy: .public) \(on ? "on" : "off", privacy: .public) refused"); return false
}

/// Turn every display we know about back on and disarm. Safe to call from anywhere, any time.
func restoreAll() {
    blog.notice("restoring all displays")
    var ids = Set(onlineIDs())
    for o in Marker.load() + Marker.read(Marker.legacy) { ids.insert(o.lastID) }
    let act = activeIDs()
    for id in ids where !act.contains(id) { _ = setEnabled(id, true) }
    Marker.save([])
    try? FileManager.default.removeItem(at: Marker.legacy)
}

/// "v1.10" > "1.9": compares dot-separated numbers, ignoring a leading "v".
func isNewer(_ tag: String, than current: String) -> Bool {
    let n = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
    let a = n(tag), b = n(current)
    for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
    return false
}

// MARK: - Rescue: `Shade --rescue` turns everything on and exits (works over SSH)

if CommandLine.arguments.contains("--rescue") {
    restoreAll()
    print(configureEnabled == nil ? "Shade: display API not found; nothing to do." : "Shade: all displays on.")
    exit(0)
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    var signalSources: [DispatchSourceSignal] = []
    var supported: Bool { configureEnabled != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        blog.notice("Shade \(appVersion, privacy: .public) launched, display API \(configureEnabled == nil ? "missing" : "found", privacy: .public)")
        if Marker.armed { blog.notice("marker found at launch; recovering"); restoreAll() }   // recover from a crash, kill or reboot
        menu.delegate = self
        item.menu = menu
        updateIcon()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(allOn), name: NSWorkspace.didWakeNotification, object: nil)
        registerHotKey()
        installSignalHandlers()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let me = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            // Let the display list settle, then make sure something is still lit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { me.ensureSomethingOn() }
        }, Unmanaged.passUnretained(self).toOpaque())
        checkForUpdate()
        if defaults.object(forKey: "loginSet") == nil { try? SMAppService.mainApp.register(); defaults.set(true, forKey: "loginSet") }
    }

    func applicationWillTerminate(_ n: Notification) { restoreAll() }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // let the dispatch source handle it instead of dying
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { blog.notice("signal \(sig, privacy: .public)"); restoreAll(); exit(0) }
            s.resume(); signalSources.append(s)
        }
    }

    func ensureSomethingOn() {
        if activeIDs().isEmpty { blog.error("no active display after reconfiguration"); restoreAll() }
        updateIcon()
    }

    // MARK: Update check: at most once a day, asks GitHub's public releases API. No server, no auto-install.
    var update: (tag: String, url: URL)?
    func checkForUpdate(force: Bool = false) {
        if defaults.object(forKey: "checkUpdates") == nil { defaults.set(true, forKey: "checkUpdates") }
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard force || (defaults.bool(forKey: "checkUpdates") && Date().timeIntervalSince1970 - last > 86_400) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        let api = URL(string: "https://api.github.com/repos/peteoco/shade/releases/latest")!
        URLSession.shared.dataTask(with: api) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            DispatchQueue.main.async {
                self.update = isNewer(tag, than: appVersion) ? (tag, page) : nil
                blog.notice("update check: latest \(tag, privacy: .public), newer: \(self.update != nil, privacy: .public)")
            }
        }.resume()
    }
    @objc func openUpdate() { if let u = update?.url { NSWorkspace.shared.open(u) } }
    @objc func toggleUpdates() { defaults.set(!defaults.bool(forKey: "checkUpdates"), forKey: "checkUpdates"); checkForUpdate() }

    @objc func about() {
        let credits = NSAttributedString(string: """
            Turn any display off without unplugging it.

            Lost a screen? Press ⌃⌥⌘B, or run
            /Applications/Shade.app/Contents/MacOS/Shade --rescue

            github.com/peteoco/shade · MIT License
            """, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationVersion: appVersion, .version: "", NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Peter O'Connell"])
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.hotToggle() }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: OSType(0x424C4B54), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
    // ⌃⌥⌘B: if anything is off, turn it all back on; otherwise turn off every display except the main one
    @objc func hotToggle() {
        if !Marker.load().isEmpty { allOn(); return }
        guard supported else { return }
        let main = CGMainDisplayID()
        for id in activeIDs() where id != main { set(id, false) }
    }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }

    /// Online displays plus the ones we turned off (disabled displays drop out of the online list).
    func listed() -> [CGDirectDisplayID] {
        var all = onlineIDs()
        for o in Marker.load() where !all.contains(o.lastID) { all.append(o.lastID) }
        return all
    }
    func name(_ id: CGDirectDisplayID) -> String {
        if let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            return s.localizedName
        }
        if let o = Marker.load().first(where: { $0.lastID == id }) { return o.name }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }
    func updateIcon() {
        let img = NSImage(systemSymbolName: Marker.load().isEmpty ? "display" : "display.2", accessibilityDescription: "Shade")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if !supported {
            let u = NSMenuItem(title: "Unsupported on this macOS", action: nil, keyEquivalent: "")
            u.isEnabled = false; m.addItem(u); m.addItem(.separator())
        }
        let act = activeIDs()
        for id in listed() {
            let on = act.contains(id)
            let mi = NSMenuItem(title: name(id), action: #selector(toggle(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(id); mi.state = on ? .on : .off
            if on && (act.count == 1 || !supported) { mi.isEnabled = false; mi.toolTip = supported ? "Last active display" : nil }
            m.addItem(mi)
        }
        m.addItem(.separator())
        let all = NSMenuItem(title: "Turn All On", action: #selector(allOn), keyEquivalent: "")
        all.target = self; m.addItem(all)
        let hk = NSMenuItem(title: "Toggle Other Displays", action: supported ? #selector(hotToggle) : nil, keyEquivalent: "b")
        hk.keyEquivalentModifierMask = [.command, .option, .control]; hk.target = self; hk.isEnabled = supported; m.addItem(hk)
        m.addItem(.separator())
        if let u = update {
            let ui = NSMenuItem(title: "Update Available: \(u.tag)…", action: #selector(openUpdate), keyEquivalent: "")
            ui.target = self; m.addItem(ui)
        }
        let ab = NSMenuItem(title: "About Shade", action: #selector(about), keyEquivalent: "")
        ab.target = self; m.addItem(ab)
        let cu = NSMenuItem(title: "Check for Updates Daily", action: #selector(toggleUpdates), keyEquivalent: "")
        cu.target = self; cu.state = defaults.bool(forKey: "checkUpdates") ? .on : .off; m.addItem(cu)
        let li = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        li.target = self; li.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(li)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Shade", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func set(_ id: CGDirectDisplayID, _ on: Bool) {
        guard let u = uuid(id) else { return }
        var l = Marker.load().filter { $0.uuid != u }
        if !on {
            // Arm before turning off, so a crash mid-change still recovers.
            l.append(OffDisplay(uuid: u, lastID: id, name: name(id)))
            Marker.save(l)
            if !setEnabled(id, false) { Marker.save(l.filter { $0.uuid != u }) }
        } else if setEnabled(id, true) {
            Marker.save(l)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon() }
    }
    @objc func toggle(_ s: NSMenuItem) {
        let id = CGDirectDisplayID(s.tag), act = activeIDs()
        if act.contains(id) { if act.count > 1 && supported { set(id, false) } } else { set(id, true) }
    }
    @objc func allOn() { restoreAll(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon() } }
}

let app = NSApplication.shared
let d = App(); app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
