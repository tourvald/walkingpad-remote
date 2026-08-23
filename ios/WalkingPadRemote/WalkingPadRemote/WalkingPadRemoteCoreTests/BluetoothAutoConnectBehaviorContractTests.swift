import Foundation
import XCTest

final class BluetoothAutoConnectBehaviorContractTests: XCTestCase {
    private lazy var managerSource = source(
        relativePath: "WalkingPadRemote/BluetoothManager.swift"
    )

    func testRetrievedKnownPeripheralsReuseTheProtectedConnectionPath() throws {
        let autoConnect = try functionBody(
            "private func attemptAutoConnectIfNeeded()",
            in: managerSource
        )
        let preferredKnown = try functionBody(
            "private func preferredKnownPeripheral(from peripherals: [CBPeripheral])",
            in: managerSource
        )

        XCTAssertFalse(autoConnect.contains("central.connect("))
        XCTAssertTrue(autoConnect.contains("retrieveConnectedPeripherals"))
        XCTAssertTrue(autoConnect.contains("retrievePeripherals(withIdentifiers: ids)"))
        XCTAssertEqual(
            autoConnect.components(separatedBy: "preferredKnownPeripheral(from:").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            autoConnect.components(separatedBy: "connectToDiscovered(id:").count - 1,
            3
        )
        XCTAssertTrue(preferredKnown.contains("knownPeripherals.lazy.compactMap"))
        XCTAssertTrue(preferredKnown.contains("$0.identifier == known.id"))
        XCTAssertTrue(autoConnect.contains("clearsAutoConnectSuppression: false"))
    }

    func testConnectionPathPreventsParallelAttemptsAndSchedulesTimeouts() throws {
        let connect = try functionBody(
            "func connectToDiscovered(",
            in: managerSource
        )

        assertOrdered(
            [
                "if isConnected",
                "if let inProgress = connectingPeripheralId",
                "connectingPeripheralId = id",
                "central.connect(p, options: nil)",
                "scheduleConnectTimeout(for: id)",
            ],
            in: connect
        )
        XCTAssertEqual(connect.components(separatedBy: "central.connect(p, options: nil)").count - 1, 2)
        XCTAssertEqual(connect.components(separatedBy: "scheduleConnectTimeout(for: id)").count - 1, 2)
        XCTAssertTrue(managerSource.contains("clearsAutoConnectSuppression: Bool = true"))
        XCTAssertTrue(connect.contains("if clearsAutoConnectSuppression"))
    }

    func testTimeoutAndFailureReturnToFilteredDiscoveryScan() throws {
        let timeout = try functionBody(
            "private func scheduleConnectTimeout(for id: UUID, seconds: TimeInterval = 12)",
            in: managerSource
        )
        let failure = try functionBody(
            "func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)",
            in: managerSource
        )
        let disconnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)",
            in: managerSource
        )
        let resumeScan = try functionBody(
            "private func resumeDiscoveryScanIfNeeded()",
            in: managerSource
        )

        assertOrdered(
            [
                "guard self.connectingPeripheralId == id",
                "self.cancellingConnectionPeripheralId = id",
                "central.cancelPeripheralConnection(p)",
            ],
            in: timeout
        )
        XCTAssertFalse(timeout.contains("self.connectingPeripheralId = nil"))
        XCTAssertTrue(timeout.contains("self.connectTimeoutWorkItem = nil"))
        XCTAssertTrue(timeout.contains("self.connectingPeripheral"))
        XCTAssertTrue(failure.contains("guard self.connectingPeripheralId == peripheral.identifier"))
        XCTAssertTrue(failure.contains("self.connectingPeripheralId = nil"))
        XCTAssertTrue(failure.contains("self.resumeDiscoveryScanIfNeeded()"))
        XCTAssertTrue(disconnect.contains("self.connectingPeripheralId == peripheralID"))
        XCTAssertTrue(disconnect.contains("self.resumeDiscoveryScanIfNeeded()"))
        XCTAssertTrue(resumeScan.contains("shouldBeScanning"))
        XCTAssertTrue(resumeScan.contains("central.state == .poweredOn"))
        XCTAssertTrue(resumeScan.contains("scanForPeripherals"))
        XCTAssertTrue(resumeScan.contains("supportedServiceUuids"))
    }

    func testKnownDiscoveryAndUserSuppressionPolicyRemainIntact() throws {
        let discovery = try functionBody(
            "func centralManager(_ central: CBCentralManager,\n                        didDiscover peripheral: CBPeripheral,",
            in: managerSource
        )
        let disconnect = try functionBody(
            "private func disconnect(userInitiated: Bool = false)",
            in: managerSource
        )
        let forget = try functionBody(
            "func forgetKnownPeripheral(id: UUID)",
            in: managerSource
        )

        XCTAssertTrue(discovery.contains("if self.autoConnectSuppressed"))
        XCTAssertTrue(discovery.contains("self.preferredKnownDiscoveredPeripheral() != nil"))
        XCTAssertTrue(discovery.contains("self.connectToDiscovered("))
        XCTAssertTrue(discovery.contains("clearsAutoConnectSuppression: false"))
        XCTAssertTrue(disconnect.contains("if userInitiated"))
        XCTAssertTrue(disconnect.contains("autoConnectSuppressed = true"))
        XCTAssertTrue(forget.contains("self.autoConnectSuppressed = true"))
        XCTAssertTrue(forget.contains("self.connectingPeripheralId == id"))
        XCTAssertTrue(forget.contains("self.connectingPeripheral"))
        XCTAssertTrue(forget.contains("self.cancellingConnectionPeripheralId = id"))
        XCTAssertTrue(forget.contains("central.cancelPeripheralConnection(peripheral)"))
    }

    func testLateConnectionAfterCancellationCannotBecomeConnectedOrKnown() throws {
        let didConnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)",
            in: managerSource
        )

        assertOrdered(
            [
                "guard self.connectingPeripheralId == peripheralID",
                "if self.cancellingConnectionPeripheralId == peripheralID || self.autoConnectSuppressed",
                "central.cancelPeripheralConnection(peripheral)",
                "self.logTrainingEvent(\"ble_connection_event\"",
                "self.isConnected = true",
                "central.stopScan()",
                "self.knownPeripherals.append",
            ],
            in: didConnect
        )
        XCTAssertEqual(didConnect.components(separatedBy: "central.stopScan()").count - 1, 1)
    }

    func testEstablishedUserDisconnectRetainsIdentityUntilNormalCleanup() throws {
        let disconnect = try functionBody(
            "private func disconnect(userInitiated: Bool = false)",
            in: managerSource
        )
        let didDisconnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)",
            in: managerSource
        )

        assertOrdered(
            [
                "if let id = connectedPeripheralId, let p = discoveredMap[id]",
                "cancellingConnectionPeripheralId = id",
                "central.cancelPeripheralConnection(p)",
            ],
            in: disconnect
        )
        assertOrdered(
            [
                "let endedEstablishedConnection",
                "self.cancellingConnectionPeripheralId == peripheralID",
                "guard endedConnectionAttempt || endedEstablishedConnection",
                "if endedConnectionAttempt",
                "self.resetProtocolState()",
                "self.connectedPeripheral = nil",
                "self.manualModeSet = false",
            ],
            in: didDisconnect
        )
    }

    func testEqualRssiKnownCandidatesUsePersistedOrderAsTieBreak() throws {
        let preferredKnown = try functionBody(
            "private func preferredKnownDiscoveredPeripheral()",
            in: managerSource
        )
        let autoConnect = try functionBody(
            "private func attemptAutoConnectIfNeeded()",
            in: managerSource
        )

        XCTAssertTrue(preferredKnown.contains("if lhs.rssi != rhs.rssi"))
        XCTAssertTrue(preferredKnown.contains("let knownIDs = Set(knownPeripherals.map(\\.id))"))
        XCTAssertTrue(preferredKnown.contains("knownIDs.contains($0.id)"))
        XCTAssertTrue(preferredKnown.contains("knownPeripherals.firstIndex"))
        XCTAssertTrue(preferredKnown.contains("return lhsIndex > rhsIndex"))
        XCTAssertTrue(autoConnect.contains("preferredKnownDiscoveredPeripheral()"))
    }

    func testUnknownAutoConnectRemainsExplicitlyOptIn() throws {
        let autoConnect = try functionBody(
            "private func attemptAutoConnectIfNeeded()",
            in: managerSource
        )

        XCTAssertTrue(managerSource.contains("@Published var allowAutoConnectUnknown: Bool = false"))
        XCTAssertTrue(autoConnect.contains("if allowAutoConnectUnknown"))
        XCTAssertTrue(autoConnect.contains("clearsAutoConnectSuppression: false"))
        XCTAssertTrue(
            autoConnect.contains(
                "self.knownPeripherals.isEmpty && self.allowAutoConnectUnknown && !self.autoConnectSuppressed"
            )
        )
    }

    private func source(relativePath: String) -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDirectory.deletingLastPathComponent()
        return (try? String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )) ?? ""
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
        else {
            throw NSError(domain: "BluetoothAutoConnectBehaviorContractTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "BluetoothAutoConnectBehaviorContractTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for fragment in fragments {
            guard let range = source.range(
                of: fragment,
                range: lowerBound..<source.endIndex
            ) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}
