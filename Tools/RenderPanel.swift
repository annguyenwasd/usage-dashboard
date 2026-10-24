import SwiftUI
import AppKit

@main
struct RenderPanel {
    static func main() async {
        if CommandLine.arguments.contains("--probe") {
            await runProbe()
            return
        }
        let quota = try? await ZCodeQuotaService.fetchQuota()
        let startPlan = try? await StartPlanService.fetchBalance()
        let deepseek = await DeepSeekService.fetch()
        let jev = try? await JevService.fetchBalance()
        let snapshot = Snapshot(
            zcode: quota.map { .loaded($0) } ?? .failed("quota unavailable"),
            startPlan: startPlan.map { .loaded($0) } ?? .failed("start plan unavailable"),
            deepseek: deepseek,
            jev: jev.map { .loaded($0) } ?? .failed("jev unavailable"),
            updatedAt: Date()
        )
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/panel.png"

        await MainActor.run {
            let store = UsageStore(snapshot: snapshot)
            print("menu bar: \(store.menuBarLabel)")
            let renderer = ImageRenderer(content: DashboardView(store: store))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render failed\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    @MainActor
    private static func runProbe() async {
        let store = UsageStore()

        var deadline = Date().addingTimeInterval(10)
        while (store.updatedAt == nil || store.isRefreshing) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let first = store.updatedAt else {
            print("refresh on activation: no (no initial load)")
            exit(1)
        }

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        var second: Date?
        deadline = Date().addingTimeInterval(10)
        while second == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let updated = store.updatedAt, updated > first { second = updated }
        }

        let firstText = clock.string(from: first)
        let secondText = second.map { clock.string(from: $0) } ?? "none"
        let refreshed = second != nil
        print("refresh on activation: \(refreshed ? "yes" : "no") (\(firstText) -> \(secondText))")
        exit(refreshed ? 0 : 1)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
