import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

@main
struct Whisperbar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
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
        buildStatusItem()
        wireHotkey()

        recorder.onLevel = { [weak self] v in
            guard let self else { return }
            self.state.level = self.state.level * 0.55 + v * 0.45      // smoothing
        }

        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
            .store(in: &bag)

        // A tap that gets disabled by the system must be revived, or the app goes quietly deaf.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.hotkey.reenableIfNeeded()
        }

        Recorder.requestMic { _ in }
        if !startHotkeyIfPermitted() { presentFirstRun() }
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

    private func presentFirstRun() {
        let a = NSAlert()
        a.messageText = "Whisperbar needs Accessibility access"
        a.informativeText = """
        It uses it for two things: noticing when you hold ⌃⌥/, and pasting the transcript into \
        whatever you are typing in.

        Open Privacy & Security → Accessibility, switch Whisperbar on, then choose Retry.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Retry")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
            pollForPermission()
        case .alertSecondButtonReturn:
            if !startHotkeyIfPermitted() { presentFirstRun() }
        default: break
        }
    }

    /// Granting Accessibility does not notify us, so poll briefly after sending them to Settings.
    private func pollForPermission() {
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            tries += 1
            if self.startHotkeyIfPermitted() {
                t.invalidate()
                self.flash(.warning("Hotkey armed"), for: 1.4)
            } else if tries > 40 {
                t.invalidate()
            }
        }
    }

    // MARK: Hotkey wiring

    private func wireHotkey() {
        hotkey.onPressStart = { [weak self] in self?.beginRecording(locked: false) }
        hotkey.onDoubleTap  = { [weak self] in self?.lockRecording() }
        hotkey.onPressEnd   = { [weak self] in self?.releaseKey() }
        hotkey.onForeignKey = { [weak self] in self?.stopIfLocked() }
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
        state.phase = .recording(locked: locked)
        hud.show()
        Sound.start()

        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordingStart else { return }
            self.state.elapsed = Date().timeIntervalSince(s)
            if self.state.elapsed >= Limits.maxRecordSeconds {
                self.finishRecording()
            }
        }
    }

    private func lockRecording() {
        switch state.phase {
        case .recording:
            state.phase = .recording(locked: true)
            Sound.tick()
        case .idle:
            beginRecording(locked: true)
        default: break
        }
    }

    private func releaseKey() {
        guard case .recording(let locked) = state.phase else { return }
        if locked { return }                       // locked runs until a key or Escape
        finishRecording()
    }

    private func stopIfLocked() {
        if case .recording(true) = state.phase { finishRecording() }
    }

    private func cancel() {
        guard state.isBusy else { return }
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        recorder.discard()
        Sound.stop()
        flash(.warning("Cancelled"), for: 1.2)
    }

    private func finishRecording() {
        guard case .recording = state.phase else { return }
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
        refreshStatusIcon()
        rebuildMenu()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        var tint: NSColor? = nil
        switch state.phase {
        case .recording:    name = "waveform.circle.fill"; tint = .systemRed
        case .transcribing: name = "ellipsis.circle";      tint = .systemPurple
        case .done:         name = "checkmark.circle";     tint = .systemGreen
        case .failed:       name = "exclamationmark.circle"; tint = .systemRed
        default:            name = "mic"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Whisperbar")
        img?.isTemplate = (tint == nil)
        button.image = img
        button.contentTintColor = tint
        button.toolTip = "Whisperbar · \(state.lang.long)\nHold ⌃⌥/ to dictate"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let m = NSMenu()

        let status = NSMenuItem(title: hotkey.running ? "Ready · hold ⌃⌥/" : "Not armed — grant Accessibility",
                                action: hotkey.running ? nil : #selector(fixPermissions), keyEquivalent: "")
        status.target = self
        status.isEnabled = !hotkey.running
        m.addItem(status)
        m.addItem(.separator())

        let langHeader = NSMenuItem(title: "Primary language  ⌃⌥.", action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        m.addItem(langHeader)
        for l in Lang.allCases {
            let it = NSMenuItem(title: "   \(l.long)", action: #selector(pickLang(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.state = (l == state.lang) ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())

        let paste = NSMenuItem(title: "Paste into the focused field",
                               action: #selector(togglePaste), keyEquivalent: "")
        paste.target = self
        paste.state = Prefs.autoPaste ? .on : .off
        m.addItem(paste)

        let snd = NSMenuItem(title: "Sound cues", action: #selector(toggleSounds), keyEquivalent: "")
        snd.target = self
        snd.state = Prefs.sounds ? .on : .off
        m.addItem(snd)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())

        let count = NSMenuItem(title: "\(Prefs.totalWords.formatted()) words dictated", action: nil, keyEquivalent: "")
        count.isEnabled = false
        m.addItem(count)

        if Paths.whisper == nil {
            let w = NSMenuItem(title: "⚠︎ whisper-cli not found", action: nil, keyEquivalent: "")
            w.isEnabled = false; m.addItem(w)
        }
        if !Paths.modelExists {
            let w = NSMenuItem(title: "⚠︎ model missing", action: nil, keyEquivalent: "")
            w.isEnabled = false; m.addItem(w)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Whisperbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m
    }

    // MARK: Menu actions

    @objc private func pickLang(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Lang(rawValue: raw) else { return }
        state.lang = l
        Prefs.lang = l
        refreshStatusIcon()
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
