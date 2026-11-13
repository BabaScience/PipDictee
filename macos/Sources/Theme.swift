// Pip's look, shared by every window: colours, type, the Pip character and its moods, the menu-bar glyph and
// a few controls. Same palette as Pip (docs/06-brand.md in the Pip repo): coral, night ink, lilac mist.
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    static let pipCoral = Color(hex: 0xFF6A4D)
    static let pipCoralLight = Color(hex: 0xFFA184)
    static let pipCoralSoft = Color(hex: 0xFF8A6E)      // waveform on ink
    static let pipCoralText = Color(hex: 0xB8361F)      // small coral text on light backgrounds (passes 4.5:1)
    static let pipInk = Color(hex: 0x17142A)
    static let pipInkSoft = Color(hex: 0x3D3852)
    static let pipInkMuted = Color(hex: 0x4A4560)
    static let pipMist = Color(hex: 0xF5F2FC)
    static let pipMint = Color(hex: 0x3DD6A0)
    static let pipMintText = Color(hex: 0x1F7A57)
    static let pipSun = Color(hex: 0xFFC845)
    static let pipSunText = Color(hex: 0x7A5400)
    static let pipLine = Color(hex: 0x17142A, opacity: 0.09)
}

extension Font {
    /// Headlines and the pill: SF Rounded, the closest system face to Pip's Fredoka.
    static func pipTitle(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static func pipText(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

// MARK: - Pip

enum PipMood: Equatable { case ready, listening, thinking, happy, oops, needsYou, resting }

/// Pip, drawn from the same curves as Pip's logo (viewBox 20 40 160 145). `mini` is the flat version used in the pill.
struct PipView: View {
    var mood: PipMood = .ready
    var mini = false
    var lean: Double = 0   // degrees, for the listening sway

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 160, size.height / 145)
            ctx.translateBy(x: (size.width - 160 * s) / 2, y: (size.height - 145 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -20, y: -40)
            let tilt = mood == .needsYou ? -10.0 : lean
            if tilt != 0 {
                ctx.translateBy(x: 100, y: 165); ctx.rotate(by: .degrees(tilt)); ctx.translateBy(x: -100, y: -165)
            }
            draw(&ctx)
        }
        .aspectRatio(160 / 145, contentMode: .fit)
        .accessibilityLabel(Text("Pip"))
    }

    private func ell(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }
    private func line(_ pts: [(CGFloat, CGFloat)], quad: Bool = true) -> Path {
        var p = Path(); p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        if quad, pts.count == 3 { p.addQuadCurve(to: CGPoint(x: pts[2].0, y: pts[2].1), control: CGPoint(x: pts[1].0, y: pts[1].1)) }
        else { for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) } }
        return p
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(.pipInk)
        let bodyPath = PipShape.path
        if mini {
            ctx.fill(bodyPath, with: .color(Color(hex: 0xFF7A5C, opacity: mood == .resting ? 0.75 : 1)))
        } else {
            ctx.fill(bodyPath, with: .linearGradient(Gradient(colors: [.pipCoralLight, .pipCoral]),
                                                     startPoint: CGPoint(x: 100, y: 52), endPoint: CGPoint(x: 100, y: 170)))
            var hl = ctx; hl.translateBy(x: 72, y: 80); hl.rotate(by: .degrees(-20))
            hl.fill(ell(0, 0, 18, 9), with: .color(.white.opacity(0.4)))
            ctx.fill(ell(62, 130, 9, 5), with: .color(Color(hex: 0xE8365D, opacity: 0.3)))
            ctx.fill(ell(138, 130, 9, 5), with: .color(Color(hex: 0xE8365D, opacity: 0.3)))
        }
        let big: CGFloat = mini ? 1.25 : 1
        let stroke = { (w: CGFloat) in StrokeStyle(lineWidth: w * (mini ? 1.4 : 1), lineCap: .round, lineJoin: .round) }
        func eyes(_ y: CGFloat, dx: CGFloat = 0, rx: CGFloat, ry: CGFloat, shine: CGFloat) {
            ctx.fill(ell(80 + dx, y, rx * big, ry * big), with: ink)
            ctx.fill(ell(120 + dx, y, rx * big, ry * big), with: ink)
            if !mini, shine > 0 {
                ctx.fill(ell(83.5 + dx, y - 6, shine, shine), with: .color(.white))
                ctx.fill(ell(123.5 + dx, y - 6, shine, shine), with: .color(.white))
            }
        }
        switch mood {
        case .ready:
            eyes(112, rx: 8, ry: 12, shine: 3)
            ctx.stroke(line([(92, 134), (100, 141), (108, 134)]), with: ink, style: stroke(5))
        case .listening:
            eyes(mini ? 108 : 110, rx: 9.5, ry: 14, shine: 3.6)
            ctx.fill(ell(100, mini ? 140 : 137, 5 * big, 4.5 * big), with: ink)
        case .thinking:
            eyes(100, dx: 6, rx: 8, ry: 12, shine: 0)
            ctx.stroke(line([(93, 139), (109, 139)], quad: false), with: ink, style: stroke(5))
        case .happy:
            ctx.stroke(line([(68, 112), (80, 99), (92, 112)]), with: ink, style: stroke(6.5))
            ctx.stroke(line([(108, 112), (120, 99), (132, 112)]), with: ink, style: stroke(6.5))
            ctx.stroke(line([(86, 130), (100, 146), (114, 130)]), with: ink, style: stroke(5.5))
        case .oops:
            ctx.stroke(line([(64, 96), (90, 88)], quad: false), with: ink, style: stroke(5))
            ctx.stroke(line([(136, 96), (110, 88)], quad: false), with: ink, style: stroke(5))
            eyes(114, rx: 8, ry: 11, shine: 0)
            var w = Path(); w.move(to: CGPoint(x: 88, y: 142))
            w.addQuadCurve(to: CGPoint(x: 100, y: 142), control: CGPoint(x: 94, y: 136))
            w.addQuadCurve(to: CGPoint(x: 112, y: 142), control: CGPoint(x: 106, y: 148))
            ctx.stroke(w, with: ink, style: stroke(4.5))
        case .needsYou:
            eyes(104, dx: 6, rx: 8, ry: 12, shine: 2.6)
            ctx.fill(ell(104, 140, 4.5, 4), with: ink)
        case .resting:
            ctx.stroke(line([(70, 112), (90, 112)], quad: false), with: ink, style: stroke(6.5))
            ctx.stroke(line([(110, 112), (130, 112)], quad: false), with: ink, style: stroke(6.5))
        }
    }
}

enum PipShape {
    /// The pebble, in Pip's logo coordinates.
    static let path: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 100, y: 52))
        p.addCurve(to: CGPoint(x: 172, y: 118), control1: CGPoint(x: 150, y: 52), control2: CGPoint(x: 172, y: 84))
        p.addCurve(to: CGPoint(x: 100, y: 170), control1: CGPoint(x: 172, y: 152), control2: CGPoint(x: 142, y: 170))
        p.addCurve(to: CGPoint(x: 28, y: 118), control1: CGPoint(x: 58, y: 170), control2: CGPoint(x: 28, y: 152))
        p.addCurve(to: CGPoint(x: 100, y: 52), control1: CGPoint(x: 28, y: 84), control2: CGPoint(x: 50, y: 52))
        p.closeSubpath()
        return p
    }()
}

// MARK: - Menu-bar glyph

enum GlyphState { case ready, listening, thinking, needsYou }

/// Pip's outline with a small sound arc: the same family as Pip's menu-bar glyph, but tellable apart.
func menuBarGlyph(_ state: GlyphState) -> NSImage {
    let size = NSSize(width: 24, height: 18)
    let img = NSImage(size: size, flipped: true) { _ in
        let t = NSAffineTransform()
        t.translateX(by: 1, yBy: 1.5); t.scaleX(by: 0.105, yBy: 0.105); t.translateX(by: -28, yBy: -52)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 100, y: 52))
        body.curve(to: NSPoint(x: 172, y: 118), controlPoint1: NSPoint(x: 150, y: 52), controlPoint2: NSPoint(x: 172, y: 84))
        body.curve(to: NSPoint(x: 100, y: 170), controlPoint1: NSPoint(x: 172, y: 152), controlPoint2: NSPoint(x: 142, y: 170))
        body.curve(to: NSPoint(x: 28, y: 118), controlPoint1: NSPoint(x: 58, y: 170), controlPoint2: NSPoint(x: 28, y: 152))
        body.curve(to: NSPoint(x: 100, y: 52), controlPoint1: NSPoint(x: 28, y: 84), controlPoint2: NSPoint(x: 50, y: 52))
        body.close()
        body.transform(using: t as AffineTransform)
        let eyeY: CGFloat = state == .thinking ? 100 : 112, dx: CGFloat = state == .thinking ? 6 : 0
        let eyes = [NSRect(x: 69 + dx, y: eyeY - 16, width: 22, height: 32), NSRect(x: 109 + dx, y: eyeY - 16, width: 22, height: 32)].map { r -> NSBezierPath in
            let p = NSBezierPath(ovalIn: r); p.transform(using: t as AffineTransform); return p
        }
        let ink = NSColor.labelColor
        if state == .listening {
            NSColor(srgbRed: 1, green: 0.416, blue: 0.302, alpha: 1).setFill(); body.fill()
            NSColor(srgbRed: 0.09, green: 0.08, blue: 0.165, alpha: 1).setFill(); eyes.forEach { $0.fill() }
        } else {
            ink.setStroke(); body.lineWidth = 1.5; body.stroke()
            ink.setFill(); eyes.forEach { $0.fill() }
        }
        let arc = NSBezierPath()
        arc.move(to: NSPoint(x: 18.5, y: 6)); arc.curve(to: NSPoint(x: 18.5, y: 13), controlPoint1: NSPoint(x: 21, y: 8), controlPoint2: NSPoint(x: 21, y: 11))
        arc.lineWidth = 1.6; arc.lineCapStyle = .round
        (state == .listening ? NSColor(srgbRed: 0.76, green: 0.25, blue: 0.16, alpha: 1) : ink).setStroke(); arc.stroke()
        if state == .needsYou {
            NSColor(srgbRed: 0.88, green: 0.63, blue: 0, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: 12, width: 6, height: 6)).fill()
        }
        return true
    }
    img.isTemplate = (state == .ready || state == .thinking)
    img.accessibilityDescription = "Pip Dictée"
    return img
}

// MARK: - Controls

struct PipButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, amber, quiet }
    var kind: Kind = .primary
    var fill = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pipText(13.5, .bold))
            .lineLimit(1)   // a long label (German) is shortened with … rather than broken mid-word
            .foregroundStyle(kind == .quiet ? Color.pipInkSoft : Color.pipInk)
            .padding(.vertical, 9).padding(.horizontal, 14)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(kind == .secondary || kind == .quiet ? Color.pipLine : .clear))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
    private var background: Color {
        switch kind { case .primary: return .pipCoral; case .amber: return .pipSun; case .secondary: return .white; case .quiet: return .clear }
    }
}

/// A switch drawn in SwiftUI (coral when on), so it looks the same everywhere, snapshots included.
struct PipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.pipCoral : Color(hex: 0xD6D1E0)).frame(width: 38, height: 22)
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? L("On") : L("Off"))
    }
}

struct Keycap: View {
    var label: String
    var body: some View {
        Text(label).font(.pipText(13, .heavy)).foregroundStyle(Color.pipInk)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pipLine))
            .shadow(color: Color.pipInk.opacity(0.08), radius: 0, y: 1.5)
    }
}

struct Check: View {
    var text: String
    var color: Color = .pipMintText
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(color == .pipMintText ? Color.pipMintText : color)
            Text(text).font(.pipText(13.5, .bold)).foregroundStyle(color)
        }
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// Lays out chips left to right, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > b.minX, x + sz.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

/// Snapshots (`--snapshot`) can't render scroll views; everything else scrolls normally.
struct SnapshotMode: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var snapshot: Bool { get { self[SnapshotMode.self] } set { self[SnapshotMode.self] = newValue } } }

struct MaybeScroll<Content: View>: View {
    @Environment(\.snapshot) var snapshot
    @ViewBuilder var content: Content
    var body: some View {
        if snapshot {
            // Takes exactly the space offered, shows the content from its top, and cuts what doesn't fit (like a scroll view at rest).
            Color.clear.overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else { ScrollView { content } }
    }
}

/// In `--snapshot` renders, native menus and text fields can't be drawn (they show a placeholder): this draws a
/// faithful static stand-in instead, so screenshots for the README and pull requests look like the real app.
struct SnapshotStandIn: ViewModifier {
    @Environment(\.snapshot) var snapshot
    var text: String
    var kind: Kind
    enum Kind { case menu, field, editor }
    func body(content: Content) -> some View {
        if !snapshot { content } else {
            switch kind {
            case .menu:
                HStack(spacing: 5) {
                    Text(text).font(.pipText(13, .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.pipInk)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white).shadow(color: .black.opacity(0.12), radius: 1, y: 0.5))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pipInk.opacity(0.1)))
            case .field:
                Text(text).font(.pipText(13.5, .bold)).foregroundStyle(Color.pipInkMuted).frame(maxWidth: .infinity, alignment: .leading)
            case .editor:
                Text(text).font(.pipText(15, .semibold)).foregroundStyle(Color.pipInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(5)
            }
        }
    }
}
extension View {
    func snapshotStandIn(_ text: String, _ kind: SnapshotStandIn.Kind = .menu) -> some View { modifier(SnapshotStandIn(text: text, kind: kind)) }
}
