import Cocoa
import Carbon
import ServiceManagement

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let names = UserDefaults.standard

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        updateIcon()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(allOn), name: NSWorkspace.didWakeNotification, object: nil)
        registerHotKey()
        if names.object(forKey: "loginSet") == nil { try? SMAppService.mainApp.register(); names.set(true, forKey: "loginSet") }
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
        if !offSet().isEmpty { allOn(); return }
        let main = CGMainDisplayID()
        for id in active() where id != main { set(id, false) }
    }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    }

    func online() -> [CGDirectDisplayID] {
        var c: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &c)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(c)); CGGetOnlineDisplayList(c, &ids, &c)
        var all = ids
        for o in offSet() where !all.contains(o) { all.append(o) }
        return all
    }
    func active() -> Set<CGDirectDisplayID> {
        var c: UInt32 = 0; CGGetActiveDisplayList(0, nil, &c)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(c)); CGGetActiveDisplayList(c, &ids, &c)
        return Set(ids)
    }
    func offSet() -> [CGDirectDisplayID] { (names.array(forKey: "off") as? [Int] ?? []).map { CGDirectDisplayID($0) } }
    func setOff(_ id: CGDirectDisplayID, _ off: Bool) {
        var l = Set(offSet()); if off { l.insert(id) } else { l.remove(id) }
        names.set(l.map { Int($0) }, forKey: "off")
    }
    func name(_ id: CGDirectDisplayID) -> String {
        if let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            names.set(s.localizedName, forKey: "name-\(id)"); return s.localizedName
        }
        return names.string(forKey: "name-\(id)") ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
    }
    func updateIcon() {
        let off = offSet().count
        let img = NSImage(systemSymbolName: off > 0 ? "display.2" : "display", accessibilityDescription: "Blackout")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let act = active()
        for id in online() {
            let on = act.contains(id)
            let mi = NSMenuItem(title: name(id), action: #selector(toggle(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(id); mi.state = on ? .on : .off
            if on && act.count == 1 { mi.isEnabled = false; mi.toolTip = "Last active display" }
            m.addItem(mi)
        }
        m.addItem(.separator())
        let all = NSMenuItem(title: "Turn All On", action: #selector(allOn), keyEquivalent: "")
        all.target = self; m.addItem(all)
        let hk = NSMenuItem(title: "Toggle Other Displays", action: #selector(hotToggle), keyEquivalent: "b")
        hk.keyEquivalentModifierMask = [.command, .option, .control]; hk.target = self; m.addItem(hk)
        m.addItem(.separator())
        let li = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        li.target = self; li.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(li)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Blackout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func set(_ id: CGDirectDisplayID, _ on: Bool) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        if CGSConfigureDisplayEnabled(cfg, id, on) == .success { CGCompleteDisplayConfiguration(cfg, .permanently); setOff(id, !on) }
        else { CGCancelDisplayConfiguration(cfg) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon() }
    }
    @objc func toggle(_ s: NSMenuItem) {
        let id = CGDirectDisplayID(s.tag), act = active()
        if act.contains(id) { if act.count > 1 { set(id, false) } } else { set(id, true) }
    }
    @objc func allOn() { for id in online() where !active().contains(id) { set(id, true) }; names.set([Int](), forKey: "off"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateIcon() } }
}

let app = NSApplication.shared
let d = App(); app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
