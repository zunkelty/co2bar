import AppKit
import ServiceManagement

enum AirQuality {
    case good, fair, poor

    init(ppm: Int) {
        if ppm > Config.poorAbove { self = .poor }
        else if ppm >= Config.fairFrom { self = .fair }
        else { self = .good }
    }

    var color: NSColor {
        switch self {
        case .good: return .systemGreen
        case .fair: return .systemYellow
        case .poor: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Open a window"
        }
    }
}

enum DisplayState {
    case needsBoard
    case loading
    case signingIn
    case signedOut
    case reading(Reading)
    case failed(String, last: Reading?)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var honeycomb: Honeycomb?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state = DisplayState.loading
    private var lastReading: Reading?
    private var readingPeriod = Config.defaultReadingPeriod
    private var isFetching = false
    private var pollTask: Task<Void, Never>?
    private let pollingActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "App Nap would delay polls by minutes, leaving the CO₂ value outdated"
    )

    private var isSignedIn: Bool { honeycomb?.isSignedIn ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }

        if let board = Self.boardFromLaunchArguments() {
            if board.host != Board.load()?.host { Honeycomb.forgetTokens() }
            board.save()
            use(board)
        } else if let board = Board.load() {
            use(board)
        } else {
            askForBoard()
        }
    }

    private static func boardFromLaunchArguments() -> Board? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--board"), flag + 1 < arguments.count else { return nil }
        return Board.parse(arguments[flag + 1])
    }

    private func use(_ board: Board) {
        honeycomb = Honeycomb(board: board)
        lastReading = nil
        readingPeriod = Config.defaultReadingPeriod
        if isSignedIn {
            restartPolling()
        } else {
            Task { await signIn() }
        }
    }

    @objc private func askForBoard() {
        guard let board = promptForBoardURL(current: honeycomb?.board.url) else {
            if honeycomb == nil {
                state = .needsBoard
                render()
            }
            return
        }
        if board.host != honeycomb?.board.host {
            Honeycomb.forgetTokens()
        }
        board.save()
        use(board)
    }

    private func promptForBoardURL(current: URL?) -> Board? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://ui.honeycomb.io/<team>/environments/<env>/board/<id>/…"
        field.stringValue = current?.absoluteString ?? ""

        var message = "Paste the link to the Honeycomb board that shows the CO₂ level."
        while true {
            let alert = NSAlert()
            alert.messageText = "Honeycomb board"
            alert.informativeText = message
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if let board = Board.parse(field.stringValue) { return board }
            message = "That is not a Honeycomb board link. It looks like https://ui.honeycomb.io/<team>/environments/<env>/board/<id>/<name>."
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled, await fetch() {
                try? await Task.sleep(for: .seconds(nextPollDelay()))
            }
        }
    }

    // A reading becomes queryable 3–15 s after its timestamp, so poll quickly only in that window.
    private func nextPollDelay() -> TimeInterval {
        guard let lastReading else { return Config.fallbackPollInterval }
        let due = lastReading.time.addingTimeInterval(readingPeriod)
        let untilDue = due.timeIntervalSinceNow
        if untilDue > 0 { return untilDue }
        if untilDue > -Config.burstWindow { return Config.burstPollInterval }
        return Config.fallbackPollInterval
    }

    /// Returns false when polling should stop because there is no signed-in board.
    private func fetch() async -> Bool {
        guard let honeycomb else { return false }
        guard honeycomb.isSignedIn else {
            if case .signingIn = state { return false }
            state = .signedOut
            render()
            return false
        }
        guard !isFetching else { return true }
        isFetching = true
        defer { isFetching = false }
        do {
            let snapshot = try await honeycomb.latestCO2()
            lastReading = snapshot.latest
            readingPeriod = snapshot.readingPeriod ?? readingPeriod
            state = .reading(snapshot.latest)
        } catch HoneycombError.signedOut {
            state = .signedOut
            render()
            return false
        } catch {
            state = .failed(error.localizedDescription, last: lastReading)
        }
        render()
        return true
    }

    @objc private func signInFromMenu() {
        Task { await signIn() }
    }

    private func signIn() async {
        guard let honeycomb else { return }
        state = .signingIn
        render()
        do {
            try await honeycomb.signIn()
            restartPolling()
        } catch {
            state = .failed("Sign-in failed: \(error.localizedDescription)", last: lastReading)
            render()
        }
    }

    @objc private func signOut() {
        pollTask?.cancel()
        honeycomb?.signOut()
        lastReading = nil
        state = .signedOut
        render()
    }

    @objc private func refreshNow() {
        restartPolling()
    }

    @objc private func openBoard() {
        if let url = honeycomb?.board.url { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func render() {
        statusItem.button?.attributedTitle = title()
    }

    private func title() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let text = NSMutableAttributedString()
        func append(_ string: String, color: NSColor = .labelColor) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }

        switch state {
        case .reading(let reading) where !isStale(reading):
            append("● ", color: AirQuality(ppm: reading.ppm).color)
            append("\(reading.ppm) ppm")
        case .reading(let reading), .failed(_, last: .some(let reading)):
            append("● ", color: .tertiaryLabelColor)
            append("\(reading.ppm) ppm", color: .secondaryLabelColor)
        case .needsBoard, .loading, .signingIn, .signedOut, .failed:
            append("CO₂ –", color: .secondaryLabelColor)
        }
        return text
    }

    private func isStale(_ reading: Reading) -> Bool {
        Date().timeIntervalSince(reading.time) > Config.staleAfter
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for line in statusLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if isSignedIn {
            menu.addItem(item("Refresh Now", #selector(refreshNow), key: "r"))
        }
        if honeycomb != nil {
            menu.addItem(item("Open Board in Honeycomb", #selector(openBoard), key: "o"))
        }
        menu.addItem(item(honeycomb == nil ? "Set Board…" : "Change Board…", #selector(askForBoard)))
        menu.addItem(.separator())

        let launchAtLogin = item("Launch at Login", #selector(toggleLaunchAtLogin))
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        if isSignedIn {
            menu.addItem(item("Sign Out of Honeycomb", #selector(signOut)))
        } else if case .signingIn = state {
            menu.addItem(item("Restart Sign-In…", #selector(signInFromMenu)))
        } else if honeycomb != nil {
            menu.addItem(item("Sign In to Honeycomb…", #selector(signInFromMenu)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CO2 Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func statusLines() -> [String] {
        switch state {
        case .needsBoard:
            return ["No Honeycomb board set"]
        case .loading:
            return ["Loading…"]
        case .signingIn:
            return ["Waiting for Honeycomb sign-in in your browser…"]
        case .signedOut:
            return ["Not signed in to Honeycomb"]
        case .reading(let reading):
            return readingLines(reading)
        case .failed(let message, let last):
            return (last.map(readingLines) ?? []) + ["⚠︎ \(message)"]
        }
    }

    private func readingLines(_ reading: Reading) -> [String] {
        let quality = AirQuality(ppm: reading.ppm)
        let age = RelativeDateTimeFormatter().localizedString(for: reading.time, relativeTo: Date())
        let time = reading.time.formatted(date: .omitted, time: .shortened)
        var lines = ["CO₂ \(reading.ppm) ppm · \(quality.label)", "Measured \(time) (\(age))"]
        if isStale(reading) { lines.append("⚠︎ Reading is out of date") }
        return lines
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
