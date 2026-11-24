import Foundation
import Security

public final class TokenStore: @unchecked Sendable {
    public static let defaultTokenKey = "AirTrackpad.PairingToken"
    public static let defaultPortKey = "AirTrackpad.PreferredPort"
    public static let defaultPort: UInt16 = 47291

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let tokenKey: String
    private var cachedToken: String

    public init(defaults: UserDefaults = .standard, tokenKey: String = TokenStore.defaultTokenKey) {
        self.defaults = defaults
        self.tokenKey = tokenKey

        if let existing = defaults.string(forKey: tokenKey), Self.isWellFormedHexToken(existing) {
            self.cachedToken = existing
        } else {
            let fresh = Self.generateHexToken()
            defaults.set(fresh, forKey: tokenKey)
            self.cachedToken = fresh
        }
    }

    public var currentToken: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedToken
    }

    @discardableResult
    public func rotateToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        let fresh = Self.generateHexToken()
        defaults.set(fresh, forKey: tokenKey)
        cachedToken = fresh
        return fresh
    }

    public func isValid(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.isEmpty else {
            return false
        }
        let expected = currentToken
        return Self.constantTimeEquals(candidate, expected)
    }

    public static func generateHexToken(byteCount: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isWellFormedHexToken(_ token: String) -> Bool {
        guard token.count == 32 else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || // 0-9
            (scalar.value >= 97 && scalar.value <= 102) || // a-f
            (scalar.value >= 65 && scalar.value <= 70) // A-F
        }
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let maxLen = max(aBytes.count, bBytes.count)
        guard maxLen > 0 else { return aBytes.isEmpty && bBytes.isEmpty }

        var diff: UInt8 = aBytes.count == bBytes.count ? 0 : 1
        for i in 0..<maxLen {
            let ca = i < aBytes.count ? aBytes[i] : 0
            let cb = i < bBytes.count ? bBytes[i] : 0
            diff |= (ca ^ cb)
        }
        return diff == 0
    }

    public static func loadPreferredPort(
        defaults: UserDefaults = .standard,
        key: String = defaultPortKey
    ) -> UInt16 {
        let stored = defaults.integer(forKey: key)
        if stored >= 1024 && stored <= Int(UInt16.max) {
            return UInt16(stored)
        }
        return defaultPort
    }

    public static func savePreferredPort(
        _ port: UInt16,
        defaults: UserDefaults = .standard,
        key: String = defaultPortKey
    ) {
        defaults.set(Int(port), forKey: key)
    }
}
