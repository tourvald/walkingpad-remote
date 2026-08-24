enum DiscoveryUIPublicationPolicy {
    // Suppress normal 1–2 dBm jitter while keeping the UI snapshot within 2 dBm of factual RSSI.
    static let minimumRSSIDelta = 3

    static func shouldPublish(
        currentName: String,
        currentRSSI: Int,
        currentIsKnown: Bool,
        nextName: String,
        nextRSSI: Int,
        nextIsKnown: Bool
    ) -> Bool {
        currentName != nextName
            || currentIsKnown != nextIsKnown
            || abs(nextRSSI - currentRSSI) >= minimumRSSIDelta
    }
}
