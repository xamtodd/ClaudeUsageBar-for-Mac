import SwiftUI
import AppKit
import ServiceManagement

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(model: model)
        } label: {
            // Menüleiste: "5h 42% · W 18%"
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - ViewModel

@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var error: String?
    @Published var lastUpdate: Date?
    @Published var isLoading = false
    @Published var now = Date()

    @Published var tokenStats: TokenStats?

    /// Liegt im Schlüsselbund, nicht im Klartext in UserDefaults
    @Published var sessionKey: String = SessionKeyStore.load() {
        didSet { SessionKeyStore.save(sessionKey) }
    }
    /// Mindestens 30 s – bei Rate-Limit (429) verlängert das Backoff automatisch
    @Published var refreshSeconds: Double = {
        let v = UserDefaults.standard.double(forKey: "refreshSeconds")
        return v > 0 ? max(30, v) : 120
    }() {
        didSet { UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds") }
    }

    private var fetchTimer: Timer?
    private var clockTimer: Timer?

    /// Wird bei Rate-Limit (429) verdoppelt, bei Erfolg zurückgesetzt
    private var backoffFactor: Double = 1

    init() {
        Task { await refresh() }
        scheduleFetchTimer()
        // Countdown jede 30 s aktualisieren
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // Nach Aufwachen sofort neu laden
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func scheduleFetchTimer() {
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: max(30, refreshSeconds) * backoffFactor, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        // Timer, Klick und Aufwachen können gleichzeitig auslösen → nur ein Abruf auf einmal
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            usage = try await UsageService.fetch(sessionKey: sessionKey)
            error = nil
            lastUpdate = Date()
            now = Date()
            if backoffFactor != 1 { backoffFactor = 1; scheduleFetchTimer() }
        } catch UsageError.http(429, _) {
            backoffFactor = min(backoffFactor * 2, 10)
            scheduleFetchTimer()
            let next = Int(max(30, refreshSeconds) * backoffFactor)
            self.error = "Rate-Limit erreicht – nächster Versuch in \(next >= 60 ? "\(next / 60) min" : "\(next) s")."
        } catch {
            self.error = error.localizedDescription
        }
        // Lokale Zahlen auch dann, wenn die API gerade nicht antwortet
        await refreshTokenStats()
    }

    /// Lokale Token-Zahlen aus den Claude-Code-Logs, passend zu den API-Fenstern
    func refreshTokenStats() async {
        let now = Date()
        let fiveStart = usage?.fiveHour?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) } ?? now.addingTimeInterval(-5 * 3600)
        let weekStart = usage?.sevenDay?.resetsAt.map { $0.addingTimeInterval(-7 * 86400) } ?? now.addingTimeInterval(-7 * 86400)
        tokenStats = await TokenScanner.shared.stats(fiveHourStart: fiveStart, weekStart: weekStart)
    }

    @Published var showResetInBar: Bool = UserDefaults.standard.object(forKey: "showResetInBar") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showResetInBar, forKey: "showResetInBar") }
    }

    /// z. B. "5h 42% ↻14:00 │ W 18% ↻Mo 09:00"
    var menuBarTitle: String {
        guard let u = usage else { return error == nil ? "Claude …" : "Claude ⚠︎" }
        func part(_ name: String, _ w: UsageWindow?) -> String {
            var t = "\(name) \(Self.pct(w?.utilization))"
            if showResetInBar, let r = w?.resetsAt { t += " ↻\(Self.shortReset(r))" }
            return t
        }
        let warn = error != nil ? " ⚠︎" : ""
        return "\(part("5h", u.fiveHour)) │ \(part("W", u.sevenDay))\(warn)"
    }

    /// Auf volle Minute gerundet (API liefert z. B. 13:59:59.8)
    static func rounded(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// heute → "14:00", sonst "Mo 09:00"
    static func shortReset(_ d: Date) -> String {
        let r = rounded(d)
        let f = Calendar.current.isDateInToday(r) ? Formatters.time : Formatters.weekdayTime
        return f.string(from: r).replacingOccurrences(of: ".", with: "")
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
    }
}

// MARK: - Panel

struct UsagePanel: View {
    @ObservedObject var model: UsageModel
    @State private var showSettings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Jetzt aktualisieren")
            }

            if let u = model.usage {
                UsageRow(title: "5-Stunden-Limit", window: u.fiveHour, now: model.now)
                UsageRow(title: "Wochenlimit", window: u.sevenDay, now: model.now)
                if let opus = u.sevenDayOpus, opus.utilization != nil {
                    UsageRow(title: "Woche (Opus)", window: opus, now: model.now)
                }
                if let sonnet = u.sevenDaySonnet, sonnet.utilization != nil {
                    UsageRow(title: "Woche (Sonnet)", window: sonnet, now: model.now)
                }
            }

            TokenSection(stats: model.tokenStats)

            if let err = model.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(model.usage == nil ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if showSettings {
                VStack(alignment: .leading, spacing: 8) {
                    Text("claude.ai sessionKey (nur nötig ohne Claude Code)")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-ant-sid01-…", text: $model.sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            UserDefaults.standard.removeObject(forKey: "orgID")
                            Task { await model.refresh() }
                        }
                    HStack {
                        Text("Intervall")
                        Picker("", selection: $model.refreshSeconds) {
                            Text("30 s").tag(30.0)
                            Text("1 min").tag(60.0)
                            Text("2 min").tag(120.0)
                            Text("5 min").tag(300.0)
                        }
                        .labelsHidden()
                        .onChange(of: model.refreshSeconds) { _ in model.scheduleFetchTimer() }
                    }
                    Toggle("Reset-Uhrzeit in der Menüleiste", isOn: $model.showResetInBar)
                    Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                model.error = "Autostart: \(error.localizedDescription)"
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }

            HStack {
                if let t = model.lastUpdate {
                    Text("Stand \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(showSettings ? "Fertig" : "Einstellungen") { showSettings.toggle() }
                    .buttonStyle(.borderless)
                Button("Beenden") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowHeightFitter())
    }
}

// MARK: - Token-Anzeige

struct TokenSection: View {
    let stats: TokenStats?   // nil = erster Scan läuft noch
    @AppStorage("tokensExpanded") private var expanded = false
    @AppStorage("tokensWeek") private var week = false

    private var s: TokenSummary {
        guard let stats else { return TokenSummary() }
        return week ? stats.week : stats.fiveHour
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Tokens (Claude Code)").font(.subheadline.weight(.medium))
                    Spacer()
                    if stats == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        // Input + Output: Cache-Lesen ist sehr günstig und würde die Zahl aufblähen
                        Text(Self.fmt(s.totals.io))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .help("Input + Output (\(week ? "Woche" : "5-Stunden-Fenster")), ohne Cache")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, stats == nil {
                Text("Claude-Code-Logs werden gelesen …")
                    .font(.caption).foregroundStyle(.secondary)
            } else if expanded {
                Picker("", selection: $week) {
                    Text("5-Stunden-Fenster").tag(false)
                    Text("Woche").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if s.requests == 0 {
                    Text("Keine Claude-Code-Anfragen in diesem Zeitraum.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                        row("Input", s.totals.input)
                        row("Output", s.totals.output)
                        row("Cache lesen", s.totals.cacheRead)
                        row("Cache schreiben", s.totals.cacheWrite)
                        row("Anfragen", s.requests, plain: true)
                        GridRow {
                            Text("Gesamt inkl. Cache").foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.fmt(s.totals.total)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)

                    section("Nach Modell", s.byModel)
                    section("Top-Projekte", Array(s.byProject.prefix(3)))
                }
            }
        }
    }

    private func row(_ label: String, _ value: Int, plain: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(plain ? "\(value)" : Self.fmt(value)).monospacedDigit()
        }
    }

    private func section(_ title: String, _ items: [(name: String, counts: TokenCounts)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium))
            ForEach(items, id: \.name) { item in
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Self.fmt(item.counts.io)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 1234 → "1.234", 345_678 → "346 Tsd", 12_345_678 → "12,3 Mio"
    static func fmt(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1f Mio", Double(n) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        case 100_000...: return "\(Int((Double(n) / 1000).rounded())) Tsd"
        default: return n.formatted(.number.locale(Locale(identifier: "de_DE")))
        }
    }
}

// MARK: - Formatter (einmal erzeugt statt bei jedem Neuzeichnen)

enum Formatters {
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = format
        return f
    }
    static let time = make("HH:mm")
    static let weekdayTime = make("EEE HH:mm")
    static let today = make("'heute um' HH:mm 'Uhr'")
    static let tomorrow = make("'morgen um' HH:mm 'Uhr'")
    static let later = make("EE, dd.MM. 'um' HH:mm 'Uhr'")
}

// MARK: - Fensterhöhe

/// MenuBarExtra(.window) passt die Fensterhöhe nicht zuverlässig an, wenn der Inhalt
/// kleiner wird (z. B. verschwundene Fehlermeldung) – dann bleibt unten ein leerer Rand.
/// Dieser Helfer setzt die Fensterhöhe bei jeder Größenänderung auf die Inhaltshöhe,
/// die Oberkante (unter der Menüleiste) bleibt dabei fest.
private struct WindowHeightFitter: View {
    var body: some View {
        GeometryReader { geo in
            Fitter(height: geo.size.height)
        }
    }

    private struct Fitter: NSViewRepresentable {
        let height: CGFloat
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            let height = height
            DispatchQueue.main.async {
                guard let window = view.window, height > 0 else { return }
                let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: height)).height
                var frame = window.frame
                guard abs(frame.height - target) > 0.5 else { return }
                frame.origin.y += frame.height - target
                frame.size.height = target
                window.setFrame(frame, display: true)
            }
        }
    }
}

struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    private var value: Double { min(max((window?.utilization ?? 0) / 100, 0), 1) }

    private var color: Color {
        switch value {
        case ..<0.5: return .green
        case ..<0.8: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(UsageModel.pct(window?.utilization))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color.gradient)
                        .frame(width: max(value > 0 ? 6 : 0, geo.size.width * value))
                }
            }
            .frame(height: 6)
            HStack {
                Text(resetDate)
                Spacer()
                Text(countdown).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var reset: Date? { window?.resetsAt.map(UsageModel.rounded) }

    /// "Reset heute um 16:20 Uhr" / "Reset Mi, 25.11. um 14:00 Uhr"
    private var resetDate: String {
        guard let r = reset else { return "Kein aktives Fenster" }
        let cal = Calendar.current
        let f = cal.isDateInToday(r) ? Formatters.today
            : cal.isDateInTomorrow(r) ? Formatters.tomorrow : Formatters.later
        return "Reset " + f.string(from: r).replacingOccurrences(of: "., ", with: ", ")
    }

    /// "in 3 Std 41 Min" / "in 4 T 1 Std"
    private var countdown: String {
        guard let r = reset else { return "" }
        let secs = max(0, Int(r.timeIntervalSince(now)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "in \(d) T \(h) Std" }
        if h > 0 { return "in \(h) Std \(m) Min" }
        return "in \(m) Min"
    }
}
