import Foundation
import RestwattCore

/// Runs `pmset -g log` once, off the main thread at utility priority, and streams its output
/// through `PowerLogStream`, so only the current line is held, never the whole log. No
/// shell; the child sees the same minimal environment as every other command. A read that
/// takes longer than `PowerLog.readTimeout` is stopped, and killed if it has not exited
/// `PowerLog.killGrace` seconds later; it answers `.failed` however it then exits, as do a
/// non-zero exit, a line longer than `PowerLog.maximumLineLength` and a tool that cannot be
/// started. The caller runs one read at a time (`PowerLogReadQueue`).
enum PmsetPowerLogReader {
    static func read(completion: @escaping @Sendable (PowerLogOutcome) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(run(SystemCommands.pmsetReadLog))
        }
    }

    private static func run(_ vector: CommandVector) -> PowerLogOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vector.executable)
        process.arguments = vector.arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.qualityOfService = .utility
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed
        }
        let child = RunningChild(process)
        let deadline = DispatchWorkItem {
            // Its exit closes the pipe and ends the read below.
            child.expire()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + PowerLog.readTimeout, execute: deadline)

        var stream = PowerLogStream()
        let reader = stdout.fileHandleForReading
        var open = true
        while open {
            // Each chunk is released right away; a worker thread has no run loop that would
            // drain autoreleased buffers, and without the pool all 18 MB of reads pile up.
            autoreleasepool {
                let chunk = reader.availableData
                if chunk.isEmpty {
                    open = false
                    return
                }
                let overflowedBefore = stream.overflowed
                stream.consume(chunk)
                if stream.overflowed, !overflowedBefore {
                    // The read has failed; the rest of the output is drained unread.
                    child.stop()
                }
            }
        }
        process.waitUntilExit()
        deadline.cancel()
        return stream.finish(exitedCleanly: process.terminationReason == .exit && process.terminationStatus == 0,
                             timedOut: child.timedOut)
    }
}

/// The child as the timeout sees it. `Process.terminate()` is a no-op once the child has
/// exited, so a deadline that fires late can never signal a reused process id; the kill after
/// the grace period checks the same way first.
private final class RunningChild: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var expired = false

    init(_ process: Process) {
        self.process = process
    }

    /// Whether the deadline stopped the read.
    var timedOut: Bool {
        lock.withLock { expired }
    }

    /// The deadline fired: the read is stopped and can only fail.
    func expire() {
        lock.withLock { expired = true }
        stop()
    }

    /// SIGTERM now, SIGKILL after `PowerLog.killGrace` if the child is still running.
    func stop() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + PowerLog.killGrace) {
            if self.process.isRunning {
                kill(self.process.processIdentifier, SIGKILL)
            }
        }
    }
}
