import SwiftUI
import Combine
import CoreBluetooth

private struct RenamingTarget: Identifiable, Equatable { let id: UUID }

private enum DevicePickerFormatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

@MainActor
private final class BluetoothStateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var state: CBManagerState = .unknown
    private var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        state = central.state
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.state = central.state
    }

    var isPoweredOn: Bool { state == .poweredOn }
}

@MainActor
struct DevicePickerView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isScanning: Bool = true
    @State private var renamingTarget: RenamingTarget? = nil
    @State private var renameText: String = ""
    @State private var lastUpdate: Date = Date()
    @StateObject private var btMonitor = BluetoothStateMonitor()
    @State private var scanSessionId: UUID = UUID()
    @State private var interactionQuietActive: Bool = false
    @State private var interactionQuietToken: UUID = UUID()

    private var lastUpdateText: String {
        "обновлено: \(DevicePickerFormatters.time.string(from: lastUpdate))"
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -50 { return .green }
        if rssi >= -70 { return .orange }
        return .secondary
    }
    private func shortId(_ id: UUID) -> String {
        String(id.uuidString.suffix(4))
    }

    private func scheduleScanTimeout() {
        let currentId = UUID()
        scanSessionId = currentId
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak manager] in
            guard let manager = manager else { return }
            if scanSessionId == currentId && isScanning && manager.discoveryUIPeripherals.isEmpty {
                isScanning = false
                manager.stopDiscoveryScan()
                lastUpdate = Date()
            }
        }
    }

    private func markUpdated(force: Bool = false) {
        if force || Date().timeIntervalSince(lastUpdate) >= 0.4 {
            lastUpdate = Date()
        }
    }

    private func startScanIfPossible(refresh: Bool = true) {
        guard btMonitor.isPoweredOn, scenePhase == .active, !manager.isConnected, !interactionQuietActive else { return }
        if !isScanning { isScanning = true }
        manager.startDiscoveryScan()
        if refresh { manager.refreshDiscovery() }
        markUpdated(force: true)
        scheduleScanTimeout()
    }

    private func engageInteractionQuietScan(for seconds: TimeInterval = 1.4) {
        guard isScanning, renamingTarget == nil else { return }
        let token = UUID()
        interactionQuietToken = token
        if !interactionQuietActive {
            interactionQuietActive = true
            manager.stopDiscoveryScan()
            markUpdated(force: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak manager] in
            guard let manager = manager else { return }
            guard interactionQuietToken == token else { return }
            interactionQuietActive = false
            if btMonitor.isPoweredOn, scenePhase == .active, !manager.isConnected, isScanning, renamingTarget == nil {
                startScanIfPossible(refresh: false)
            }
        }
    }

    private func presentRenameSheet(for peripheral: BluetoothManager.KnownPeripheral) {
        interactionQuietToken = UUID()
        interactionQuietActive = false
        renameText = peripheral.name
        renamingTarget = RenamingTarget(id: peripheral.id)
        if isScanning {
            isScanning = false
            manager.stopDiscoveryScan()
            markUpdated(force: true)
        }
    }

    @ViewBuilder
    private func KnownPeripheralsSection() -> some View {
        if !manager.knownPeripherals.isEmpty {
            Section("Известные") {
                ForEach(manager.knownPeripherals) { kp in
                    HStack {
                        Button {
                            manager.connectToKnownPeripheral(id: kp.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kp.name)
                                        .foregroundStyle(.primary)
                                    Text("ID: \(shortId(kp.id))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if manager.connectedPeripheralId == kp.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                        if pressing {
                            engageInteractionQuietScan(for: 2.0)
                        }
                    }, perform: {})
                    .swipeActions(edge: .trailing) {
                        if manager.connectedPeripheralId == kp.id {
                            Button {
                                manager.disconnectFromCurrent()
                            } label: {
                                Label("Отключиться", systemImage: "bolt.slash")
                            }
                            .tint(.orange)
                        }
                        Button(role: .destructive) {
                            manager.forgetKnownPeripheral(id: kp.id)
                        } label: {
                            Label("Забыть", systemImage: "trash")
                        }
                        Button {
                            presentRenameSheet(for: kp)
                        } label: {
                            Label("Переименовать", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        if manager.connectedPeripheralId == kp.id {
                            Button {
                                manager.disconnectFromCurrent()
                            } label: {
                                Label("Отключиться", systemImage: "bolt.slash")
                            }
                        }
                        Button {
                            presentRenameSheet(for: kp)
                        } label: {
                            Label("Переименовать", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            manager.forgetKnownPeripheral(id: kp.id)
                        } label: {
                            Label("Забыть", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func DiscoveryHeader() -> some View {
        HStack(spacing: 8) {
            Text("Устройств: \(manager.discoveryUIPeripherals.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(lastUpdateText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func DiscoveredPeripheralsSection() -> some View {
        Section("Найденные рядом") {
            DiscoveryHeader()
            if scenePhase != .active {
                Text("Сканирование приостановлено — приложение в фоне")
                    .foregroundStyle(.secondary)
            } else if !btMonitor.isPoweredOn {
                Text("Bluetooth выключен — включите Bluetooth")
                    .foregroundStyle(.secondary)
            } else if manager.isConnected {
                Text("Сканирование отключено — уже подключены к дорожке")
                    .foregroundStyle(.secondary)
            } else if manager.discoveryUIPeripherals.isEmpty {
                if isScanning {
                    HStack {
                        ProgressView()
                        Text("Сканирование устройств…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Нет найденных устройств")
                        .foregroundStyle(.secondary)
                }
                Button {
                    manager.stopDiscoveryScan()
                    manager.refreshDiscovery()
                    startScanIfPossible(refresh: false)
                    markUpdated(force: true)
                } label: {
                    Label("Повторить поиск", systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(manager.discoveryUIPeripherals) { d in
                    Button {
                        manager.connectToDiscovered(id: d.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(rssiColor(d.rssi))
                                .frame(width: 10, height: 10)
                                .accessibilityLabel(Text("Сигнал: \(d.rssi) dBm"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name.isEmpty ? "Без имени" : d.name)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text("Сигнал: \(d.rssi) dBm")
                                    Text("•")
                                    Text(d.isKnown ? "Известная" : "Новая")
                                    Text("•")
                                    Text("ID: \(shortId(d.id))")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if manager.connectedPeripheralId == d.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ToolbarControls() -> some View {
        HStack(spacing: 12) {
            let refreshDisabled = manager.isConnected || scenePhase != .active || !btMonitor.isPoweredOn
            Button {
                manager.stopDiscoveryScan()
                manager.refreshDiscovery()
                startScanIfPossible(refresh: false)
                markUpdated(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(refreshDisabled)

            Toggle(isOn: Binding(get: { isScanning }, set: { newVal in
                isScanning = newVal
                if newVal {
                    startScanIfPossible()
                } else {
                    manager.stopDiscoveryScan()
                }
            })) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(isScanning ? .primary : .secondary)
            }
            .labelsHidden()
            .accessibilityLabel("Сканирование Bluetooth")
            .disabled(refreshDisabled)

            Toggle(isOn: Binding(get: { manager.allowAutoConnectUnknown }, set: { manager.allowAutoConnectUnknown = $0 })) {
                Image(systemName: manager.allowAutoConnectUnknown ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
            }
            .help("Разрешать автоподключение к неизвестным")
            .labelsHidden()
            .accessibilityLabel("Автоподключение к неизвестным")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                KnownPeripheralsSection()
                DiscoveredPeripheralsSection()

                if manager.allowAutoConnectUnknown {
                    Section(footer: Text("Автоподключение к неизвестным включено — приложение может подключиться к ближайшей дорожке этой модели без подтверждения.").font(.caption2).foregroundStyle(.secondary)) { EmptyView() }
                } else {
                    Section(footer: Text("Автоподключение к неизвестным выключено — новые дорожки появятся в списке, но подключение будет только вручную.").font(.caption2).foregroundStyle(.secondary)) { EmptyView() }
                }
            }
            .navigationTitle("Выбрать дорожку")
            .transaction { transaction in
                transaction.animation = nil
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in
                        engageInteractionQuietScan(for: 1.0)
                    }
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarControls()
                }
            }
            .task {
                if manager.isConnected {
                    isScanning = false
                    manager.stopDiscoveryScan()
                    markUpdated(force: true)
                } else {
                    // По умолчанию хотим сканировать, как только Bluetooth будет готов
                    isScanning = true
                    startScanIfPossible()
                }
            }
            .onChange(of: manager.isConnected) { oldValue, newValue in
                if newValue {
                    isScanning = false
                    manager.stopDiscoveryScan()
                } else {
                    startScanIfPossible()
                }
            }
            .onChange(of: manager.allowAutoConnectUnknown) { oldValue, newValue in
                if newValue && scenePhase == .active && btMonitor.isPoweredOn && !manager.isConnected {
                    if !isScanning { isScanning = true }
                    startScanIfPossible()
                }
            }
            .onChange(of: manager.discoveryUIPeripherals.count) { _, _ in
                markUpdated()
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                if newValue == .active {
                    startScanIfPossible()
                } else {
                    manager.stopDiscoveryScan()
                }
            }
            .onChange(of: btMonitor.state) { oldValue, newValue in
                if newValue == .poweredOn {
                    startScanIfPossible()
                } else {
                    isScanning = false
                    manager.stopDiscoveryScan()
                }
            }
            .onChange(of: isScanning) { oldValue, newValue in
                if newValue {
                    scheduleScanTimeout()
                }
            }
            .onDisappear {
                interactionQuietToken = UUID()
                interactionQuietActive = false
                manager.stopDiscoveryScan()
            }
            .sheet(item: $renamingTarget) { target in
                RenameKnownDeviceSheet(id: target.id, initialName: renameText) { newName in
                    manager.renameKnownPeripheral(id: target.id, newName: newName)
                }
            }
            .onChange(of: renamingTarget) { _, newValue in
                guard newValue == nil else { return }
                if btMonitor.isPoweredOn, scenePhase == .active, !manager.isConnected {
                    startScanIfPossible(refresh: false)
                }
            }
        }
    }
}

#Preview {
    let m = BluetoothManager()
    return DevicePickerView()
        .environmentObject(m)
}

struct RenameKnownDeviceSheet: View {
    let id: UUID
    let initialName: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Новое имя")) {
                    TextField("Введите имя", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .focused($nameFieldFocused)
                }
            }
            .navigationTitle("Переименовать")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        onSave(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = initialName
                nameFieldFocused = true
            }
        }
    }
}

#Preview("RenameKnownDeviceSheet") {
    RenameKnownDeviceSheet(id: UUID(), initialName: "Дорожка 1") { _ in }
}
