import Darwin
import Foundation
import Testing
@testable import AirTrackpadCore

@Suite("Token and Network")
struct TokenAndNetworkTests {
    @Test func tokenPersistenceValidationAndRotation() {
        let suiteName = "AirTrackpadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = TokenStore(defaults: defaults, tokenKey: "testToken")
        let initial = store1.currentToken
        #expect(TokenStore.isWellFormedHexToken(initial))
        #expect(store1.isValid(initial))
        #expect(!store1.isValid(nil))
        #expect(!store1.isValid(""))
        #expect(!store1.isValid(String(initial.dropLast())))
        #expect(!store1.isValid(initial + "0"))

        let store2 = TokenStore(defaults: defaults, tokenKey: "testToken")
        #expect(store2.currentToken == initial)

        let rotated = store1.rotateToken()
        #expect(TokenStore.isWellFormedHexToken(rotated))
        #expect(rotated != initial)
        #expect(!store1.isValid(initial))
        #expect(store1.isValid(rotated))
    }

    @Test func constantTimeEqualsEdgeCases() {
        #expect(TokenStore.constantTimeEquals("", ""))
        #expect(TokenStore.constantTimeEquals("abcdef", "abcdef"))
        #expect(!TokenStore.constantTimeEquals("abc", "abcd"))
        #expect(!TokenStore.constantTimeEquals("abcd", "abc"))
        #expect(!TokenStore.constantTimeEquals("abcdef", "abcdeg"))
    }

    @Test func networkInterfaceFilteringAndHotspotPriority() {
        let upRunning = UInt32(IFF_UP | IFF_RUNNING)
        let loopbackFlags = upRunning | UInt32(IFF_LOOPBACK)

        let raw: [RawInterfaceEntry] = [
            RawInterfaceEntry(name: "lo0", ip: "127.0.0.1", flags: loopbackFlags),
            RawInterfaceEntry(name: "utun4", ip: "10.8.0.2", flags: upRunning),
            RawInterfaceEntry(name: "awdl0", ip: "192.168.50.1", flags: upRunning),
            RawInterfaceEntry(name: "llw0", ip: "192.168.51.1", flags: upRunning),
            RawInterfaceEntry(name: "anpi0", ip: "192.168.52.1", flags: upRunning),
            RawInterfaceEntry(name: "ap1", ip: "192.168.53.1", flags: upRunning),
            RawInterfaceEntry(name: "gif0", ip: "192.168.54.1", flags: upRunning),
            RawInterfaceEntry(name: "stf0", ip: "192.168.55.1", flags: upRunning),
            RawInterfaceEntry(name: "en1", ip: "169.254.12.34", flags: upRunning),
            RawInterfaceEntry(name: "en2", ip: "192.168.1.99", flags: UInt32(IFF_UP)),
            RawInterfaceEntry(name: "en0", ip: "192.168.1.42", flags: upRunning),
            RawInterfaceEntry(name: "en5", ip: "172.20.10.3", flags: upRunning)
        ]

        let filtered = NetworkDiscovery.filterAndSort(raw)
        #expect(filtered.count == 2)
        #expect(filtered[0].name == "en5")
        #expect(filtered[0].ip == "172.20.10.3")
        #expect(filtered[0].isHotspotOrUSB)
        #expect(filtered[1].name == "en0")
        #expect(filtered[1].ip == "192.168.1.42")
        #expect(!filtered[1].isHotspotOrUSB)
    }

    @Test func networkSnapshotPrefersLocalWithoutHotspotAndIPWithHotspot() {
        let wifiOnly = NetworkSnapshot(
            localHostName: "My-MacBook-Pro",
            interfaces: [NetworkInterfaceInfo(name: "en0", ip: "192.168.1.25")]
        )
        #expect(!wifiOnly.hasHotspotOrUSB)
        #expect(wifiOnly.mdnsHost == "My-MacBook-Pro.local")
        #expect(wifiOnly.preferredHost == "My-MacBook-Pro.local")
        #expect(wifiOnly.addressOptions.map(\.host) == ["My-MacBook-Pro.local", "192.168.1.25"])

        let withHotspot = NetworkSnapshot(
            localHostName: "My-MacBook-Pro",
            interfaces: [
                NetworkInterfaceInfo(name: "en5", ip: "172.20.10.4"),
                NetworkInterfaceInfo(name: "en0", ip: "192.168.1.25")
            ]
        )
        #expect(withHotspot.hasHotspotOrUSB)
        #expect(withHotspot.preferredHost == "172.20.10.4")
        #expect(
            withHotspot.addressOptions.map(\.host) == ["172.20.10.4", "My-MacBook-Pro.local", "192.168.1.25"]
        )

        let offline = NetworkSnapshot(localHostName: nil, interfaces: [])
        #expect(offline.preferredHost == "127.0.0.1")
    }
}
