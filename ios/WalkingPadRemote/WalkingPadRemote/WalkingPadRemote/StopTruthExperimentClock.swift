import Foundation

struct StopTruthExperimentTimestamp: Codable, Equatable {
    let originID: UUID
    let monotonicUptimeNanoseconds: UInt64
    let monotonicElapsedSeconds: Double
    let wallDate: Date
}

struct StopTruthExperimentClock {
    typealias UptimeProvider = () -> UInt64
    typealias WallProvider = () -> Date

    let originID: UUID
    let originUptimeNanoseconds: UInt64
    private let uptimeProvider: UptimeProvider
    private let wallProvider: WallProvider

    init(
        originID: UUID = UUID(),
        uptimeProvider: @escaping UptimeProvider = { DispatchTime.now().uptimeNanoseconds },
        wallProvider: @escaping WallProvider = Date.init
    ) {
        self.originID = originID
        self.uptimeProvider = uptimeProvider
        self.wallProvider = wallProvider
        self.originUptimeNanoseconds = uptimeProvider()
    }

    func now() -> StopTruthExperimentTimestamp? {
        timestamp(uptimeNanoseconds: uptimeProvider(), wallDate: wallProvider())
    }

    func timestamp(
        uptimeNanoseconds: UInt64,
        wallDate: Date
    ) -> StopTruthExperimentTimestamp? {
        guard uptimeNanoseconds >= originUptimeNanoseconds else { return nil }
        return StopTruthExperimentTimestamp(
            originID: originID,
            monotonicUptimeNanoseconds: uptimeNanoseconds,
            monotonicElapsedSeconds: Double(uptimeNanoseconds - originUptimeNanoseconds) / 1_000_000_000,
            wallDate: wallDate
        )
    }

    func ageSeconds(
        since timestamp: StopTruthExperimentTimestamp,
        nowUptimeNanoseconds: UInt64? = nil
    ) -> Double? {
        guard timestamp.originID == originID else { return nil }
        let now = nowUptimeNanoseconds ?? uptimeProvider()
        guard now >= timestamp.monotonicUptimeNanoseconds else { return nil }
        return Double(now - timestamp.monotonicUptimeNanoseconds) / 1_000_000_000
    }
}
