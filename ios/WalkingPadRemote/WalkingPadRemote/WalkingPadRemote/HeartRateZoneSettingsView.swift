import SwiftUI

struct HeartRateZoneSettingsView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var maximumText = ""
    @State private var maximumError: String?
    @State private var maximumProfileID: UUID?
    @FocusState private var maximumFocused: Bool

    private let colors: [Color] = [.cyan, .green, .yellow, .orange, .red]
    private var isManual: Bool { manager.heartRateZoneSettings.source == .manual }
    private var isEditable: Bool { manager.canEditHeartRateZoneSettings && !manager.heartRateZoneReadInFlight }
    private var bounds: [Int] { manager.heartRateZoneSettings.effectiveUpperBounds }

    var body: some View {
        Form {
            Section {
                if #available(iOS 27.0, *) {
                    Picker("Источник", selection: Binding(
                        get: { manager.heartRateZoneSettings.source },
                        set: { source in
                            if source == .manual {
                                manager.useManualHeartRateZones()
                            } else {
                                Task { await manager.readAppleHeartRateZones(requestAuthorization: true) }
                            }
                        }
                    )) {
                        Text("Вручную").tag(HeartRateZoneSettings.Source.manual)
                        Text("Apple Health").tag(HeartRateZoneSettings.Source.appleHealth)
                    }
                    .disabled(!isEditable)
                } else {
                    LabeledContent("Источник", value: "Вручную")
                }
            } footer: {
                Text("Границы сохраняются для выбранного профиля. Apple Health содержит данные владельца iPhone — подключайте его только к своему профилю.")
            }

            Section {
                ForEach(0..<5) { index in
                    HStack {
                        Circle().fill(colors[index]).frame(width: 9, height: 9)
                        if isManual && index < 4 {
                            Stepper(value: Binding(
                                get: { bounds[index] },
                                set: { manager.updateManualHeartRateZone(index: index, upperBound: $0) }
                            ), in: permittedRange(index)) {
                                zoneLabel(index)
                            }
                            .disabled(!isEditable)
                        } else {
                            zoneLabel(index)
                        }
                    }
                    .frame(minHeight: 38)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            } header: {
                Text("Пульсовые зоны")
            } footer: {
                Text(isManual
                     ? "Укажите верхние границы зон 1–4. Зона 5 начинается со следующего удара."
                     : "Границы из Apple Health доступны только для чтения. Чтобы изменить их здесь, выберите «Вручную».")
            }

            if #available(iOS 27.0, *) {
                Section {
                    if manager.heartRateZoneReadInFlight {
                        HStack { ProgressView(); Text("Чтение зон…") }
                    }
                    if let snapshot = manager.heartRateZoneSettings.appleSnapshot, !isManual {
                        LabeledContent("Расчёт Apple", value: snapshot.configuration == "automatic" ? "Автоматический" : "Вручную")
                        LabeledContent("Обновлено") {
                            Text(snapshot.fetchedAt, format: .dateTime.day().month().hour().minute())
                        }
                    }
                    Button(isManual ? "Прочитать из Apple Health" : "Обновить из Apple Health") {
                        Task { await manager.readAppleHeartRateZones(requestAuthorization: true) }
                    }
                    .disabled(!isEditable)
                    if let error = manager.heartRateZoneReadError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("При ошибке последний успешно прочитанный набор сохраняется. Проверяйте дату обновления.")
                }
            }

            Section {
                HStack {
                    Text("Максимальный пульс")
                    Spacer()
                    TextField("Не указан", text: $maximumText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 95)
                        .focused($maximumFocused)
                        .accessibilityLabel("Максимальный пульс, ударов в минуту")
                        .disabled(!isEditable)
                    Text("bpm").foregroundStyle(.secondary)
                }
                if let maximumError {
                    Text(maximumError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Максимальный пульс")
            } footer: {
                Text("На Apple Watch: «Настройки» → «Тренировка» → «Пульсовые зоны». При автоматическом расчёте найдите «Максимальный пульс» и перенесите значение сюда.\n\nApple Health не передаёт эту оценку приложению. Поле необязательное: его можно очистить. Оно не меняет границы зон и управление скоростью.")
            }
            if !manager.canEditHeartRateZoneSettings {
                Section {
                    Text("Настройки доступны после завершения тренировки и связанных операций.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Пульсовые зоны")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { saveMaximum(); maximumFocused = false }
            }
        }
        .onAppear { reloadMaximum() }
        .task { await manager.readAppleHeartRateZones(requestAuthorization: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await manager.readAppleHeartRateZones(requestAuthorization: false) }
            }
        }
        .onChange(of: maximumFocused) { _, focused in
            if !focused { saveMaximum() }
        }
        .onChange(of: manager.activeUserProfileID) { _, _ in reloadMaximum() }
        .onDisappear { saveMaximum() }
    }

    private func zoneLabel(_ index: Int) -> some View {
        HStack {
            Text("Зона \(index + 1)")
            Spacer()
            Text(index == 0 ? "≤ \(bounds[0]) bpm" : index == 4
                 ? "≥ \(bounds[3] + 1) bpm" : "\(bounds[index - 1] + 1)–\(bounds[index]) bpm")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func permittedRange(_ index: Int) -> ClosedRange<Int> {
        let minimum = index == 0 ? 80 : bounds[index - 1] + 1
        let maximum = min([200, 210, 220, 230][index], index == 3 ? 230 : bounds[index + 1] - 1)
        return minimum...maximum
    }

    private func reloadMaximum() {
        maximumProfileID = manager.activeUserProfileID
        maximumText = manager.heartRateZoneSettings.maximumHeartRate.map(String.init) ?? ""
        maximumError = nil
    }

    private func saveMaximum() {
        guard maximumProfileID == manager.activeUserProfileID,
              manager.canEditHeartRateZoneSettings else { reloadMaximum(); return }
        let trimmed = maximumText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Int(trimmed)
        guard trimmed.isEmpty || value != nil,
              manager.updateMaximumHeartRate(trimmed.isEmpty ? nil : value) else {
            maximumError = "Введите целое число от 80 до 250 или оставьте поле пустым."
            return
        }
        maximumError = nil
    }
}
