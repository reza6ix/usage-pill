// Usage Pill — app shell: floating windows, local server, menu bar.
// Models and views live in UI.swift (shared with promo/ which renders the demo video).

import AppKit
import SwiftUI
import Network
import Combine
import ServiceManagement

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
    var onHover: (() -> Void)?
    var hotInset: CGFloat = 0          // only the visible shape counts, not the shadow margin
    var dragsWindow = false
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?

    private var downMouse: NSPoint?
    private var downOrigin = NSPoint.zero
    private var dragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.userInfo?["hover"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: hotInset, dy: hotInset),
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: ["hover": true]))
    }
    override func mouseEntered(with e: NSEvent) { super.mouseEntered(with: e); onHover?() }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); onHover?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // Click = toggle the card. Drag (> 3pt) = move the pill.
    override func mouseDown(with e: NSEvent) {
        guard dragsWindow, let w = window else { return super.mouseDown(with: e) }
        downMouse = NSEvent.mouseLocation
        downOrigin = w.frame.origin
        dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragsWindow, let start = downMouse, let w = window else { return super.mouseDragged(with: e) }
        let m = NSEvent.mouseLocation
        let dx = m.x - start.x, dy = m.y - start.y
        if !dragging && hypot(dx, dy) > 3 { dragging = true; onDragStart?() }
        if dragging { w.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy)) }
    }
    override func mouseUp(with e: NSEvent) {
        guard dragsWindow, downMouse != nil else { return super.mouseUp(with: e) }
        if !dragging { onClick?() }
        downMouse = nil
        dragging = false
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
    // Measure with a fresh off-screen copy each time (a reused one never re-measures);
    // the on-screen views don't size their own windows.
    var pillFit: NSSize { NSHostingView(rootView: PillView(store: store)).fittingSize }
    var cardFit: NSSize { NSHostingView(rootView: CardView(store: store, onRefresh: {}, onOpen: {})).fittingSize }
    var statusItem: NSStatusItem!
    var bag = Set<AnyCancellable>()
    var hoverTimer: Timer?
    var leaveWork: DispatchWorkItem?, shrinkWork: DispatchWorkItem?
    var clickMonitor: Any?
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
        pillHost.sizingOptions = [] // we size the windows ourselves; don't let SwiftUI pin a min size
        pillHost.dragsWindow = true
        pillHost.hotInset = PILL_PAD
        pillHost.onHover = { [weak self] in self?.syncHover() }
        pillHost.onClick = { [weak self] in self?.toggleCard() }
        pillHost.onDragStart = { [weak self] in self?.closeCard(animated: false) }
        pill = FloatingPanel(view: pillHost)

        cardHost = HoverHostingView(rootView: CardView(store: store,
                                                       onRefresh: { [weak self] in self?.fetchNow(manual: true) },
                                                       onOpen: { NSWorkspace.shared.open(USAGE_URL) }))
        cardHost.sizingOptions = []
        cardHost.hotInset = CARD_PAD
        cardHost.onHover = { [weak self] in self?.syncHover() }
        card = FloatingPanel(view: cardHost)

        // A click anywhere else on screen closes the card (no extra permissions needed).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.store.cardOpen else { return }
            self.closeCard(animated: true)
        }

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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.fetchNow() }
        // When a window's reset time passes, fetch the fresh numbers instead of waiting for the next poll.
        resetTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.now = Date()
            let fetched = self.store.fetchedAt ?? .distantPast
            let justReset = self.store.limits.contains { l in
                guard let r = l.resetDate else { return false }
                return r <= Date() && fetched < r.addingTimeInterval(30)
            }
            if justReset && Date().timeIntervalSince(self.lastAttempt) > 60 { self.fetchNow() }
        }
    }

    // --- Claude Code source: poll the account's usage directly ---

    var pollTimer: Timer?
    var resetTimer: Timer?

    func fetchNow() {
        fetchNow(manual: false)
    }

    var lastAttempt = Date.distantPast
    var backoff: TimeInterval = 0

    func fetchNow(manual: Bool) {
        let src = store.source
        guard src != Sources.browser, !store.refreshing else { return }
        // While Anthropic has asked us to wait, nothing (not even Refresh) asks again — extra
        // requests only extend the block.
        if let r = store.retryAt, r > Date() { store.now = Date(); return }
        // Anthropic's usage endpoint 429s after a handful of quick calls, so a manual Refresh
        // within a minute of the last request is a no-op.
        if manual && Date().timeIntervalSince(lastAttempt) < 60 { store.now = Date(); return }
        store.refreshing = true
        lastAttempt = Date()
        ClaudeCode.fetch(src) { [weak self] code, json, retryAfter in
            guard let self else { return }
            self.store.refreshing = false
            guard self.store.source == src else { return } // switched accounts mid-request
            switch code {
            case 200:
                self.backoff = 0; self.store.retryAt = nil
                if let json { self.store.applyRaw(json) } else { self.store.status = "error" }
            case -1: self.store.status = "no_login"
            case 401, 403: self.store.status = "expired"
            case 429:
                // Back off: honour Retry-After, else 2 → 4 → 8 … up to 30 minutes.
                self.backoff = min(max(self.backoff * 2, 120), 1800)
                self.store.retryAt = Date().addingTimeInterval(retryAfter ?? self.backoff)
                self.store.status = "rate_limited"
            default: self.store.status = "error"
            }
            self.store.now = Date()
        }
    }

    @objc func pickSource(_ item: NSMenuItem) {
        guard let s = item.representedObject as? String else { return }
        store.setSource(s)
        backoff = 0
        fetchNow(manual: true)
    }
    @objc func refreshFromMenu() { fetchNow(manual: true) }

    // --- layout ---

    func placePill() {
        let size = pillFit
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
        let size = cardFit
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
        let size = pillFit
        if size != lastPillSize {
            shrinkWork?.cancel(); shrinkWork = nil
            if size.width < lastPillSize.width {
                // Let the collapse animation finish before the window gets narrower.
                let w = DispatchWorkItem { [weak self] in self?.placePill() }
                shrinkWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
            } else {
                placePill()
            }
        }
        if card.isVisible { placeCard() }
    }

    // --- hover + click (Wispr Flow style) ---
    // Hover the pill → it widens to show the countdown, instantly.
    // Click the pill → the card opens. Move away or click elsewhere → it closes right away.

    var pillHot: NSRect { pill.frame.insetBy(dx: PILL_PAD, dy: PILL_PAD) }
    var cardHot: NSRect { card.frame.insetBy(dx: CARD_PAD, dy: CARD_PAD) }

    /// Decide hover from the real pointer position against the visible shapes.
    /// Runs on enter/exit and, while anything is open, ~60×/s so exits are never missed.
    func syncHover() {
        let m = NSEvent.mouseLocation
        let inPill = pill.isVisible && pillHot.contains(m)
        if store.pillHover != inPill { store.pillHover = inPill }

        if store.cardOpen {
            // The pill, the card and the small gap between them count as "inside".
            let zone = pillHot.union(cardHot).insetBy(dx: -4, dy: -4)
            if zone.contains(m) {
                leaveWork?.cancel(); leaveWork = nil
            } else if leaveWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.closeCard(animated: true) }
                leaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
            }
        }

        let watching = inPill || store.cardOpen
        if watching, hoverTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.syncHover() }
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        } else if !watching {
            hoverTimer?.invalidate(); hoverTimer = nil
        }
    }

    func toggleCard() { store.cardOpen ? closeCard(animated: true) : openCard() }

    func openCard() {
        guard widgetOn, pill.isVisible else { return }
        leaveWork?.cancel(); leaveWork = nil
        store.cardOpen = true
        placeCard()
        let final = card.frame
        let pillVisible = pillHot
        let dy: CGFloat = final.midY > pillVisible.midY ? -6 : 6
        card.setFrame(final.offsetBy(dx: 0, dy: dy), display: false)
        card.alphaValue = 0
        card.orderFrontRegardless()
        pill.orderFrontRegardless() // keep the pill above the card's transparent margin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            card.animator().alphaValue = 1
            card.animator().setFrame(final, display: true)
        }
        syncHover()
    }

    func closeCard(animated: Bool) {
        leaveWork?.cancel(); leaveWork = nil
        guard store.cardOpen else { return }
        store.cardOpen = false
        syncHover()
        if !animated { card.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.store.cardOpen else { return }
            self.card.orderOut(nil)
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
        for l in store.current {
            let reset = l.resetDate.map { " · resets in \(Fmt.left($0, now: Date()))" } ?? " · \(Fmt.short(l, now: Date()))"
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
        if widgetOn { placePill(); pill.orderFrontRegardless() } else { closeCard(animated: false); pill.orderOut(nil) }
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
        let text = p.map { " \(Int($0.pct.rounded()))% · \(Fmt.short($0, now: store.now))" } ?? " —"
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
