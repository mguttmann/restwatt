import Foundation
import RestwattCore

/// One file under `~/Library/Application Support/Restwatt/`: read whole, written atomically,
/// the directory created on the first write. Shared by the settings and the statistics store.
struct ApplicationSupportFile {
    let url: URL

    init(fileName: String, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        url = base
            .appendingPathComponent(SettingsStoreLocation.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The file's contents, or nil when it is missing or unreadable.
    func read() -> Data? {
        try? Data(contentsOf: url)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
