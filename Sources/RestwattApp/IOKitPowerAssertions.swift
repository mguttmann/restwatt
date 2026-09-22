import Foundation
import IOKit.pwr_mgt
import RestwattCore

/// Holds IOPM assertions for this process. No privileges needed; the kernel drops every
/// assertion when the process ends.
struct IOKitPowerAssertions: PowerAssertionHolding {
    func acquire(_ assertion: AwakeAssertion, name: String) throws -> UInt32 {
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            assertion.rawValue as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &identifier)
        guard result == kIOReturnSuccess else {
            throw SettingsFailure("IOPMAssertionCreateWithName returned \(String(result, radix: 16))")
        }
        return identifier
    }

    func release(_ token: UInt32) {
        IOPMAssertionRelease(token)
    }
}
