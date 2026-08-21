import AppKit
import ClapCore
import os

// MARK: - Pasteboard copy & thumbnail loading

extension AppState {

    // MARK: - Copy to pasteboard

    /// Writes the entry to NSPasteboard.general. The monitor is told about
    /// the expected self-inflicted change first so it only bumps recency
    /// instead of re-capturing.
    func copy(_ entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wrote = await self.writeToPasteboard(entry)
            if entry.type != .image || wrote {
                IPC.post(.storeChanged)
                self.onCloseRequest?()
                await self.pasteToFrontmostIfEnabled()
            }
        }
    }

    /// Returns false when an image copy failed (panel stays open so the user
    /// sees that nothing happened).
    private func writeToPasteboard(_ entry: ClipboardEntry) async -> Bool {
        let pasteboard = NSPasteboard.general
        switch entry.type {
        case .text:
            await monitor.expectSelfChange(entryID: entry.id)
            pasteboard.clearContents()
            pasteboard.setString(entry.content ?? "", forType: .string)
            await monitor.confirmSelfChange(changeCount: pasteboard.changeCount)
        case .shell:
            pasteboard.clearContents()
            pasteboard.setString(entry.content ?? "", forType: .string)
            await perform("Recency touch") { try await store.touch(id: entry.id) }
        case .image:
            // Load the full image data first: only tell the monitor once
            // we know the write will actually happen.
            guard let url = await store.imageFileURL(for: entry) else { return false }
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard let data else {
                logger.error("copy failed: image file missing for entry \(entry.id, privacy: .public)")
                showTransientError("Image file missing")
                return false
            }
            await monitor.expectSelfChange(entryID: entry.id)
            pasteboard.clearContents()
            if let uti = ImageFormats.uti(forFormat: entry.imageFormat ?? "") {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti))
            } else {
                // Unknown format: convert through NSImage to TIFF.
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                } else {
                    pasteboard.setData(data, forType: .tiff)
                }
            }
            await monitor.confirmSelfChange(changeCount: pasteboard.changeCount)
        }
        return true
    }

    /// Maccy-style paste-on-select: the panel never activated clap, so the
    /// app the user came from still has key focus. Small delay so the panel
    /// is gone and the pasteboard write has settled before the synthetic
    /// Cmd+V lands.
    private func pasteToFrontmostIfEnabled() async {
        let pasteEnabled = ((try? await store.config(ConfigKey.pasteOnCopy)) ?? "1") == "1"
        guard pasteEnabled else { return }
        try? await Task.sleep(nanoseconds: Timing.pasteDelayNanos)
        Paster.pasteToFrontmostApp()
    }

    /// Writes transformed text to clipboard, captures it as a new entry,
    /// closes the panel, and optionally pastes it to the frontmost app.
    func copyTransformedText(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            await self.perform("Capture transformed text") {
                try await self.store.captureText(text, sourceApp: "clap")
            }
            IPC.post(.storeChanged)
            self.reload()
            self.onCloseRequest?()
            await self.pasteToFrontmostIfEnabled()
        }
    }

    // MARK: - Thumbnails

    /// Loads (and lazily generates) the thumbnail for an image entry,
    /// cached in a small NSCache.
    func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        let key = NSNumber(value: entry.id)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let url = try? await store.thumbnailURL(for: entry) else { return nil }
        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }

    /// Loads the full-resolution image for preview rendering (not cached).
    func fullImage(for entry: ClipboardEntry) async -> NSImage? {
        guard let url = await store.imageFileURL(for: entry) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }
}
