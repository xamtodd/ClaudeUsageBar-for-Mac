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

    @Published var sessionKey: String = UserDefaults.standard.string(forKey: "sessionKey") ?? "" {
        didSet { UserDefaults.standard.set(sessionKey, forKey: "sessionKey") }
    }
    @Published var refreshSeconds: Double = {
        let v = UserDefaults.standard.double(forKey: "refreshSeconds")
        return v > 0 ? v : 60
    }() {
        didSet { UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds") }
    }

    private var fetchTimer: Timer?
    private var clockTimer: Timer?

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
        fetchTimer = Timer.scheduledTimer(withTimeInterval: max(30, refreshSeconds), repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            usage = try await UsageService.fetch(sessionKey: sessionKey)
            error = nil
            lastUpdate = Date()
            now = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @Published var showResetInBar: Bool = UserDefaults.standard.object(forKey: "showResetInBar") as? Bool ?? true {
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(r) ? "HH:mm" : "EEE HH:mm"
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

            if let err = model.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
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
            ProgressView(value: value)
                .tint(color)
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard let raw = window?.resetsAt else { return "Kein aktives Fenster" }
        let r = UsageModel.rounded(raw)
        let secs = max(0, Int(r.timeIntervalSince(now)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        let rel: String
        if d > 0 { rel = "\(d) T \(h) Std \(m) Min" }
        else if h > 0 { rel = "\(h) Std \(m) Min" }
        else { rel = "\(m) Min" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        let cal = Calendar.current
        if cal.isDateInToday(r) { f.dateFormat = "'heute um' HH:mm 'Uhr'" }
        else if cal.isDateInTomorrow(r) { f.dateFormat = "'morgen um' HH:mm 'Uhr'" }
        else { f.dateFormat = "EEEE, dd.MM. 'um' HH:mm 'Uhr'" }
        return "Reset \(f.string(from: r)) · in \(rel)"
    }
}
