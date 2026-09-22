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
