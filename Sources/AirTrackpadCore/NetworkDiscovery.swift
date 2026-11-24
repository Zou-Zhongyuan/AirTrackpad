import Darwin
import Foundation
import Network
import SystemConfiguration

public struct RawInterfaceEntry: Sendable, Equatable {
    public let name: String
    public let ip: String
    public let flags: UInt32

    public init(name: String, ip: String, flags: UInt32) {
        self.name = name
        self.ip = ip
        self.flags = flags
    }
}

public struct NetworkInterfaceInfo: Sendable, Equatable, Identifiable {
    public var id: String { "\(name):\(ip)" }
    public let name: String
    public let ip: String
    public let isHotspotOrUSB: Bool

    public init(name: String, ip: String) {
        self.name = name
        self.ip = ip
        self.isHotspotOrUSB = ip.hasPrefix("172.20.10.")
    }

    public var displayLabel: String {
        if isHotspotOrUSB {
            return "热点/USB (\(ip))"
        }
        return "\(name) (\(ip))"
    }
}

public struct AddressOption: Sendable, Equatable, Identifiable {
    public var id: String { host }
    public let host: String
    public let label: String
    public let badge: String?
    public let isHotspotOrUSB: Bool
    public let isMDNS: Bool

    public init(host: String, label: String, badge: String?, isHotspotOrUSB: Bool, isMDNS: Bool) {
        self.host = host
        self.label = label
        self.badge = badge
        self.isHotspotOrUSB = isHotspotOrUSB
        self.isMDNS = isMDNS
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let localHostName: String?
    public let mdnsHost: String?
    public let interfaces: [NetworkInterfaceInfo]
    public let hasHotspotOrUSB: Bool
    public let addressOptions: [AddressOption]
    public let preferredHost: String

    public init(localHostName: String?, interfaces: [NetworkInterfaceInfo]) {
        let trimmedHost = localHostName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        self.localHostName = validHost
        let mdns = validHost.map { host in
            host.hasSuffix(".local") ? host : "\(host).local"
        }
        self.mdnsHost = mdns
        self.interfaces = interfaces
        self.hasHotspotOrUSB = interfaces.contains(where: \.isHotspotOrUSB)

        var options: [AddressOption] = []
        var seenHosts = Set<String>()

        func appendOption(_ opt: AddressOption) {
            if seenHosts.insert(opt.host).inserted {
                options.append(opt)
            }
        }

        if self.hasHotspotOrUSB {
            for iface in interfaces where iface.isHotspotOrUSB {
                appendOption(AddressOption(
                    host: iface.ip,
                    label: iface.ip,
                    badge: "热点/USB 推荐",
                    isHotspotOrUSB: true,
                    isMDNS: false
                ))
            }
        }

        if let mdns {
            appendOption(AddressOption(
                host: mdns,
                label: mdns,
                badge: self.hasHotspotOrUSB ? "局域网" : "推荐 .local",
                isHotspotOrUSB: false,
                isMDNS: true
            ))
        }

        for iface in interfaces where !iface.isHotspotOrUSB {
            appendOption(AddressOption(
                host: iface.ip,
                label: iface.displayLabel,
                badge: iface.name,
                isHotspotOrUSB: false,
                isMDNS: false
            ))
        }

        self.addressOptions = options
        if let firstOption = options.first {
            self.preferredHost = firstOption.host
        } else {
            self.preferredHost = "127.0.0.1"
        }
    }
}

public final class NetworkDiscovery: @unchecked Sendable {
    public static let excludedInterfacePrefixes = [
        "lo", "utun", "awdl", "llw", "anpi", "ap", "gif", "stf"
    ]

    private let queue = DispatchQueue(label: "com.airtrackpad.network-discovery")
    private var monitor: NWPathMonitor?
    private var lastSnapshot: NetworkSnapshot?

    public init() {}

    public func currentSnapshot() -> NetworkSnapshot {
        Self.collectSnapshot()
    }

    public func startMonitoring(onChange: @Sendable @escaping (NetworkSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.monitor?.cancel()
            let monitor = NWPathMonitor()
            self.monitor = monitor

            let initial = Self.collectSnapshot()
            self.lastSnapshot = initial
            onChange(initial)

            monitor.pathUpdateHandler = { [weak self] _ in
                guard let self else { return }
                let updated = Self.collectSnapshot()
                if updated != self.lastSnapshot {
                    self.lastSnapshot = updated
                    onChange(updated)
                }
            }
            monitor.start(queue: self.queue)
        }
    }

    public func stopMonitoring() {
        queue.async { [weak self] in
            self?.monitor?.cancel()
            self?.monitor = nil
        }
    }

    public static func collectSnapshot() -> NetworkSnapshot {
        let localHostName = SCDynamicStoreCopyLocalHostName(nil) as String?
        let rawEntries = enumerateIPv4Interfaces()
        let filtered = filterAndSort(rawEntries)
        return NetworkSnapshot(localHostName: localHostName, interfaces: filtered)
    }

    public static func filterAndSort(_ entries: [RawInterfaceEntry]) -> [NetworkInterfaceInfo] {
        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING)
        let loopbackFlag = UInt32(IFF_LOOPBACK)

        var seen = Set<String>()
        var result: [NetworkInterfaceInfo] = []

        for entry in entries {
            guard (entry.flags & requiredFlags) == requiredFlags else { continue }
            guard (entry.flags & loopbackFlag) == 0 else { continue }
            guard !excludedInterfacePrefixes.contains(where: { entry.name.hasPrefix($0) }) else {
                continue
            }
            guard !entry.ip.isEmpty, !entry.ip.hasPrefix("169.254."), entry.ip != "0.0.0.0" else {
                continue
            }
            let key = "\(entry.name):\(entry.ip)"
            if seen.insert(key).inserted {
                result.append(NetworkInterfaceInfo(name: entry.name, ip: entry.ip))
            }
        }

        // Prioritize Hotspot/USB (172.20.10.x), then en0, then other en*, then remaining
        result.sort { lhs, rhs in
            if lhs.isHotspotOrUSB != rhs.isHotspotOrUSB {
                return lhs.isHotspotOrUSB && !rhs.isHotspotOrUSB
            }
            let lhsEn0 = lhs.name == "en0"
            let rhsEn0 = rhs.name == "en0"
            if lhsEn0 != rhsEn0 {
                return lhsEn0 && !rhsEn0
            }
            let lhsEn = lhs.name.hasPrefix("en")
            let rhsEn = rhs.name.hasPrefix("en")
            if lhsEn != rhsEn {
                return lhsEn && !rhsEn
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.ip < rhs.ip
        }

        return result
    }

    private static func enumerateIPv4Interfaces() -> [RawInterfaceEntry] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(firstAddr) }

        var entries: [RawInterfaceEntry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let ptr = cursor {
            let interface = ptr.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var sinAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ipBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    let ip = String(decoding: ipBytes, as: UTF8.self)
                    let name = String(cString: interface.ifa_name)
                    entries.append(RawInterfaceEntry(name: name, ip: ip, flags: interface.ifa_flags))
                }
            }
            cursor = interface.ifa_next
        }

        return entries
    }
}
