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
