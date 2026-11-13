// The app icon (design/ui/Brand.dc.html): Pip in its listening mood on Pip's ink tile, with two coral sound arcs.
// Drawn in code and rendered by build.sh (`PipDictee --render-icon <folder>`), so it never drifts from the app's Pip.
import AppKit
import SwiftUI

struct AppIconView: View {
    /// Below 64 px the arcs and details blur: just the pebble and the eyes, like Pip's small icon.
    var small = false

    var body: some View {
        GeometryReader { g in
            let side = g.size.width
            let tile = side * 824 / 1024               // macOS icon grid: 824 px tile on a 1024 canvas
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(RadialGradient(colors: [Color(hex: 0x4A2E4A), Color(hex: 0x2A2346), Color(hex: 0x17142A)],
                                         center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: tile * 0.75))
                    .overlay(RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: max(1, tile / 300)))
                    .frame(width: tile, height: tile)
                    .shadow(color: .black.opacity(small ? 0 : 0.3), radius: side * 0.02, y: side * 0.012)
                if small {
                    PipView(mood: .listening, mini: true).frame(width: tile * 0.72)
                } else {
                    HStack(spacing: tile * 0.03) {
                        PipView(mood: .listening).frame(width: tile * 0.6)
                        SoundArcs().frame(width: tile * 0.16, height: tile * 0.36)
                    }
                    .offset(x: tile * 0.005)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct SoundArcs: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, lw = w * 0.2
            var near = Path()
            near.move(to: CGPoint(x: lw, y: h * 0.25))
            near.addQuadCurve(to: CGPoint(x: lw, y: h * 0.75), control: CGPoint(x: w * 0.55, y: h * 0.5))
            var far = Path()
            far.move(to: CGPoint(x: w * 0.55, y: h * 0.06))
            far.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.94), control: CGPoint(x: w * 1.15, y: h * 0.5))
            let style = StrokeStyle(lineWidth: lw, lineCap: .round)
            ctx.stroke(near, with: .color(.pipCoralSoft), style: style)
            ctx.stroke(far, with: .color(.pipCoralSoft.opacity(0.6)), style: style)
        }
    }
}

/// Writes a macOS .iconset (every size Apple asks for); build.sh turns it into AppIcon.icns with iconutil.
@MainActor
func renderAppIcon(to dir: String) {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let r = ImageRenderer(content: AppIconView(small: px < 64).frame(width: CGFloat(px), height: CGFloat(px)))
            r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("could not render \(px) px"); exit(1) }
            let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}

/// The Windows app's images (scripts/make-windows-assets.sh): the tray icon in each state, and the app icon at every
/// size the .ico needs. Same Pip as here, so both apps look like one family.
@MainActor
func renderWindowsAssets(to dir: String) {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func save<V: View>(_ name: String, _ px: Int, _ view: V) {
        let r = ImageRenderer(content: view.frame(width: CGFloat(px), height: CGFloat(px)))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("could not render \(name)"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
    // Tray: the flat Pip, readable on light and dark taskbars; an amber dot when setup is needed.
    let tray: [(String, PipMood, Bool)] = [("ready", .ready, false), ("listening", .listening, false), ("thinking", .thinking, false), ("needs-you", .ready, true)]
    for (name, mood, dot) in tray {
        save("tray-\(name)", 32, ZStack(alignment: .bottomTrailing) {
            PipView(mood: mood, mini: true).padding(1)
            if dot { Circle().fill(Color(hex: 0xE0A100)).overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).frame(width: 13, height: 13) }
        })
    }
    for px in [16, 24, 32, 48, 64, 128, 256] { save("icon-\(px)", px, AppIconView(small: px < 64)) }

    // Installer wizard (Inno Setup): the tall side image and the small header image, at 100 % and 200 %.
    // Opaque backgrounds: the installer shows them as plain bitmaps.
    func saveRect<V: View>(_ name: String, _ w: Int, _ h: Int, _ view: V) {
        let r = ImageRenderer(content: view.frame(width: CGFloat(w), height: CGFloat(h)))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("could not render \(name)"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
    for (suffix, k) in [("", 1.0), ("-2x", 2.0)] {
        saveRect("wizard\(suffix)", Int(164 * k), Int(314 * k), WizardSideImage().scaleEffect(k).frame(width: 164 * k, height: 314 * k))
        saveRect("wizard-small\(suffix)", Int(55 * k), Int(58 * k),
                 ZStack { Color.white; PipView(mood: .happy).padding(6 * k) })
    }
}

/// The installer's side image: Pip, happy, on Pip's ink with the two coral sound arcs.
struct WizardSideImage: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A2346), Color.pipInk], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0x4A2E4A).opacity(0.9), .clear], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 120)
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    PipView(mood: .happy).frame(width: 96)
                    SoundArcs().frame(width: 20, height: 46)
                }
                .offset(x: 8)
                Text("Pip Dictée").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .offset(y: -20)
        }
        .frame(width: 164, height: 314)
    }
}
