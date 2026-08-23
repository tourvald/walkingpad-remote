import SwiftUI

struct StatusPillsRow: View {
    @EnvironmentObject private var manager: BluetoothManager
    @Binding var showDisconnectAlert: Bool
    @State private var showDevicePicker = false
    @State private var showConnectError = false
    @State private var presentSuggestedPicker = false
    @State private var showInfoToast = false
    // Removed: @State private var showConnectionSheet = false

    var body: some View {
        let staleSecs = manager.hrDataStaleSeconds
        let isStale = (manager.hrLastValueAt != nil) && !manager.hrStreamingActive

        let watchTitle: String
        let watchSubtitle: String?
        let watchColor: Color

        if !manager.watchPaired {
            watchTitle = "Часы не сопряжены"
            watchSubtitle = nil
            watchColor = .secondary
        } else if !manager.watchAppInstalled {
            watchTitle = "Нет приложения на часах"
            watchSubtitle = nil
            watchColor = .secondary
        } else if manager.watchReachable {
            if manager.hrStreamingActive {
                watchTitle = "Часы подключены"
                watchSubtitle = nil
                watchColor = .green
            } else {
                watchTitle = "Часы подключены"
                watchSubtitle = isStale ? "Нет пульса \(staleSecs) c" : "Нет пульса"
                watchColor = .orange
            }
        } else if manager.hrStreamingActive {
            watchTitle = "Часы в фоне"
            watchSubtitle = nil
            watchColor = .orange
        } else if !manager.hrPermissionGranted {
            watchTitle = "Нет разрешения HR"
            watchSubtitle = nil
            watchColor = .secondary
        } else {
            watchTitle = "Часы недоступны"
            watchSubtitle = isStale ? "Нет данных \(staleSecs) c" : nil
            watchColor = .secondary
        }

        return HStack(spacing: 10) {
            StatusPill(
                title: watchTitle,
                subtitle: watchSubtitle,
                systemImage: "applewatch",
                color: watchColor
            ) {
                manager.pingWatch()
            }
            Button {
                showDevicePicker = true
            } label: {
                StatusPillLabel(
                    title: manager.connectionStateText,
                    subtitle: manager.displayDeviceName,
                    systemImage: manager.isConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash",
                    color: manager.isConnected ? .green : .secondary
                )
            }
            .alert("Disconnect treadmill?", isPresented: $showDisconnectAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    manager.toggleConnection()
                }
            } message: {
                Text("The belt is currently connected. Are you sure you want to disconnect?")
            }
            .sheet(isPresented: $showDevicePicker) {
                DevicePickerView()
                    .environmentObject(manager)
            }
            .onChange(of: manager.connectErrorMessage) { oldValue, newValue in
                if newValue != nil { showConnectError = true }
            }
            .alert("Проблема с подключением", isPresented: $showConnectError, presenting: manager.connectErrorMessage) { _ in
                Button("Выбрать другую дорожку") {
                    manager.consumeConnectErrorMessage()
                    showDevicePicker = true
                }
                Button("OK", role: .cancel) {
                    manager.consumeConnectErrorMessage()
                }
            } message: { msg in
                Text(msg)
            }
            .onChange(of: manager.suggestDevicePicker) { oldValue, newValue in
                if newValue {
                    presentSuggestedPicker = true
                }
            }
            .sheet(isPresented: $presentSuggestedPicker, onDismiss: {
                // Reset the suggestion flag on dismiss to avoid repeated prompts
                manager.suggestDevicePicker = false
            }) {
                DevicePickerView()
                    .environmentObject(manager)
            }
            .onChange(of: manager.infoToastMessage) { oldValue, newValue in
                if newValue != nil { showInfoToast = true }
            }
            .alert("Информация", isPresented: $showInfoToast, presenting: manager.infoToastMessage) { _ in
                Button("Открыть выбор") { showDevicePicker = true }
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }
}

// Removed the entire ConnectionActionsSheet struct as instructed

struct StatusPill: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.caption2)
                            .hidden()
                    }
                }
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 44)
            .background(
                Capsule().fill(.regularMaterial)
            )
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct StatusPillLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(" ")
                        .font(.caption2)
                        .hidden()
                }
            }
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 44)
        .background(
            Capsule().fill(.regularMaterial)
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
