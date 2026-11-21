import SwiftUI
import AppKit

/// `ClaudeUsageBar --screenshot <ordner>`
/// Lädt einmal echte Daten und schreibt README-Bilder:
///   screenshot.png        – Menüleiste + aufgeklapptes Panel (dunkel)
///   screenshot-light.png  – dasselbe hell
///   menubar.png / menubar-light.png – Menüleiste kompakt vs. mit Reset-Uhrzeit
enum ScreenshotMode {
    static var outputDir: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(dir: String) {
        let model = UsageModel(autoStart: false)
        Task { @MainActor in
            await model.refresh()
            for (name, dark) in [("screenshot.png", true), ("screenshot-light.png", false)] {
                let view = Showcase(model: model, dark: dark)
                let path = (dir as NSString).appendingPathComponent(name)
                if await render(view, dark: dark, to: path) {
                    print("✅ \(path)")
                } else {
                    print("❌ \(path)")
                }
            }
            // Menüleisten-Vergleich: kompakt vs. erweitert (Einstellung danach zurücksetzen)
            let previous = model.showResetInBar
            model.showResetInBar = false
            let compact = model.menuBarTitle
            model.showResetInBar = true
            let extended = model.menuBarTitle
            model.showResetInBar = previous
            for (name, dark) in [("menubar.png", true), ("menubar-light.png", false)] {
                let view = MenuBarVariants(compact: compact, extended: extended, dark: dark)
                let path = (dir as NSString).appendingPathComponent(name)
                print(await render(view, dark: dark, to: path) ? "✅ \(path)" : "❌ \(path)")
            }
            print("Menüleiste: \(compact)  |  erweitert: \(extended)")
            if let e = model.error { print("Fehler: \(e)") }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, dark: Bool, to path: String) async -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// Menüleisten-Ausschnitt + aufgeklapptes Panel, wie es auf dem Mac aussieht
private struct Showcase: View {
    @ObservedObject var model: UsageModel
    let dark: Bool

    /// Gleiche Zeit wie „Stand“ im Panel, im Format der macOS-Menüleisten-Uhr („Sa. 21. Nov. 12:44“)
    private var clock: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f.string(from: model.lastUpdate ?? Date())
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Text(model.menuBarTitle)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.15)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text(clock).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(dark ? Color.black.opacity(0.85) : Color.white.opacity(0.85))

            UsagePanel(model: model)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                .padding(.trailing, 150)
                .padding(.bottom, 24)
        }
        .frame(width: 560)
        .background(
            LinearGradient(colors: dark ? [Color(red: 0.16, green: 0.12, blue: 0.22), Color(red: 0.08, green: 0.10, blue: 0.16)]
                                        : [Color(red: 0.85, green: 0.89, blue: 0.97), Color(red: 0.96, green: 0.90, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

/// Zwei Menüleisten-Zeilen untereinander: Standard und mit Reset-Uhrzeit
private struct MenuBarVariants: View {
    let compact: String
    let extended: String
    let dark: Bool

    private func row(_ label: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.15)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(dark ? Color.black.opacity(0.85) : Color.white.opacity(0.85))
    }

    var body: some View {
        VStack(spacing: 8) {
            row("Standard", compact)
            row("Mit Reset-Uhrzeit", extended)
        }
        .padding(12)
        .frame(width: 560)
        .background(
            LinearGradient(colors: dark ? [Color(red: 0.16, green: 0.12, blue: 0.22), Color(red: 0.08, green: 0.10, blue: 0.16)]
                                        : [Color(red: 0.85, green: 0.89, blue: 0.97), Color(red: 0.96, green: 0.90, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ScreenshotMode.outputDir {
            Task { @MainActor in ScreenshotMode.run(dir: dir) }
        }
    }
}
