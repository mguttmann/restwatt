import Foundation
import RestwattCore

/// The statistics file under `~/Library/Application Support/Restwatt/`. Missing or unreadable
/// means a start from zero; writes are atomic.
struct FileStatisticsStore: StatisticsStoring {
    private let file: ApplicationSupportFile

    init(fileManager: FileManager = .default) {
        file = ApplicationSupportFile(fileName: StatisticsStoreLocation.fileName, fileManager: fileManager)
    }

    func load() -> StoredStatistics {
        guard let data = file.read() else {
            return StoredStatistics()
        }
        return StatisticsCodec.decode(data)
    }

    func save(_ statistics: StoredStatistics) throws {
        do {
            try file.write(StatisticsCodec.encode(statistics))
        } catch {
            throw SettingsFailure(error.localizedDescription)
        }
    }
}
