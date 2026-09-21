import Darwin
import Foundation
import RestwattCore

/// Reads `ri_energy_nj` and CPU time for every process the current user may inspect.
/// Root and system processes refuse the query without privileges and are skipped.
struct LibprocProcessReader: ProcessReading {
    /// Mach time units to seconds, read once.
    private let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    func readProcesses() -> [ProcessEnergySample] {
        var samples: [ProcessEnergySample] = []
        for pid in Self.allPids() {
            guard let usage = Self.rusage(pid) else {
                continue
            }
            let cpuTicks = usage.ri_user_time + usage.ri_system_time
            samples.append(ProcessEnergySample(
                pid: pid,
                name: Self.name(pid),
                energyNanoJoules: usage.ri_energy_nj,
                cpuTimeSeconds: Double(cpuTicks) * secondsPerTick
            ))
        }
        return samples
    }

    /// Two-step `proc_listallpids`: ask for the count, then fetch into a buffer with headroom.
    private static func allPids() -> [pid_t] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else {
            return []
        }
        var buffer = [pid_t](repeating: 0, count: count + 64)
        let bytes = Int32(buffer.count * MemoryLayout<pid_t>.size)
        let filled = Int(proc_listallpids(&buffer, bytes))
        guard filled > 0 else {
            return []
        }
        return Array(buffer.prefix(filled)).filter { $0 > 0 }
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    private static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return "pid \(pid)"
        }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
