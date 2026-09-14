import AppKit
import SwiftUI

// MARK: - Design tokens

enum T {
    static let radius: CGFloat = 16
    static let stroke = Color.white.opacity(0.10)
    static let fg = Color.primary
    static let muted = Color.primary.opacity(0.55)
    static let faint = Color.primary.opacity(0.35)
    static let accent = Color(red: 0.851, green: 0.447, blue: 0.306)  // Ember #D9724E
    static let sand   = Color(red: 0.937, green: 0.918, blue: 0.886)  // Sand #EFEAE2
    static let good = Color(red: 0.33, green: 0.67, blue: 0.24)
    static let bad = Color(red: 0.85, green: 0.27, blue: 0.29)
    static let warn = Color(red: 0.79, green: 0.54, blue: 0.18)

    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .monospaced)
    }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
}

// MARK: - Small parts

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

        case .recording(let locked):
            Dot(color: T.bad, pulse: true)
            Meter(level: state.level)
            VStack(alignment: .leading, spacing: 2) {
                Text(locked ? "Locked on" : "Listening")
                    .font(T.ui(13, .semibold)).foregroundColor(T.fg)
                Text(locked ? "Any key to stop" : "Release to transcribe")
                    .font(T.ui(10.5)).foregroundColor(T.faint)
            }
            Spacer(minLength: 2)
            Text(timeString(state.elapsed))
                .font(T.mono(11, .semibold)).foregroundColor(T.muted)
                .monospacedDigit()
            Pill(text: state.lang.label, tone: T.accent)

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

    func show() {
        hideWork?.cancel()
        if panel == nil { build() }
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
        p.ignoresMouseEvents = true         // never steals a click
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
