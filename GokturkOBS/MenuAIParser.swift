//
//  MenuAIParser.swift
//  GokturkOBS
//
//  Created for GokturkOBS AI Cafeteria Intelligence.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AI Parser Protocol & Types

public protocol MenuParsingEngine: Sendable {
    func parseMenu(from content: ExtractedMenuContent, schoolID: String, referenceDate: Date) async throws -> [CafeteriaDay]
}

// MARK: - Menu AI Parser (Apple Intelligence + Fallback)

public final class MenuAIParser: Sendable {
    public static let shared = MenuAIParser()

    public init() {}

    public var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    public var intelligenceStatusDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Apple Foundation Models Aktif"
            case .unavailable(let reason):
                switch reason {
                case .modelNotReady:
                    return "Apple Intelligence Modeli İndiriliyor / Hazırlanıyor (Kural Tabanlı Mod Devrede)"
                default:
                    return "Apple Intelligence Kullanılamıyor (\(reason)) (Kural Tabanlı Mod Devrede)"
                }
            }
        }
        #endif
        return "Cihazda Apple Foundation Models Bulunmuyor (Kural Tabanlı Mod Devrede)"
    }

    public func parse(
        content: ExtractedMenuContent,
        schoolID: String = "default",
        sourceURL: URL? = nil,
        referenceDate: Date = Date()
    ) async -> [CafeteriaDay] {
        // Try Apple Intelligence Foundation Models if available
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if SystemLanguageModel.default.availability == .available {
                if let days = await parseWithFoundationModels(content: content, schoolID: schoolID, sourceURL: sourceURL, referenceDate: referenceDate) {
                    if !days.isEmpty {
                        return days
                    }
                }
            }
        }
        #endif

        // Clean, zero-hallucination heuristic fallback parser
        return parseWithHeuristics(content: content, schoolID: schoolID, sourceURL: sourceURL, referenceDate: referenceDate)
    }

    // MARK: - Apple Intelligence Foundation Models Implementation

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private func parseWithFoundationModels(
        content: ExtractedMenuContent,
        schoolID: String,
        sourceURL: URL?,
        referenceDate: Date
    ) async -> [CafeteriaDay]? {
        let systemPrompt = """
        You are a cafeteria menu parsing assistant for GokturkOBS.
        Analyze the provided cafeteria menu text or table and convert it into a structured JSON array of days.
        Strict Rules:
        - NEVER hallucinate or invent dates or dishes that are not explicitly present in the input.
        - For each day, identify: date (YYYY-MM-DD), day name in Turkish (e.g. Pazartesi, Salı, Çarşamba, Perşembe, Cuma), mealType ("lunch", "breakfast", or "dinner"), and an array of meal items.
        - For each meal item, identify: name (String), category ("soup", "mainDish", "sideDish", "dessertOrFruit", "beverage", "breadOrOther", "snack"), calories (Int or null), allergens ([String]), dietaryTags ([String]: "vegetarian", "vegan", "glutenFree", "dairyFree", "highProtein", "halal").
        - Output ONLY valid JSON matching this schema:
        [
          {
            "date": "2026-11-05",
            "day": "Perşembe",
            "mealType": "lunch",
            "items": [
              {
                "name": "Mercimek Çorbası",
                "category": "soup",
                "calories": 140,
                "allergens": ["gluten"],
                "dietaryTags": ["vegetarian", "halal"]
              }
            ]
          }
        ]
        If content is malformed or not a menu, return an empty array [].
        """

        let prompt = """
        Reference current date is: \(ISO8601DateFormatter().string(from: referenceDate)).
        Cafeteria Menu Raw Input:
        \(content.rawText)
        """

        do {
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(to: prompt)
            let rawJSON = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract JSON substring if response contains markdown formatting
            let jsonString: String
            if let start = rawJSON.range(of: "["), let end = rawJSON.range(of: "]", options: .backwards) {
                jsonString = String(rawJSON[start.lowerBound...end.upperBound])
            } else {
                jsonString = rawJSON
            }

            guard let jsonData = jsonString.data(using: .utf8) else { return nil }

            struct AIFoodItem: Decodable {
                let name: String
                let category: String?
                let calories: Int?
                let allergens: [String]?
                let dietaryTags: [String]?
            }

            struct AIDay: Decodable {
                let date: String
                let day: String
                let mealType: String?
                let items: [AIFoodItem]
            }

            let parsedDays = try JSONDecoder().decode([AIDay].self, from: jsonData)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.locale = Locale(identifier: "tr_TR")

            var cafeteriaDays: [CafeteriaDay] = []
            for aiDay in parsedDays {
                guard let date = dateFormatter.date(from: aiDay.date) else { continue }
                let items = aiDay.items.compactMap { item -> CafeteriaMealItem? in
                    let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }

                    let cat = MealCategory(rawValue: item.category ?? "") ?? MenuAIParser.inferCategory(for: trimmed)
                    let dTags = (item.dietaryTags ?? []).compactMap { DietaryTag(rawValue: $0) }
                    return CafeteriaMealItem(
                        name: trimmed,
                        category: cat,
                        calories: item.calories,
                        allergens: item.allergens ?? MenuAIParser.inferAllergens(for: trimmed),
                        dietaryTags: dTags.isEmpty ? MenuAIParser.inferDietaryTags(for: trimmed) : dTags
                    )
                }

                let mType = MealType(rawValue: aiDay.mealType ?? "") ?? .lunch
                let dayObj = CafeteriaDay(
                    schoolID: schoolID,
                    date: date,
                    day: aiDay.day,
                    mealItems: items,
                    mealType: mType,
                    sourceURL: sourceURL,
                    fetchedAt: Date(),
                    lastUpdatedAt: Date(),
                    parsingStatus: items.isEmpty ? .uncertain : .success,
                    confidence: 0.95,
                    rawText: content.rawText
                )
                cafeteriaDays.append(dayObj)
            }

            return cafeteriaDays.isEmpty ? nil : cafeteriaDays
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - Heuristic Rule-Based Parser (Fallback & Offline)

    public func parseWithHeuristics(
        content: ExtractedMenuContent,
        schoolID: String,
        sourceURL: URL?,
        referenceDate: Date
    ) -> [CafeteriaDay] {
        if !content.structuredRows.isEmpty {
            let days = parseTableRows(content.structuredRows, schoolID: schoolID, sourceURL: sourceURL, referenceDate: referenceDate)
            if !days.isEmpty { return days }
        }

        return parseTextBlocks(content.rawText, schoolID: schoolID, sourceURL: sourceURL, referenceDate: referenceDate)
    }

    // MARK: - Table Parsing Strategy

    private func parseTableRows(
        _ rows: [[String]],
        schoolID: String,
        sourceURL: URL?,
        referenceDate: Date
    ) -> [CafeteriaDay] {
        guard !rows.isEmpty else { return [] }

        // Strategy A: Columns are days of the week (e.g. Header has Pazartesi, Salı, Çarşamba, Perşembe, Cuma)
        if let headerRowIndex = rows.firstIndex(where: { row in
            row.contains(where: { cell in
                let lower = cell.lowercased()
                return lower.contains("pazartesi") || lower.contains("salı") || lower.contains("çarşamba") || lower.contains("cuma")
            })
        }) {
            let header = rows[headerRowIndex]
            var days: [CafeteriaDay] = []

            for colIndex in 0..<header.count {
                let headerCell = header[colIndex]
                guard let (date, dayName) = extractDateAndDay(from: headerCell, referenceDate: referenceDate) else {
                    continue
                }

                var items: [CafeteriaMealItem] = []
                for rowIndex in (headerRowIndex + 1)..<rows.count {
                    let row = rows[rowIndex]
                    if colIndex < row.count {
                        let text = row[colIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                        if isLegitimateMealItem(text) {
                            items.append(createMealItem(from: text))
                        }
                    }
                }

                if !items.isEmpty {
                    days.append(CafeteriaDay(
                        schoolID: schoolID,
                        date: date,
                        day: dayName,
                        mealItems: items,
                        mealType: .lunch,
                        sourceURL: sourceURL,
                        fetchedAt: Date(),
                        lastUpdatedAt: Date(),
                        parsingStatus: .success,
                        confidence: 0.90
                    ))
                }
            }

            if !days.isEmpty { return days }
        }

        // Strategy B: Rows are days (Column 0 is date/day, subsequent columns are meal items)
        var rowDays: [CafeteriaDay] = []
        for row in rows {
            guard !row.isEmpty else { continue }
            let firstCell = row[0]
            if let (date, dayName) = extractDateAndDay(from: firstCell, referenceDate: referenceDate) {
                var items: [CafeteriaMealItem] = []
                for colIndex in 1..<row.count {
                    let cellText = row[colIndex]
                    let subItems = splitMealCell(cellText)
                    for itemText in subItems {
                        if isLegitimateMealItem(itemText) {
                            items.append(createMealItem(from: itemText))
                        }
                    }
                }

                if !items.isEmpty {
                    rowDays.append(CafeteriaDay(
                        schoolID: schoolID,
                        date: date,
                        day: dayName,
                        mealItems: items,
                        mealType: .lunch,
                        sourceURL: sourceURL,
                        fetchedAt: Date(),
                        lastUpdatedAt: Date(),
                        parsingStatus: .success,
                        confidence: 0.88
                    ))
                }
            }
        }

        return rowDays
    }

    // MARK: - Plain Text Parsing Strategy

    private func parseTextBlocks(
        _ text: String,
        schoolID: String,
        sourceURL: URL?,
        referenceDate: Date
    ) -> [CafeteriaDay] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [CafeteriaDay] = []
        var currentDate: Date?
        var currentDayName: String?
        var currentItems: [CafeteriaMealItem] = []

        for line in lines {
            if let (date, dayName) = extractDateAndDay(from: line, referenceDate: referenceDate) {
                // Save previous day
                if let cDate = currentDate, let cDay = currentDayName, !currentItems.isEmpty {
                    result.append(CafeteriaDay(
                        schoolID: schoolID,
                        date: cDate,
                        day: cDay,
                        mealItems: currentItems,
                        mealType: .lunch,
                        sourceURL: sourceURL,
                        fetchedAt: Date(),
                        lastUpdatedAt: Date(),
                        parsingStatus: .success,
                        confidence: 0.85
                    ))
                }

                currentDate = date
                currentDayName = dayName
                currentItems = []

                // Line may contain meal items after a colon, e.g. "Pazartesi: Mercimek Çorbası, Tavuk Sote"
                if line.contains(":") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count > 1 {
                        let subItems = splitMealCell(String(parts[1]))
                        for item in subItems where isLegitimateMealItem(item) {
                            currentItems.append(createMealItem(from: item))
                        }
                    }
                }
            } else if currentDate != nil {
                let subItems = splitMealCell(line)
                for item in subItems where isLegitimateMealItem(item) {
                    currentItems.append(createMealItem(from: item))
                }
            }
        }

        // Add last day
        if let cDate = currentDate, let cDay = currentDayName, !currentItems.isEmpty {
            result.append(CafeteriaDay(
                schoolID: schoolID,
                date: cDate,
                day: cDay,
                mealItems: currentItems,
                mealType: .lunch,
                sourceURL: sourceURL,
                fetchedAt: Date(),
                lastUpdatedAt: Date(),
                parsingStatus: .success,
                confidence: 0.85
            ))
        }

        return result
    }

    // MARK: - Date & Day Extraction

    public func extractDateAndDay(from text: String, referenceDate: Date) -> (Date, String)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()

        let turkishDays = [
            "pazartesi": 2,
            "salı": 3,
            "çarşamba": 4,
            "perşembe": 5,
            "cuma": 6,
            "cumartesi": 7,
            "pazar": 1
        ]

        var matchedDayName: String?
        var matchedWeekdayNumber: Int?
        for (day, weekdayNum) in turkishDays {
            if lower.contains(day) {
                matchedDayName = day.capitalized(with: Locale(identifier: "tr_TR"))
                matchedWeekdayNumber = weekdayNum
                break
            }
        }

        // Pattern 1: Exact date with DD.MM.YYYY or DD/MM/YYYY or DD-MM-YYYY
        let dateRegex = try? NSRegularExpression(pattern: #"(\d{1,2})[\.\/\-](\d{1,2})[\.\/\-](\d{2,4})"#)
        if let match = dateRegex?.firstMatch(in: clean, options: [], range: NSRange(clean.startIndex..., in: clean)),
           let dRange = Range(match.range(at: 1), in: clean),
           let mRange = Range(match.range(at: 2), in: clean),
           let yRange = Range(match.range(at: 3), in: clean) {
            let d = Int(clean[dRange]) ?? 1
            let m = Int(clean[mRange]) ?? 1
            var y = Int(clean[yRange]) ?? 2026
            if y < 100 { y += 2000 }

            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = d
            comps.hour = 12
            if let parsedDate = Calendar(identifier: .gregorian).date(from: comps) {
                let dayName = matchedDayName ?? turkishDayName(for: parsedDate)
                return (parsedDate, dayName)
            }
        }

        // Pattern 2: Day with month name, e.g. "5 Kasım", "12 Ekim 2026"
        let monthMap: [String: Int] = [
            "ocak": 1, "şubat": 2, "mart": 3, "nisan": 4, "mayıs": 5, "haziran": 6,
            "temmuz": 7, "ağustos": 8, "eylül": 9, "ekim": 10, "kasım": 11, "aralık": 12
        ]

        for (monthName, monthNum) in monthMap {
            if lower.contains(monthName) {
                let dayRegex = try? NSRegularExpression(pattern: #"(\d{1,2})\s+"# + monthName)
                if let match = dayRegex?.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..., in: lower)),
                   let dRange = Range(match.range(at: 1), in: lower),
                   let dayVal = Int(lower[dRange]) {
                    let cal = Calendar(identifier: .gregorian)
                    var comps = cal.dateComponents([.year], from: referenceDate)
                    comps.month = monthNum
                    comps.day = dayVal
                    comps.hour = 12
                    if let parsedDate = cal.date(from: comps) {
                        let dayName = matchedDayName ?? turkishDayName(for: parsedDate)
                        return (parsedDate, dayName)
                    }
                }
            }
        }

        // Pattern 3: Only Day Name given (e.g. "Pazartesi", "Salı") -> map to current week's corresponding date
        if let matchedWeekday = matchedWeekdayNumber, let dayName = matchedDayName {
            var cal = Calendar(identifier: .gregorian)
            cal.firstWeekday = 2 // Monday is 2 in gregorian
            let currentWeekday = cal.component(.weekday, from: referenceDate)
            let diff = matchedWeekday - currentWeekday
            if let calculatedDate = cal.date(byAdding: .day, value: diff, to: referenceDate) {
                return (calculatedDate, dayName)
            }
        }

        return nil
    }

    private func turkishDayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date).capitalized(with: Locale(identifier: "tr_TR"))
    }

    // MARK: - Meal Item Processing & Classification

    public func splitMealCell(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: " - ", with: ",")
            .replacingOccurrences(of: "/", with: ",")
        return normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func isLegitimateMealItem(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.count < 3 || lower.count > 60 { return false }

        let forbiddenKeywords = [
            "afiyet olsun", "menü", "yemek listesi", "sayfa", "tarih", "günlük kalori",
            "öğle yemeği", "sabah kahvaltısı", "akşam yemeği", "okul", "toplam kalori",
            "pazartesi", "salı", "çarşamba", "perşembe", "cuma", "hafta", "dönem",
            "beslenme", "kalori:", "kcal", "kap", "1. kap", "2. kap", "3. kap", "4. kap"
        ]

        if forbiddenKeywords.contains(where: { lower == $0 }) {
            return false
        }

        // Must contain letters
        if !lower.contains(where: { $0.isLetter }) {
            return false
        }

        return true
    }

    public func createMealItem(from rawText: String) -> CafeteriaMealItem {
        var cleanName = rawText
        var extractedCalories: Int?

        // Check for calorie pattern, e.g. "Tavuk Sote (320 kcal)" or "180 kalori"
        let calorieRegex = try? NSRegularExpression(pattern: #"\(?\s*(\d{2,4})\s*(?:kcal|kal|kalori)\s*\)?"#, options: [.caseInsensitive])
        if let match = calorieRegex?.firstMatch(in: cleanName, options: [], range: NSRange(cleanName.startIndex..., in: cleanName)),
           let calRange = Range(match.range(at: 1), in: cleanName),
           let fullMatchRange = Range(match.range(at: 0), in: cleanName) {
            extractedCalories = Int(cleanName[calRange])
            cleanName.removeSubrange(fullMatchRange)
        }

        cleanName = cleanName.trimmingCharacters(in: CharacterSet(charactersIn: " ()-:,*#\t\n"))

        let category = Self.inferCategory(for: cleanName)
        let allergens = Self.inferAllergens(for: cleanName)
        let dietaryTags = Self.inferDietaryTags(for: cleanName)

        return CafeteriaMealItem(
            name: cleanName,
            category: category,
            calories: extractedCalories,
            allergens: allergens,
            dietaryTags: dietaryTags
        )
    }

    // MARK: - Classification Helpers

    public static func inferCategory(for dishName: String) -> MealCategory {
        let lower = dishName.lowercased()

        if lower.contains("çorba") || lower.contains("corba") || lower.contains("ezogelin") || lower.contains("tarhana") {
            return .soup
        }
        if lower.contains("tatlı") || lower.contains("tatli") || lower.contains("puding") || lower.contains("helva") ||
            lower.contains("revani") || lower.contains("kemalpaşa") || lower.contains("elma") || lower.contains("portakal") ||
            lower.contains("muz") || lower.contains("mandalina") || lower.contains("karpuz") || lower.contains("kavun") ||
            lower.contains("sütlaç") || lower.contains("kazandibi") || lower.contains("browni") || lower.contains("kek") {
            return .dessertOrFruit
        }
        if lower.contains("pilav") || lower.contains("makarna") || lower.contains("bulgur") || lower.contains("püre") ||
            lower.contains("patates kızartma") || lower.contains("salata") || lower.contains("cacık") || lower.contains("yoğurt") ||
            lower.contains("piyaz") || lower.contains("erişte") {
            return .sideDish
        }
        if lower.contains("ayran") || lower.contains("komposto") || lower.contains("meyve suyu") || lower.contains("limonata") ||
            lower.contains("şalgam") || lower.contains("hoşaf") || lower.contains("su") {
            return .beverage
        }
        if lower.contains("ekmek") || lower.contains("roll ekmek") || lower.contains("somun") {
            return .breadOrOther
        }

        return .mainDish
    }

    public static func inferAllergens(for dishName: String) -> [String] {
        let lower = dishName.lowercased()
        var allergens: [String] = []

        if lower.contains("makarna") || lower.contains("şehriye") || lower.contains("ekmek") ||
            lower.contains("bulgur") || lower.contains("börek") || lower.contains("un") ||
            lower.contains("erişte") || lower.contains("tarhana") {
            allergens.append("Gluten")
        }
        if lower.contains("yoğurt") || lower.contains("cacık") || lower.contains("süt") ||
            lower.contains("peynir") || lower.contains("tereyağ") || lower.contains("ayran") ||
            lower.contains("puding") || lower.contains("sütlaç") {
            allergens.append("Süt / Laktoz")
        }
        if lower.contains("yumurta") || lower.contains("menemen") || lower.contains("kek") || lower.contains("browni") {
            allergens.append("Yumurta")
        }
        if lower.contains("ceviz") || lower.contains("fındık") || lower.contains("fıstık") || lower.contains("badem") {
            allergens.append("Kuruyemiş")
        }
        if lower.contains("balık") || lower.contains("somon") || lower.contains("ton") {
            allergens.append("Balık")
        }

        return allergens
    }

    public static func inferDietaryTags(for dishName: String) -> [DietaryTag] {
        let lower = dishName.lowercased()
        var tags: [DietaryTag] = [.halal]

        let isMeat = lower.contains("tavuk") || lower.contains("köfte") || lower.contains("kıyma") ||
            lower.contains("et") || lower.contains("kavurma") || lower.contains("hindi") ||
            lower.contains("tas kebabı") || lower.contains("balık") || lower.contains("sote")

        if !isMeat {
            tags.append(.vegetarian)
            let isDairy = lower.contains("yoğurt") || lower.contains("peynir") || lower.contains("süt") ||
                lower.contains("tereyağ") || lower.contains("ayran") || lower.contains("sütlaç")
            let isEgg = lower.contains("yumurta")
            if !isDairy && !isEgg {
                tags.append(.vegan)
            }
        }

        if isMeat || lower.contains("nohut") || lower.contains("kuru fasulye") || lower.contains("mercimek") {
            tags.append(.highProtein)
        }

        let hasGluten = lower.contains("makarna") || lower.contains("şehriye") || lower.contains("ekmek") ||
            lower.contains("bulgur") || lower.contains("börek") || lower.contains("un")
        if !hasGluten {
            tags.append(.glutenFree)
        }

        return tags
    }
}
