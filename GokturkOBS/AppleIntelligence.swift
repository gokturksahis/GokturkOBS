import SwiftUI
import Foundation
import AppIntents
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A validated meal representation. Every displayed food name is copied from the OBS source.
struct MealDay: Identifiable, Equatable {
    let date: String
    let soup: String?
    let mainCourse: String?
    let sideDish: String?
    let dessert: String?
    let additionalItems: [String]
    let isUncertain: Bool

    var id: String { date }

    static func from(menuDay: FoodMenuDay) -> MealDay {
        let items = menuDay.items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let soup = items.first(where: { normalized($0).contains("corba") })
        let remaining = items.filter { $0 != soup }
        let dessert = remaining.first(where: { normalized($0).contains("tatli") || normalized($0).contains("meyve") })
        let withoutDessert = remaining.filter { $0 != dessert }

        return MealDay(
            date: menuDay.heading,
            soup: soup,
            mainCourse: withoutDessert.first,
            sideDish: withoutDessert.dropFirst().first,
            dessert: dessert,
            additionalItems: Array(withoutDessert.dropFirst(2)),
            isUncertain: items.isEmpty || (soup == nil && items.count > 1)
        )
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}

/// On-device analysis of a single cafeteria day. Dish names always come from the
/// OBS source; only the interpretation (category, calories, tags) is generated.
struct FoodMenuAnalysisItem: Identifiable, Equatable, Codable, Sendable {
    let name: String
    let category: MealCategory
    let calories: Int?
    let allergens: [String]
    let dietaryTags: [DietaryTag]

    var id: String { name }
}

struct FoodMenuAnalysisDay: Equatable, Codable, Sendable {
    let summary: String
    let items: [FoodMenuAnalysisItem]
    let usedAppleIntelligence: Bool

    func item(named name: String) -> FoodMenuAnalysisItem? {
        if let exact = items.first(where: { $0.name == name }) {
            return exact
        }
        let normalizedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "tr_TR")
        )
        return items.first {
            $0.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "tr_TR")
            ) == normalizedName
        }
    }
}

struct DashboardIntelligenceContext: Equatable {
    let sourceFacts: [String]
    let scheduleSummary: String?
    let mealSummary: String?
    let reminders: [String]
    let announcements: [String]

    var hasData: Bool { !sourceFacts.isEmpty }

    var signature: String {
        sourceFacts.joined(separator: "|")
    }

    static func make(
        schedule: LessonSchedule?,
        homework: [Homework],
        foodState: FoodListLoadState,
        announcements: [PortalRecord]
    ) -> DashboardIntelligenceContext {
        var facts: [String] = []
        var scheduleSummary: String?
        var mealSummary: String?
        var reminders: [String] = []

        if let schedule, let upcoming = ScheduleDashboardResolver.upcomingDay(in: schedule) {
            let names = upcoming.lessons.map { lesson in
                lesson.title.isEmpty ? lesson.subject : lesson.title
            }.filter { !$0.isEmpty }
            if !names.isEmpty {
                scheduleSummary = "\(upcoming.dayName) günü \(names.count) ders: \(names.joined(separator: ", "))."
                facts.append(scheduleSummary!)
            }
        }

        let activeHomework = homework.filter { $0.isActive }
        for homework in activeHomework.prefix(3) {
            let detail = homework.endDate.isEmpty ? homework.title : "\(homework.title) — teslim: \(homework.endDate)"
            reminders.append(detail)
            facts.append("Ödev: \(detail)")
        }

        if case .loaded(_, let days) = foodState,
           let menuDay = FoodDashboardResolver.currentOrNextMeal(in: days)?.day {
            let meal = MealDay.from(menuDay: menuDay)
            let dishes = [meal.soup, meal.mainCourse, meal.sideDish, meal.dessert]
                .compactMap { $0 } + meal.additionalItems
            if !dishes.isEmpty {
                mealSummary = "\(meal.date): \(dishes.joined(separator: ", "))"
                facts.append("Yemek: \(mealSummary!)")
            }
        }

        let announcementTexts = announcements.prefix(3).compactMap {
            $0.string("title", "announcementTitle", "content")
        }
        for announcement in announcementTexts {
            facts.append("Duyuru: \(announcement)")
        }

        return DashboardIntelligenceContext(
            sourceFacts: facts,
            scheduleSummary: scheduleSummary,
            mealSummary: mealSummary,
            reminders: reminders,
            announcements: announcementTexts
        )
    }
}

enum AppleIntelligencePanelState: Equatable {
    case idle
    case loading
    case ready(DailyBriefing)
    case unavailable(String)
    case failure(String)
}

struct DailyBriefing: Equatable {
    let text: String
    let reminders: [String]
    let schedule: String?
    let meal: String?
    let announcements: [String]
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "A short Turkish school-day briefing based only on supplied OBS facts.")
private struct GeneratedDailyBriefing {
    @Guide(description: "One or two concise Turkish sentences. Do not add facts that are not supplied.")
    let text: String
}

@available(macOS 26.0, *)
@Generable(description: "A classification of an OBS meal day. Use only exact dish names supplied in the input.")
private struct GeneratedMealDay {
    let soup: String?
    let mainCourse: String?
    let sideDish: String?
    let dessert: String?
    let additionalItems: [String]
}

@available(macOS 26.0, *)
@Generable(description: "A complete school cafeteria menu copied from the source document.")
private struct GeneratedMenuDocument {
    let days: [GeneratedMenuDocumentDay]
}

@available(macOS 26.0, *)
@Generable(description: "One dated or weekday-labelled day in a school cafeteria menu.")
private struct GeneratedMenuDocumentDay {
    @Guide(description: "Copy the day heading exactly as it appears in the source document.")
    let heading: String

    @Guide(description: "Copy each food name exactly as it appears in the source document. Do not add, combine, translate, or rename foods.")
    let items: [String]
}

@available(macOS 26.0, *)
@Generable(description: "A nutritional analysis of one school cafeteria menu day. Only analyse dishes that are supplied in the input.")
private struct GeneratedFoodMenuAnalysis {
    @Guide(description: "One or two concise Turkish sentences summarising the day's menu and its balance. Never mention a dish that is not supplied.")
    let summary: String

    @Guide(description: "One entry for every supplied dish, in the same order.")
    let items: [GeneratedFoodMenuAnalysisItem]
}

@available(macOS 26.0, *)
@Generable(description: "An analysed dish from a school cafeteria menu.")
private struct GeneratedFoodMenuAnalysisItem {
    @Guide(description: "The dish name copied exactly from the supplied list. Do not rename or translate it.")
    let name: String

    @Guide(description: "One of: soup, mainDish, sideDish, dessertOrFruit, beverage, breadOrOther, snack")
    let category: String

    @Guide(description: "A conservative calorie estimate for one student portion. Use 0 when it cannot be estimated.")
    let calories: Int

    @Guide(description: "Likely allergens using Turkish labels such as Gluten, Süt / Laktoz, Yumurta, Kuruyemiş, Balık. Use an empty list when none are likely.")
    let allergens: [String]

    @Guide(description: "Applicable tags from: vegetarian, vegan, glutenFree, dairyFree, highProtein, halal")
    let dietaryTags: [String]
}
#endif

/// Runs only Apple's on-device system model; no network model or synthetic fallback is used.
enum AppleIntelligenceService {
    private static let cachedFactsKey = "appleIntelligence.cachedOBSFacts"

    static func cache(_ context: DashboardIntelligenceContext) {
        UserDefaults.standard.set(context.sourceFacts, forKey: cachedFactsKey)
    }

    static func cachedAnswer(for question: String) -> String {
        let facts = UserDefaults.standard.stringArray(forKey: cachedFactsKey) ?? []
        guard !facts.isEmpty else {
            return "Önce GöktürkOBS'u açıp güncel OBS verilerini yükleyin."
        }
        let normalized = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
        let prefixes: [String]
        if normalized.contains("yemek") || normalized.contains("tatli") || normalized.contains("tavuk") {
            prefixes = ["Yemek:"]
        } else if normalized.contains("ders") || normalized.contains("program") {
            prefixes = []
        } else if normalized.contains("odev") {
            prefixes = ["Ödev:"]
        } else if normalized.contains("duyuru") {
            prefixes = ["Duyuru:"]
        } else {
            return "Bu soruyu yalnızca GöktürkOBS'ta yüklenmiş OBS verileriyle yanıtlayabiliyorum."
        }
        let answer = facts.filter { fact in
            prefixes.isEmpty || prefixes.contains { prefix in fact.hasPrefix(prefix) }
        }
        return answer.isEmpty ? "Bu konu için yüklenmiş OBS verisi bulunmuyor." : answer.joined(separator: " · ")
    }

    static func availabilityMessage() -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return "Apple Intelligence bu macOS sürümünde kullanılamıyor."
        }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return "Apple Intelligence modeli bu Mac'te henüz kullanıma hazır değil."
        }
        guard model.supportsLocale(Locale(identifier: "tr_TR")) else {
            return "Apple Intelligence şu anda Türkçe için kullanılamıyor."
        }
        return nil
        #else
        return "Apple Intelligence bu uygulama derlemesinde kullanılamıyor."
        #endif
    }

    static func generateBriefing(for context: DashboardIntelligenceContext) async throws -> DailyBriefing {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw AppleIntelligenceError.unavailable }
        guard availabilityMessage() == nil else { throw AppleIntelligenceError.unavailable }

        let session = LanguageModelSession(
            model: .default,
            instructions: "The person's locale is tr_TR. You MUST respond in Turkish. You summarize only the supplied OBS facts. Never infer, calculate, or invent a lesson, deadline, meal, announcement, date, or school event."
        )
        let prompt = """
        OBS kaynak gerçekleri:
        \(context.sourceFacts.map { "- " + $0 }.joined(separator: "\n"))

        Bu gerçeklere dayanarak çok kısa bir günlük bilgilendirme üret.
        """
        let response = try await session.respond(to: prompt, generating: GeneratedDailyBriefing.self)
        let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppleIntelligenceError.emptyResponse }

        return DailyBriefing(
            text: text,
            reminders: context.reminders,
            schedule: context.scheduleSummary,
            meal: context.mealSummary,
            announcements: context.announcements
        )
        #else
        throw AppleIntelligenceError.unavailable
        #endif
    }

    /// Provides a structured, validated extension point for the existing PDF-based menu extractor.
    static func understandMealDay(_ menuDay: FoodMenuDay) async throws -> MealDay {
        let deterministic = MealDay.from(menuDay: menuDay)
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availabilityMessage() == nil else { return deterministic }
        let sourceItems = menuDay.items.filter { !$0.isEmpty }
        let session = LanguageModelSession(
            model: .default,
            instructions: "The person's locale is tr_TR. Classify Turkish school meals. You MUST only select exact dish names from the supplied list. Do not create or rename food items."
        )
        let itemLines = sourceItems.map { "- " + $0 }.joined(separator: "\n")
        let response = try await session.respond(
            to: "Başlık: \(menuDay.heading)\nYemekler:\n\(itemLines)",
            generating: GeneratedMealDay.self
        )
        let generated = response.content
        let allGenerated = [generated.soup, generated.mainCourse, generated.sideDish, generated.dessert]
            .compactMap { $0 } + generated.additionalItems
        guard allGenerated.allSatisfy(sourceItems.contains) else { return deterministic }

        return MealDay(
            date: menuDay.heading,
            soup: generated.soup,
            mainCourse: generated.mainCourse,
            sideDish: generated.sideDish,
            dessert: generated.dessert,
            additionalItems: generated.additionalItems,
            isUncertain: deterministic.isUncertain
        )
        #else
        return deterministic
        #endif
    }

    /// Interprets a parsed menu day with Apple Intelligence. The model only supplies
    /// category, calorie, allergen and dietary information; every dish name is taken
    /// from the OBS source so the UI can never show an invented food.
    static func analyzeMenuDay(_ menuDay: FoodMenuDay) async throws -> FoodMenuAnalysisDay {
        let sourceItems = menuDay.items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallback = heuristicAnalysis(for: menuDay)
        guard !sourceItems.isEmpty else { return fallback }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availabilityMessage() == nil else {
            return fallback
        }

        let session = LanguageModelSession(
            model: .default,
            instructions: "The person's locale is tr_TR. You analyse Turkish school cafeteria menus. Analyse only the exact dish names supplied by the user. Never add, remove, rename, translate or combine dishes. Be conservative with calorie estimates and always answer in Turkish."
        )
        let response = try await session.respond(
            to: """
            Başlık: \(menuDay.heading)
            Yemekler:
            \(sourceItems.map { "- " + $0 }.joined(separator: "\n"))
            """,
            generating: GeneratedFoodMenuAnalysis.self
        )

        let generated = response.content
        var items: [FoodMenuAnalysisItem] = []
        items.reserveCapacity(sourceItems.count)
        for sourceName in sourceItems {
            guard let generatedItem = generated.items.first(where: {
                sameDish($0.name, sourceName)
            }) else {
                items.append(heuristicItem(for: sourceName))
                continue
            }

            let category = MealCategory(rawValue: generatedItem.category)
                ?? MenuAIParser.inferCategory(for: sourceName)
            let tags = generatedItem.dietaryTags.compactMap(DietaryTag.init(rawValue:))
            items.append(
                FoodMenuAnalysisItem(
                    name: sourceName,
                    category: category,
                    calories: generatedItem.calories > 0 ? generatedItem.calories : nil,
                    allergens: generatedItem.allergens,
                    dietaryTags: tags.isEmpty
                        ? MenuAIParser.inferDietaryTags(for: sourceName)
                        : tags
                )
            )
        }

        return FoodMenuAnalysisDay(
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            items: items,
            usedAppleIntelligence: true
        )
        #else
        return fallback
        #endif
    }

    /// Offline analysis used when Apple Intelligence is unavailable or still preparing.
    /// It never invents calories; it only classifies the source dish names.
    static func heuristicAnalysis(for menuDay: FoodMenuDay) -> FoodMenuAnalysisDay {
        let items = menuDay.items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { heuristicItem(for: $0) }

        let groups = MealCategory.allCases.compactMap { category -> String? in
            let count = items.filter { $0.category == category }.count
            guard count > 0 else { return nil }
            return "\(count) \(category.titleTr.lowercased())"
        }
        let summary = groups.isEmpty
            ? ""
            : "Menüde \(groups.joined(separator: ", ")) bulunuyor."

        return FoodMenuAnalysisDay(
            summary: summary,
            items: items,
            usedAppleIntelligence: false
        )
    }

    static func heuristicItem(for name: String) -> FoodMenuAnalysisItem {
        FoodMenuAnalysisItem(
            name: name,
            category: MenuAIParser.inferCategory(for: name),
            calories: nil,
            allergens: MenuAIParser.inferAllergens(for: name),
            dietaryTags: MenuAIParser.inferDietaryTags(for: name)
        )
    }

    private static func sameDish(_ first: String, _ second: String) -> Bool {
        let lhs = normalizedMenuSource(first)
        let rhs = normalizedMenuSource(second)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shortest = min(lhs.count, rhs.count)
        guard shortest >= 4 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    /// Parses all extracted menu pages. The model is first asked to return plain JSON,
    /// which is decoded directly and reused via `FoodMenuCacheStore`. Guided
    /// generation remains as a fallback if the model does not follow the JSON format.
    static func parseCompleteMenu(rawText: String) async throws -> [FoodMenuDay] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw AppleIntelligenceError.unavailable }
        guard availabilityMessage() == nil else { throw AppleIntelligenceError.unavailable }

        if let jsonDays = try? await parseMenuJSON(rawText: rawText), !jsonDays.isEmpty {
            return verifiedMenu(jsonDays, against: rawText)
        }

        let session = LanguageModelSession(
            model: .default,
            instructions: "The person's locale is tr_TR. You extract Turkish school cafeteria menus. Return only days and dishes explicitly present in the source. Preserve source spelling. Never infer a missing day, date, dish, category, or meal."
        )
        let response = try await session.respond(
            to: "Aşağıdaki metin, yemek listesinin TÜM sayfalarından çıkarılmış ham metindir. Tamamını ayrıştır.\n\n\(rawText)",
            generating: GeneratedMenuDocument.self
        )

        let guidedDays = response.content.days.map { day in
            FoodMenuDay(heading: day.heading, items: day.items, pageIndex: 0)
        }
        return verifiedMenu(guidedDays, against: rawText)
        #else
        throw AppleIntelligenceError.unavailable
        #endif
    }

    #if canImport(FoundationModels)
    private struct RawMenuJSONDocument: Decodable {
        struct Day: Decodable {
            let heading: String
            let items: [String]
        }

        let days: [Day]
    }

    @available(macOS 26.0, *)
    private static func parseMenuJSON(rawText: String) async throws -> [FoodMenuDay] {
        let session = LanguageModelSession(
            model: .default,
            instructions: "The person's locale is tr_TR. You extract Turkish school cafeteria menus. Return only valid JSON and never add commentary. Use only days and dishes explicitly present in the source, and preserve source spelling. Never infer a missing day, date, dish, category, or meal."
        )
        let response = try await session.respond(
            to: """
            Aşağıdaki metin, yemek listesinin TÜM sayfalarından çıkarılmış ham metindir. Yalnızca metinde açıkça bulunan günleri ve yemekleri çıkar.

            SADECE şu biçimde geçerli JSON döndür:
            {"days":[{"heading":"2 Kasım 2026","items":["SÜTLÜ EZME ÇORBASI","ANNE KÖFTE"]}]}

            Metin:
            \(rawText)
            """
        )
        guard let json = jsonObjectString(in: response.content),
              let data = json.data(using: .utf8) else {
            throw AppleIntelligenceError.emptyResponse
        }

        let document = try JSONDecoder().decode(RawMenuJSONDocument.self, from: data)
        return document.days.enumerated().map { index, day in
            FoodMenuDay(heading: day.heading, items: day.items, pageIndex: index)
        }
    }

    private static func jsonObjectString(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }
    #endif

    /// Every returned heading and dish must exist in the source before it can be
    /// displayed or cached. This keeps the model from inventing food.
    private static func verifiedMenu(_ days: [FoodMenuDay], against rawText: String) -> [FoodMenuDay] {
        let source = normalizedMenuSource(rawText)
        return days.enumerated().compactMap { index, day in
            let heading = day.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty, source.contains(normalizedMenuSource(heading)) else { return nil }
            let items = day.items.filter { item in
                let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
                return !cleaned.isEmpty && source.contains(normalizedMenuSource(cleaned))
            }
            guard !items.isEmpty else { return nil }
            return FoodMenuDay(heading: heading, items: items, pageIndex: index)
        }
    }

    private static func normalizedMenuSource(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppleIntelligenceError: LocalizedError {
    case unavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Intelligence şu anda kullanılamıyor."
        case .emptyResponse: "Apple Intelligence boş bir yanıt verdi."
        }
    }
}

struct AppleIntelligencePanel: View {
    let context: DashboardIntelligenceContext

    @State private var state: AppleIntelligencePanelState = .idle
    @State private var question = ""
    @State private var answer: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                switch state {
                case .idle, .loading:
                    ProgressView("Günlük bilgilendirme hazırlanıyor…")
                        .controlSize(.small)
                case .ready(let briefing):
                    Text(briefing.text)
                        .font(.body)
                    details(for: briefing)
                    questionField
                case .unavailable(let message):
                    Label(message, systemImage: "brain.head.profile")
                        .foregroundStyle(.secondary)
                    sourceOnlyDetails
                case .failure(let message):
                    Label("Bilgilendirme oluşturulamadı", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sourceOnlyDetails
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Apple Intelligence", systemImage: "apple.intelligence")
                .font(.headline)
        }
        .task(id: context.signature) {
            await loadBriefing()
        }
    }

    @ViewBuilder
    private func details(for briefing: DailyBriefing) -> some View {
        if let schedule = briefing.schedule {
            Label(schedule, systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let meal = briefing.meal {
            Label(meal, systemImage: "fork.knife")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(briefing.reminders, id: \.self) {
            Label($0, systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(briefing.announcements, id: \.self) {
            Label($0, systemImage: "megaphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sourceOnlyDetails: some View {
        if context.hasData {
            if let schedule = context.scheduleSummary {
                Label(schedule, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let meal = context.mealSummary {
                Label(meal, systemImage: "fork.knife")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Bilgilendirme için henüz OBS verisi yok.")
                .foregroundStyle(.secondary)
        }
    }

    private var questionField: some View {
        HStack {
            TextField("Örn. Bugün ne yemek var?", text: $question)
                .textFieldStyle(.roundedBorder)
            Button("Sor") {
                answer = groundedAnswer(for: question)
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityLabel("Apple Intelligence soru alanı")
        .overlay(alignment: .bottomLeading) {
            if let answer {
                Text(answer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .offset(y: 20)
            }
        }
        .padding(.bottom, answer == nil ? 0 : 18)
    }

    private func loadBriefing() async {
        AppleIntelligenceService.cache(context)
        guard context.hasData else {
            state = .unavailable("Önce OBS verilerinin yüklenmesi gerekiyor.")
            return
        }
        if let message = AppleIntelligenceService.availabilityMessage() {
            state = .unavailable(message)
            return
        }
        state = .loading
        do {
            state = .ready(try await AppleIntelligenceService.generateBriefing(for: context))
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    private func groundedAnswer(for question: String) -> String {
        AppleIntelligenceService.cachedAnswer(for: question)
    }
}

struct AskGokturkOBSIntent: AppIntent {
    static let title: LocalizedStringResource = "GöktürkOBS'a Sor"
    static let description = IntentDescription("Yüklenmiş OBS verilerinden ders, ödev, yemek veya duyuru bilgisi getirir.")

    @Parameter(title: "Soru")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("GöktürkOBS'a \(\.$question) sor")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let answer = await MainActor.run {
            AppleIntelligenceService.cachedAnswer(for: question)
        }
        return .result(value: answer)
    }
}

struct GokturkOBSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGokturkOBSIntent(),
            phrases: ["\(.applicationName) ile GöktürkOBS'a sor"],
            shortTitle: "GöktürkOBS'a Sor",
            systemImageName: "brain.head.profile"
        )
    }
}
