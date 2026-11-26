// Usage Pill — models and SwiftUI views (shared by the app and promo/, which renders the demo video).
// Numbers come from a Claude Code login (Keychain) or the browser extension (POST 127.0.0.1:47823/usage).

import AppKit
import SwiftUI
import Network
import Combine
import ServiceManagement
import CryptoKit
import os

let LOG = Logger(subsystem: "com.reza6ix.usagepill", category: "fetch")

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
    var assumedReset: Bool? = nil // its reset time passed and we have no fresh numbers yet
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
    @Published var cardOpen = false
    @Published var refreshing = false
    /// Set when Anthropic says "slow down" (HTTP 429). Saved, so restarting the app doesn't skip the wait.
    @Published var retryAt: Date? = UserDefaults.standard.object(forKey: "retryAt") as? Date {
        didSet { UserDefaults.standard.set(retryAt, forKey: "retryAt") }
    }
    var waiting: Bool { retryAt.map { $0 > now } ?? false }
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

    /// Limits as they stand right now: once a window's reset time has passed it is back to 0%,
    /// even before the next fetch confirms it (never show a stale "100% · now").
    var current: [Limit] {
        limits.map { l in
            guard let r = l.resetDate, r <= now else { return l }
            return Limit(key: l.key, label: l.label, pct: 0, resetsAt: nil, assumedReset: true)
        }
    }
    var primary: Limit? { current.first { $0.key == "five_hour" } ?? current.first }
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

    static func fetch(_ dir: String, done: @escaping (Int, [String: Any]?, TimeInterval?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = accessToken(dir) else { return DispatchQueue.main.async { done(-1, nil, nil) } }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData // never show a cached, stale answer
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                // Status code only — never the token or the response body.
                LOG.notice("usage fetch: HTTP \(code, privacy: .public), retry-after \(retry.map { String(Int($0)) } ?? "none", privacy: .public)")
                DispatchQueue.main.async { done(code, json, retry) }
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
    /// Pill / menu-bar text for a limit's time slot.
    static func short(_ l: Limit, now: Date) -> String {
        if l.assumedReset == true { return "reset" }        // window just ended; fresh numbers on the way
        if l.resetDate == nil { return "not started" }      // no 5h window running until you send a message
        return left(l.resetDate, now: now)
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

// Always: ring · 35% │ 2h 10m. Hover just lifts it a touch; click opens the card.
struct PillView: View {
    @ObservedObject var store: Store
    var body: some View {
        let p = store.primary
        let lit = store.pillHover || store.cardOpen
        HStack(spacing: 7) {
            Ring(pct: p?.pct)
            Text(p.map { "\(Int($0.pct.rounded()))%" } ?? "—")
                .font(.system(size: 12, weight: .semibold))
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 12)
            Text(p.map { Fmt.short($0, now: store.now) } ?? "Claude")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Style.fg.opacity(0.62))
        }
        .monospacedDigit()
        .lineLimit(1)
        .foregroundColor(Style.fg)
        .padding(.leading, 9).padding(.trailing, 12)
        .frame(height: 30)
        .background(Capsule().fill(Style.bg))
        .overlay(Capsule().strokeBorder(Color.white.opacity(lit ? 0.22 : 0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
        .scaleEffect(lit ? 1.03 : 1, anchor: .trailing)
        .opacity(store.stale && !store.limits.isEmpty ? 0.6 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: lit)
        .padding(PILL_PAD)
        .fixedSize()
        // Grow to the left: the right edge stays put while the window resizes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
                    Text(limit.assumedReset == true ? "reset" : limit.resetDate != nil ? Fmt.left(limit.resetDate, now: now) : "—")
                        .font(.system(size: 13, weight: .semibold))
                    Text(limit.assumedReset == true ? "updating…" : limit.resetDate.map { "resets \(Fmt.resetAt($0))" } ?? "starts with your next message")
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
        case "rate_limited": return "Anthropic asked us to slow down. It retries automatically in a few minutes."
        default:
            if store.isBrowser && store.lastPush == nil { return "Waiting for the browser extension. Keep your browser open with Usage Pill installed." }
            return "Loading…"
        }
    }

    var footer: String {
        if store.isBrowser && !store.browserConnected && store.fetchedAt != nil { return "Browser closed · \(Fmt.ago(store.fetchedAt, now: store.now))" }
        // Say *why* it isn't updating, not just "Offline".
        let ago = store.fetchedAt == nil ? "" : " · data \(Fmt.ago(store.fetchedAt, now: store.now))"
        switch store.status {
        case "expired": return "Login expired" + ago
        case "no_login": return "No Claude Code login"
        case "rate_limited":
            if let r = store.retryAt, r > store.now { return "Busy · retry in \(Fmt.left(r, now: store.now))" }
            return "Busy · retrying" + ago
        case "error": return "Can't reach Anthropic" + ago
        default: break
        }
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
                ForEach(Array(store.current.enumerated()), id: \.element.id) { i, l in
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
                    PillButton(title: store.refreshing ? "Refreshing" : store.waiting ? "Wait \(Fmt.left(store.retryAt, now: store.now))" : "Refresh",
                               icon: store.waiting ? "hourglass" : "arrow.clockwise",
                               spinning: store.refreshing, action: onRefresh)
                        .disabled(store.waiting).opacity(store.waiting ? 0.5 : 1)
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


