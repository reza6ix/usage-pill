// Renders the demo video for Usage Pill, frame by frame, using the app's real views (UI.swift).
// Output: raw BGRA frames on stdout → pipe into ffmpeg (see promo/render.sh).
// The numbers shown are demo values, not anyone's real usage.

import AppKit
import SwiftUI

let W: CGFloat = 1920, H: CGFloat = 1080      // output pixels
let DW: CGFloat = 1280, DH: CGFloat = 720     // "desktop" in points (camera zooms into it)
let FPS = 60.0
let DURATION = 14.0

// MARK: - easing

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeOutBack(_ x: Double) -> Double { let c1 = 1.3, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
func lerpP(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }
func bez(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { lerpP(lerpP(a, c, x), lerpP(c, b, x), x) }
/// fade in over `f` after `a`, fade out over `f` before `b`
func window(_ t: Double, _ a: Double, _ b: Double, _ f: Double = 0.35) -> Double { min(prog(t, a, a + f), 1 - prog(t, b - f, b)) }

// MARK: - demo data

_ = NSApplication.shared
let store = Store()
store.source = HOME + "/.claude-personal"   // card chip reads "personal"
let NOW: Date = Calendar.current.date(bySettingHour: 16, minute: 20, second: 0, of: Date())!
store.now = NOW
store.fetchedAt = NOW
store.status = "ok"
func setLimits(_ session: Double, _ weekly: Double) {
    let n = NOW.timeIntervalSince1970
    store.limits = [
        Limit(key: "five_hour", label: "Session · 5h", pct: session, resetsAt: (n + 2 * 3600 + 9 * 60 + 30) * 1000),
        Limit(key: "seven_day", label: "Weekly · all models", pct: weekly, resetsAt: (n + 2 * 86400 + 5 * 3600 - 30) * 1000),
    ]
}
setLimits(35, 45)

func fit<V: View>(_ v: V) -> CGSize { NSHostingView(rootView: v).fittingSize }

// MARK: - scene pieces

let ink = Color(red: 0.05, green: 0.055, blue: 0.07)

struct Wallpaper: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.05, blue: 0.065)
            RadialGradient(colors: [Style.accent.opacity(0.55), .clear], center: UnitPoint(x: 0.92, y: 1.0), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [Color(red: 0.28, green: 0.33, blue: 0.62).opacity(0.45), .clear], center: UnitPoint(x: 0.05, y: 0.0), startRadius: 0, endRadius: 820)
            RadialGradient(colors: [Color(red: 0.55, green: 0.3, blue: 0.5).opacity(0.18), .clear], center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: 600)
        }
    }
}

struct MenuBar: View {
    var body: some View {
        let p = store.primary
        HStack(spacing: 18) {
            Circle().fill(Color.white.opacity(0.85)).frame(width: 11, height: 11)
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            HStack(spacing: 5) {
                Ring(pct: p?.pct).scaleEffect(0.85)
                Text("\(Int(p!.pct.rounded()))% · \(Fmt.left(p!.resetDate, now: store.now))").monospacedDigit()
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Thu 4:20 PM")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.88))
        .padding(.horizontal, 14)
        .frame(width: DW, height: 24)
        .background(Color.black.opacity(0.32))
    }
}

struct TitleBar: View {
    let dark: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 11, height: 11)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(dark ? Color(white: 0.13) : Color(white: 0.93))
    }
}

/// A generic code editor.
struct EditorWindow: View {
    let lines: [(Int, [(CGFloat, Color)])] = {
        let pal: [Color] = [Color(red: 0.78, green: 0.55, blue: 0.95), Color(red: 0.45, green: 0.72, blue: 1),
                            Color(red: 0.98, green: 0.72, blue: 0.45), Color(red: 0.55, green: 0.85, blue: 0.6),
                            Color.white.opacity(0.55), Color.white.opacity(0.3)]
        var seed: UInt64 = 7
        func r() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        return (0..<14).map { i in
            let indent = [0, 1, 1, 2, 2, 2, 1, 0, 0, 1, 2, 2, 1, 0][i]
            let n = i % 7 == 6 ? 0 : 1 + Int(r() * 4)
            return (indent, (0..<n).map { _ in (CGFloat(24 + r() * 90), pal[Int(r() * Double(pal.count)) % pal.count]) })
        }
    }()
    var body: some View {
        VStack(spacing: 0) {
            TitleBar(dark: true)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<9, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(i == 2 ? 0.35 : 0.14))
                            .frame(width: CGFloat(50 + (i * 37) % 50), height: 8)
                    }
                    Spacer()
                }
                .padding(16).frame(width: 140).background(Color(white: 0.1))
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.22)).frame(width: 18, alignment: .trailing)
                            Spacer().frame(width: CGFloat(l.0) * 18)
                            ForEach(Array(l.1.enumerated()), id: \.offset) { _, b in
                                RoundedRectangle(cornerRadius: 3).fill(b.1.opacity(0.8)).frame(width: b.0, height: 8)
                            }
                        }
                        .frame(height: 12)
                    }
                    Spacer()
                }
                .padding(.vertical, 16).padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 600, height: 400)
        .background(Color(white: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }
}

/// A generic browser page.
struct BrowserWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TitleBar(dark: false)
                Capsule().fill(Color.black.opacity(0.06)).frame(width: 300, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.22)).frame(width: 140, height: 6))
            }
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.78)).frame(width: 260, height: 20)
                    RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.78)).frame(width: 190, height: 20)
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.16))
                            .frame(width: i == 6 ? 170 : 300, height: 8)
                    }
                    Capsule().fill(Style.accent).frame(width: 120, height: 30).padding(.top, 8)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.83, blue: 0.76), Color(red: 0.82, green: 0.86, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 210, height: 210)
            }
            .padding(30)
            Spacer(minLength: 0)
        }
        .frame(width: 640, height: 400)
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}

struct CursorShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 17))
        p.addLine(to: CGPoint(x: 4.2, y: 13))
        p.addLine(to: CGPoint(x: 7, y: 19.5))
        p.addLine(to: CGPoint(x: 9.6, y: 18.4))
        p.addLine(to: CGPoint(x: 6.9, y: 12.2))
        p.addLine(to: CGPoint(x: 12.3, y: 12.2))
        p.closeSubpath()
        return p
    }
}

struct Cursor: View {
    let press: Double
    var body: some View {
        ZStack {
            CursorShape().fill(Color.black)
            CursorShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .frame(width: 13, height: 20)
        .scaleEffect(1 - 0.12 * press, anchor: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

struct Caption: View {
    let a: String, b: String
    let o: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a).foregroundColor(.white)
            Text(b).foregroundColor(.white.opacity(0.5))
        }
        .font(.system(size: 70, weight: .semibold))
        .tracking(-2)
        .opacity(o)
        .offset(y: (1 - easeOut(o)) * 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 120)
        .padding(.bottom, 60)
    }
}

// MARK: - timeline

struct Shot {
    var t = 0.0
    var cursor: CGPoint? = nil
    var press = 0.0
    var ripple: (CGPoint, Double)? = nil
    var cardO = 0.0, cardS = 1.0, cardDY = 0.0
}

var cardOpenedAt: Double? = nil
var leftAt: Double? = nil

let P0 = CGPoint(x: 1010, y: 560)

func frameState(_ t: Double) -> Shot {
    var s = Shot(); s.t = t

    // numbers: a refresh at 7.75s ticks the session up by one
    store.refreshing = t >= 7.75 && t < 8.45
    setLimits(t >= 8.45 ? 36 : 35, t >= 8.45 ? 46 : 45)
    store.fetchedAt = NOW
    store.now = NOW

    let pill = fit(PillView(store: store))
    let pr = CGRect(x: DW - 20 - (pill.width - 2 * PILL_PAD), y: DH - 20 - 30, width: pill.width - 2 * PILL_PAD, height: 30)
    let card = fit(CardView(store: store, onRefresh: {}, onOpen: {}))
    let cw = card.width - 2 * CARD_PAD, ch = card.height - 2 * CARD_PAD
    let cr = CGRect(x: pr.maxX - cw, y: pr.minY - 10 - ch, width: cw, height: ch)
    let pillC = CGPoint(x: pr.midX + 6, y: pr.midY + 2)
    let refreshC = CGPoint(x: cr.maxX - 16 - 46, y: cr.maxY - 12 - 12)
    let away = CGPoint(x: 880, y: 470)

    // cursor path
    var c: CGPoint? = nil
    if t >= 4.3 { c = bez(P0, CGPoint(x: 1120, y: 640), pillC, easeInOut(prog(t, 4.55, 5.35))) }
    if t >= 6.9 { c = bez(pillC, CGPoint(x: refreshC.x + 40, y: refreshC.y + 50), refreshC, easeInOut(prog(t, 6.9, 7.5))) }
    if t >= 8.85 { c = bez(refreshC, CGPoint(x: 1000, y: 560), away, easeInOut(prog(t, 8.85, 9.45))) }
    s.cursor = c
    let cursorIn = { (r: CGRect) in c.map { r.contains($0) } ?? false }

    // clicks
    for (at, pt) in [(5.6, pillC), (7.7, refreshC)] where t >= at - 0.06 && t < at + 0.5 {
        s.press = t < at + 0.08 ? 1 : max(0, 1 - (t - at - 0.08) / 0.1)
        s.ripple = (pt, prog(t, at, at + 0.45))
    }

    store.pillHover = cursorIn(pr)

    // card: opens on the click, closes 0.1s after the pointer leaves
    if t >= 5.62 && cardOpenedAt == nil { cardOpenedAt = 5.62 }
    if let o = cardOpenedAt {
        let zone = pr.union(cr).insetBy(dx: -4, dy: -4)
        if leftAt == nil && t > o + 0.2 && !cursorIn(zone) { leftAt = t }
        let open = easeOutBack(prog(t, o, o + 0.24))
        let shut = leftAt.map { prog(t, $0 + 0.1, $0 + 0.2) } ?? 0
        s.cardO = clamp(prog(t, o, o + 0.18)) * (1 - shut)
        s.cardS = lerp(0.97, 1, open)
        s.cardDY = lerp(6, 0, open)
        store.cardOpen = leftAt == nil || shut < 1
    }
    return s
}

// MARK: - frame

struct Frame: View {
    let s: Shot
    var body: some View {
        let t = s.t
        // camera: wide → zoom on the bottom-right corner
        let z = easeInOut(prog(t, 3.2, 4.5))
        let vw = exp(lerp(log(Double(DW)), log(Double(W) / 2.6), z))
        let vh = vw * Double(H / W)
        let cam = Double(W) / vw
        // zoom around the pill so it never leaves the frame
        let camW = Double(W / DW), vwF = Double(W) / 2.6, camF = 2.6
        let fx = Double(DW) - 80, fy = Double(DH) - 35
        let sxF = (fx - (Double(DW) - vwF - 6)) * camF, syF = (fy - (Double(DH) - vwF * Double(H / W) - 4)) * camF
        let sx = lerp(fx * camW, sxF, z), sy = lerp(fy * camW, syF, z)
        let vx = fx - sx / cam, vy = fy - sy / cam
        _ = vh

        let pill = fit(PillView(store: store))
        let pr = CGRect(x: DW - 20 - (pill.width - 2 * PILL_PAD), y: DH - 20 - 30, width: pill.width - 2 * PILL_PAD, height: 30)
        let card = fit(CardView(store: store, onRefresh: {}, onOpen: {}))
        let cw = card.width - 2 * CARD_PAD, ch = card.height - 2 * CARD_PAD
        let cr = CGRect(x: pr.maxX - cw, y: pr.minY - 10 - ch, width: cw, height: ch)

        let bFront = prog(t, 1.75, 2.05)
        let endO = easeInOut(prog(t, 10.75, 11.35))

        let desk = ZStack(alignment: .topLeading) {
                Wallpaper().frame(width: DW, height: DH)
                Group {
                    if bFront < 0.5 {
                        BrowserWindow().position(x: 940, y: 400)
                        EditorWindow().position(x: 850, y: 290)
                    } else {
                        EditorWindow().opacity(0.92).position(x: 850, y: 290)
                        BrowserWindow().scaleEffect(lerp(0.985, 1, easeOut(bFront))).position(x: 940, y: 400)
                    }
                }
                MenuBar()
                CardView(store: store, onRefresh: {}, onOpen: {})
                    .scaleEffect(s.cardS, anchor: .bottomTrailing)
                    .opacity(s.cardO)
                    .position(x: cr.midX, y: cr.midY + s.cardDY)
                PillView(store: store).fixedSize().position(x: pr.midX, y: pr.midY)
                if let (p, k) = s.ripple, k > 0, k < 1 {
                    Circle().stroke(Color.white.opacity(0.55 * (1 - k)), lineWidth: 1.5)
                        .frame(width: 8 + 34 * k, height: 8 + 34 * k).position(p)
                }
                if let c = s.cursor {
                    Cursor(press: s.press).position(x: c.x + 6.5, y: c.y + 10)
                }
            }
            .frame(width: DW, height: DH)
            .scaleEffect(cam, anchor: .topLeading)
            .offset(x: -vx * cam, y: -vy * cam)
            .frame(width: W, height: H, alignment: .topLeading)

        return ZStack(alignment: .topLeading) {
            desk
            // soft blur + dark wash on the left so captions always read
            desk.blur(radius: 22)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.56, y: 0.5)))
            LinearGradient(colors: [Color.black.opacity(0.72), Color.black.opacity(0.45), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.58, y: 0.5))
                .frame(width: W, height: H)


            Caption(a: "Your Claude usage.", b: "Always on screen.", o: window(t, 0.35, 3.3))
            Caption(a: "35% used.", b: "Resets in 2h 10m.", o: window(t, 3.75, 5.5))
            Caption(a: "Click for details.", b: "Session, weekly, refresh.", o: window(t, 5.85, 8.75))
            Caption(a: "Move away,", b: "and it's gone.", o: window(t, 9.0, 10.7))

            // end card
            ZStack {
                Wallpaper().frame(width: W, height: H)
                Color.black.opacity(0.35)
                VStack(spacing: 0) {
                    PillView(store: store).fixedSize().scaleEffect(3.4).frame(height: 150)
                    Text("Usage Pill").font(.system(size: 96, weight: .semibold)).tracking(-3).foregroundColor(.white)
                        .padding(.top, 70)
                    Text("Your Claude limits, one glance away.").font(.system(size: 36, weight: .medium))
                        .foregroundColor(.white.opacity(0.55)).padding(.top, 14)
                    Text("macOS  ·  Chrome  ·  Free").font(.system(size: 24, weight: .medium)).tracking(1)
                        .foregroundColor(.white.opacity(0.4)).padding(.top, 34)
                }
                .offset(y: (1 - endO) * 20)
            }
            .frame(width: W, height: H)
            .opacity(endO)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - render

let out = FileHandle.standardOutput
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: Int(W) * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
let total = Int(DURATION * FPS)
let only = CommandLine.arguments.dropFirst().first.flatMap(Double.init) // `promo 5.8` → one PNG still at 5.8s

MainActor.assumeIsolated {
    for f in 0..<total {
        let t = Double(f) / FPS
        let s = frameState(t)
        if let only, abs(t - only) > 0.5 / FPS { continue }
        let r = ImageRenderer(content: Frame(s: s))
        r.proposedSize = ProposedViewSize(width: W, height: H)
        r.scale = 1
        guard let img = r.cgImage else { FileHandle.standardError.write("frame \(f) failed\n".data(using: .utf8)!); exit(1) }
        if only != nil {
            let rep = NSBitmapImageRep(cgImage: img)
            out.write(rep.representation(using: .png, properties: [:])!)
            exit(0)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        out.write(Data(bytes: ctx.data!, count: Int(W * H * 4)))
        if f % 60 == 0 { FileHandle.standardError.write("\(f / 60)s ".data(using: .utf8)!) }
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
}
