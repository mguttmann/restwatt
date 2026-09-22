import Foundation
import RestwattCore

/// The settings file under `~/Library/Application Support/Restwatt/`. Missing or unreadable
/// means defaults; writes are atomic and only happen when the coordinator has a change.
struct FileSettingsStore: SettingsStoring {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = base
            .appendingPathComponent(SettingsStoreLocation.directoryName, isDirectory: true)
            .appendingPathComponent(SettingsStoreLocation.fileName)
    }

    func load() -> StoredSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return StoredSettings()
        }
        return SettingsCodec.decode(data)
    }

    func save(_ settings: StoredSettings) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SettingsCodec.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            throw SettingsFailure(error.localizedDescription)
        }
    }
}
