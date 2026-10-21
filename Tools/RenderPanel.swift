import SwiftUI
import AppKit

@main
struct RenderPanel {
    static func main() async {
        let quota = try? await ZCodeQuotaService.fetchQuota()
        let deepseek = await DeepSeekService.fetch()
        let snapshot = Snapshot(
            zcode: quota.map { .loaded($0) } ?? .failed("quota unavailable"),
            deepseek: deepseek,
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
}
