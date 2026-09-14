import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

// MARK: - Configuration

enum Paths {
    static let model = NSString(string: "~/.local/share/whisper-models/ggml-large-v3-turbo.bin")
        .expandingTildeInPath
    /// whisper-cli is installed by homebrew; the PATH of a GUI app does not include /opt/homebrew.
    static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper",
    ]
    static var whisper: String? {
        whisperCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var modelExists: Bool { FileManager.default.fileExists(atPath: model) }
}

/// Primary language. whisper decides one language per clip, so forcing the dominant one
/// gives better results on code-switched speech than leaving it to auto-detect.
enum Lang: String, CaseIterable {
    case english = "en"
    case arabic = "ar"
    case auto = "auto"

    var label: String {
        switch self {
        case .english: return "EN"
        case .arabic: return "AR"
        case .auto: return "AUTO"
        }
    }
    var long: String {
        switch self {
        case .english: return "English, with Arabic mixed in"
        case .arabic: return "Arabic, with English mixed in"
        case .auto: return "Detect automatically"
        }
    }
    var next: Lang {
        switch self {
        case .english: return .arabic
        case .arabic: return .auto
        case .auto: return .english
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "lang") ?? "en") ?? .english }
        set { d.set(newValue.rawValue, forKey: "lang") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "sounds") == nil ? true : d.bool(forKey: "sounds") }
        set { d.set(newValue, forKey: "sounds") }
    }
    static var autoPaste: Bool {
        get { d.object(forKey: "autoPaste") == nil ? true : d.bool(forKey: "autoPaste") }
        set { d.set(newValue, forKey: "autoPaste") }
    }
    static var totalWords: Int {
        get { d.integer(forKey: "totalWords") }
        set { d.set(newValue, forKey: "totalWords") }
    }
}

// MARK: - Limits

enum Limits {
    static let maxRecordSeconds: TimeInterval = 120
    static let minRecordSeconds: TimeInterval = 0.4
    static let transcribeTimeout: TimeInterval = 90
    static let doubleTapWindow: TimeInterval = 0.4
    static let silenceRMSFloor: Float = 0.004
}

// MARK: - App state machine

enum Phase: Equatable {
    case idle
    case recording(locked: Bool, paused: Bool)
    case transcribing
    case done(text: String, pasted: Bool)
    case failed(String)
    case warning(String)
}

final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var level: Float = 0          // 0…1 smoothed mic level
    /// Rolling window of recent mic levels, newest last. The meter renders this
    /// directly, so silence is visibly flat and speech visibly is not.
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
    @Published var elapsed: TimeInterval = 0
    @Published var lang: Lang = Prefs.lang
    @Published var hudVisible: Bool = false

    var isBusy: Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// True only while a locked run is in progress, which is when the HUD
    /// becomes clickable and shows its controls.
    var isLocked: Bool {
        if case .recording(true, _) = phase { return true }
        return false
    }
    var isPaused: Bool {
        if case .recording(_, true) = phase { return true }
        return false
    }

    // Wired by the app delegate; called from the HUD's buttons.
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func pushLevel(_ v: Float) {
        levels.removeFirst()
        levels.append(v)
    }

    func cycleLang() {
        lang = lang.next
        Prefs.lang = lang
        Sound.tick()
    }
}

// MARK: - Sound cues

enum Sound {
    static func start() { play("Tink") }
    static func stop()  { play("Pop") }
    static func ok()    { play("Glass") }
    static func fail()  { play("Basso") }
    static func tick()  { play("Tink") }

    private static func play(_ name: String) {
        guard Prefs.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

// MARK: - Permissions

enum Permissions {
    /// Accessibility is required both to observe the hotkey and to send the paste keystroke.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// True when the app is not trusted yet a grant for it already exists, which is what
    /// happens after a rebuild changes the ad-hoc signature. The row must be removed and
    /// re-added; toggling it does nothing.
    static var hasStaleEntry: Bool {
        guard !accessibility else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["/Library/Application Support/com.apple.TCC/TCC.db",
                       "select count(*) from access where service='kTCCServiceAccessibility' and client like '%murmur%';"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    static func openMicrophoneSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        NSWorkspace.shared.open(URL(string: url)!)
    }
}

// MARK: - Global hotkey

/// Watches for two chords via a CGEventTap:
///   ⌃⌥/  hold to talk, double-tap to lock on
///   ⌃⌥.  cycle the primary language
///
/// The tap swallows both chords so the characters never reach the focused app.
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastPressAt: TimeInterval = 0
    private var isDown = false

    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onCycleLang: (() -> Void)?
    /// Any unrelated key, used to end a locked recording.
    var onForeignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var running = false

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)

        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        running = true
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        tap = nil; source = nil; running = false
    }

    /// macOS disables a tap that ever blocks. Re-enable rather than dying silently.
    func reenableIfNeeded() {
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let chord = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let noCmd = !flags.contains(.maskCommand)

        // ⌃⌥.  cycle language
        if type == .keyDown, chord, noCmd, code == kVK_ANSI_Period {
            DispatchQueue.main.async { self.onCycleLang?() }
            return nil
        }

        // ⌃⌥/  push to talk
        if chord, noCmd, code == kVK_ANSI_Slash {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                let now = Date().timeIntervalSince1970
                let isDouble = (now - lastPressAt) < Limits.doubleTapWindow
                lastPressAt = now
                isDown = true
                DispatchQueue.main.async {
                    if isDouble { self.onDoubleTap?() } else { self.onPressStart?() }
                }
            } else if type == .keyUp {
                isDown = false
                DispatchQueue.main.async { self.onPressEnd?() }
            }
            return nil
        }

        if type == .keyDown {
            if code == kVK_Escape {
                DispatchQueue.main.async { self.onEscape?() }
            } else if !isDown {
                DispatchQueue.main.async { self.onForeignKey?() }
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
