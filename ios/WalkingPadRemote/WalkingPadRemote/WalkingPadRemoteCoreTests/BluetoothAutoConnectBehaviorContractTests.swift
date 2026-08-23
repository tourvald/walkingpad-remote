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
            3
        )
        XCTAssertGreaterThanOrEqual(
            autoConnect.components(separatedBy: "connectToDiscovered(id:").count - 1,
            3
        )
        XCTAssertTrue(preferredKnown.contains("orderedAutoConnectCandidateIDs.lazy.compactMap"))
        XCTAssertTrue(preferredKnown.contains("$0.identifier == candidateID"))
        XCTAssertTrue(autoConnect.contains("clearsAutoConnectSuppression: false"))
    }

    func testLastSuccessfulKnownPeripheralOwnsStartupPriorityAndPersistence() throws {
        let start = try functionBody("func start()", in: managerSource)
        let loadPreference = try functionBody(
            "private func loadLastSuccessfulPeripheral()",
            in: managerSource
        )
        let candidateOrder = try functionBody(
            "private var orderedAutoConnectCandidateIDs: [UUID]",
            in: managerSource
        )
        let didConnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)",
            in: managerSource
        )
        let rememberValidated = try functionBody(
            "private func rememberCurrentValidatedTreadmill()",
            in: managerSource
        )
        let forget = try functionBody("func forgetKnownPeripheral(id: UUID)", in: managerSource)
        let disconnect = try functionBody(
            "private func disconnect(userInitiated: Bool = false)",
            in: managerSource
        )

        assertOrdered(
            ["loadKnownPeripherals()", "loadLastSuccessfulPeripheral()"],
            in: start
        )
        XCTAssertTrue(loadPreference.contains("knownPeripherals.contains"))
        XCTAssertTrue(loadPreference.contains("lastSuccessfulPeripheralID = peripheralID"))
        XCTAssertTrue(candidateOrder.contains("ordered.insert(lastSuccessfulPeripheralID, at: 0)"))
        XCTAssertFalse(didConnect.contains("self.knownPeripherals.append"))
        XCTAssertFalse(didConnect.contains("self.saveLastSuccessfulPeripheral"))
        assertOrdered(
            [
                "guard isTreadmillControlReady",
                "knownPeripherals.append",
                "saveLastSuccessfulPeripheral(peripheral.identifier)",
            ],
            in: rememberValidated
        )
        XCTAssertTrue(forget.contains("if self.lastSuccessfulPeripheralID == id"))
        XCTAssertTrue(forget.contains("removeObject(forKey: self.lastSuccessfulPeripheralStoreKey)"))
        XCTAssertFalse(disconnect.contains("lastSuccessfulPeripheral"))
    }

    func testKnownStartupGivesScanGraceBeforeRetrievedFallback() throws {
        let start = try functionBody("func start()", in: managerSource)
        let autoConnect = try functionBody(
            "private func attemptAutoConnectIfNeeded()",
            in: managerSource
        )
        let grace = try functionBody(
            "private func scheduleKnownDiscoveryFallbackIfNeeded()",
            in: managerSource
        )
        let discovery = try functionBody(
            "func centralManager(_ central: CBCentralManager,\n                        didDiscover peripheral: CBPeripheral,",
            in: managerSource
        )

        assertOrdered(["startDiscoveryScan()", "attemptAutoConnectIfNeeded()"], in: start)
        assertOrdered(
            [
                "retrieveConnectedPeripherals",
                "connectedList.first(where: { $0.identifier == lastSuccessfulPeripheralID })",
                "guard knownDiscoveryGraceCompleted",
                "scheduleKnownDiscoveryFallbackIfNeeded()",
                "retrievePeripherals(withIdentifiers: ids)",
            ],
            in: autoConnect
        )
        XCTAssertTrue(grace.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 1.0"))
        XCTAssertTrue(grace.contains("self.attemptAutoConnectIfNeeded()"))
        XCTAssertTrue(discovery.contains("self.attemptAutoConnectIfNeeded()"))
        XCTAssertFalse(discovery.contains("central.connect("))
    }

    func testAutomaticFailuresStaySilentAndFallBackSerially() throws {
        let failure = try functionBody(
            "func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)",
            in: managerSource
        )
        let timeout = try functionBody(
            "private func scheduleConnectTimeout(for id: UUID, seconds: TimeInterval = 12)",
            in: managerSource
        )
        let disconnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)",
            in: managerSource
        )

        assertOrdered(
            [
                "let wasAutomatic = self.connectingAttemptIsAutomatic",
                "if wasAutomatic",
                "self.markAutoConnectCandidateFailed",
                "self.connectErrorMessage = error?.localizedDescription",
                "self.connectingPeripheralId = nil",
                "self.attemptAutoConnectIfNeeded()",
            ],
            in: failure
        )
        XCTAssertTrue(timeout.contains("if !self.connectingAttemptIsAutomatic"))
        XCTAssertTrue(timeout.contains("self.connectErrorMessage = \"Connection timeout\""))
        XCTAssertTrue(disconnect.contains("shouldContinueAutoConnect"))
        XCTAssertTrue(disconnect.contains("self.markAutoConnectCandidateFailed"))
        XCTAssertTrue(disconnect.contains("self.attemptAutoConnectIfNeeded()"))
    }

    func testExhaustedKnownRoundRearmsOneFreshDiscoveryAfterCooldown() throws {
        let markFailed = try functionBody(
            "private func markAutoConnectCandidateFailed(_ peripheralID: UUID)",
            in: managerSource
        )
        let rearm = try functionBody(
            "private func rearmAutoConnectCandidateAfterFreshDiscovery(",
            in: managerSource
        )
        let discovery = try functionBody(
            "func centralManager(_ central: CBCentralManager,\n                        didDiscover peripheral: CBPeripheral,",
            in: managerSource
        )

        XCTAssertTrue(markFailed.contains("autoConnectRetryPolicy.markFailed(peripheralID)"))
        XCTAssertTrue(rearm.contains("autoConnectRetryPolicy.rearmAfterFreshDiscovery"))
        XCTAssertTrue(rearm.contains("knownPeripheralIDs: Set(knownPeripherals.map(\\.id))"))
        XCTAssertEqual(
            discovery.components(separatedBy: "rearmAutoConnectCandidateAfterFreshDiscovery(").count - 1,
            1
        )
        XCTAssertTrue(
            discovery.contains("if rearmedKnownCandidate || self.preferredKnownDiscoveredPeripheral() != nil")
        )
        assertOrdered(
            [
                "rearmAutoConnectCandidateAfterFreshDiscovery(",
                "self.attemptAutoConnectIfNeeded()",
            ],
            in: discovery
        )
    }

    func testSuccessfulConnectionAndAlertDismissalConsumeStaleErrors() throws {
        let didConnect = try functionBody(
            "func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)",
            in: managerSource
        )
        let consume = try functionBody("func consumeConnectErrorMessage()", in: managerSource)
        let contentSource = source(relativePath: "WalkingPadRemote/ContentView.swift")
        let statusSource = source(relativePath: "WalkingPadRemote/StatusPillsRow.swift")

        assertOrdered(
            ["guard self.connectingPeripheralId == peripheralID", "self.connectErrorMessage = nil", "self.isConnected = true"],
            in: didConnect
        )
        XCTAssertTrue(consume.contains("connectErrorMessage = nil"))
        XCTAssertEqual(
            contentSource.components(separatedBy: "manager.consumeConnectErrorMessage()").count - 1,
            2
        )
        XCTAssertEqual(
            statusSource.components(separatedBy: "manager.consumeConnectErrorMessage()").count - 1,
            2
        )
    }

    func testStartupInventoryParsingRunsOffTheFirstFramePath() throws {
        let refresh = try functionBody("func refreshTrainingLogsInventory()", in: managerSource)

        assertOrdered(
            [
                "trainingLogQueue.async",
                "TrainingTelemetryWriter.trainingLogsInventorySnapshot",
                "DispatchQueue.main.async",
                "self.trainingLogsInventory = snapshot.inventory",
                "self.lastTrainingLogPath = snapshot.latestMatchingProfileFile?.path",
            ],
            in: refresh
        )
    }

    func testConnectionPathPreventsParallelAttemptsAndSchedulesTimeouts() throws {
        let connect = try functionBody(
            "func connectToDiscovered(",
            in: managerSource
        )

        assertOrdered(
            [
                "if isConnected",
                "if let cancellingConnectionPeripheralId",
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
                "if self.cancellingConnectionPeripheralId != nil || self.autoConnectSuppressed",
                "central.cancelPeripheralConnection(peripheral)",
                "self.logTrainingEvent(\"ble_connection_event\"",
                "self.isConnected = true",
                "central.stopScan()",
            ],
            in: didConnect
        )
        XCTAssertFalse(didConnect.contains("knownPeripherals.append"))
        XCTAssertTrue(managerSource.contains("Connect known skipped: cancellation pending"))
        XCTAssertTrue(managerSource.contains("Connect discovered skipped: cancellation pending"))
        XCTAssertTrue(managerSource.contains("AutoConnect skipped: cancellation pending"))
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
        XCTAssertTrue(preferredKnown.contains("let candidateIDs = orderedAutoConnectCandidateIDs"))
        XCTAssertTrue(preferredKnown.contains("candidateIDs.contains($0.id)"))
        XCTAssertTrue(preferredKnown.contains("lastSuccessfulPeripheralID"))
        XCTAssertTrue(preferredKnown.contains("candidateIDs.firstIndex"))
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

    func testControlReadinessUsesCurrentSubscribedTransportAndResetsTheQueue() throws {
        let reset = try functionBody("private func resetProtocolState()", in: managerSource)
        let services = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)",
            in: managerSource
        )
        let characteristics = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)",
            in: managerSource
        )
        let notification = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)",
            in: managerSource
        )
        let valueUpdate = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)",
            in: managerSource
        )
        let writeUpdate = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)",
            in: managerSource
        )
        let modifiedServices = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])",
            in: managerSource
        )

        XCTAssertTrue(managerSource.contains("@Published private(set) var isTreadmillControlReady: Bool = false"))
        assertOrdered(
            [
                "resetCommandQueue(",
                "treadmillProtocolConnection = nil",
                "commandCharacteristicConnection = nil",
                "notifyCharacteristicConnection = nil",
                "isTreadmillControlReady = false",
            ],
            in: reset
        )
        XCTAssertTrue(services.contains("peripheral === connectedPeripheral"))
        XCTAssertTrue(services.contains("treadmillProtocolConnection = currentTreadmillControlConnection"))
        XCTAssertTrue(services.contains("invalidateTreadmillControlReadinessEvidence(includingProtocol: true)"))
        XCTAssertTrue(characteristics.contains("commandCharacteristicConnection = currentTreadmillControlConnection"))
        XCTAssertTrue(characteristics.contains("notifyCharacteristic = dataChar"))
        XCTAssertTrue(characteristics.contains("notifyCharacteristic = rx"))
        XCTAssertTrue(characteristics.contains("invalidateTreadmillControlReadinessEvidence()"))
        XCTAssertTrue(notification.contains("characteristic === notifyCharacteristic"))
        XCTAssertTrue(notification.contains("characteristic.isNotifying"))
        XCTAssertTrue(notification.contains("recomputeTreadmillControlReadiness()"))
        XCTAssertTrue(valueUpdate.contains("peripheral === connectedPeripheral"))
        XCTAssertTrue(valueUpdate.contains("isCurrentCharacteristicCallback(characteristic)"))
        XCTAssertTrue(valueUpdate.contains("Ignoring value update from stale peripheral"))
        XCTAssertTrue(valueUpdate.contains("ftmsControlRequestConnection == currentTreadmillControlConnection"))
        XCTAssertTrue(writeUpdate.contains("characteristic === commandCharacteristic"))
        XCTAssertTrue(writeUpdate.contains("isCurrentCharacteristicCallback(characteristic)"))
        XCTAssertTrue(modifiedServices.contains("$0 === selectedService"))
        XCTAssertTrue(modifiedServices.contains("invalidateTreadmillControlReadinessEvidence(includingProtocol: true)"))
    }

    func testProductionMotionUsesReadinessWhileStopRemainsLinkBased() throws {
        let start = try functionBody("func startWithSpeed(_ kmh: Double)", in: managerSource)
        let slider = try functionBody("func setTargetSpeedFromSlider(_ kmh: Double)", in: managerSource)
        let adjust = try functionBody("func adjustSpeed(delta: Double)", in: managerSource)
        let hrStart = try functionBody("func startHrControl()", in: managerSource)
        let testRun = try functionBody("var canStartTreadmillTestRun: Bool", in: managerSource)
        let speedWrite = try functionBody("private func sendTreadmillSetSpeed(", in: managerSource)
        let performWrite = try functionBody("private func performWrite(", in: managerSource)
        let stop = try functionBody("func stopBelt()", in: managerSource)

        XCTAssertTrue(start.contains("guard isTreadmillControlReady"))
        XCTAssertTrue(slider.contains("guard isTreadmillControlReady"))
        XCTAssertTrue(adjust.contains("guard isTreadmillControlReady"))
        XCTAssertTrue(hrStart.contains("treadmillConnected: isTreadmillControlReady"))
        XCTAssertTrue(testRun.contains("isTreadmillControlReady"))
        XCTAssertTrue(speedWrite.contains("guard isTreadmillControlReady"))
        XCTAssertTrue(performWrite.contains("requiresControlReadiness && !isTreadmillControlReady"))
        XCTAssertTrue(stop.contains("guard isConnected"))
        XCTAssertFalse(stop.contains("isTreadmillControlReady"))

        let content = source(relativePath: "WalkingPadRemote/ContentView.swift")
        XCTAssertTrue(content.contains("treadmillConnected: manager.isTreadmillControlReady"))
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
