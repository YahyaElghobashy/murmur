import AppKit
import SwiftUI

// MARK: - Design tokens

/// Breath palette. The bubble commits to the brand's dark card in both system
/// themes, the way the menu-bar glyph stays monochrome: one deliberate look.
enum T {
    static let radius: CGFloat = 16
    static let char   = Color(red: 0.090, green: 0.082, blue: 0.102)  // Char  #17151A
    static let sand   = Color(red: 0.937, green: 0.918, blue: 0.886)  // Sand  #EFEAE2
    static let accent = Color(red: 0.851, green: 0.447, blue: 0.306)  // Ember #D9724E
    static let stone  = Color(red: 0.486, green: 0.455, blue: 0.502)  // Stone #7C7480
    static let stroke = sand.opacity(0.10)
    static let fg = sand
    static let muted = sand.opacity(0.55)
    static let faint = sand.opacity(0.38)
    static let good = Color(red: 0.42, green: 0.72, blue: 0.34)
    static let bad = Color(red: 0.89, green: 0.38, blue: 0.40)
    static let warn = Color(red: 0.85, green: 0.62, blue: 0.28)

    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .monospaced)
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
}

// MARK: - Small parts

/// The decay mark, leading every bubble state. Loaded once from the bundle;
/// absent in dev harnesses, where the bubble simply runs without it.
private struct BrandMark: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "HudMark@2x", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: img.size.width / 2, height: img.size.height / 2)
        return img
    }()
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img)
                .padding(.trailing, 1)
                .accessibilityLabel("Murmur")
        }
    }
}

private struct Pill: View {
    let text: String
    var tone: Color = T.faint
    var body: some View {
        Text(text)
            .font(T.mono(9.5, .semibold))
            .tracking(0.6)
            .foregroundColor(tone)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tone.opacity(0.13))
            )
    }
}

/// The mark itself is the live indicator while recording: the Ember disc is
/// the recording light, pulsing, and the crescents drift gently left and
/// right like air carrying the sound. Paused, everything settles and dims.
private struct AnimatedMark: View {
    var paused: Bool

    private struct HalfDisc: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.minX, y: rect.midY),
                     radius: rect.height / 2,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.closeSubpath()
            return p
        }
    }

    private func pulse(_ t: Double) -> CGFloat {
        if paused { return 1 }
        let wave: Double = 0.5 + 0.5 * sin(t * 2 * Double.pi / 1.2)
        return CGFloat(1.0 + 0.10 * wave)
    }
    private func drift(_ t: Double, _ i: Int) -> CGFloat {
        if paused { return 0 }
        let period: Double = 1.5 + Double(i) * 0.25
        let phase: Double = Double(i) * 1.9
        return CGFloat(sin(t * 2 * Double.pi / period + phase) * 1.3)
    }
    private static let heights: [CGFloat] = [11, 8.5, 6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
            let t: Double = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                Circle()
                    .fill(T.accent)
                    .frame(width: 13, height: 13)
                    .scaleEffect(pulse(t))
                    .shadow(color: T.accent.opacity(paused ? 0 : 0.5), radius: 3.5 * pulse(t))
                ForEach(0..<3, id: \.self) { i in
                    HalfDisc()
                        .fill(T.sand.opacity(paused ? 0.4 : 0.92))
                        .frame(width: Self.heights[i] / 2 + 1.5, height: Self.heights[i])
                        .offset(x: drift(t, i))
                }
            }
            .opacity(paused ? 0.75 : 1)
        }
        .frame(height: 16)
        .accessibilityLabel(paused ? "Paused" : "Recording")
    }
}

/// A real level meter: the rolling history of what the microphone heard,
/// newest at the right. Silence reads flat; speech reads as movement.
private struct LiveMeter: View {
    let levels: [Float]
    var dimmed: Bool = false
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule(style: .continuous)
                    .fill(T.accent.opacity(dimmed ? 0.22 : 0.35 + 0.65 * Double(min(1, v))))
                    .frame(width: 2.5, height: max(2.5, CGFloat(min(1, v)) * 22))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// Five bars that ride the mic level, with a gentle idle shimmer so it never looks dead.
private struct Meter: View {
    let level: Float
    @State private var phase: Double = 0
    private let bars = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                let weight = [0.55, 0.85, 1.0, 0.8, 0.5][i]
                let idle = 0.16 + 0.06 * sin(phase * 2 + Double(i) * 0.9)
                let h = max(3, CGFloat(max(Double(level) * weight, idle)) * 22)
                Capsule(style: .continuous)
                    .fill(T.accent)
                    .frame(width: 2.5, height: h)
                    .animation(.easeOut(duration: 0.07), value: level)
            }
        }
        .frame(height: 22)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

private struct Dot: View {
    let color: Color
    var pulse: Bool = false
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulse ? (on ? 1 : 0.35) : 1)
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// A compact control for the locked bubble. Deliberately low-contrast until
/// hovered, so the bubble stays calm while still being obviously clickable.
private struct CtlButton: View {
    let system: String
    let label: String
    var tone: Color = T.fg
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 9.5, weight: .bold))
                if !label.isEmpty { Text(label).font(T.ui(11, .semibold)).fixedSize() }
            }
            .foregroundColor(tone)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tone.opacity(hovering ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tone.opacity(hovering ? 0.35 : 0.0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
    }
}

private struct Spinner: View {
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(T.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

// MARK: - The card

struct HUDView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 11) {
            if case .recording = state.phase {} else { BrandMark() }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minWidth: 190)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: T.radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: T.radius, style: .continuous)
                    .fill(T.char.opacity(0.78))
                RoundedRectangle(cornerRadius: T.radius, style: .continuous)
                    .strokeBorder(T.stroke, lineWidth: 1)
            }
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.phase)
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch state.phase {

        case .idle:
            EmptyView()

        case .recording(let locked, let paused):
            AnimatedMark(paused: paused)
            LiveMeter(levels: state.levels, dimmed: paused)
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "Paused" : (locked ? "Locked on" : "Listening"))
                    .font(T.ui(13, .semibold)).foregroundColor(T.fg)
                Text(paused ? "Resume or stop when ready"
                            : (locked ? "Hands free" : "Release to transcribe"))
                    .font(T.ui(10.5)).foregroundColor(T.faint)
            }
            Spacer(minLength: 2)
            Text(timeString(state.elapsed))
                .font(T.mono(11, .semibold)).foregroundColor(T.muted)
                .monospacedDigit()

            if locked {
                CtlButton(system: paused ? "play.fill" : "pause.fill",
                          label: paused ? "Resume" : "Pause",
                          tone: T.fg) { state.onPauseToggle?() }
                CtlButton(system: "stop.fill", label: "Stop",
                          tone: T.accent) { state.onStop?() }
                CtlButton(system: "xmark", label: "",
                          tone: T.bad) { state.onCancel?() }
                    .help("Discard the recording")
            } else {
                Pill(text: state.lang.label, tone: T.accent)
            }

        case .transcribing:
            Spinner()
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribing").font(T.ui(13, .semibold)).foregroundColor(T.fg)
                Text("Recording ended").font(T.ui(10.5)).foregroundColor(T.faint)
            }
            Spacer(minLength: 2)
            Pill(text: state.lang.label, tone: T.accent)

        case .done(let text, let pasted):
            Dot(color: T.good)
            VStack(alignment: .leading, spacing: 2) {
                Text(pasted ? "Pasted" : "Copied to clipboard")
                    .font(T.ui(13, .semibold)).foregroundColor(T.fg)
                Text(preview(text))
                    .font(T.ui(10.5)).foregroundColor(T.faint)
                    .lineLimit(1).frame(maxWidth: 260, alignment: .leading)
            }
            Spacer(minLength: 2)
            Pill(text: "\(wordCount(text))W", tone: T.good)

        case .failed(let msg):
            Dot(color: T.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg).font(T.ui(13, .semibold)).foregroundColor(T.fg)
                    .lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                Text("Nothing was saved").font(T.ui(10.5)).foregroundColor(T.faint)
            }

        case .warning(let msg):
            Dot(color: T.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg).font(T.ui(13, .semibold)).foregroundColor(T.fg)
                Text("Recording ended").font(T.ui(10.5)).foregroundColor(T.faint)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    private func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
    private func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 48 ? String(one.prefix(48)) + "…" : one
    }
}

// MARK: - The window that carries it

final class HUDController {
    private var panel: NSPanel?
    private let state: AppState
    private var hideWork: DispatchWorkItem?

    init(state: AppState) { self.state = state }

    /// The bubble is click-through except during a locked run, where it carries
    /// the pause and stop controls. A nonactivating panel takes those clicks
    /// without pulling focus off whatever is being dictated into.
    func setInteractive(_ on: Bool) {
        panel?.ignoresMouseEvents = !on
    }

    func show() {
        hideWork?.cancel()
        if panel == nil { build() }
        panel?.ignoresMouseEvents = !state.isLocked
        position()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel?.animator().alphaValue = 1
        }
    }

    /// Auto-dismiss for terminal states.
    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func build() {
        let host = NSHostingView(rootView: HUDView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 56)

        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                 // SwiftUI draws its own
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true         // flipped on for the locked bubble only
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel = p
    }

    /// Bottom centre of whichever screen has the pointer.
    private func position() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 300, height: 56)
        p.setContentSize(size)
        let x = vf.midX - size.width / 2
        let y = vf.minY + 64
        p.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
