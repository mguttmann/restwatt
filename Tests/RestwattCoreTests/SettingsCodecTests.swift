import XCTest
@testable import RestwattCore

final class SettingsCodecTests: XCTestCase {
    func testRoundTrip() {
        let settings = StoredSettings(awake: [.idleSleep: true, .displaySleep: false, .diskIdle: true],
                                      lidClosedAwakeArmedByRestwatt: true)
        XCTAssertEqual(SettingsCodec.decode(SettingsCodec.encode(settings)), settings)
    }

    func testEncodingIsDeterministicAndReadable() {
        let settings = StoredSettings(awake: [.idleSleep: true])
        let text = String(decoding: SettingsCodec.encode(settings), as: UTF8.self)
        XCTAssertEqual(text, """
        {"awake":{"PreventDiskIdle":false,"PreventUserIdleDisplaySleep":false,"PreventUserIdleSystemSleep":true},\
        "lidClosedAwakeArmedByRestwatt":false,"version":1}
        """)
        XCTAssertEqual(SettingsCodec.encode(settings), SettingsCodec.encode(settings))
    }

    func testDefaultsHaveEverythingOff() {
        let defaults = StoredSettings()
        for assertion in AwakeAssertion.allCases {
            XCTAssertFalse(defaults.isOn(assertion))
        }
        XCTAssertFalse(defaults.lidClosedAwakeArmedByRestwatt)
        XCTAssertEqual(defaults.version, 1)
    }

    func testUnknownKeysAreIgnored() {
        let json = """
        {"version":1,"awake":{"PreventUserIdleSystemSleep":true,"SomethingNew":true},"lidClosedAwakeArmedByRestwatt":true,"future":42}
        """
        let decoded = SettingsCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded, StoredSettings(awake: [.idleSleep: true], lidClosedAwakeArmedByRestwatt: true))
    }

    func testMissingKeysMeanOff() {
        XCTAssertEqual(SettingsCodec.decode(Data("{}".utf8)), StoredSettings())
        XCTAssertEqual(SettingsCodec.decode(Data("{\"awake\":{\"PreventDiskIdle\":true}}".utf8)),
                       StoredSettings(awake: [.diskIdle: true]))
    }

    func testCorruptDataMeansDefaultsNotACrash() {
        XCTAssertEqual(SettingsCodec.decode(Data("not json".utf8)), StoredSettings())
        XCTAssertEqual(SettingsCodec.decode(Data()), StoredSettings())
        XCTAssertEqual(SettingsCodec.decode(Data("[1,2]".utf8)), StoredSettings())
    }

    func testDocumentedPathMatchesTheConstants() {
        XCTAssertEqual(SettingsStoreLocation.documentedPath,
                       "~/Library/Application Support/\(SettingsStoreLocation.directoryName)/\(SettingsStoreLocation.fileName)")
    }
}
