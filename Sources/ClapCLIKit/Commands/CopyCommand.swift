import Foundation
import AppKit
import ClapCore

enum CopyCommand {
    static let usage = """
    Usage: clap copy <id>

    Writes the entry back to the system clipboard (text or image), bumps its
    recency, and notifies the app.
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage)
        let id = parsed.requiredID(commandName: "copy")

        await CLI.run {
            let store = try context.makeStore()
            guard let entry = try await store.entry(id: id) else {
                CLI.fail("entry \(id) not found")
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            switch entry.type {
            case .text, .shell:
                guard pasteboard.setString(entry.content ?? "", forType: .string) else {
                    CLI.fail("failed to write to the pasteboard (is a GUI session available?)")
                }
            case .image:
                guard let fileURL = await store.imageFileURL(for: entry) else {
                    CLI.fail("entry \(id) has no image file")
                }
                let data: Data
                do {
                    data = try Data(contentsOf: fileURL)
                } catch {
                    CLI.fail("unable to read image file at \(fileURL.path)")
                }
                let primary = pasteboardType(for: entry.imageFormat ?? "")
                var ok = pasteboard.setData(data, forType: primary)
                if !ok, primary != .tiff {
                    // Fallback: many consumers accept TIFF-typed image data.
                    pasteboard.clearContents()
                    ok = pasteboard.setData(data, forType: .tiff)
                }
                guard ok else {
                    CLI.fail("failed to write image data to the pasteboard")
                }
            }

            // When the app is running, its pasteboard monitor will see a text/image
            // write and capture it as a duplicate — which already bumps
            // recency. Touching here too would double-count use_count.
            // Shell entries are distinct from clipboard text captures so touch them directly.
            if entry.type == .shell || !AppProcess.isRunning() {
                try await store.touch(id: id)
                Notify.storeChanged()
            }
            print("Copied entry \(id) to clipboard.")
        }
    }

    static func pasteboardType(for format: String) -> NSPasteboard.PasteboardType {
        if let uti = ImageFormats.uti(forFormat: format) {
            return NSPasteboard.PasteboardType(uti)
        }
        return .tiff
    }
}
