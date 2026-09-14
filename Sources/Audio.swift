import AppKit
import AVFoundation
import Foundation

// MARK: - Errors

enum VoiceError: LocalizedError {
    case micDenied
    case noInput
    case engineFailed(String)
    case tooShort
    case silent
    case whisperMissing
    case modelMissing
    case transcribeFailed(String)
    case timedOut
    case empty

    var errorDescription: String? {
        switch self {
        case .micDenied:              return "Microphone access is off"
        case .noInput:                return "No microphone found"
        case .engineFailed(let m):    return "Audio engine failed: \(m)"
        case .tooShort:               return "Too short, ignored"
        case .silent:                 return "Nothing heard"
        case .whisperMissing:         return "whisper-cli not found"
        case .modelMissing:           return "Whisper model not found"
        case .transcribeFailed(let m):return "Transcription failed: \(m)"
        case .timedOut:               return "Transcription timed out"
        case .empty:                  return "No speech detected"
        }
    }

    /// A one-line remedy shown under the error in the HUD.
    var remedy: String? {
        switch self {
        case .micDenied:      return "Open Privacy settings and allow the microphone"
        case .whisperMissing: return "brew install whisper-cpp"
        case .modelMissing:   return "Model expected at ~/.local/share/whisper-models/"
        default:              return nil
        }
    }
}

// MARK: - Recorder

/// Captures the default input straight to a 16 kHz mono WAV, which is exactly what
/// whisper wants. No ffmpeg step, no format guessing.
final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var url: URL?
    private var startedAt: Date?
    private var peak: Float = 0
    /// The tap runs on a realtime audio thread while stop() runs on main.
    /// Every touch of `file` is serialised through this.
    private let lock = NSLock()

    var onLevel: ((Float) -> Void)?

    /// What lands on disk: 16 kHz mono signed 16-bit, exactly what whisper wants.
    private let diskSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// Wall clock minus whatever was spent paused, so the timer matches the audio.
    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        let now = pausedAt ?? Date()
        return now.timeIntervalSince(startedAt) - pausedTotal
    }
    var isPaused: Bool { pausedAt != nil }

    /// Stops rendering without tearing the graph down, so the wav simply has no
    /// frames for the paused stretch and stays one continuous file.
    func pause() {
        guard engine.isRunning, pausedAt == nil else { return }
        engine.pause()
        pausedAt = Date()
    }

    func resume() {
        guard let at = pausedAt else { return }
        pausedTotal += Date().timeIntervalSince(at)
        pausedAt = nil
        try? engine.start()
    }
    var sawSound: Bool { peak > Limits.silenceRMSFloor }

    func start() throws {
        peak = 0
        pausedAt = nil
        pausedTotal = 0
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw VoiceError.noInput }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("clip-\(UUID().uuidString).wav")
        url = out

        let f = try AVAudioFile(forWriting: out, settings: diskSettings)
        // AVAudioFile encodes to diskSettings on write, but write(from:) demands a buffer
        // in processingFormat, which is float32. Converting to anything else traps.
        guard let conv = AVAudioConverter(from: hw, to: f.processingFormat) else {
            throw VoiceError.engineFailed("cannot convert \(Int(hw.sampleRate))Hz to 16kHz")
        }
        lock.lock(); file = f; lock.unlock()
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            self?.consume(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { throw VoiceError.engineFailed(error.localizedDescription) }
        startedAt = Date()
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buf.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            if rms > peak { peak = rms }
            // A power curve lifts quiet speech into the visible range while
            // keeping true silence at the floor, like the system mic meter.
            let shaped = min(1, pow(max(0, rms) * 16, 0.72))
            DispatchQueue.main.async { self.onLevel?(shaped) }
        }

        lock.lock()
        defer { lock.unlock() }
        guard let conv = converter, let file else { return }

        let target = file.processingFormat
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }

        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0 else { return }
        do { try file.write(from: out) } catch { NSLog("[murmur] write failed: %@", "\(error)") }
    }

    @discardableResult
    func stop() -> (url: URL?, seconds: TimeInterval) {
        let secs = duration
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); file = nil; lock.unlock()   // closing finalises the wav header
        converter = nil
        startedAt = nil
        let u = url
        url = nil
        return (u, secs)
    }

    func discard() {
        let (u, _) = stop()
        if let u { try? FileManager.default.removeItem(at: u) }
    }

    static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }
}

// MARK: - Transcriber

enum Transcriber {
    /// Runs whisper-cli against the wav and returns the text. The audio is deleted
    /// before this function returns, on every path.
    static func run(wav: URL, lang: Lang, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let base = wav.deletingPathExtension().path
            let txt = URL(fileURLWithPath: base + ".txt")

            func cleanup() {
                try? FileManager.default.removeItem(at: wav)
                try? FileManager.default.removeItem(at: txt)
            }
            func finish(_ r: Result<String, Error>) {
                cleanup()
                DispatchQueue.main.async { completion(r) }
            }

            guard let bin = Paths.whisper else { return finish(.failure(VoiceError.whisperMissing)) }
            guard Paths.modelExists      else { return finish(.failure(VoiceError.modelMissing)) }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-m", Paths.model, "-f", wav.path,
                           "-l", lang.rawValue,
                           "-t", "8", "-otxt", "-of", base]
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()

            do { try p.run() } catch {
                return finish(.failure(VoiceError.transcribeFailed(error.localizedDescription)))
            }

            // Hard timeout so a wedged process cannot hang the app forever.
            let deadline = DispatchTime.now() + Limits.transcribeTimeout
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            if done.wait(timeout: deadline) == .timedOut {
                p.terminate()
                return finish(.failure(VoiceError.timedOut))
            }

            guard p.terminationStatus == 0 else {
                let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
                let line = e.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
                return finish(.failure(VoiceError.transcribeFailed(line)))
            }

            let raw = (try? String(contentsOf: txt, encoding: .utf8)) ?? ""
            let text = clean(raw)
            finish(text.isEmpty ? .failure(VoiceError.empty) : .success(text))
        }
    }

    /// whisper emits bracketed non-speech markers and stray whitespace.
    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(BLANK_AUDIO|inaudible|silence)[^)]*\)"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Delivery

enum Inserter {
    /// Puts text on the pasteboard, then pastes it if the focused element accepts text.
    /// Returns true when it actually pasted. The clipboard is left holding the transcript
    /// either way, so a failed paste is still recoverable with ⌘V.
    static func deliver(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard Prefs.autoPaste, Permissions.accessibility, focusedAcceptsText() else { return false }

        // ⌘V through the same event source the tap uses.
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        src.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let v: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Asks the accessibility API whether the thing with keyboard focus is a text control.
    private static func focusedAcceptsText() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
              let element = focused
        else { return false }
        let el = element as! AXUIElement

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if textRoles.contains(role) { return true }

        // Web views and Electron apps report generic roles; fall back to asking whether
        // the value attribute is writable.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }
}
