import Foundation
import IOKit
import IOKit.ps

/// Dashboard vitals (§4.8): disk breakdown, memory, CPU load, battery health.
/// All read-only probes — nothing here mutates anything. Per §6, these inform;
/// they never feed an opaque "system score" and RAM is never "purged".

// MARK: - Disk

/// Storage breakdown for one volume, separating the two numbers macOS itself
/// reports differently — the root of the "System Data" / Storage-panel trust
/// complaint (§4.8): Apple's Storage panel counts *purgeable* space (local
/// snapshots, evicted iCloud files, caches the system will drop on demand) as
/// available, while plain free space excludes it.
public struct DiskBreakdown: Sendable, Equatable {
    public let totalBytes: Int64
    /// Free space right now, excluding purgeable (what `df`/Finder tend to show).
    public let freeBytes: Int64
    /// Free space including purgeable (what Apple's Storage panel calls
    /// "Available" — `volumeAvailableCapacityForImportantUsage`).
    public let availableIncludingPurgeableBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64, availableIncludingPurgeableBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableIncludingPurgeableBytes = availableIncludingPurgeableBytes
    }

    /// Space the system reclaims on demand — explains most Storage-panel gaps.
    public var purgeableBytes: Int64 {
        max(0, availableIncludingPurgeableBytes - freeBytes)
    }
    /// Genuinely occupied space (excludes purgeable).
    public var usedBytes: Int64 {
        max(0, totalBytes - availableIncludingPurgeableBytes)
    }

    public static func probe(volumeContaining url: URL) -> DiskBreakdown? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return DiskBreakdown(totalBytes: Int64(total), freeBytes: free,
                             availableIncludingPurgeableBytes: Int64(important))
    }
}

// MARK: - Memory

/// Point-in-time memory usage via `host_statistics64`. "Used" mirrors Activity
/// Monitor's composition: app (active) + wired + compressed.
public struct MemorySnapshot: Sendable, Equatable {
    public let totalBytes: Int64
    public let appBytes: Int64
    public let wiredBytes: Int64
    public let compressedBytes: Int64

    public var usedBytes: Int64 { appBytes + wiredBytes + compressedBytes }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    public init(totalBytes: Int64, appBytes: Int64, wiredBytes: Int64, compressedBytes: Int64) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
    }

    public static func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = Int64(pageSize)
        return MemorySnapshot(
            totalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            appBytes: Int64(stats.active_count) * page,
            wiredBytes: Int64(stats.wire_count) * page,
            compressedBytes: Int64(stats.compressor_page_count) * page
        )
    }
}

// MARK: - CPU

/// Load averages from `getloadavg` — a single honest read, no sampling window
/// to misrepresent. Shown against the core count for context.
public struct CPULoad: Sendable, Equatable {
    public let oneMinute: Double
    public let fiveMinutes: Double
    public let fifteenMinutes: Double
    public let coreCount: Int

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double, coreCount: Int) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
        self.coreCount = coreCount
    }

    public static func sample() -> CPULoad? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return CPULoad(oneMinute: loads[0], fiveMinutes: loads[1],
                       fifteenMinutes: loads[2],
                       coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }
}

// MARK: - Battery

/// Battery status + health for laptops (§4.8). `probe()` returns nil on
/// desktops — the dashboard simply omits the card. Health is the raw
/// max-capacity/design-capacity ratio from the power-management registry,
/// alongside Apple's own condition string ("Good"…), so the number is
/// verifiable, not invented.
public struct BatteryInfo: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool
    /// Apple's condition string (kIOPSBatteryHealthKey), e.g. "Good".
    public let condition: String?
    /// Current max capacity as % of design capacity, if the registry exposes it.
    public let healthPercent: Int?
    public let cycleCount: Int?

    public init(percentage: Int, isCharging: Bool, condition: String?,
                healthPercent: Int?, cycleCount: Int?) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.condition = condition
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
    }

    public static func probe() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let condition = desc[kIOPSBatteryHealthKey] as? String

            var healthPercent: Int?
            var cycles: Int?
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func intProp(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(
                        service, key as CFString, kCFAllocatorDefault, 0
                    )?.takeRetainedValue() as? Int
                }
                cycles = intProp("CycleCount")
                if let raw = intProp("AppleRawMaxCapacity") ?? intProp("MaxCapacity"),
                   let design = intProp("DesignCapacity"), design > 0 {
                    healthPercent = Int((Double(raw) / Double(design) * 100).rounded())
                }
            }

            let pct = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            return BatteryInfo(percentage: pct, isCharging: charging,
                               condition: condition, healthPercent: healthPercent,
                               cycleCount: cycles)
        }
        return nil
    }
}
