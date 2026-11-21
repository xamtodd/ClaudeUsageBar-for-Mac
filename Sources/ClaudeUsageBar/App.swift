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

    @AppStorage("sessionKey") var sessionKey: String = ""
    @AppStorage("refreshSeconds") var refreshSeconds: Double = 60

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

    var menuBarTitle: String {
        guard let u = usage else { return error == nil ? "Claude …" : "Claude ⚠︎" }
        let five = Self.pct(u.fiveHour?.utilization)
        let week = Self.pct(u.sevenDay?.utilization)
        let warn = error != nil ? " ⚠︎" : ""
        return "5h \(five) · W \(week)\(warn)"
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
        guard let r = window?.resetsAt else { return "Kein aktives Fenster" }
        let secs = max(0, Int(r.timeIntervalSince(now)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        let rel: String
        if d > 0 { rel = "\(d) T \(h) Std" }
        else if h > 0 { rel = "\(h) Std \(m) Min" }
        else { rel = "\(m) Min" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(r) ? "'heute' HH:mm" : "EEE dd.MM. HH:mm"
        return "Reset in \(rel) · \(f.string(from: r))"
    }
}
