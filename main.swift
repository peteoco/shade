import Cocoa
import Carbon
import ServiceManagement
import os

let blog = Logger(subsystem: "com.peteoconnell.shade", category: "display")
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let defaults = UserDefaults.standard

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
func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }

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

// MARK: - Display model shared by the panel, hotkeys and CLI

struct Display: Equatable { let id: CGDirectDisplayID; let uuid: String; let name: String; let on: Bool }

func displayName(_ id: CGDirectDisplayID) -> String {
    if let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
        return s.localizedName
    }
    if let o = Marker.load().first(where: { $0.lastID == id }) { return o.name }
    return isBuiltin(id) ? "Built-in Display" : "Display \(id)"
}

/// Online displays plus the ones we turned off, in a stable order (first seen first),
/// so "display 2" means the same screen in the panel, the hotkeys and the CLI.
func displays() -> [Display] {
    // A display that is off may no longer report its UUID, so use the one we saved.
    var pairs = onlineIDs().compactMap { id in uuid(id).map { (id, $0) } }
    for o in Marker.load() where !pairs.contains(where: { $0.1 == o.uuid }) { pairs.append((o.lastID, o.uuid)) }
    let act = activeIDs()
    var order = defaults.stringArray(forKey: "order") ?? []
    var list: [Display] = []
    for (id, u) in pairs {
        if !order.contains(u) { order.append(u) }
        list.append(Display(id: id, uuid: u, name: displayName(id), on: act.contains(id)))
    }
    defaults.set(order, forKey: "order")
    return list.sorted { (order.firstIndex(of: $0.uuid) ?? 0) < (order.firstIndex(of: $1.uuid) ?? 0) }
}

enum TurnResult { case ok, lastDisplay, unsupported, failed }

/// The one place a display is switched. Refuses to turn off the last active display,
/// and arms the marker before anything goes dark.
@discardableResult
func turn(_ d: Display, on: Bool) -> TurnResult {
    guard configureEnabled != nil else { return .unsupported }
    var l = Marker.load().filter { $0.uuid != d.uuid }
    if on {
        guard setEnabled(d.id, true) else { return .failed }
        Marker.save(l); return .ok
    }
    let act = activeIDs()
    guard act.contains(d.id) else { return .ok }
    guard act.count > 1 else { return .lastDisplay }
    l.append(OffDisplay(uuid: d.uuid, lastID: d.id, name: d.name))
    Marker.save(l)
    guard setEnabled(d.id, false) else { Marker.save(l.filter { $0.uuid != d.uuid }); return .failed }
    return .ok
}

/// ⌃⌥⌘B: if anything is off, turn it all back on; otherwise turn off every display except the main one.
func toggleOthers() {
    if Marker.armed { restoreAll(); return }
    let main = CGMainDisplayID()
    for d in displays() where d.on && d.id != main { turn(d, on: false) }
}

/// Auto mode: when an external display appears, turn the built-in display off.
/// Only acts when the set of connected externals changes, so turning the built-in back on by hand sticks.
func applyAutoMode(force: Bool = false) {
    let externals = Set(displays().filter { !isBuiltin($0.id) }.map(\.uuid))
    let previous = Set(defaults.stringArray(forKey: "lastExternals") ?? [])
    defaults.set(Array(externals), forKey: "lastExternals")
    guard defaults.bool(forKey: "autoBuiltinOff"), force || externals != previous, !externals.isEmpty else { return }
    let ds = displays()
    guard ds.contains(where: { !isBuiltin($0.id) && $0.on }), let b = ds.first(where: { isBuiltin($0.id) && $0.on }) else { return }
    blog.notice("auto mode: external connected, turning built-in off")
    turn(b, on: false)
}

/// "v1.10" > "1.9": compares dot-separated numbers, ignoring a leading "v".
func isNewer(_ tag: String, than current: String) -> Bool {
    let n = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
    let a = n(tag), b = n(current)
    for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
    return false
}

// MARK: - Command line: `Shade --rescue`, `Shade list`, `Shade off 2`, ...

let cliUsage = """
    usage: Shade <command>
      list            show displays with their numbers
      on <n|uuid>     turn a display on
      off <n|uuid>    turn a display off (never the last one)
      toggle <n|uuid> switch a display
      others          same as ⌃⌥⌘B
      all-on          turn every display on
      --rescue        turn every display on (same as all-on)
    """

func runCLI(_ args: [String]) -> Int32 {
    let cmd = args.first ?? ""
    if cmd == "--rescue" || cmd == "all-on" {
        restoreAll()
        print(configureEnabled == nil ? "Shade: display API not found; nothing to do." : "Shade: all displays on.")
        return 0
    }
    let ds = displays()
    func find(_ key: String?) -> Display? {
        guard let key else { return nil }
        if let n = Int(key), n >= 1, n <= ds.count { return ds[n - 1] }
        return ds.first { $0.uuid.caseInsensitiveCompare(key) == .orderedSame }
    }
    switch cmd {
    case "list":
        for (i, d) in ds.enumerated() { print("\(i + 1)  \(d.on ? "on " : "off")  \(d.name)\(d.id == CGMainDisplayID() ? " (main)" : "")  \(d.uuid)") }
        return 0
    case "others": toggleOthers(); return 0
    case "on", "off", "toggle":
        guard let d = find(args.dropFirst().first) else { fputs("Shade: no such display. Run `Shade list`.\n", stderr); return 2 }
        switch turn(d, on: cmd == "on" || (cmd == "toggle" && !d.on)) {
        case .ok: return 0
        case .lastDisplay: fputs("Shade: refusing to turn off the last active display.\n", stderr); return 3
        case .unsupported: fputs("Shade: unsupported on this macOS.\n", stderr); return 4
        case .failed: fputs("Shade: macOS refused the change.\n", stderr); return 1
        }
    default: print(cliUsage); return cmd == "help" || cmd == "--help" ? 0 : 2
    }
}

// Launched with arguments (other than the ones macOS adds): act as a CLI and exit.
let cliArgs = Array(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") })
if !cliArgs.isEmpty { exit(runCLI(cliArgs)) }

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    lazy var panel = Panel(app: self)
    var signalSources: [DispatchSourceSignal] = []
    var supported: Bool { configureEnabled != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        blog.notice("Shade \(appVersion, privacy: .public) launched, display API \(configureEnabled == nil ? "missing" : "found", privacy: .public)")
        if Marker.armed { blog.notice("marker found at launch; recovering"); restoreAll() }   // recover from a crash, kill or reboot
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        panel.devHooks()
        updateIcon()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(allOn), name: NSWorkspace.didWakeNotification, object: nil)
        registerHotKeys()
        installSignalHandlers()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            let me = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            guard !flags.contains(.beginConfigurationFlag) else { DispatchQueue.main.async { me.panel.beginReconfigure() }; return }
            // Let the display list settle, then make sure something is still lit.
            me.settle?.cancel()
            let w = DispatchWorkItem { me.displaysChanged() }
            me.settle = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
        }, Unmanaged.passUnretained(self).toOpaque())
        checkForUpdate()
        if defaults.object(forKey: "loginSet") == nil { try? SMAppService.mainApp.register(); defaults.set(true, forKey: "loginSet") }
        applyAutoMode(force: true)
    }
    var settle: DispatchWorkItem?

    func applicationWillTerminate(_ n: Notification) { restoreAll() }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // let the dispatch source handle it instead of dying
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { blog.notice("signal \(sig, privacy: .public)"); restoreAll(); exit(0) }
            s.resume(); signalSources.append(s)
        }
    }

    func displaysChanged() {
        if activeIDs().isEmpty { blog.error("no active display after reconfiguration"); restoreAll() }
        applyAutoMode()
        updateIcon()
        panel.model.refresh()
        panel.endReconfigure()
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
                self.panel.model.refresh()
                blog.notice("update check: latest \(tag, privacy: .public), newer: \(self.update != nil, privacy: .public)")
            }
        }.resume()
    }
    @objc func openUpdate() { if let u = update?.url { NSWorkspace.shared.open(u) } }
    func toggleUpdates() { defaults.set(!defaults.bool(forKey: "checkUpdates"), forKey: "checkUpdates"); checkForUpdate() }

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

    // MARK: Hotkeys: ⌃⌥⌘B toggles other displays, ⌃⌥⌘1…9 toggle display 1…9
    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.hotKey(Int(hk.id)) }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let mods = UInt32(cmdKey | optionKey | controlKey)
        let keys = [kVK_ANSI_B, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in keys.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(k), mods, EventHotKeyID(signature: OSType(0x53484445), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
        }
    }
    func hotTurn(_ d: Display, on: Bool) -> TurnResult { let r = turn(d, on: on); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon() }; return r }
    func hotKey(_ n: Int) {
        if n == 0 { toggleOthers() }
        else if let d = displays().dropFirst(n - 1).first, turn(d, on: !d.on) == .lastDisplay { NSSound.beep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon(); self.panel.model.refresh() }
    }

    @objc func togglePanel() { panel.toggle(item.button) }
    func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }
    func toggleAuto() {
        defaults.set(!defaults.bool(forKey: "autoBuiltinOff"), forKey: "autoBuiltinOff")
        applyAutoMode(force: true); updateIcon()
    }

    func updateIcon() {
        let img = NSImage(systemSymbolName: Marker.armed ? "display.2" : "display", accessibilityDescription: "Shade")
        img?.isTemplate = true
        item.button?.image = img
    }

    @objc func allOn() { restoreAll(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon(); self.panel.model.refresh() } }
}

let app = NSApplication.shared
let d = App(); app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
