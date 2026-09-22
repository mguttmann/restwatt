import Foundation
import RestwattCore

/// Runs one executable with fixed arguments and no shell, and waits for it. The child sees a
/// minimal environment; its output is captured, never logged.
struct ProcessCommandRunner: CommandRunning {
    func run(_ vector: CommandVector) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vector.executable)
        process.arguments = vector.arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(exitStatus: -1, stderr: "could not start \(vector.executable): \(error.localizedDescription)")
        }
        // Both outputs are a few lines at most; reading them fully before waiting avoids a
        // full pipe blocking the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}
