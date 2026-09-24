import XCTest
@testable import RestwattCore

/// Guards the repository against drift between code and the files around it.
final class RepositoryConsistencyTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RestwattCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    private func read(_ relativePath: String) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) is missing from the repository")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testVersionFileMatchesLatestChangelogRelease() throws {
        let version = try read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "VERSION must be a plain semantic version, got \(version)")

        let changelog = try read("CHANGELOG.md")
        let pattern = #"^## \[(\d+\.\d+\.\d+)\]"#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(changelog.startIndex..., in: changelog)
        guard let match = regex.firstMatch(in: changelog, range: range),
              let versionRange = Range(match.range(at: 1), in: changelog) else {
            return XCTFail("CHANGELOG.md has no released version heading")
        }
        XCTAssertEqual(String(changelog[versionRange]), version)
    }

    func testReadmeNamesTheSamplingInterval() throws {
        let readme = try read("README.md")
        let seconds = Int(Sampling.interval)
        XCTAssertTrue(readme.contains("\(seconds) seconds") || readme.contains("\(seconds) s "),
                      "README must state the sampling interval of \(seconds) seconds")
    }

    /// The README names the settings file, and the path it names is the one the code uses.
    func testReadmeNamesTheSettingsFile() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains(SettingsStoreLocation.documentedPath),
                      "README must name the settings file \(SettingsStoreLocation.documentedPath)")
    }

    /// The README names the statistics file, and the path it names is the one the code uses.
    func testReadmeNamesTheStatisticsFile() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains(StatisticsStoreLocation.documentedPath),
                      "README must name the statistics file \(StatisticsStoreLocation.documentedPath)")
        XCTAssertEqual(StatisticsStoreLocation.directoryName, SettingsStoreLocation.directoryName)
        XCTAssertTrue(StatisticsStoreLocation.documentedPath.hasSuffix(
            "/\(StatisticsStoreLocation.directoryName)/\(StatisticsStoreLocation.fileName)"))
    }

    /// The one-shot second sample is documented with its delay and comes before the first
    /// regular tick.
    func testReadmeNamesTheSecondSampleDelay() throws {
        XCTAssertLessThan(Sampling.secondSampleDelay, Sampling.interval)
        let readme = try read("README.md")
        let seconds = Int(Sampling.secondSampleDelay)
        XCTAssertTrue(readme.contains("\(seconds) seconds"),
                      "README must state the second sample delay of \(seconds) seconds")
    }

    /// The on-battery period: the README quotes the one log read verbatim and names each of
    /// its numbers together with the constant that holds it.
    func testReadmeNamesThePowerLogReadAndItsNumbers() throws {
        let readme = try read("README.md")
        let vector = SystemCommands.pmsetReadLog
        let quoted = (["pmset"] + vector.arguments).joined(separator: " ")
        XCTAssertEqual(vector.executable, "/usr/bin/pmset")
        XCTAssertTrue(readme.contains("\n\(quoted)\n"), "README must quote `\(quoted)` on its own line")

        let facts: [(value: Int, unit: String, constant: String)] = [
            (Int(PowerLog.readTimeout), "seconds", "PowerLog.readTimeout"),
            (Int(PowerLog.preciseBracket / 60), "minutes", "PowerLog.preciseBracket"),
            (Int(BatteryPeriodTracker.maximumObservationGap), "seconds", "BatteryPeriodTracker.maximumObservationGap"),
            (Int(UnplugRecord.futureTolerance), "seconds", "UnplugRecord.futureTolerance"),
        ]
        XCTAssertEqual(PowerLog.preciseBracket.truncatingRemainder(dividingBy: 60), 0)
        for fact in facts {
            XCTAssertTrue(Self.mentions(readme, value: fact.value, unit: fact.unit, near: fact.constant),
                          "README must give \(fact.constant) as \(fact.value) \(fact.unit) right before it")
        }
    }

    /// `<value> <unit>` followed, across line breaks and within 40 characters without a period, by the
    /// constant in backticks.
    private static func mentions(_ text: String, value: Int, unit: String, near constant: String) -> Bool {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let pattern = "\\b\(value) \(unit)\\b[^.`]{0,40}\\(`" + NSRegularExpression.escapedPattern(for: constant) + "`"
        return flat.range(of: pattern, options: .regularExpression) != nil
    }

    /// The pmset values in the README are held by the vector test: every call of both
    /// profiles appears verbatim (without the `/usr/bin/` prefix and without sudo) in the docs.
    func testReadmeQuotesBothPmsetProfiles() throws {
        let readme = try read("README.md")
        for profile in PmsetProfile.allCases {
            for vector in profile.vectors {
                let text = "pmset " + vector.arguments.joined(separator: " ")
                XCTAssertTrue(readme.contains(text), "README must quote `\(text)`")
            }
        }
    }

    /// Ticket 11: every Energy Mode vector appears verbatim in the README (without sudo and prefix).
    func testReadmeQuotesEveryEnergyModeVector() throws {
        let readme = try read("README.md")
        for vector in SystemCommands.energyModeVectors {
            let text = "pmset " + vector.arguments.joined(separator: " ")
            XCTAssertTrue(readme.contains(text), "README must quote `\(text)`")
        }
        XCTAssertEqual(SystemCommands.energyModeVectors.count, 6)
    }

    /// The red-fill threshold in the README is the constant the tint test holds.
    func testReadmeNamesTheLowChargeThreshold() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("\(BatteryGlyph.lowChargeThresholdPercent) %"),
                      "README must state the low charge threshold of \(BatteryGlyph.lowChargeThresholdPercent) %")
    }

    /// The README names the write key and the read key pmset reports it back under.
    func testReadmeNamesTheEnergyModeKey() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains(SystemCommands.energyModeKey))
        XCTAssertTrue(readme.contains("powermode"))
    }

    /// Tester hardening (AC2, AC6, N2, N5): nothing in the app touches Manuel's LaunchAgent or
    /// caffeinate, nothing runs through a shell, and neither code nor docs mention a sudoers
    /// rule. The words are checked case-insensitively over every Swift source file.
    func testSourcesNeverNameTheLaunchAgentCaffeinateAShellOrSudoers() throws {
        let forbiddenInSources = ["caffeinate", "keepdisplayawake", "sudoers", "visudo", "nopasswd",
                                  "/bin/sh", "/bin/bash", "/bin/zsh", "launchagents.disabled"]
        let root = Self.repositoryRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var checked = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else {
                continue
            }
            checked += 1
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for word in forbiddenInSources {
                XCTAssertFalse(text.contains(word), "\(url.lastPathComponent) mentions \(word)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "the Sources tree must be enumerable")

        for doc in ["README.md", "CHANGELOG.md"] {
            let text = try read(doc).lowercased()
            for word in ["sudoers", "visudo", "nopasswd"] {
                XCTAssertFalse(text.contains(word), "\(doc) mentions \(word)")
            }
        }
    }

    /// The power log fixture is synthetic. The real log read while building 0.4.0 dates from
    /// 2026; no line in its format and year may come back into the public repository.
    func testNoPowerLogLineFrom2026IsCheckedIn() throws {
        let logLine = try NSRegularExpression(pattern: #"2026-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#)
        var files = ["README.md", "CHANGELOG.md"]
        let root = Self.repositoryRoot.appendingPathComponent("Tests")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append("Tests/" + url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        XCTAssertTrue(files.contains("Tests/RestwattCoreTests/Fixtures.swift"), "the fixture must be checked")
        for file in files {
            let text = try read(file)
            let found = logLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertNil(found, "\(file) carries a power log line dated 2026")
        }
        XCTAssertTrue(try read("Tests/RestwattCoreTests/Fixtures.swift").contains("SYNTHETIC: invented power source lines"))
        XCTAssertFalse(Fixtures.powerLogLines.isEmpty)
        for line in Fixtures.powerLogLines {
            XCTAssertFalse(line.hasPrefix("2026-"), line)
        }
    }

    func testNoDashesInSourcesAndDocs() throws {
        var files = ["Package.swift", "README.md", "CHANGELOG.md", "Makefile", "scripts/make-app.sh",
                     ".github/workflows/ci.yml", "packaging/Info.plist.template"]
        for directory in ["Sources", "Tests"] {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" {
                    files.append(directory + "/" + url.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
        }
        XCTAssertGreaterThan(files.count, 7, "the Sources and Tests trees must be enumerable")

        for file in files {
            let url = Self.repositoryRoot.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("\(file) is missing from the repository")
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(file)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(file)")
        }
    }
}
