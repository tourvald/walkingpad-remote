import SwiftUI

struct AboutPrivacyView: View {
    var body: some View {
        List {
            Section("WalkingPad Remote") {
                Text("Управление дорожкой и тренировки с контролем пульса.")
                Text("Оператор: Кожушкевич Дмитрий Александрович")
            }
            Section("Данные и конфиденциальность") {
                Text("Профили, история и диагностика сохраняются локально. Пульс поступает через Apple Здоровье на iPhone; тренировки могут сохраняться в Apple Здоровье. Экспорт отправляется только выбранному вами получателю и может содержать данные о здоровье.")
                Link("Политика конфиденциальности", destination: URL(string: "https://tourvald.github.io/walkingpad-remote/privacy.html")!)
                Text("Удаление профиля сохраняет другие профили и записи Apple Здоровья. Ранее отправленные копии не отзываются. При незавершённой очистке повторите удаление после устранения причины.")
            }
            Section("Поддержка") {
                Link("Telegram @HJDmitry", destination: URL(string: "https://t.me/HJDmitry")!)
                Link("sw.newgeneration@icloud.com", destination: URL(string: "mailto:sw.newgeneration@icloud.com")!)
                Link("Страница поддержки", destination: URL(string: "https://tourvald.github.io/walkingpad-remote/support.html")!)
                Text("Для первого обращения достаточно описания проблемы. Не прикладывайте историю или диагностику без необходимости. Рабочие копии обращений у оператора удаляются в течение 30 дней после закрытия, по запросу — раньше.")
            }
            Section("Разрешения") {
                Text("Таймер планки запрашивает разрешение на локальный сигнал завершения. Звук и доставка зависят от настроек уведомлений iPhone.")
                Text("Доступ к Apple Здоровью и Bluetooth меняется в системных настройках iPhone. Без необходимого разрешения или свежего пульса HR-контроль может быть недоступен. Отзыв разрешения не удаляет сохранённые данные.")
            }
        }
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
}
