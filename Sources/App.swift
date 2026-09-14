import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

@main
struct Murmur {
    /// NSApplication.delegate is weak. Held here so ARC cannot free it the
    /// instant it is assigned, which would silently skip every launch callback.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)      // menu bar only, no Dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let state = AppState()
    private lazy var hud = HUDController(state: state)
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()

    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var watchdog: Timer?
    private var bag = Set<AnyCancellable>()
    private var recordingStart: Date?

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        Diag.log("launch: ax=\(Permissions.accessibility) whisper=\(Paths.whisper ?? "nil") model=\(Paths.modelExists)")
        buildStatusItem()
        wireHotkey()

        state.onPauseToggle = { [weak self] in self?.togglePause() }
        state.onStop        = { [weak self] in self?.finishRecording() }
        state.onCancel      = { [weak self] in self?.cancel() }

        recorder.onLevel = { [weak self] v in
            guard let self else { return }
            self.state.level = self.state.level * 0.55 + v * 0.45
            self.state.pushLevel(v)
        }

        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] p in
                guard let self else { return }
                self.refreshStatusIcon()
                if case .recording(true, _) = p { self.hud.setInteractive(true) }
                else { self.hud.setInteractive(false) }
            }
            .store(in: &bag)

        // A tap that gets disabled by the system must be revived, or the app goes quietly deaf.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.hotkey.reenableIfNeeded()
        }

        Recorder.requestMic { ok in Diag.log("mic granted=\(ok)") }
        let armed = startHotkeyIfPermitted()
        Diag.log("hotkey armed=\(armed) statusButton=\(self.statusItem?.button != nil)")
        if !armed { presentFirstRun() }
    }

    func applicationWillTerminate(_ note: Notification) {
        recorder.discard()
        hotkey.stop()
    }

    // MARK: Permissions

    @discardableResult
    private func startHotkeyIfPermitted() -> Bool {
        guard Permissions.accessibility else { return false }
        return hotkey.start()
    }

    /// Non-blocking. A modal alert from a menu-bar app freezes the main thread, which
    /// also stops the status item from drawing, so the onboarding runs entirely through
    /// the HUD, the menu, and a poll that arms the hotkey the moment the switch flips.
    private func presentFirstRun() {
        Diag.log("not armed; opening Accessibility settings")
        rebuildMenu()
        flash(.failed("Turn Murmur on in Accessibility"), for: 4.5)
        Permissions.requestAccessibility()          // puts the app in the list
        Permissions.openAccessibilitySettings()
        pollForPermission()
    }

    /// Granting Accessibility does not notify us, so poll briefly after sending them to Settings.
    private func pollForPermission() {
        var tries = 0
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            tries += 1
            if self.startHotkeyIfPermitted() {
                t.invalidate()
                if let w = NSApp.modalWindow { NSApp.abortModal(); w.orderOut(nil) }
                self.rebuildMenu()
                self.flash(.warning("Hotkey armed"), for: 1.4)
            } else if tries > 40 {
                t.invalidate()
            }
        }
        // .common so it keeps firing while the permission alert is modal.
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Hotkey wiring

    private func wireHotkey() {
        hotkey.onPressStart = { [weak self] in
            guard let self else { return }
            // A second chord while locked ends the run rather than starting a new one.
            if self.state.isLocked { self.finishRecording() } else { self.beginRecording(locked: false) }
        }
        hotkey.onDoubleTap  = { [weak self] in self?.lockRecording() }
        hotkey.onPressEnd   = { [weak self] in self?.releaseKey() }
        // Typing no longer ends a locked run; that made hands-free dictation
        // fragile. The bubble's Stop button, the chord, or Escape end it.
        hotkey.onForeignKey = { }
        hotkey.onEscape     = { [weak self] in self?.cancel() }
        hotkey.onCycleLang  = { [weak self] in
            guard let self else { return }
            self.state.cycleLang()
            self.refreshStatusIcon()
            if !self.state.isBusy { self.flash(.warning("Language: \(self.state.lang.long)"), for: 1.3) }
        }
    }

    // MARK: Recording lifecycle

    private func beginRecording(locked: Bool) {
        guard !state.isBusy else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            return fail(VoiceError.micDenied)
        }
        do {
            try recorder.start()
        } catch {
            return fail(error)
        }

        recordingStart = Date()
        state.level = 0
        state.elapsed = 0
        state.phase = .recording(locked: locked, paused: false)
        hud.show()
        Sound.start()

        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.recordingStart != nil else { return }
            self.state.elapsed = self.recorder.duration
            if self.state.elapsed >= Limits.maxRecordSeconds {
                self.finishRecording()
            }
        }
    }

    private func lockRecording() {
        switch state.phase {
        case .recording(_, let paused):
            state.phase = .recording(locked: true, paused: paused)
            hud.setInteractive(true)
            hud.show()
            Sound.tick()
        case .transcribing:
            break
        default:
            // idle, or the too-short flash the first tap of a double-tap just
            // caused. Treating that flash as idle is what makes a fast
            // double-tap actually lock instead of dying in the warning state.
            beginRecording(locked: true)
        }
    }

    private func releaseKey() {
        guard case .recording(let locked, _) = state.phase else { return }
        if locked { return }               // locked runs until Stop, ⌃⌥/ again, or Escape
        finishRecording()
    }

    /// Pressing the chord again during a locked run ends it, so the keyboard
    /// still works for anyone who does not want to reach for the bubble.
    private func stopIfLocked() {
        if case .recording(true, _) = state.phase { finishRecording() }
    }

    private func togglePause() {
        guard case .recording(let locked, let paused) = state.phase else { return }
        if paused { recorder.resume() } else { recorder.pause() }
        state.phase = .recording(locked: locked, paused: !paused)
        Sound.tick()
        hud.show()
    }

    private func cancel() {
        guard state.isBusy else { return }
        hud.setInteractive(false)
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        recorder.discard()
        Sound.stop()
        flash(.warning("Cancelled"), for: 1.2)
    }

    private func finishRecording() {
        guard case .recording = state.phase else { return }
        if recorder.isPaused { recorder.resume() }      // flush the graph before closing
        ticker?.invalidate(); ticker = nil
        recordingStart = nil

        let heardSound = recorder.sawSound
        let (url, secs) = recorder.stop()
        Sound.stop()

        guard let url else { return fail(VoiceError.engineFailed("no audio captured")) }

        // Guard rails before spending 3 seconds on whisper.
        if secs < Limits.minRecordSeconds {
            try? FileManager.default.removeItem(at: url)
            return flash(.warning("Too short, ignored"), for: 1.3)
        }
        if !heardSound {
            try? FileManager.default.removeItem(at: url)
            return flash(.warning("Nothing heard"), for: 1.6)
        }

        state.phase = .transcribing
        hud.show()

        Transcriber.run(wav: url, lang: state.lang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                let pasted = Inserter.deliver(text)
                Prefs.totalWords += text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                self.state.phase = .done(text: text, pasted: pasted)
                Sound.ok()
                self.hud.show()
                self.hud.hide(after: 2.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if case .done = self.state.phase { self.state.phase = .idle }
                }
            case .failure(let err):
                self.fail(err)
            }
        }
    }

    // MARK: Feedback helpers

    private func fail(_ error: Error) {
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        let ve = error as? VoiceError
        let msg = ve?.errorDescription ?? error.localizedDescription
        state.phase = .failed(msg)
        Sound.fail()
        hud.show()
        hud.hide(after: 3.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) {
            if case .failed = self.state.phase { self.state.phase = .idle }
        }
        if case .micDenied = ve { Permissions.openMicrophoneSettings() }
    }

    private func flash(_ phase: Phase, for seconds: TimeInterval) {
        state.phase = phase
        hud.show()
        hud.hide(after: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.3) {
            if self.state.phase == phase { self.state.phase = .idle }
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.behavior = []            // never let the user accidentally drag it away
        refreshStatusIcon()
        rebuildMenu()
        NSLog("[murmur] status item built; button=%@ visible=%d",
              statusItem.button == nil ? "nil" : "ok", statusItem.isVisible ? 1 : 0)
    }

    /// The brand glyph, template-rendered so it follows the menu bar in light and dark.
    /// State is carried by tint, falling back to an SF Symbol if the asset is ever missing.
    private static let glyph: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuGlyph", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 22, height: 11)      // points, not pixels
        img.isTemplate = true
        return img
    }()

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }

        var tint: NSColor? = nil
        switch state.phase {
        case .recording:    tint = NSColor(srgbRed: 0.851, green: 0.447, blue: 0.306, alpha: 1)  // Ember
        case .transcribing: tint = NSColor(srgbRed: 0.486, green: 0.455, blue: 0.502, alpha: 1)  // Stone
        case .done:         tint = NSColor.systemGreen
        case .failed:       tint = NSColor.systemRed
        default:            tint = nil                                                           // follows the bar
        }

        if let g = AppDelegate.glyph {
            button.image = g
        } else {
            let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
            img?.isTemplate = true
            button.image = img
        }
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = tint
        button.toolTip = "Murmur · \(state.lang.long)\nHold ⌃⌥/ to dictate"
        rebuildMenu()
    }

    private func item(_ title: String, symbol: String? = nil, action: Selector? = nil,
                      key: String = "", checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = action == nil ? nil : self
        it.isEnabled = enabled
        it.state = checked ? .on : .off
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            it.image = img
        }
        return it
    }

    private func rebuildMenu() {
        let m = NSMenu()
        m.autoenablesItems = false

        // Header: name in bold with the live state under it.
        let ready = hotkey.running
        let head = NSMenuItem()
        head.isEnabled = false
        let title = NSMutableAttributedString(
            string: "Murmur\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        title.append(NSAttributedString(
            string: ready ? "Ready · hold ⌃⌥/ to dictate" : "Not armed — grant Accessibility",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        head.attributedTitle = title
        m.addItem(head)
        if !ready {
            m.addItem(item("Open Accessibility Settings…", symbol: "lock.open",
                           action: #selector(fixPermissions)))
        }
        m.addItem(.separator())

        // Language, as a submenu with the cycle hint where the eye lands.
        let langItem = item("Language — \(state.lang.label)", symbol: "globe")
        langItem.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        for l in Lang.allCases {
            let it = item(l.long, action: #selector(pickLang(_:)), checked: l == state.lang)
            it.representedObject = l.rawValue
            sub.addItem(it)
        }
        sub.addItem(.separator())
        sub.addItem(item("⌃⌥.  cycles from anywhere", enabled: false))
        langItem.submenu = sub
        m.addItem(langItem)
        m.addItem(.separator())

        m.addItem(item("Paste into the focused field", symbol: "cursorarrow.and.square.on.square.dashed",
                       action: #selector(togglePaste), checked: Prefs.autoPaste))
        m.addItem(item("Sound cues", symbol: "speaker.wave.2",
                       action: #selector(toggleSounds), checked: Prefs.sounds))
        m.addItem(item("Start at login", symbol: "power",
                       action: #selector(toggleLogin), checked: loginEnabled))
        m.addItem(.separator())

        if Prefs.totalWords > 0 {
            m.addItem(item("\(Prefs.totalWords.formatted()) words dictated",
                           symbol: "text.word.spacing", enabled: false))
        }
        if Paths.whisper == nil {
            m.addItem(item("whisper-cli not found — brew install whisper-cpp",
                           symbol: "exclamationmark.triangle", enabled: false))
        }
        if !Paths.modelExists {
            m.addItem(item("Model missing from ~/.local/share/whisper-models",
                           symbol: "exclamationmark.triangle", enabled: false))
        }
        if Prefs.totalWords > 0 || Paths.whisper == nil || !Paths.modelExists {
            m.addItem(.separator())
        }

        m.addItem(item("View on GitHub", symbol: "arrow.up.right.square",
                       action: #selector(openRepo)))
        m.addItem(item("Quit Murmur", action: #selector(NSApplication.terminate(_:)), key: "q"))
        statusItem.menu = m
    }

        // MARK: Menu actions

    @objc private func pickLang(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Lang(rawValue: raw) else { return }
        state.lang = l
        Prefs.lang = l
        refreshStatusIcon()
    }
    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/YahyaElghobashy/murmur")!)
    }
    @objc private func togglePaste()  { Prefs.autoPaste.toggle(); rebuildMenu() }
    @objc private func toggleSounds() { Prefs.sounds.toggle(); rebuildMenu() }
    @objc private func fixPermissions() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        pollForPermission()
    }

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                NSLog("login item: \(error.localizedDescription)")
            }
            rebuildMenu()
        }
    }
}
