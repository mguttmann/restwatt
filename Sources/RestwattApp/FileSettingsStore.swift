import Foundation
import RestwattCore

/// The settings file under `~/Library/Application Support/Restwatt/`. Missing or unreadable
/// means defaults; writes are atomic and only happen when the coordinator has a change.
struct FileSettingsStore: SettingsStoring {
    private let file: ApplicationSupportFile

    init(fileManager: FileManager = .default) {
        file = ApplicationSupportFile(fileName: SettingsStoreLocation.fileName, fileManager: fileManager)
    }

    func load() -> StoredSettings {
        guard let data = file.read() else {
            return StoredSettings()
        }
        return SettingsCodec.decode(data)
    }

    func save(_ settings: StoredSettings) throws {
        do {
            try file.write(SettingsCodec.encode(settings))
        } catch {
            throw SettingsFailure(error.localizedDescription)
        }
    }
}
