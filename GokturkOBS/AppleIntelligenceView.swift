import SwiftUI
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Kapsamlı Apple Intelligence sohbet görünümü. Foundation Models tool calling
/// kullanarak kullanıcının sorusuna göre OBS verilerini dinamik olarak çeker.
struct AppleIntelligenceView: View {
    @ObservedObject var model: AppModel

    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isThinking = false
    @State private var errorMessage: String?

    private struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        let text: String
        enum Role { case user, assistant }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence")
                        .font(.title2.bold())
                    Text("OBS verilerinizle sohbet edin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let msg = errorMessage {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            welcomeMessage
                        }
                        ForEach(messages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                        if isThinking {
                            thinkingIndicator
                        }
                    }
                    .padding(20)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 10) {
                TextField("Bir şey sorun…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(16)
        }
        .navigationTitle("Apple Intelligence")
        .task {
            await model.refreshHome()
        }
    }

    // MARK: - Welcome

    private var welcomeMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merhaba! 👋")
                .font(.title3.bold())
            Text("OBS verilerinizi yükledim. Bana şunları sorabilirsiniz:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                exampleChip("Bugün ne yemek var?")
                exampleChip("Yarın hangi derslerim var?")
                exampleChip("Aktif ödevlerim neler?")
                exampleChip("Bu hafta sınav var mı?")
                exampleChip("Devamsızlık durumum nasıl?")
                exampleChip("Yemek listesinde en sevdiğim yemek hangi gün?")
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func exampleChip(_ text: String) -> some View {
        Button {
            inputText = text
            send()
        } label: {
            Text("• \(text)")
                .font(.caption)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat Bubble

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 40) }
            Text(msg.text)
                .padding(12)
                .background(msg.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .textSelection(.enabled)
                .frame(maxWidth: 600, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var thinkingIndicator: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Düşünüyor…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
    }

    // MARK: - Send

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        inputText = ""
        isThinking = true
        errorMessage = nil

        Task {
            let reply = await generateReply(for: text)
            await MainActor.run {
                messages.append(ChatMessage(role: .assistant, text: reply))
                isThinking = false
            }
        }
    }

    // MARK: - AI Generation with Tool Calling

    private func generateReply(for question: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let availability = AppleIntelligenceService.availabilityMessage()
            if availability == nil {
                do {
                    let tools = makeTools()
                    let today = Date()
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "tr_TR")
                    formatter.dateFormat = "d MMMM yyyy, EEEE"
                    let todayString = formatter.string(from: today)

                    let session = LanguageModelSession(
                        tools: tools,
                        instructions: """
                        Sen GöktürkOBS okul asistanısın. Kullanıcı öğrenci. Bugün: \(todayString)
                        Araçlarla veri çek, sadece o verilere dayan. Türkçe, kısa, net yanıt ver.
                        Veri yoksa "Bu bilgi OBS'de bulunmuyor" de. Uydurma.
                        Ödev detayı (açıklama, sayfa sayısı vb.) için getHomework(subject: "matematik") çağır - otomatik detay getirir.
                        """
                    )
                    let response = try await session.respond(to: question)
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                } catch {
                    errorMessage = "AI yanıt veremedi: \(error.localizedDescription)"
                }
            } else {
                errorMessage = availability
            }
        }
        #endif

        // Fallback: veri tabanlı yanıt
        return buildFallbackAnswer(for: question)
    }

    // MARK: - Tools (dynamic data fetching)

    private func makeTools() -> [any Tool] {
        return [
            CurrentDateTool(),
            FoodMenuTool(model: model),
            ScheduleTool(model: model),
            HomeworkTool(model: model),
            AnnouncementsTool(model: model),
            ExamsTool(model: model),
        ]
    }

    // MARK: - Fallback

    private func buildFallbackAnswer(for question: String) -> String {
        let normalized = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))

        if normalized.contains("yemek") || normalized.contains("tatli") || normalized.contains("tavuk") || normalized.contains("corba") {
            if case .loaded(_, let days) = model.foodListState, let menuDay = FoodDashboardResolver.currentOrNextMeal(in: days)?.day {
                return "\(menuDay.heading): \(menuDay.items.joined(separator: ", "))"
            }
            return "Yemek bilgisi bulunamadı."
        }
        if normalized.contains("ders") || normalized.contains("program") {
            if let schedule = model.schedule, let upcoming = ScheduleDashboardResolver.upcomingDay(in: schedule) {
                let names = upcoming.lessons.map { $0.title.isEmpty ? $0.subject : $0.title }.filter { !$0.isEmpty }
                return "\(upcoming.dayName): \(names.joined(separator: ", "))"
            }
            return "Ders programı bulunamadı."
        }
        if normalized.contains("odev") {
            let hw = model.homework.filter { $0.isActive }
            return hw.isEmpty ? "Aktif ödev bulunamadı." : hw.map { "\($0.title) (Teslim: \($0.endDate))" }.joined(separator: "\n")
        }
        if normalized.contains("duyuru") {
            let anns = model.announcements.compactMap { $0.string("title", "announcementTitle", "content") }
            return anns.isEmpty ? "Duyuru bulunamadı." : anns.joined(separator: "\n")
        }
        if normalized.contains("sinav") {
            if let dashboard = model.examDashboard, !dashboard.exams.isEmpty {
                return dashboard.exams.map { "\($0.examName) (\($0.examDate)): Puan \($0.point)" }.joined(separator: "\n")
            }
            return "Sınav bilgisi bulunamadı."
        }
        return "Bu soruyu yanıtlamak için Apple Intelligence gerekli. macOS 26+ ve Apple Intelligence desteği olan bir Mac kullanın."
    }
}

// MARK: - Tools

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct CurrentDateTool: Tool {
    let name = "getCurrentDate"
    let description = "Bugünün tarihini ve gününü getirir. 'Bugün', 'yarın', 'bu hafta' gibi tarih referansları için kullan."

    @Generable
    struct Arguments {}

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        let today = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy, EEEE"
        let todayString = formatter.string(from: today)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let tomorrowString = formatter.string(from: tomorrow)
        return Output(text: "Bugün: \(todayString)\nYarın: \(tomorrowString)")
    }
}

@available(macOS 26.0, *)
struct FoodMenuTool: Tool {
    let name = "getFoodMenu"
    let description = "Okul yemek listesini getirir. Tarihli (örn. '12 Kasım 2026') günler ve o günün yemekleri. 'Bugün' için getCurrentDate ile tarihi al, sonra bu listede eşleşen günü bul."

    let model: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Hangi günün yemek listesi isteniyor. 'Bugün', 'yarın', 'Pazartesi' gibi. Boş bırakılırsa tüm günler döner.")
        var day: String?
    }

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        let state = await MainActor.run { model.foodListState }
        guard case .loaded(_, let days) = state else {
            return Output(text: "Yemek listesi henüz yüklenmedi.")
        }
        
        // "Bugün" veya "yarın" gibi referansları tarihe çevir
        var searchDay = arguments.day ?? ""
        let today = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy"
        
        let lowerDay = searchDay.lowercased(with: Locale(identifier: "tr_TR"))
        if lowerDay.contains("bugün") || lowerDay.contains("bugun") {
            // Ana ekrandaki gibi: okul bittiyse yarının yemeğini göster
            let schoolDayEnded = await MainActor.run {
                model.schedule.map { ScheduleDashboardResolver.hasSchoolDayEnded(in: $0) } ?? false
            }
            let targetDate = schoolDayEnded
                ? (Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today)
                : today
            searchDay = formatter.string(from: targetDate)
        } else if lowerDay.contains("yarın") || lowerDay.contains("yarin") {
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) {
                searchDay = formatter.string(from: tomorrow)
            }
        }
        
        if !searchDay.isEmpty {
            // Önce tam tarih eşleşmesi dene
            let filtered = days.filter { $0.heading.localizedCaseInsensitiveContains(searchDay) }
            if !filtered.isEmpty {
                return Output(text: filtered.map { "\($0.heading): \($0.items.joined(separator: ", "))" }.joined(separator: "\n"))
            }
            // Kısmi eşleşme dene (gün numarası ile)
            let dayNumber = searchDay.split(separator: " ").first.map(String.init) ?? ""
            if !dayNumber.isEmpty {
                let partial = days.filter { $0.heading.hasPrefix(dayNumber) }
                if !partial.isEmpty {
                    return Output(text: partial.map { "\($0.heading): \($0.items.joined(separator: ", "))" }.joined(separator: "\n"))
                }
            }
            return Output(text: "Bu gün için yemek bilgisi bulunamadı. Mevcut günler: \(days.map { $0.heading }.joined(separator: ", "))")
        }
        // Tüm günler istenirse sadece ilk 7 günü döner (context limiti)
        let limited = Array(days.prefix(7))
        return Output(text: limited.map { "\($0.heading): \($0.items.joined(separator: ", "))" }.joined(separator: "\n"))
    }
}

@available(macOS 26.0, *)
struct ScheduleTool: Tool {
    let name = "getSchedule"
    let description = "Ders programını getirir. Haftalık ders programı ve bugünün dersleri."

    let model: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Hangi günün ders programı isteniyor. Boş bırakılırsa tüm hafta döner.")
        var day: String?
    }

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        let schedule = await MainActor.run { model.schedule }
        guard let schedule = schedule else {
            return Output(text: "Ders programı henüz yüklenmedi.")
        }
        let dayNames = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"]
        var lines: [String] = []
        for apiDay in 1...7 {
            let lessons = schedule.data.data
                .filter { $0.y == apiDay }
                .sorted { $0.x < $1.x }
            if !lessons.isEmpty {
                let dayName = dayNames[apiDay - 1]
                if let day = arguments.day, !day.isEmpty, !dayName.localizedCaseInsensitiveContains(day) {
                    continue
                }
                let lessonNames = lessons.map { lesson in
                    let name = MainActor.assumeIsolated {
                        lesson.title.isEmpty ? lesson.subject : lesson.title
                    }
                    return name
                }.joined(separator: ", ")
                lines.append("\(dayName): \(lessonNames)")
            }
        }
        if lines.isEmpty {
            return Output(text: "Bu gün için ders bulunamadı.")
        }
        return Output(text: lines.joined(separator: "\n"))
    }
}

@available(macOS 26.0, *)
struct HomeworkTool: Tool {
    let name = "getHomework"
    let description = "Ödevleri getirir. Varsayılan olarak son 8 günün ödevlerini döner. Her ödevin detaylı açıklaması otomatik getirilir. Ders filtresi için subject kullan (örn. matematik). Tüm ödevler için getAll=true kullan."

    let model: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Sadece aktif ödevleri mi getirsin? true/false")
        var activeOnly: Bool?
        @Guide(description: "Tüm ödevlere eriş (son 8 gün kısıtlamasını kaldır). Sadece özel durumlarda kullan.")
        var getAll: Bool?
        @Guide(description: "Belirli bir ödevin ID'si. Bu verilirse o ödevin detaylı açıklaması döner.")
        var homeworkId: Int?
        @Guide(description: "Ders adı (örn. matematik, türkçe). Bu verilirse o dersin ödevlerinin detayları da getirilir.")
        var subject: String?
    }

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        // Belirli bir ödevin detayını getir
        if let hwId = arguments.homeworkId {
            do {
                let detail = try await model.client.loadHomeworkDetail(id: hwId)
                var lines: [String] = []
                lines.append("Ödev: \(detail.title)")
                lines.append("Ders: \(detail.lesson)")
                lines.append("Öğretmen: \(detail.teaNameSurname)")
                lines.append("Tür: \(detail.typeName)")
                lines.append("Başlangıç: \(detail.startDate)")
                lines.append("Teslim: \(detail.endDate)")
                lines.append("Durum: \(detail.statusName)")
                lines.append("Puan: \(detail.score)")
                if !detail.description.isEmpty {
                    lines.append("Açıklama: \(detail.description)")
                }
                if let konu = detail.konuAd, !konu.isEmpty {
                    lines.append("Konu: \(konu)")
                }
                if !detail.teacherComment.isEmpty {
                    lines.append("Öğretmen yorumu: \(detail.teacherComment)")
                }
                if !detail.attachFiles.isEmpty {
                    lines.append("Ek dosyalar: \(detail.attachFiles.map { $0.fileName }.joined(separator: ", "))")
                }
                if !detail.answerFiles.isEmpty {
                    lines.append("Cevap dosyaları: \(detail.answerFiles.map { $0.fileName }.joined(separator: ", "))")
                }
                return Output(text: lines.joined(separator: "\n"))
            } catch {
                return Output(text: "Ödev detayı alınamadı (ID: \(hwId)): \(error.localizedDescription)")
            }
        }

        let homeworks = await MainActor.run { model.homework }
        if homeworks.isEmpty {
            return Output(text: "Ödev bulunamadı.")
        }

        // Son 8 günün ödevlerini filtrele (varsayılan)
        let filtered: [Homework]
        if arguments.getAll == true {
            filtered = homeworks
        } else {
            let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: Date()) ?? Date()
            filtered = homeworks.filter { hw in
                let dateStr = hw.endDate.isEmpty ? hw.startDate : hw.endDate
                guard !dateStr.isEmpty else { return true }
                let df = DateFormatter()
                df.dateFormat = "dd.MM.yyyy"
                if let hwDate = df.date(from: dateStr) {
                    return hwDate >= eightDaysAgo
                }
                df.dateFormat = "yyyy-MM-dd"
                if let hwDate = df.date(from: dateStr) {
                    return hwDate >= eightDaysAgo
                }
                return true
            }
        }

        let activeFiltered = (arguments.activeOnly == true) ? filtered.filter { $0.isActive } : filtered
        if activeFiltered.isEmpty {
            return Output(text: "Son 8 gün içinde ödev bulunamadı. Tüm ödevlere erişmek için getAll=true kullanın.")
        }

        // Ders filtresi
        var subjectFiltered = activeFiltered
        if let subject = arguments.subject, !subject.isEmpty {
            let lowerSubject = subject.lowercased(with: Locale(identifier: "tr_TR"))
            subjectFiltered = activeFiltered.filter { hw in
                hw.lesson.lowercased(with: Locale(identifier: "tr_TR")).contains(lowerSubject) ||
                hw.title.lowercased(with: Locale(identifier: "tr_TR")).contains(lowerSubject)
            }
            if subjectFiltered.isEmpty {
                subjectFiltered = activeFiltered
            }
        }

        if subjectFiltered.isEmpty {
            return Output(text: "Son 8 gün içinde ödev bulunamadı. Tüm ödevlere erişmek için getAll=true kullanın.")
        }

        // Her zaman detayları çek (en fazla 3 ödev için)
        let toDetail = Array(subjectFiltered.prefix(3))
        if !toDetail.isEmpty {
            var detailLines: [String] = []
            for hw in toDetail {
                do {
                    let detail = try await model.client.loadHomeworkDetail(id: hw.id)
                    var lines: [String] = []
                    lines.append("Ödev: \(detail.title)")
                    lines.append("Ders: \(detail.lesson)")
                    lines.append("Öğretmen: \(detail.teaNameSurname)")
                    lines.append("Teslim: \(detail.endDate)")
                    lines.append("Durum: \(detail.statusName)")
                    if !detail.description.isEmpty {
                        lines.append("Açıklama: \(detail.description)")
                    }
                    if let konu = detail.konuAd, !konu.isEmpty {
                        lines.append("Konu: \(konu)")
                    }
                    if !detail.teacherComment.isEmpty {
                        lines.append("Öğretmen yorumu: \(detail.teacherComment)")
                    }
                    if !detail.attachFiles.isEmpty {
                        lines.append("Ek dosyalar: \(detail.attachFiles.map { $0.fileName }.joined(separator: ", "))")
                    }
                    if !detail.answerFiles.isEmpty {
                        lines.append("Cevap dosyaları: \(detail.answerFiles.map { $0.fileName }.joined(separator: ", "))")
                    }
                    detailLines.append(lines.joined(separator: "\n"))
                } catch {
                    let status = hw.isActive ? "Aktif" : "Tamamlandı"
                    detailLines.append("- \(hw.title) (Ders: \(hw.lesson), Teslim: \(hw.endDate)) [\(status)] [ID: \(hw.id)]")
                }
            }
            // 3'ten fazla ödev varsa kalanları da listele
            if subjectFiltered.count > 3 {
                let rest = subjectFiltered.dropFirst(3).map { hw in
                    let status = hw.isActive ? "Aktif" : "Tamamlandı"
                    return "- \(hw.title) (Ders: \(hw.lesson), Teslim: \(hw.endDate)) [\(status)] [ID: \(hw.id)]"
                }
                detailLines.append(rest.joined(separator: "\n"))
            }
            return Output(text: detailLines.joined(separator: "\n---\n"))
        }

        return Output(text: subjectFiltered.map { hw in
            let status = hw.isActive ? "Aktif" : "Tamamlandı"
            return "- \(hw.title) (Ders: \(hw.lesson), Öğretmen: \(hw.teaNameSurname), Teslim: \(hw.endDate)) [\(status)] [ID: \(hw.id)]"
        }.joined(separator: "\n"))
    }
}

@available(macOS 26.0, *)
struct AnnouncementsTool: Tool {
    let name = "getAnnouncements"
    let description = "Okul duyurularını getirir."

    let model: AppModel

    @Generable
    struct Arguments {}

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        let announcements = await MainActor.run { model.announcements }
        if announcements.isEmpty {
            return Output(text: "Duyuru bulunamadı.")
        }
        let limited = Array(announcements.prefix(5))
        return Output(text: limited.compactMap { ann in
            MainActor.assumeIsolated {
                ann.string("title", "announcementTitle", "content")
            }
        }.map { "- \($0)" }.joined(separator: "\n"))
    }
}

@available(macOS 26.0, *)
struct ExamsTool: Tool {
    let name = "getExams"
    let description = "Sınav sonuçlarını ve KPI bilgilerini getirir."

    let model: AppModel

    @Generable
    struct Arguments {}

    struct Output: PromptRepresentable {
        let text: String
        var promptRepresentation: Prompt { Prompt(text) }
    }

    func call(arguments: Arguments) async throws -> Output {
        let dashboard = await MainActor.run { model.examDashboard }
        guard let dashboard = dashboard else {
            return Output(text: "Sınav bilgisi yüklenmedi.")
        }
        if dashboard.exams.isEmpty {
            return Output(text: "Sınav bulunamadı.")
        }
        var lines = dashboard.exams.prefix(5).map { exam in
            "- \(exam.examName) (\(exam.examDate)): Puan \(exam.point), Net \(exam.net)"
        }
        if let kpi = dashboard.kpi {
            var kpiParts: [String] = []
            if let avg = kpi.avgPoint { kpiParts.append("Ort. puan: \(avg)") }
            if let success = kpi.avgSuccess { kpiParts.append("Ort. başarı: \(success)%") }
            if let maxP = kpi.maxPoint { kpiParts.append("En yüksek: \(maxP)") }
            if !kpiParts.isEmpty { lines.append("KPI: \(kpiParts.joined(separator: ", "))") }
        }
        return Output(text: lines.joined(separator: "\n"))
    }
}
#endif