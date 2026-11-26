// Usage Pill — a floating Claude usage widget for macOS.
// Shows over every app and Space. Data is pushed to it by the browser extension
// (POST http://127.0.0.1:47823/usage), so this app never touches your login.

import AppKit
import SwiftUI
import Network
import Combine
import ServiceManagement
import CryptoKit

let PORT: UInt16 = 47823
let USAGE_URL = URL(string: "https://claude.ai/settings/usage")!
let PILL_PAD: CGFloat = 14   // transparent room around the pill for its shadow
let CARD_PAD: CGFloat = 22   // same for the card

// MARK: - Model

struct Limit: Codable, Identifiable, Equatable {
    let key: String
    let label: String
    let pct: Double
    let resetsAt: Double? // ms since epoch
    var id: String { key }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct Payload: Codable {
    let limits: [Limit]?
    let fetchedAt: Double?
    let status: String?
}

// Where the numbers come from: a Claude Code config folder (its own login, read from
// the macOS Keychain), or the browser extension (whatever account claude.ai is logged into).
let HOME = NSHomeDirectory()
enum Sources {
    static let browser = "browser"
    static func all() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: HOME)) ?? []
        let dirs = names.filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted().map { HOME + "/" + $0 }
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
        return dirs + [browser]
    }
    static func label(_ s: String) -> String {
        if s == browser { return "browser" }
        let n = (s as NSString).lastPathComponent
        return n == ".claude" ? "Claude Code" : String(n.dropFirst(".claude-".count))
    }
    static func menuTitle(_ s: String) -> String {
        s == browser ? "Browser extension (claude.ai login)" : "Claude Code · ~/\((s as NSString).lastPathComponent)"
    }
    static var fallback: String { all().first { $0 == HOME + "/.claude" } ?? all().first ?? browser }
}

final class Store: ObservableObject {
    @Published var limits: [Limit] = []
    @Published var fetchedAt: Date?
    @Published var status: String?
    @Published var lastPush: Date?
    @Published var now = Date()
    @Published var pillHover = false
    @Published var refreshing = false
    @Published var source: String

    private var timer: Timer?
    private var saveKey: String { "lastPayload|" + source }

    init() {
        let saved = UserDefaults.standard.string(forKey: "source")
        source = saved.flatMap { Sources.all().contains($0) ? $0 : nil } ?? Sources.fallback
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.now = Date() }
    }

    var isBrowser: Bool { source == Sources.browser }

    func setSource(_ s: String) {
        guard s != source else { return }
        source = s
        UserDefaults.standard.set(s, forKey: "source")
        limits = []; fetchedAt = nil; status = nil
        restore()
    }

    private func restore() {
        if let d = UserDefaults.standard.data(forKey: saveKey),
           let p = try? JSONDecoder().decode(Payload.self, from: d) { apply(p) }
    }

    private func persist() {
        let p = Payload(limits: limits, fetchedAt: fetchedAt.map { $0.timeIntervalSince1970 * 1000 }, status: status)
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: saveKey) }
    }

    /** From the browser extension. Only used when the browser is the chosen source. */
    func ingest(_ data: Data) {
        lastPush = Date()
        guard isBrowser, let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        apply(p)
        if !limits.isEmpty { persist() }
    }

    /** From api.anthropic.com/api/oauth/usage (Claude Code login). */
    func applyRaw(_ raw: [String: Any]) {
        let l = normalize(raw)
        guard !l.isEmpty else { status = "error"; return }
        limits = l
        fetchedAt = Date()
        status = "ok"
        now = Date()
        persist()
    }

    private func apply(_ p: Payload) {
        if let l = p.limits, !l.isEmpty { limits = l }
        if let f = p.fetchedAt { fetchedAt = Date(timeIntervalSince1970: f / 1000) }
        status = p.status
        now = Date()
    }

    var primary: Limit? { limits.first { $0.key == "five_hour" } ?? limits.first }
    var stale: Bool { fetchedAt.map { now.timeIntervalSince($0) > 10 * 60 } ?? true }
    var browserConnected: Bool { lastPush.map { now.timeIntervalSince($0) < 5 * 60 } ?? false }
}

let LABELS = ["five_hour": "Session · 5h", "seven_day": "Weekly · all models", "seven_day_opus": "Weekly · Opus",
              "seven_day_sonnet": "Weekly · Sonnet", "seven_day_oauth_apps": "Weekly · apps"]
let ORDER = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"]

func parseISO(_ s: String) -> Date? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

func normalize(_ raw: [String: Any]) -> [Limit] {
    var out: [Limit] = []
    for (k, v) in raw {
        guard let d = v as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
        let ts = (d["resets_at"] as? String).flatMap(parseISO).map { $0.timeIntervalSince1970 * 1000 }
        out.append(Limit(key: k, label: LABELS[k] ?? k.replacingOccurrences(of: "_", with: " ").capitalized,
                         pct: min(100, max(0, u)), resetsAt: ts))
    }
    return out.sorted { (ORDER.firstIndex(of: $0.key) ?? 99, $0.key) < (ORDER.firstIndex(of: $1.key) ?? 99, $1.key) }
}

// MARK: - Claude Code login → usage

enum ClaudeCode {
    /// Claude Code's Keychain item: plain for ~/.claude, suffixed with a hash of the folder otherwise.
    static func keychainService(_ dir: String) -> String {
        if dir == HOME + "/.claude" { return "Claude Code-credentials" }
        let h = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + h.prefix(8)
    }

    /// Reads the access token. Never logged, never stored, never refreshed (refreshing would sign Claude Code out).
    static func accessToken(_ dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService(dir), "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var data = Data()
        if (try? p.run()) != nil {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { data = Data() }
        }
        if data.isEmpty { data = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/.credentials.json"))) ?? Data() }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static func fetch(_ dir: String, done: @escaping (Int, [String: Any]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = accessToken(dir) else { return DispatchQueue.main.async { done(-1, nil) } }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async { done(code, json) }
            }.resume()
        }
    }
}


// MARK: - Formatting

enum Fmt {
    static func left(_ d: Date?, now: Date) -> String {
        guard let d else { return "—" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let m = Int((s / 60).rounded(.up))
        if m < 60 { return "\(m)m" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm > 0 ? "\(h)h \(mm)m" : "\(h)h" }
        let dd = h / 24, hh = h % 24
        return hh > 0 ? "\(dd)d \(hh)h" : "\(dd)d"
    }
    static func resetAt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }
    static func ago(_ d: Date?, now: Date) -> String {
        guard let d else { return "never" }
        let s = Int(now.timeIntervalSince(d))
        if s < 30 { return "just now" }
        if s < 3600 { return "\(max(1, s / 60))m ago" }
        return "\(s / 3600)h ago"
    }
}

// MARK: - Style

enum Style {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let fg = Color(red: 0.96, green: 0.96, blue: 0.957)
    static let muted = Color(red: 0.96, green: 0.96, blue: 0.957).opacity(0.46)
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let rose = Color(red: 0.984, green: 0.443, blue: 0.522)
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)
    static func level(_ pct: Double) -> Color { pct >= 80 ? rose : pct >= 50 ? amber : fg }
}

// MARK: - Views

struct Ring: View {
    let pct: Double?
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.6)
            if let pct, pct > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(max(pct, 2) / 100))
                    .stroke(Style.level(pct), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.5), value: pct)
    }
}

struct PillView: View {
    @ObservedObject var store: Store
    var body: some View {
        let p = store.primary
        HStack(spacing: 8) {
            Ring(pct: p?.pct)
            Text(p.map { "\(Int($0.pct.rounded()))%" } ?? "—")
                .font(.system(size: 12, weight: .semibold))
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 12)
            Text(p.map { $0.resetDate == nil ? "idle" : Fmt.left($0.resetDate, now: store.now) } ?? "Claude")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Style.fg.opacity(0.6))
        }
        .monospacedDigit()
        .foregroundColor(Style.fg)
        .padding(.leading, 9).padding(.trailing, 13)
        .frame(height: 30)
        .background(Capsule().fill(Style.bg))
        .overlay(Capsule().strokeBorder(Color.white.opacity(store.pillHover ? 0.2 : 0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
        .scaleEffect(store.pillHover ? 1.04 : 1, anchor: .trailing)
        .opacity(store.stale && !store.limits.isEmpty ? 0.6 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.pillHover)
        .padding(PILL_PAD)
        .fixedSize()
    }
}

struct Meter: View {
    let pct: Double
    var body: some View {
        let n = 24
        let on = pct > 0 ? max(1, Int((pct / 100 * Double(n)).rounded())) : 0
        let c = Style.level(pct)
        HStack(spacing: 3) {
            ForEach(0..<n, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i < on ? c : Color.white.opacity(0.08))
                    .frame(height: 7)
                    .shadow(color: i < on && pct >= 50 ? c.opacity(0.45) : .clear, radius: 4)
            }
        }
    }
}

struct LimitRow: View {
    let limit: Limit
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(limit.label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.9)
                .foregroundColor(Style.muted)
                .padding(.bottom, 6)
            HStack(alignment: .bottom) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(Int(limit.pct.rounded()))")
                        .font(.system(size: 30, weight: .semibold)).tracking(-1.2)
                        .foregroundColor(limit.pct >= 50 ? Style.level(limit.pct) : Style.fg)
                    Text("%").font(.system(size: 15, weight: .medium)).foregroundColor(Style.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(limit.resetDate != nil ? Fmt.left(limit.resetDate, now: now) : "—")
                        .font(.system(size: 13, weight: .semibold))
                    Text(limit.resetDate.map { "resets \(Fmt.resetAt($0))" } ?? "starts on next message")
                        .font(.system(size: 11)).foregroundColor(Style.muted)
                }
            }
            .monospacedDigit()
            Meter(pct: limit.pct).padding(.top, 10)
        }
    }
}

struct CardView: View {
    @ObservedObject var store: Store
    let onRefresh: () -> Void
    let onOpen: () -> Void

    var message: String {
        switch store.status {
        case "no_login": return "No Claude Code login found for ~/\((store.source as NSString).lastPathComponent). Run Claude Code there once, then hit Refresh."
        case "expired": return "Claude Code's login for this account expired. Run it once (it refreshes itself), then hit Refresh."
        case "signed_out": return "You're signed out of claude.ai in your browser."
        case "error": return "Couldn't load usage. Check your connection and hit Refresh."
        default:
            if store.isBrowser && store.lastPush == nil { return "Waiting for the browser extension. Keep your browser open with Usage Pill installed." }
            return "Loading…"
        }
    }

    var footer: String {
        if store.isBrowser && !store.browserConnected && store.fetchedAt != nil { return "Browser closed · \(Fmt.ago(store.fetchedAt, now: store.now))" }
        if store.status == "expired" || store.status == "error" || store.status == "no_login" { return store.fetchedAt == nil ? "Not updated" : "Offline · \(Fmt.ago(store.fetchedAt, now: store.now))" }
        return "Updated \(Fmt.ago(store.fetchedAt, now: store.now))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Style.accent).frame(width: 6, height: 6).shadow(color: Style.accent.opacity(0.8), radius: 5)
                Text("Claude usage").font(.system(size: 12, weight: .semibold))
                Text(Sources.label(store.source)).font(.system(size: 11, weight: .medium)).foregroundColor(Style.muted)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .padding(.bottom, 16)

            if store.limits.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(Style.fg.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(store.limits.enumerated()), id: \.element.id) { i, l in
                    LimitRow(limit: l, now: store.now).padding(.top, i == 0 ? 0 : 18)
                }
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.top, 18)
            HStack(spacing: 6) {
                Text(footer).font(.system(size: 11)).foregroundColor(Style.muted)
                Spacer()
                if store.isBrowser {
                    PillButton(title: "Usage page", icon: "arrow.up.right", action: onOpen)
                } else {
                    PillButton(title: store.refreshing ? "Refreshing" : "Refresh", icon: "arrow.clockwise",
                               spinning: store.refreshing, action: onRefresh)
                }
            }
            .padding(.top, 12)
        }
        .foregroundColor(Style.fg)
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Style.bg))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .padding(CARD_PAD)
        .fixedSize()
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    var spinning = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: spinning)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Windows

final class FloatingPanel: NSPanel {
    init(view: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = view
    }
    override var canBecomeKey: Bool { true }
}

final class HoverHostingView<V: View>: NSHostingView<V> {
    var onHover: ((Bool) -> Void)?
    var dragsWindow = false
    var onMouseDown: ((NSEvent) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.userInfo?["hover"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }
    override func mouseEntered(with e: NSEvent) { super.mouseEntered(with: e); onHover?(true) }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); onHover?(false) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard dragsWindow else { return super.mouseDown(with: e) }
        onMouseDown?(e)
        if e.clickCount < 2 { window?.performDrag(with: e) }
    }
}

// MARK: - Local server (receives usage from the extension)

final class Server {
    private var listener: NWListener?

    init(port: UInt16, onData: @escaping (Data) -> Void) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            Server.read(c, Data(), onData)
        }
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("UsagePill: server failed: \(err)") }
        }
        l.start(queue: .main)
        listener = l
    }

    private static func read(_ c: NWConnection, _ buffer: Data, _ onData: @escaping (Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let len = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[r.upperBound...]
                if body.count >= len {
                    if head.hasPrefix("POST /usage") { onData(Data(body.prefix(len))) }
                    let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                    c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
                    return
                }
            }
            if done || err != nil || buf.count > 1_000_000 { c.cancel(); return }
            read(c, buf, onData)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var server: Server?
    var pill: FloatingPanel!
    var card: FloatingPanel!
    var pillHost: HoverHostingView<PillView>!
    var cardHost: HoverHostingView<CardView>!
    var statusItem: NSStatusItem!
    var bag = Set<AnyCancellable>()
    var overPill = false, overCard = false
    var showWork: DispatchWorkItem?, hideWork: DispatchWorkItem?
    var lastPillSize = NSSize.zero
    var placing = false

    let defaults = UserDefaults.standard
    var widgetOn: Bool {
        get { defaults.object(forKey: "widgetOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "widgetOn") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        server = Server(port: PORT) { [weak self] d in self?.store.ingest(d) }

        pillHost = HoverHostingView(rootView: PillView(store: store))
        pillHost.dragsWindow = true
        pillHost.onHover = { [weak self] h in self?.overPill = h; self?.store.pillHover = h; self?.hoverChanged() }
        pillHost.onMouseDown = { [weak self] e in
            self?.hideCard(animated: false)
            if e.clickCount == 2 { self?.resetPosition() }
        }
        pill = FloatingPanel(view: pillHost)

        cardHost = HoverHostingView(rootView: CardView(store: store,
                                                       onRefresh: { [weak self] in self?.fetchNow() },
                                                       onOpen: { NSWorkspace.shared.open(USAGE_URL) }))
        cardHost.onHover = { [weak self] h in self?.overCard = h; self?.hoverChanged() }
        card = FloatingPanel(view: cardHost)

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: pill, queue: .main) { [weak self] _ in
            guard let self, !self.placing else { return }
            self.defaults.set(self.pill.frame.maxX, forKey: "anchorMaxX")
            self.defaults.set(self.pill.frame.minY, forKey: "anchorMinY")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placePill()
        }

        setupStatusItem()
        placePill()
        if widgetOn { pill.orderFrontRegardless() }

        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &bag)
        refresh()

        fetchNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.fetchNow() }
    }

    // --- Claude Code source: poll the account's usage directly ---

    var pollTimer: Timer?

    func fetchNow() {
        let src = store.source
        guard src != Sources.browser, !store.refreshing else { return }
        store.refreshing = true
        ClaudeCode.fetch(src) { [weak self] code, json in
            guard let self else { return }
            self.store.refreshing = false
            guard self.store.source == src else { return } // switched accounts mid-request
            switch code {
            case 200: if let json { self.store.applyRaw(json) } else { self.store.status = "error" }
            case -1: self.store.status = "no_login"
            case 401, 403: self.store.status = "expired"
            default: self.store.status = "error"
            }
        }
    }

    @objc func pickSource(_ item: NSMenuItem) {
        guard let s = item.representedObject as? String else { return }
        store.setSource(s)
        fetchNow()
    }
    @objc func refreshFromMenu() { fetchNow() }

    // --- layout ---

    func placePill() {
        let size = pillHost.fittingSize
        lastPillSize = size
        let screens = NSScreen.screens
        var maxX = defaults.object(forKey: "anchorMaxX") as? CGFloat
        var minY = defaults.object(forKey: "anchorMinY") as? CGFloat
        // Forget a saved spot that's no longer on any screen.
        if let x = maxX, let y = minY,
           !screens.contains(where: { $0.frame.insetBy(dx: -PILL_PAD, dy: -PILL_PAD).contains(NSPoint(x: x - size.width / 2, y: y + size.height / 2)) }) {
            maxX = nil; minY = nil
        }
        if maxX == nil || minY == nil {
            let vf = (NSScreen.main ?? screens[0]).visibleFrame
            maxX = vf.maxX - 20 + PILL_PAD
            minY = vf.minY + 20 - PILL_PAD
        }
        placing = true
        pill.setFrame(NSRect(x: maxX! - size.width, y: minY!, width: size.width, height: size.height), display: true)
        placing = false
    }

    func resetPosition() {
        defaults.removeObject(forKey: "anchorMaxX")
        defaults.removeObject(forKey: "anchorMinY")
        placePill()
    }

    func placeCard() {
        let size = cardHost.fittingSize
        let pf = pill.frame
        let screen = (pill.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let pillVisible = pf.insetBy(dx: PILL_PAD, dy: PILL_PAD)
        let above = pillVisible.midY < screen.midY
        let rightAligned = pillVisible.midX > screen.midX
        var x = rightAligned ? pillVisible.maxX + CARD_PAD - size.width : pillVisible.minX - CARD_PAD
        x = min(max(x, screen.minX - CARD_PAD + 8), screen.maxX - size.width + CARD_PAD - 8)
        let y = above ? pillVisible.maxY + 10 - CARD_PAD : pillVisible.minY - 10 - size.height + CARD_PAD
        card.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func refresh() {
        updateStatusItem()
        let size = pillHost.fittingSize
        if size != lastPillSize { placePill() }
        if card.isVisible { placeCard() }
    }

    // --- hover card ---

    func hoverChanged() {
        showWork?.cancel(); hideWork?.cancel()
        if overPill || overCard {
            guard !card.isVisible || card.alphaValue < 1 else { return }
            let w = DispatchWorkItem { [weak self] in self?.showCard() }
            showWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
        } else {
            let w = DispatchWorkItem { [weak self] in self?.hideCard(animated: true) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    func showCard() {
        guard widgetOn, pill.isVisible else { return }
        placeCard()
        let final = card.frame
        let pillVisible = pill.frame.insetBy(dx: PILL_PAD, dy: PILL_PAD)
        let dy: CGFloat = final.midY > pillVisible.midY ? -8 : 8
        card.setFrame(final.offsetBy(dx: 0, dy: dy), display: false)
        card.alphaValue = 0
        card.orderFrontRegardless()
        pill.orderFrontRegardless() // keep the pill above the card's transparent margin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.1)
            card.animator().alphaValue = 1
            card.animator().setFrame(final, display: true)
        }
    }

    func hideCard(animated: Bool) {
        guard card.isVisible else { return }
        if !animated { card.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.overPill || self.overCard {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; self.card.animator().alphaValue = 1 }
            } else {
                self.card.orderOut(nil)
            }
        })
    }

    // --- menu bar ---

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for l in store.limits {
            let reset = l.resetDate.map { " · resets in \(Fmt.left($0, now: Date()))" } ?? ""
            let item = NSMenuItem(title: "\(l.label): \(Int(l.pct.rounded()))%\(reset)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if store.limits.isEmpty {
            let item = NSMenuItem(title: store.isBrowser ? "Waiting for the browser extension…" : "No data yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !store.isBrowser {
            menu.addItem(withTitle: "Refresh now", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        }
        menu.addItem(.separator())

        let account = NSMenuItem(title: "Account: \(Sources.label(store.source))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in Sources.all() {
            let i = NSMenuItem(title: Sources.menuTitle(s), action: #selector(pickSource(_:)), keyEquivalent: "")
            i.representedObject = s
            i.state = s == store.source ? .on : .off
            i.target = self
            sub.addItem(i)
        }
        account.submenu = sub
        menu.addItem(account)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Show floating widget", action: #selector(toggleWidget), keyEquivalent: "")
        toggle.state = widgetOn ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(withTitle: "Reset widget position", action: #selector(resetFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Claude usage page", action: #selector(openUsage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Usage Pill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggleWidget() {
        widgetOn.toggle()
        if widgetOn { placePill(); pill.orderFrontRegardless() } else { card.orderOut(nil); pill.orderOut(nil) }
    }
    @objc func resetFromMenu() { resetPosition() }
    @objc func openUsage() { NSWorkspace.shared.open(USAGE_URL) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    func updateStatusItem() {
        guard let b = statusItem.button else { return }
        let p = store.primary
        b.image = ringImage(p?.pct)
        b.imagePosition = .imageLeading
        let text = p.map { " \(Int($0.pct.rounded()))%" + ($0.resetDate.map { " · \(Fmt.left($0, now: store.now))" } ?? "") } ?? " —"
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        b.alphaValue = store.stale && !store.limits.isEmpty ? 0.6 : 1
    }

    func ringImage(_ pct: Double?) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let rect = r.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = 2.3
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()
            if let pct, pct > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: rect.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(max(pct, 2)) / 100, clockwise: true)
                arc.lineWidth = 2.3
                arc.lineCapStyle = .round
                (pct >= 80 ? NSColor.systemRed : pct >= 50 ? NSColor.systemOrange : NSColor.labelColor).setStroke()
                arc.stroke()
            }
            return true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon
app.run()
