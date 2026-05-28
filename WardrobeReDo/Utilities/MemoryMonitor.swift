import Foundation
import Darwin

/// Build 40 — heap-usage helper for telemetry breadcrumbs in the
/// image / SAM2 / upload pipeline.
///
/// Returns the Mach `phys_footprint` in MB — the SAME metric the iOS
/// jetsam scheduler consults when deciding to kill a foreground app
/// for memory pressure, and the same metric Xcode's Debug-navigator
/// Memory gauge displays. `mach_task_basic_info`'s `resident_size`
/// is also available but undercounts compressed pages on newer
/// devices; `phys_footprint` is the truth jetsam uses.
///
/// Cost: one `task_info()` syscall (~5 μs on A15+). Safe in hot
/// paths that fire once per photo flow / once per upload — DO NOT
/// invoke from per-frame delegates (e.g. `AVCaptureVideoDataOutput`
/// 60 Hz callbacks).
///
/// Failure mode: returns 0 if `task_info` errors. Callers should
/// treat a 0 value as "missing data" rather than "no memory in use".
enum MemoryMonitor {
    static var currentHeapUsageMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }
}
