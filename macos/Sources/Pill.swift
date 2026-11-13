// The floating pill at the bottom of the screen: the only UI you see while dictating.
// Each state is one of Pip's moods (see design/ui/Pill-States.dc.html).
import AppKit
import SwiftUI

enum PillState: Equatable {
    case listening, handsFree, thinking
    case typed(app: String?, words: Int)
    case copied
    case oops(String)
    case needsYou(Need)
    case cancelled
    case info(String)

    var mood: PipMood {
        switch self {
        case .listening, .handsFree: return .listening
        case .thinking: return .thinking
        case .typed, .info: return .happy
        case .copied: return .ready
        case .oops: return .oops
        case .needsYou: return .needsYou
        case .cancelled: return .resting
        }
    }
}

final class PillModel: ObservableObject {
    @Published var state: PillState?
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 12)
    @Published var startedAt = Date()
    var action: (Need) -> Void = { _ in }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let s = model.state { pill(s).transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: model.state)
    }

    @ViewBuilder func pill(_ s: PillState) -> some View {
        let small = s == .cancelled
        HStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !(s == .listening || s == .handsFree))) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                PipView(mood: s.mood, mini: true, lean: (s == .listening || s == .handsFree) ? -3 + 2 * sin(t * 2.6) : 0)
            }
            .frame(width: small ? 36 : 44, height: small ? 32 : 40)
            content(s)
        }
        .padding(.leading, 8).padding(.trailing, s.isNeedsYou ? 8 : 18)
        .frame(height: small ? 46 : 58)
        .background(Capsule().fill(Color.pipInk.opacity(0.9)))
        .overlay(Capsule().strokeBorder(s.isNeedsYou ? Color.pipSun : Color.white.opacity(0.18), lineWidth: s.isNeedsYou ? 2 : 1))
        .background(Capsule().fill(Color.pipSun.opacity(s.isNeedsYou ? 0.25 : 0)).padding(-5))
        .shadow(color: Color.pipInk.opacity(0.35), radius: 18, y: 10)
        .foregroundStyle(.white)
        .fixedSize()
    }

    @ViewBuilder func content(_ s: PillState) -> some View {
        switch s {
        case .listening, .handsFree:
            Waveform(levels: model.levels)
            Text(s == .handsFree ? L("Hands-free") : L("Listening")).font(.pipTitle(15))
            Spacer(minLength: 8)
            if s == .handsFree {
                Label(L("⌃⌥ to finish"), systemImage: "lock.fill").font(.pipText(12.5, .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(.white.opacity(0.12)))
            } else {
                TimelineView(.periodic(from: model.startedAt, by: 1)) { tl in
                    let e = Int(tl.date.timeIntervalSince(model.startedAt))
                    Text(String(format: "%d:%02d", e / 60, e % 60)).font(.pipText(13, .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                }
            }
        case .thinking:
            Text(L("Writing it down")).font(.pipTitle(15))
            ThinkingDots()
        case .typed(let app, let words):
            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(Color.pipMint)
            Text(app.map { L("Typed in %@", $0) } ?? L("Typed")).font(.pipTitle(15)).lineLimit(1)
            Text(Lwords(words)).font(.pipText(13, .bold)).foregroundStyle(.white.opacity(0.75))
        case .copied:
            Text(L("Copied")).font(.pipTitle(15))
            Text(L("⌘V to paste")).font(.pipText(13, .bold)).foregroundStyle(.white.opacity(0.75))
        case .oops(let m), .info(let m):
            Text(m).font(.pipTitle(15)).lineLimit(1)
        case .needsYou(let need):
            Text(need.message).font(.pipTitle(15)).lineLimit(1)
            Button(need == .model || need == .whisper ? L("Set up") : L("Open Settings")) { model.action(need) }
                .buttonStyle(PipButtonStyle(kind: .amber)).clipShape(Capsule())
        case .cancelled:
            Text(L("Cancelled")).font(.pipTitle(14)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

extension PillState { var isNeedsYou: Bool { if case .needsYou = self { return true }; return false } }

struct Waveform: View {
    var levels: [CGFloat]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(levels.suffix(10).enumerated()), id: \.offset) { _, l in
                Capsule().fill(Color.pipCoralSoft).frame(width: 4, height: 6 + 22 * min(1, max(0, l)))
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let a = reduceMotion ? 1 : 0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8))
                    Circle().fill(.white.opacity(a)).frame(width: 6, height: 6).offset(y: reduceMotion ? 0 : -3 * a)
                }
            }
        }
    }
}

/// The window that holds the pill: never takes focus, joins every Space, ignores the mouse unless it needs a click.
final class Pill {
    let model = PillModel()
    let panel: NSPanel
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    var level: () -> CGFloat = { 0 }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ s: PillState, hideAfter: Double? = nil) {
        hideWork?.cancel()
        if s == .listening || s == .handsFree, !(model.state == .listening || model.state == .handsFree) { model.startedAt = Date() }
        model.state = s
        panel.ignoresMouseEvents = !s.isNeedsYou
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - 230, y: f.minY + 14, width: 460, height: 90), display: true)
        panel.orderFrontRegardless()
        let live = s == .listening || s == .handsFree
        if live, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
                guard let me = self else { return }
                var l = me.model.levels; l.removeFirst(); l.append(me.level()); me.model.levels = l
            }
        } else if !live { timer?.invalidate(); timer = nil }
        if let d = hideAfter {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: w)
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        model.state = nil
        model.levels = Array(repeating: 0, count: model.levels.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.model.state == nil { self?.panel.orderOut(nil) }
        }
    }
}
