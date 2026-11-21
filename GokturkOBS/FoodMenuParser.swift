import Foundation
import PDFKit
import CryptoKit

struct FoodMenuDay: Identifiable, Equatable, Codable {
    let heading: String
    let items: [String]
    let pageIndex: Int
    var id: String { "\(pageIndex)|\(heading)" }
}

/// The parsed menu and its on-device analysis, persisted as JSON so a PDF is only
/// ever parsed and analysed once.
struct FoodMenuCache: Codable, Equatable {
    var days: [FoodMenuDay]
    var analyses: [FoodMenuDay.ID: FoodMenuAnalysisDay]

    init(days: [FoodMenuDay], analyses: [FoodMenuDay.ID: FoodMenuAnalysisDay] = [:]) {
        self.days = days
        self.analyses = analyses
    }
}

enum FoodMenuCacheStore {
    /// Bump when the parser or cache schema changes so stale JSON is not reused.
    private static let cacheVersion = "v4"

    static func cacheKey(forPDFData data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func load(forPDFData data: Data) -> FoodMenuCache? {
        guard let url = cacheURL(forPDFData: data),
              let contents = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(FoodMenuCache.self, from: contents)
    }

    static func save(_ cache: FoodMenuCache, forPDFData data: Data) {
        guard let url = cacheURL(forPDFData: data),
              let contents = try? JSONEncoder().encode(cache) else {
            return
        }
        try? contents.write(to: url, options: .atomic)
    }

    private static func cacheURL(forPDFData data: Data) -> URL? {
        guard let directory = cacheDirectory() else { return nil }
        return directory
            .appendingPathComponent("\(cacheVersion)-\(cacheKey(forPDFData: data))")
            .appendingPathExtension("json")
    }

    private static func cacheDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = applicationSupport
            .appendingPathComponent("GokturkOBS", isDirectory: true)
            .appendingPathComponent("FoodMenuCache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }
}

enum FoodMenuParser {
    private static let weekdays = ["pazartesi", "salı", "çarşamba", "perşembe", "cuma"]
    private static let weekdayNames = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma"]
    private static let monthNames = [
        "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran",
        "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"
    ]
    nonisolated private static let turkishLocale = Locale(identifier: "tr_TR")

    private static let monthNumbers: [String: Int] = [
        "ocak": 1,
        "subat": 2,
        "mart": 3,
        "nisan": 4,
        "mayis": 5,
        "haziran": 6,
        "temmuz": 7,
        "agustos": 8,
        "eylul": 9,
        "ekim": 10,
        "kasim": 11,
        "aralik": 12
    ]

    /// Exact labels that are table sections rather than dishes.
    private static let sectionLabels: Set<String> = [
        "tarih", "grup", "corba", "ana yemek", "yardimci yemek", "tamamlayici",
        "kalori", "toplam kalori", "sabah kahvaltisi", "kahvalti", "ogle yemegi",
        "ikindi kahvaltisi", "salatbar", "pasta-tatli-meyve", "aksam yemegi",
        "ara ogun"
    ]

    /// Substrings that only appear in table headers or footers, never in a dish name.
    private static let headerFragments = [
        "tl.", "oden", "butce", "siniflar", "kulubu", "toplam kalori", "tarih",
        "meb.k12.tr", "www.", "http://", "https://", "instagram", "facebook", "twitter"
    ]

    private static let headingRowTolerance: CGFloat = 12
    private static let headerGroupGap: CGFloat = 45
    private static let cellLineGap: CGFloat = 15
    private static let xClusterGap: CGFloat = 60
    private static let rowHeadingGroupGap: CGFloat = 14
    private static let rowUpperMargin: CGFloat = 16

    private struct MenuLine {
        let text: String
        let bounds: CGRect
    }

    private struct HeadingRow {
        let lines: [MenuLine]

        var midY: CGFloat {
            average(lines.map(\.bounds.midY))
        }
    }

    private struct RowHeading {
        let text: String
        /// The top line of the heading pair (the date when one exists). Used as
        /// the upper boundary of the row that belongs to this day.
        let topY: CGFloat
    }

    private struct WeekBand {
        let startDay: Int
        let month: Int
        let year: Int
        let centerY: CGFloat
    }

    private struct MenuCell {
        let fragments: [MenuLine]
        var centerY: CGFloat {
            guard let minY = fragments.map(\.bounds.minY).min(),
                  let maxY = fragments.map(\.bounds.maxY).max() else {
                return 0
            }
            return (minY + maxY) / 2
        }

        var text: String {
            fragments
                .sorted { $0.bounds.midY > $1.bounds.midY }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    static func parse(_ document: PDFDocument) -> [FoodMenuDay] {
        var result: [FoodMenuDay] = []
        var yearsByPage: [Int: Int] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard let selection = page.selection(for: bounds) else { continue }
            let lines = selection.selectionsByLine().compactMap { line -> MenuLine? in
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    return nil
                }
                return MenuLine(text: text, bounds: line.bounds(for: page))
            }

            let defaultYear = inferredYear(in: lines)
            if let defaultYear {
                yearsByPage[pageIndex] = defaultYear
            }
            let headings = lines.filter { isHeading($0.text, defaultYear: defaultYear) }
            guard !headings.isEmpty else { continue }
            // Multi-week grids repeat one weekday column for every `I. HAFTA`
            // band, so a single column holds several weeks.
            if isWeekGrid(lines, headings: headings) {
                result.append(contentsOf: parseWeekGrid(
                    lines: lines,
                    headings: headings,
                    pageIndex: pageIndex,
                    defaultYear: defaultYear
                ))
                continue
            }

            if isRowLayout(headings, in: bounds) {
                result.append(contentsOf: parseRowLayout(
                    lines: lines,
                    headings: headings,
                    pageIndex: pageIndex,
                    bounds: bounds,
                    defaultYear: defaultYear
                ))
            } else {
                result.append(contentsOf: parseColumnLayout(
                    lines: lines,
                    headings: headings,
                    pageIndex: pageIndex,
                    bounds: bounds,
                    defaultYear: defaultYear
                ))
            }
        }
        return mergedDays(result, yearsByPage: yearsByPage)
    }

    // MARK: - Layout detection

    /// Some schools put dates in a left-hand column (one row per day); others put
    /// them across the top (one column per day). When headings all share the same
    /// x position but are stacked vertically, the page is row-oriented.
    private static func isRowLayout(_ headings: [MenuLine], in bounds: CGRect) -> Bool {
        guard headings.count >= 2 else { return false }
        let midXs = headings.map(\.bounds.midX)
        let midYs = headings.map(\.bounds.midY)
        guard let minX = midXs.min(), let maxX = midXs.max(),
              let minY = midYs.min(), let maxY = midYs.max() else {
            return false
        }
        return (maxX - minX) < bounds.width * 0.15
            && (maxY - minY) > bounds.height * 0.2
    }

    /// Detects menus laid out as a grid of `I.–V. HAFTA` week bands under one set
    /// of weekday headers (Mimar Sinan style). Such a page lists several weeks per
    /// column, which has no single menu per weekday.
    private static func isWeekGrid(_ lines: [MenuLine], headings: [MenuLine]) -> Bool {
        let hasWeekLabel = lines.contains { line in
            firstMatch(
                in: normalize(line.text),
                pattern: #"\b(?:i{1,3}|iv|v)\.?\s*hafta\b"#
            ) != nil
        }
        guard hasWeekLabel else { return false }

        let weekdayHeadings = headings.filter { line in
            guard date(in: line.text) == nil else { return false }
            let normalized = normalize(line.text)
            return weekdays.contains { normalized.contains(normalize($0)) }
        }
        guard weekdayHeadings.count >= 3 else { return false }

        let midYs = weekdayHeadings.map(\.bounds.midY)
        guard let minY = midYs.min(), let maxY = midYs.max() else { return false }
        return (maxY - minY) < headingRowTolerance
    }

    // MARK: - Week-grid menus (weekday columns + week bands)

    private static func parseWeekGrid(
        lines: [MenuLine],
        headings: [MenuLine],
        pageIndex: Int,
        defaultYear: Int?
    ) -> [FoodMenuDay] {
        let bands = weekBands(from: lines, defaultYear: defaultYear)
        guard bands.count >= 2 else { return [] }

        let weekdayHeaders: [(index: Int, midX: CGFloat)] = weekdays.enumerated().compactMap { index, name in
            guard let header = headings.first(where: { normalize($0.text) == normalize(name) }) else {
                return nil
            }
            return (index, header.bounds.midX)
        }
        guard weekdayHeaders.count >= 2 else { return [] }

        let gaps = zip(bands, bands.dropFirst())
            .map { $0.centerY - $1.centerY }
            .filter { $0 > 0 }
        let maxBandDistance = max(42, median(gaps) * 0.55)

        var itemsByBandDay: [String: [String]] = [:]
        var holidayBands = Set<Int>()

        for line in lines {
            if isHeading(line.text, defaultYear: defaultYear) { continue }
            if isWeekBandFragment(line.text) || isWeekGridLabel(line.text) { continue }

            let normalized = normalize(line.text)
            if normalized.contains("ara tatil") {
                if let band = nearestBand(to: line.bounds.midY, bands: bands, maxDistance: maxBandDistance) {
                    holidayBands.insert(band)
                }
                continue
            }

            guard line.text.rangeOfCharacter(from: .letters) != nil,
                  !headerFragments.contains(where: { normalized.contains($0) }) else {
                continue
            }
            guard let band = nearestBand(to: line.bounds.midY, bands: bands, maxDistance: maxBandDistance),
                  let weekday = weekdayHeaders.min(by: {
                      abs($0.midX - line.bounds.midX) < abs($1.midX - line.bounds.midX)
                  }) else {
                continue
            }
            let dishes = splitDishes(line.text)
            guard !dishes.isEmpty else { continue }
            itemsByBandDay["\(band)|\(weekday.index)", default: []].append(contentsOf: dishes)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var result: [FoodMenuDay] = []

        for (bandIndex, band) in bands.enumerated() {
            guard let startDate = makeDate(day: band.startDay, month: band.month, year: band.year) else {
                continue
            }
            // Calendar weekday: Sunday = 1 ... Saturday = 7.
            let startWeekday = (calendar.component(.weekday, from: startDate) + 5) % 7

            for weekday in weekdayHeaders.sorted(by: { $0.index < $1.index }) {
                let items = filteredItems(
                    deduplicated(itemsByBandDay["\(bandIndex)|\(weekday.index)"] ?? [])
                )
                let isHoliday = items.isEmpty && holidayBands.contains(bandIndex)
                guard !items.isEmpty || isHoliday else { continue }

                let offset = (weekday.index - startWeekday + 7) % 7
                guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                    continue
                }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day,
                      (1...12).contains(month) else {
                    continue
                }
                result.append(FoodMenuDay(
                    heading: "\(day) \(monthNames[month - 1]) \(year) \(weekdayNames[weekday.index])",
                    items: isHoliday ? ["ARA TATİL"] : items,
                    pageIndex: pageIndex
                ))
            }
        }
        return result
    }

    /// Reads the left-hand week labels, which are often split over several lines
    /// (`02-06` / `KASIM` / `2026`) because the column is narrow.
    private static func weekBands(from lines: [MenuLine], defaultYear: Int?) -> [WeekBand] {
        let labelLines = lines
            .filter { isWeekBandFragment($0.text) }
            .sorted { $0.bounds.midY > $1.bounds.midY }
        guard !labelLines.isEmpty else { return [] }

        var groups: [[MenuLine]] = []
        for line in labelLines {
            if let last = groups.indices.last,
               let reference = groups[last].first,
               reference.bounds.midY - line.bounds.midY <= 20 {
                groups[last].append(line)
            } else {
                groups.append([line])
            }
        }

        let currentYear = defaultYear ?? Calendar.current.component(.year, from: Date())
        return groups.compactMap { group in
            let text = group
                .sorted { $0.bounds.midY > $1.bounds.midY }
                .map(\.text)
                .joined(separator: " ")
            let normalized = normalize(text)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let match = firstMatch(
                in: normalized,
                pattern: #"^(\d{1,2})\s*[-–]\s*(\d{1,2})\s+(ocak|subat|mart|nisan|mayis|haziran|temmuz|agustos|eylul|ekim|kasim|aralik)(?:\s+(\d{4}))?$"#
            ), let day = Int(match[1]), let month = monthNumbers[match[3]] {
                return WeekBand(
                    startDay: day,
                    month: month,
                    year: Int(match[4]) ?? currentYear,
                    centerY: average(group.map(\.bounds.midY))
                )
            }

            if let match = firstMatch(
                in: normalized,
                pattern: #"^(\d{1,2})\s+(ocak|subat|mart|nisan|mayis|haziran|temmuz|agustos|eylul|ekim|kasim|aralik)(?:\s+(\d{4}))?$"#
            ), let day = Int(match[1]), let month = monthNumbers[match[2]] {
                return WeekBand(
                    startDay: day,
                    month: month,
                    year: Int(match[3]) ?? currentYear,
                    centerY: average(group.map(\.bounds.midY))
                )
            }
            return nil
        }
    }

    private static func nearestBand(to y: CGFloat, bands: [WeekBand], maxDistance: CGFloat) -> Int? {
        guard let index = bands.indices.min(by: {
            abs(bands[$0].centerY - y) < abs(bands[$1].centerY - y)
        }), abs(bands[index].centerY - y) <= maxDistance else {
            return nil
        }
        return index
    }

    private static func isWeekBandFragment(_ text: String) -> Bool {
        let normalized = normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let month = #"(?:ocak|subat|mart|nisan|mayis|haziran|temmuz|agustos|eylul|ekim|kasim|aralik)"#
        let patterns = [
            #"^\d{1,2}\s*[-–]\s*\d{1,2}$"#,
            #"^\d{1,2}\s+"# + month + #"(?:\s+\d{4})?$"#,
            #"^"# + month + #"(?:\s+\d{4})?$"#,
            #"^(?:19|20)\d{2}$"#
        ]
        return patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func isWeekGridLabel(_ text: String) -> Bool {
        let normalized = normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "gunler"
            || normalized.range(
                of: #"^(?:i{1,3}|iv|v)\.?\s*hafta$"#,
                options: .regularExpression
            ) != nil
    }

    // MARK: - Column-oriented menus (OBS style)

    private static func parseColumnLayout(
        lines: [MenuLine],
        headings: [MenuLine],
        pageIndex: Int,
        bounds: CGRect,
        defaultYear: Int?
    ) -> [FoodMenuDay] {
        let rows = headingRows(headings)
        let groups = headerGroups(rows)
        var result: [FoodMenuDay] = []

        for (groupIndex, group) in groups.enumerated() {
            let chosen = chosenHeadings(in: group, defaultYear: defaultYear)
            guard !chosen.isEmpty else { continue }
            let ordered = chosen.sorted { $0.bounds.midX < $1.bounds.midX }
            let lowerY = groupIndex + 1 < groups.count
                ? (groups[groupIndex + 1].map(\.midY).max() ?? bounds.minY)
                : bounds.minY

            for (index, heading) in ordered.enumerated() {
                let previousX: CGFloat
                if index == 0 {
                    if ordered.count > 1 {
                        let halfGap = (ordered[1].bounds.midX - heading.bounds.midX) / 2
                        previousX = max(bounds.minX, heading.bounds.midX - halfGap)
                    } else {
                        previousX = bounds.minX
                    }
                } else {
                    previousX = (ordered[index - 1].bounds.midX + heading.bounds.midX) / 2
                }
                let nextX = index == ordered.count - 1
                    ? bounds.maxX
                    : (heading.bounds.midX + ordered[index + 1].bounds.midX) / 2

                let candidates = lines.filter { line in
                    line.bounds.midX >= previousX
                        && line.bounds.midX < nextX
                        && line.bounds.midY < heading.bounds.midY
                        && line.bounds.midY > lowerY
                        && !isHeading(line.text, defaultYear: defaultYear)
                }
                let items = filteredItems(deduplicated(mergeTableCells(candidates)))
                guard !items.isEmpty else { continue }
                result.append(FoodMenuDay(
                    heading: cleanedHeading(heading.text),
                    items: items,
                    pageIndex: pageIndex
                ))
            }
        }
        return result
    }

    private static func headingRows(_ headings: [MenuLine]) -> [HeadingRow] {
        let sorted = headings.sorted { $0.bounds.midY > $1.bounds.midY }
        var rows: [[MenuLine]] = []
        for heading in sorted {
            if let lastIndex = rows.indices.last,
               let reference = rows[lastIndex].first,
               abs(reference.bounds.midY - heading.bounds.midY) <= headingRowTolerance {
                rows[lastIndex].append(heading)
            } else {
                rows.append([heading])
            }
        }
        return rows.map { row in
            HeadingRow(lines: row.sorted { $0.bounds.midX < $1.bounds.midX })
        }
    }

    /// Weekday headers and date headers can sit on two neighbouring lines of the
    /// same table. They form one header group, and dates win when both exist.
    private static func headerGroups(_ rows: [HeadingRow]) -> [[HeadingRow]] {
        var groups: [[HeadingRow]] = []
        for row in rows {
            if let lastIndex = groups.indices.last,
               let previous = groups[lastIndex].last,
               previous.midY - row.midY < headerGroupGap {
                groups[lastIndex].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }

    private static func chosenHeadings(in group: [HeadingRow], defaultYear: Int?) -> [MenuLine] {
        for row in group.reversed() {
            let dated = row.lines.filter { date(in: $0.text, defaultYear: defaultYear) != nil }
            if !dated.isEmpty { return dated }
        }
        return group.last?.lines ?? []
    }

    // MARK: - Row-oriented menus (date column on the left)

    private static func parseRowLayout(
        lines: [MenuLine],
        headings: [MenuLine],
        pageIndex: Int,
        bounds: CGRect,
        defaultYear: Int?
    ) -> [FoodMenuDay] {
        let ordered = rowHeadings(from: headings)
        guard !ordered.isEmpty else { return [] }

        let headingRight = (headings.map(\.bounds.maxX).max() ?? bounds.minX) + 2
        let upperBound = ordered[0].topY + rowUpperMargin

        let candidates = lines.filter { line in
            line.bounds.minX >= headingRight
                && line.bounds.midY < upperBound
                && line.bounds.midY > bounds.minY
                && line.text.rangeOfCharacter(from: .letters) != nil
                && !isHeading(line.text, defaultYear: defaultYear)
        }
        let gaps = zip(ordered, ordered.dropFirst())
            .map { $0.topY - $1.topY }
            .filter { $0 > 0 }
        let assignmentRadius = max(24, median(gaps) * 0.75)

        let cells = menuCells(from: candidates, boundaries: ordered.map(\.topY))
        var itemsByHeading: [Int: [String]] = [:]
        for cell in cells {
            guard let nearest = ordered.indices.min(by: {
                abs(ordered[$0].topY - cell.centerY) < abs(ordered[$1].topY - cell.centerY)
            }) else {
                continue
            }
            guard abs(ordered[nearest].topY - cell.centerY) <= assignmentRadius else {
                continue
            }
            let dishes = splitDishes(cell.text)
            if !dishes.isEmpty {
                itemsByHeading[nearest, default: []].append(contentsOf: dishes)
            }
        }

        return ordered.enumerated().compactMap { index, heading in
            let items = filteredItems(deduplicated(itemsByHeading[index] ?? []))
            guard !items.isEmpty else { return nil }
            return FoodMenuDay(heading: heading.text, items: items, pageIndex: pageIndex)
        }
    }

    /// Date and weekday labels often sit on two lines of the same table row. Keep
    /// them together as a single heading so one day does not turn into two.
    private static func rowHeadings(from headings: [MenuLine]) -> [RowHeading] {
        let sorted = headings.sorted { $0.bounds.midY > $1.bounds.midY }
        var groups: [[MenuLine]] = []
        for line in sorted {
            if let lastIndex = groups.indices.last,
               let reference = groups[lastIndex].first,
               reference.bounds.midY - line.bounds.midY <= rowHeadingGroupGap {
                groups[lastIndex].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { group in
            let text = group
                .sorted { $0.bounds.midY > $1.bounds.midY }
                .map(\.text)
                .joined(separator: " ")
            return RowHeading(
                text: cleanedHeading(text),
                topY: group.map(\.bounds.midY).max() ?? 0
            )
        }
    }

    /// Groups fragments into visual cells: first by horizontal column, then by
    /// continuous vertical runs inside that column. A heading row always starts a
    /// new cell, so two neighbouring days never merge even when rows are tight.
    private static func menuCells(from candidates: [MenuLine], boundaries: [CGFloat] = []) -> [MenuCell] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted { $0.bounds.minX < $1.bounds.minX }

        // Anchor each column on its leftmost cell. A wrapped continuation may be
        // indented, but the next real column starts far enough away to stay apart.
        var xClusters: [[MenuLine]] = []
        var clusterAnchorX = -CGFloat.greatestFiniteMagnitude
        for fragment in sorted {
            if !xClusters.isEmpty, fragment.bounds.minX - clusterAnchorX <= xClusterGap {
                xClusters[xClusters.count - 1].append(fragment)
            } else {
                xClusters.append([fragment])
                clusterAnchorX = fragment.bounds.minX
            }
        }

        var cells: [MenuCell] = []
        for cluster in xClusters {
            var current: [MenuLine] = []
            for fragment in cluster.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
                if let previous = current.last {
                    let crossesBoundary = boundaries.contains { boundary in
                        boundary >= fragment.bounds.midY && boundary <= previous.bounds.midY
                    }
                    if previous.bounds.midY - fragment.bounds.midY > cellLineGap || crossesBoundary {
                        cells.append(MenuCell(fragments: current))
                        current = [fragment]
                    } else {
                        current.append(fragment)
                    }
                } else {
                    current.append(fragment)
                }
            }
            if !current.isEmpty {
                cells.append(MenuCell(fragments: current))
            }
        }
        return cells
    }

    private static func splitDishes(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
    }

    // MARK: - Headings and dates

    /// Recognises both weekday headings and dated headings. Current OBS PDFs use
    /// `2 Kasım 2026`; other schools omit the year, so a page-level year is used.
    private static func isHeading(_ text: String, defaultYear: Int?) -> Bool {
        let normalized = normalize(text)
        if weekdays.contains(where: { normalized.contains(normalize($0)) }) {
            return true
        }
        return date(in: text, defaultYear: defaultYear) != nil
    }

    /// Extracts an explicit date from a heading. Returning a date lets the dashboard
    /// resolve today's menu even when the PDF does not contain weekday names.
    static func date(in heading: String, defaultYear: Int? = nil) -> Date? {
        let normalized = normalize(heading)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let currentYear = Calendar.current.component(.year, from: Date())
        let year = defaultYear ?? currentYear

        if let groups = firstMatch(
            in: normalized,
            pattern: #"(?<![\d\-–])(\d{1,2})[./](\d{1,2})(?:[./](\d{4}))?(?!\d)"#
        ),
           let day = Int(groups[1]),
           let month = Int(groups[2]) {
            let parsedYear = Int(groups[3]) ?? year
            return makeDate(day: day, month: month, year: parsedYear)
        }

        if let groups = firstMatch(
            in: normalized,
            pattern: #"(?<![\d\-–])(\d{1,2})\s+(ocak|subat|mart|nisan|mayis|haziran|temmuz|agustos|eylul|ekim|kasim|aralik)(?:\s+(\d{4}))?(?!\d)"#
        ),
           let day = Int(groups[1]),
           let month = monthNumbers[groups[2]] {
            let parsedYear = Int(groups[3]) ?? year
            return makeDate(day: day, month: month, year: parsedYear)
        }

        return nil
    }

    private static func inferredYear(in lines: [MenuLine]) -> Int? {
        for line in lines {
            if let groups = firstMatch(in: normalize(line.text), pattern: #"(?<!\d)(20\d{2})(?!\d)"#),
               let year = Int(groups[1]) {
                return year
            }
        }
        return nil
    }

    /// Removes stray table labels that PDFKit sometimes merges into a heading.
    private static func cleanedHeading(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\bkalori\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some PDFs repeat the same dated menu on several pages (for different
    /// school levels). Merge those into one chronological day instead of showing
    /// the same date multiple times.
    private static func mergedDays(_ days: [FoodMenuDay], yearsByPage: [Int: Int]) -> [FoodMenuDay] {
        var merged: [FoodMenuDay] = []
        var indexByDate: [Date: Int] = [:]
        let calendar = Calendar(identifier: .gregorian)

        for day in days {
            guard let dayDate = date(in: day.heading, defaultYear: yearsByPage[day.pageIndex]) else {
                merged.append(day)
                continue
            }
            let key = calendar.startOfDay(for: dayDate)
            if let index = indexByDate[key] {
                let existing = merged[index]
                var items = existing.items
                var seen = Set(items.map(normalize))
                for item in day.items {
                    let itemKey = normalize(item)
                    guard !seen.contains(itemKey) else { continue }
                    seen.insert(itemKey)
                    items.append(item)
                }
                merged[index] = FoodMenuDay(
                    heading: existing.heading,
                    items: items,
                    pageIndex: existing.pageIndex
                )
            } else {
                indexByDate[key] = merged.count
                merged.append(day)
            }
        }

        return merged.enumerated().sorted { left, right in
            let leftDate = date(
                in: left.element.heading,
                defaultYear: yearsByPage[left.element.pageIndex]
            ) ?? .distantFuture
            let rightDate = date(
                in: right.element.heading,
                defaultYear: yearsByPage[right.element.pageIndex]
            ) ?? .distantFuture
            if leftDate == rightDate {
                return left.offset < right.offset
            }
            return leftDate < rightDate
        }.map(\.element)
    }

    private static func makeDate(day: Int, month: Int, year: Int) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = turkishLocale
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let matchRange = Range(match.range(at: index), in: text) else { return "" }
            return String(text[matchRange])
        }
    }

    // MARK: - Item cleaning

    private static func filteredItems(_ items: [String]) -> [String] {
        items.filter { item in
            let normalized = normalize(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.rangeOfCharacter(from: .letters) != nil else {
                return false
            }
            if sectionLabels.contains(normalized) { return false }
            return !headerFragments.contains { normalized.contains($0) }
        }
    }

    private static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { item in
            let key = normalize(item)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: turkishLocale
        )
        // Turkish case folding turns İ into a dotless ı; unify so labels such as
        // "SABAH KAHVALTISI" match "sabah kahvaltisi".
        .replacingOccurrences(of: "ı", with: "i")
    }

    private static func average(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / CGFloat(values.count)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    // MARK: - Table cell merging (column-oriented)

    private struct TextCell {
        var bounds: CGRect
        var fragments: [(text: String, bounds: CGRect)]

        var text: String {
            fragments
                .sorted {
                    if abs($0.bounds.midY - $1.bounds.midY) > 1 {
                        return $0.bounds.midY > $1.bounds.midY
                    }
                    return $0.bounds.minX < $1.bounds.minX
                }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    private static func mergeTableCells(_ lines: [MenuLine]) -> [String] {
        let fragments = lines.compactMap { line -> (text: String, bounds: CGRect)? in
            let normalized = line.text.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            guard normalized.rangeOfCharacter(from: .letters) != nil else { return nil }
            let filterKey = normalize(normalized)
            guard filterKey != "kalori",
                  !headerFragments.contains(where: { filterKey.contains($0) }) else {
                return nil
            }
            return (normalized, line.bounds)
        }
        .sorted { $0.bounds.midY > $1.bounds.midY }

        var cells: [TextCell] = []
        for fragment in fragments {
            if let cellIndex = cells.indices.last,
               verticalRangesOverlap(cells[cellIndex].bounds, fragment.bounds) {
                cells[cellIndex].bounds = cells[cellIndex].bounds.union(fragment.bounds)
                cells[cellIndex].fragments.append(fragment)
            } else {
                cells.append(TextCell(bounds: fragment.bounds, fragments: [fragment]))
            }
        }
        return cells.map(\.text)
    }

    private static func verticalRangesOverlap(_ first: CGRect, _ second: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return second.maxY >= first.minY - tolerance
            && second.minY <= first.maxY + tolerance
    }
}
