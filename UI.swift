import SwiftUI
import ServiceManagement

// MARK: - The menu bar panel: one card per display, Turn All On, volume, settings.

let spring = Animation.spring(response: 0.2, dampingFraction: 0.9)

final class PanelModel: ObservableObject {
    unowned let app: App
    @Published var list: [Display] = []
    @Published var volume: Double = 0
    @Published var volumeMax: Double = 100
    @Published var settingsOpen = defaults.bool(forKey: "settingsOpen") { didSet { defaults.set(settingsOpen, forKey: "settingsOpen") } }
    init(app: App) { self.app = app }

    /// Publishes only what changed, so an unchanged refresh costs SwiftUI nothing.
    func refresh() {
        let l = displays()
        if l != list { withAnimation(spring) { list = l } }
        if let lv = app.volume.level, Double(lv.cur) != volume || Double(lv.max) != volumeMax { volume = Double(lv.cur); volumeMax = Double(lv.max) }
        objectWillChange.send()
    }
    var supported: Bool { app.supported }
    var onCount: Int { list.filter(\.on).count }
    func canTurnOff(_ d: Display) -> Bool { supported && !(d.on && onCount == 1) }

    func set(_ d: Display, on: Bool) {
        guard on || canTurnOff(d) else { NSSound.beep(); return }
        app.panel.beginReconfigure()   // keep the panel open while the screens rearrange
        // Show it now (the switch and curtain animate), then do the slow reconfiguration on the next turn of the run loop.
        withAnimation(spring) { list = list.map { $0.uuid == d.uuid ? Display(id: d.id, uuid: d.uuid, name: d.name, on: on) : $0 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if self.app.hotTurn(d, on: on) == .lastDisplay { NSSound.beep() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }
    func allOn() { app.allOn(); refresh() }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Displays").font(.headline)
                Spacer()
                Text(m.supported ? "\(m.onCount) of \(m.list.count) on" : "Unsupported on this macOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(Array(m.list.enumerated()), id: \.element.uuid) { i, d in DisplayCard(m: m, d: d, n: i + 1) }
            }
            Button(action: m.allOn) {
                Label("Turn All On", systemImage: "sun.max.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .help("Every display back on. Also ⌃⌥⌘B, or Shade --rescue")

            if m.app.volume.available && m.app.volume.enabled { VolumeRow(m: m) }

            Divider().padding(.top, 2)
            // One button for the whole row: arrow and label run the same single animation.
            Button { withAnimation(spring) { m.settingsOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(m.settingsOpen ? 90 : 0))
                    Text("Settings").font(.subheadline.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if m.settingsOpen { SettingsView(m: m).padding(.top, 2).transition(.opacity) }
            HStack(spacing: 14) {
                Button("About Shade") { m.app.panel.close(); m.app.about() }
                if let u = m.app.update { Button("Update \(u.tag)") { m.app.openUpdate() }.foregroundStyle(Color.accentColor) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DisplayCard: View {
    @ObservedObject var m: PanelModel
    let d: Display, n: Int
    var last: Bool { d.on && m.onCount == 1 }

    var body: some View {
        HStack(spacing: 10) {
            Thumb(on: d.on, builtin: isBuiltin(d.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { d.on }, set: { m.set(d, on: $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!m.canTurnOff(d))
                .help(last ? "Shade never turns off the last display that's on" : d.on ? "Turn off \(d.name)" : "Turn on \(d.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(d.on ? 0.06 : 0.03)))
    }
    var subtitle: String {
        if last { return "Last screen on, stays on" }
        let key = n <= 9 ? "⌃⌥⌘\(n)" : ""
        if !d.on { return ["Off", key].filter { !$0.isEmpty }.joined(separator: " · ") }
        return [CGDisplayIsMain(d.id) != 0 ? "Main" : "On", key].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The app icon in miniature: dark tile, white screen, grey curtain that drops when the display is off.
struct Thumb: View {
    let on: Bool, builtin: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.13))
            VStack(spacing: 1.5) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white)
                    HStack(spacing: 1) { ForEach(0..<4, id: \.self) { _ in Capsule().fill(Color(white: 0.58)) } }
                        .padding(.horizontal, 1.5).frame(height: on ? 2.5 : 15.5)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
                .frame(width: builtin ? 24 : 26, height: 17)
                if builtin {
                    RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 32, height: 2.5)
                } else {
                    Rectangle().fill(.white).frame(width: 4, height: 3)
                    RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 13, height: 2)
                }
            }
        }
        .frame(width: 44, height: 34)
        .animation(spring, value: on)
    }
}

struct VolumeRow: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: m.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 18)
            Slider(value: Binding(get: { m.volume }, set: { m.volume = $0; m.app.volume.userSet(Int($0)) }), in: 0...max(m.volumeMax, 1))
                .controlSize(.small).disabled(!m.app.volume.hasMonitor)
            Text(m.app.volume.hasMonitor ? "\(Int(m.volume))" : "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
        }
        .help("Your monitor's own speakers, over DDC")
    }
}

struct SettingsView: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Launch at login", SMAppService.mainApp.status == .enabled) { m.app.toggleLogin() }
            row("Built-in off when an external connects", defaults.bool(forKey: "autoBuiltinOff")) { m.app.toggleAuto() }
                .disabled(!m.supported)
            if m.app.volume.available {
                row("Monitor volume keys", m.app.volume.enabled) { m.app.volume.toggleEnabled() }
                    .help("Control an external monitor's own volume over DDC. Volume keys need Accessibility permission.")
            }
            row("Check for updates daily", defaults.bool(forKey: "checkUpdates")) { m.app.toggleUpdates() }
            HStack {
                Text("Hotkeys")
                Spacer()
                Text("⌃⌥⌘B others  ·  ⌃⌥⌘1–9 one").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
    func row(_ t: String, _ on: Bool, _ flip: @escaping () -> Void) -> some View {
        HStack {
            Text(t).font(.caption)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in flip(); m.refresh() })).labelsHidden()
                .toggleStyle(.switch).controlSize(.mini)
        }
    }
}

final class Panel: NSObject {
    let model: PanelModel
    let popover = NSPopover()
    init(app: App) {
        model = PanelModel(app: app)
        super.init()
        let host = NSHostingController(rootView: PanelView(m: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // .transient closes the panel whenever the screens reconfigure. We close it ourselves on an outside click or Esc.
        popover.behavior = .applicationDefined
        popover.animates = true
    }
    var monitors: [Any] = []
    var wantOpen = false          // the user has the panel open; survives a reconfiguration
    var reconfiguring = false
    var reconfigureEnd: DispatchWorkItem?

    func toggle(_ b: NSStatusBarButton?) {
        if popover.isShown { close(); return }
        show(b, animated: true)
    }
    func show(_ b: NSStatusBarButton?, animated: Bool) {
        guard let b, b.window != nil else { return }
        wantOpen = true
        model.app.volume.ensureTap(); model.app.volume.refresh()   // DDC is read off the main thread
        NSApp.activate(ignoringOtherApps: true)
        popover.animates = animated
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.animates = true
        DispatchQueue.main.async { self.model.refresh() }   // show the cached list now, confirm it right after
        installMonitors()
    }
    func close() {
        wantOpen = false
        removeMonitors()
        popover.performClose(nil)
    }
    func installMonitors() {
        guard monitors.isEmpty else { return }
        let outside: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: outside, handler: { [weak self] _ in
            guard let self, !self.reconfiguring else { return }
            self.close()
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53, let self, self.popover.isShown { self.close(); return nil }   // Esc
            return e
        }) { monitors.append(l) }
    }
    func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors = [] }

    /// Called when a toggle starts and when macOS begins a display reconfiguration.
    func beginReconfigure() {
        reconfiguring = true
        reconfigureEnd?.cancel()
        let w = DispatchWorkItem { self.reconfiguring = false }   // failsafe if no change ever arrives
        reconfigureEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }
    /// The screens have settled: put the panel back under the status item, which may now be on another screen's menu bar.
    func endReconfigure() {
        reconfigureEnd?.cancel()
        if wantOpen {
            let b = model.app.item.button
            if popover.isShown { popover.animates = false; popover.close() }
            show(b, animated: false)
            blog.notice("panel re-anchored after reconfiguration on screen \(b?.window?.screen?.localizedName ?? "?", privacy: .public)")
        }
        let w = DispatchWorkItem { self.reconfiguring = false }   // swallow the late clicks macOS synthesizes
        reconfigureEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// For README screenshots only: SHADE_APPEARANCE=light|dark, SHADE_OPEN_PANEL=1.
    func devHooks() {
        let env = ProcessInfo.processInfo.environment
        if let a = env["SHADE_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua); popover.appearance = NSApp.appearance }
        if let o = env["SHADE_SETTINGS_OPEN"] { model.settingsOpen = o == "1" }
        if env["SHADE_OPEN_PANEL"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toggle(self.model.app.item.button) } }
        if let path = env["SHADE_SNAPSHOT"] { DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SHADE_SNAPSHOT_DELAY"] ?? "") ?? 3)) { self.snapshot(to: path) } }
    }
    /// Draws only Shade's own popover into a PNG, so no screen-recording permission and nothing else on screen.
    func snapshot(to path: String) {
        guard let v = popover.contentViewController?.view.window?.contentView?.superview ?? popover.contentViewController?.view,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
