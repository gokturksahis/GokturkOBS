//
//  CafeteriaIntelligenceModels.swift
//  GokturkOBS
//
//  Created for GokturkOBS AI Cafeteria Intelligence.
//

import Foundation
import SwiftUI

// MARK: - Meal Category
public enum MealCategory: String, Codable, CaseIterable, Sendable {
    case soup = "soup"
    case mainDish = "mainDish"
    case sideDish = "sideDish"
    case dessertOrFruit = "dessertOrFruit"
    case beverage = "beverage"
    case breadOrOther = "breadOrOther"
    case snack = "snack"

    public var titleTr: String {
        switch self {
        case .soup: return "Çorba"
        case .mainDish: return "Ana Yemek"
        case .sideDish: return "Yan Yemek / Garnitür"
        case .dessertOrFruit: return "Tatlı / Meyve"
        case .beverage: return "İçecek"
        case .breadOrOther: return "Ekmek / Diğer"
        case .snack: return "Ara Öğün"
        }
    }

    public var iconName: String {
        switch self {
        case .soup: return "cup.and.saucer.fill"
        case .mainDish: return "fork.knife"
        case .sideDish: return "frying.pan.fill"
        case .dessertOrFruit: return "birthday.cake.fill"
        case .beverage: return "waterbottle.fill"
        case .breadOrOther: return "takeoutbag.and.cup.and.straw.fill"
        case .snack: return "carrot.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .soup: return .orange
        case .mainDish: return .red
        case .sideDish: return .yellow
        case .dessertOrFruit: return .pink
        case .beverage: return .blue
        case .breadOrOther: return .brown
        case .snack: return .green
        }
    }
}

// MARK: - Meal Type
public enum MealType: String, Codable, CaseIterable, Sendable {
    case breakfast = "breakfast"
    case lunch = "lunch"
    case dinner = "dinner"
    case snack = "snack"

    public var titleTr: String {
        switch self {
        case .breakfast: return "Kahvaltı"
        case .lunch: return "Öğle Yemeği"
        case .dinner: return "Akşam Yemeği"
        case .snack: return "Ara Öğün"
        }
    }

    public var iconName: String {
        switch self {
        case .breakfast: return "sun.horizon.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "leaf.fill"
        }
    }
}

// MARK: - Dietary Tag
public enum DietaryTag: String, Codable, CaseIterable, Sendable {
    case vegetarian = "vegetarian"
    case vegan = "vegan"
    case glutenFree = "glutenFree"
    case dairyFree = "dairyFree"
    case highProtein = "highProtein"
    case halal = "halal"

    public var titleTr: String {
        switch self {
        case .vegetarian: return "Vejetaryen"
        case .vegan: return "Vegan"
        case .glutenFree: return "Glutensiz"
        case .dairyFree: return "Laktozsuz"
        case .highProtein: return "Yüksek Protein"
        case .halal: return "Helal"
        }
    }

    public var iconName: String {
        switch self {
        case .vegetarian: return "leaf.fill"
        case .vegan: return "sparkles"
        case .glutenFree: return "cross.fill"
        case .dairyFree: return "drop.slash.fill"
        case .highProtein: return "bolt.fill"
        case .halal: return "checkmark.seal.fill"
        }
    }
}

// MARK: - Parsing Status
public enum ParsingStatus: String, Codable, Sendable {
    case success = "success"
    case partial = "partial"
    case failed = "failed"
    case uncertain = "uncertain"

    public var titleTr: String {
        switch self {
        case .success: return "Başarılı"
        case .partial: return "Kısmi Veri"
        case .failed: return "Başarısız"
        case .uncertain: return "Belirsiz"
        }
    }
}

// MARK: - Cafeteria Meal Item
public struct CafeteriaMealItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: MealCategory
    public var calories: Int?
    public var allergens: [String]
    public var dietaryTags: [DietaryTag]

    public init(
        id: String = UUID().uuidString,
        name: String,
        category: MealCategory = .mainDish,
        calories: Int? = nil,
        allergens: [String] = [],
        dietaryTags: [DietaryTag] = []
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
        self.calories = calories
        self.allergens = allergens
        self.dietaryTags = dietaryTags
    }
}

// MARK: - Cafeteria Day Menu
public struct CafeteriaDay: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var schoolID: String
    public var date: Date
    public var day: String
    public var mealItems: [CafeteriaMealItem]
    public var mealType: MealType
    public var sourceURL: URL?
    public var fetchedAt: Date
    public var lastUpdatedAt: Date
    public var parsingStatus: ParsingStatus
    public var confidence: Double
    public var rawText: String?

    public init(
        id: String = UUID().uuidString,
        schoolID: String = "default",
        date: Date,
        day: String,
        mealItems: [CafeteriaMealItem],
        mealType: MealType = .lunch,
        sourceURL: URL? = nil,
        fetchedAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        parsingStatus: ParsingStatus = .success,
        confidence: Double = 1.0,
        rawText: String? = nil
    ) {
        self.id = id
        self.schoolID = schoolID
        self.date = date
        self.day = day
        self.mealItems = mealItems
        self.mealType = mealType
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.parsingStatus = parsingStatus
        self.confidence = confidence
        self.rawText = rawText
    }

    public var formattedDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    public var shortDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}

// MARK: - Agent Personality
public enum AgentPersonality: String, Codable, CaseIterable, Identifiable, Sendable {
    case acimasiz = "acimasiz"
    case samimi = "samimi"
    case normal = "normal"
    case rehberlikHocan = "rehberlikHocan"
    case profesyonel = "profesyonel"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .acimasiz: return "Acımasız (Varsayılan)"
        case .samimi: return "Samimi"
        case .normal: return "Normal"
        case .rehberlikHocan: return "Rehberlik Hocan"
        case .profesyonel: return "Profesyonel"
        }
    }

    public var shortName: String {
        switch self {
        case .acimasiz: return "Acımasız"
        case .samimi: return "Samimi"
        case .normal: return "Normal"
        case .rehberlikHocan: return "Rehberlik"
        case .profesyonel: return "Profesyonel"
        }
    }

    public var systemPromptPersona: String {
        switch self {
        case .acimasiz:
            return "Sen GöktürkOBS Agent'ısın. Kişiliğin: Acımasız, dobralıkla mizah yapan, hafif sarkastik ve esprili bir lise/üniversite arkadaşı. Gerçek yemekleri ve verileri değiştirmeden menüyü iğneleyici ve komik bir dille yorumla. Asla hakaret etme veya kullanıcıyı yargılama, okul yemekhanesi klişeleriyle eğlenceli dalga geç."
        case .samimi:
            return "Sen GöktürkOBS Agent'ısın. Kişiliğin: Samimi, sıcakkanlı, destekleyici ve cana yakın bir okul arkadaşı. Menüyü sevgi dolu ve enerjik bir dille yorumla, gününü güzelleştirecek tavsiyeler ver."
        case .normal:
            return "Sen GöktürkOBS Agent'ısın. Kişiliğin: Dengeli, sakin, tarafsız ve net. Menüdeki yemekleri nesnel bir şekilde özetle ve kısa bilgi ver."
        case .rehberlikHocan:
            return "Sen GöktürkOBS Agent'ısın. Kişiliğin: Bilge, sevecen ama disiplinli bir okul rehberlik öğretmeni. Yemeğin ders çalışma, sınav başarısı ve zihinsel odaklanma üzerindeki etkilerini vurgula; besleyici öğütler ver."
        case .profesyonel:
            return "Sen GöktürkOBS Agent'ısın. Kişiliğin: Profesyonel beslenme uzmanı ve gastronomi analisti. Menünün protein, karbonhidrat, lif dengesini ve kalori dengesini teknik ve saygın bir üslupla değerlendir."
        }
    }

    public var iconName: String {
        switch self {
        case .acimasiz: return "bolt.shield.fill"
        case .samimi: return "heart.fill"
        case .normal: return "message.fill"
        case .rehberlikHocan: return "graduationcap.fill"
        case .profesyonel: return "chart.bar.doc.horizontal.fill"
        }
    }
}

// MARK: - Menu Change Record
public struct MenuChangeRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum ChangeType: String, Codable, Sendable {
        case itemReplaced = "itemReplaced"
        case itemAdded = "itemAdded"
        case itemRemoved = "itemRemoved"
        case menuCancelled = "menuCancelled"
    }

    public var id: String
    public var date: Date
    public var changeType: ChangeType
    public var oldItemName: String?
    public var newItemName: String?
    public var explanation: String
    public var detectedAt: Date

    public init(
        id: String = UUID().uuidString,
        date: Date,
        changeType: ChangeType,
        oldItemName: String? = nil,
        newItemName: String? = nil,
        explanation: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.changeType = changeType
        self.oldItemName = oldItemName
        self.newItemName = newItemName
        self.explanation = explanation
        self.detectedAt = detectedAt
    }
}

// MARK: - User Food Preference
public struct UserFoodPreference: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum PreferenceKind: String, Codable, CaseIterable, Sendable {
        case favorite = "favorite"
        case disliked = "disliked"
        case allergy = "allergy"
        case restriction = "restriction"

        public var titleTr: String {
            switch self {
            case .favorite: return "Sevilen / Favori"
            case .disliked: return "Sevilmeyen"
            case .allergy: return "Alerjen"
            case .restriction: return "Diyet Kısıtlaması"
            }
        }
    }

    public var id: String
    public var itemName: String
    public var kind: PreferenceKind
    public var note: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        itemName: String,
        kind: PreferenceKind,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - Menu Source Configuration
public nonisolated struct MenuSourceConfig: Codable, Equatable, Sendable {
    public var schoolID: String
    public var schoolName: String
    public var cafeteriaURL: URL?
    public var lastCheckedAt: Date?
    public var isAutoDiscovered: Bool
    public var robotsAllowed: Bool

    public init(
        schoolID: String = "default",
        schoolName: String = "Okulum",
        cafeteriaURL: URL? = nil,
        lastCheckedAt: Date? = nil,
        isAutoDiscovered: Bool = false,
        robotsAllowed: Bool = true
    ) {
        self.schoolID = schoolID
        self.schoolName = schoolName
        self.cafeteriaURL = cafeteriaURL
        self.lastCheckedAt = lastCheckedAt
        self.isAutoDiscovered = isAutoDiscovered
        self.robotsAllowed = robotsAllowed
    }
}
