//
//  MenuSourceService.swift
//  GokturkOBS
//
//  Created for GokturkOBS AI Cafeteria Intelligence.
//

import Foundation

public actor MenuSourceService {
    public static let shared = MenuSourceService()

    private let userDefaultsKey = "GokturkOBS_MenuSourceConfig"
    private let urlSession: URLSession

    public init(session: URLSession = .shared) {
        self.urlSession = session
    }

    // MARK: - Configuration Management

    public func loadConfig(for schoolID: String = "default") -> MenuSourceConfig {
        guard let data = UserDefaults.standard.data(forKey: "\(userDefaultsKey)_\(schoolID)"),
              let config = try? JSONDecoder().decode(MenuSourceConfig.self, from: data) else {
            return MenuSourceConfig(schoolID: schoolID, schoolName: "Okulum", cafeteriaURL: nil)
        }
        return config
    }

    public func saveConfig(_ config: MenuSourceConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "\(userDefaultsKey)_\(config.schoolID)")
        }
    }

    public func updateCafeteriaURL(_ url: URL, for schoolID: String = "default", schoolName: String = "Okulum") {
        var config = loadConfig(for: schoolID)
        config.schoolName = schoolName
        config.cafeteriaURL = url
        config.isAutoDiscovered = false
        saveConfig(config)
    }

    // MARK: - Robots.txt Check & Public Access Compliance

    public func checkRobotsAllowed(for url: URL) async -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return true }
        guard let robotsURL = URL(string: "\(scheme)://\(host)/robots.txt") else { return true }

        var request = URLRequest(url: robotsURL)
        request.timeoutInterval = 10
        request.setValue("GokturkOBS/1.0 (macOS; Educational OBS Client)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let robotsText = String(data: data, encoding: .utf8) else {
                return true // If robots.txt doesn't exist or errors, access is typically allowed
            }

            return parseRobotsAllows(robotsText: robotsText, targetPath: url.path)
        } catch {
            return true
        }
    }

    public func parseRobotsAllows(robotsText: String, targetPath: String) -> Bool {
        let lines = robotsText.components(separatedBy: .newlines)
        var appliesToUs = false
        var isDisallowed = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }

            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let directive = parts[0].lowercased()
            let value = parts[1]

            if directive == "user-agent" {
                if value == "*" || value.lowercased().contains("gokturkobs") {
                    appliesToUs = true
                } else {
                    appliesToUs = false
                }
            } else if appliesToUs && directive == "disallow" {
                if value.isEmpty {
                    // Empty disallow means everything allowed
                    isDisallowed = false
                } else if targetPath.hasPrefix(value) {
                    isDisallowed = true
                }
            } else if appliesToUs && directive == "allow" {
                if targetPath.hasPrefix(value) {
                    isDisallowed = false
                }
            }
        }

        return !isDisallowed
    }

    // MARK: - Auto-Discovery of Cafeteria Pages

    public func discoverCafeteriaURL(from schoolBaseURL: URL) async -> URL? {
        let commonPaths = [
            "/yemek-menusu",
            "/yemek-listesi",
            "/yemekhane",
            "/idari/yemekhane",
            "/ogrenci/yemek-menusu",
            "/hizmetlerimiz/yemekhane",
            "/menu",
            "/food-menu",
            "/cafeteria"
        ]

        // First check base page for menu links
        if let pageURL = await findMenuLinkInPage(baseURL: schoolBaseURL) {
            return pageURL
        }

        // Try probe standard common paths
        for path in commonPaths {
            guard let candidateURL = URL(string: path, relativeTo: schoolBaseURL)?.absoluteURL else { continue }
            var request = URLRequest(url: candidateURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            request.setValue("GokturkOBS/1.0", forHTTPHeaderField: "User-Agent")

            if let (_, response) = try? await urlSession.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                return candidateURL
            }
        }

        return nil
    }

    private func findMenuLinkInPage(baseURL: URL) async -> URL? {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 10
        request.setValue("GokturkOBS/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let keywords = ["yemek", "yemekhane", "menü", "menu", "öğle yemeği", "beslenme"]
        let linkPattern = #"href=["']([^"']+)["'][^>]*>(.*?)<\s*/\s*a>"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }

            let href = String(html[hrefRange])
            let text = String(html[textRange]).lowercased()

            for keyword in keywords {
                if text.contains(keyword) || href.lowercased().contains(keyword) {
                    if let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                        return resolved
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Fetch Menu Content

    public func fetchRawContent(from url: URL) async throws -> (data: Data, contentType: String, lastModified: Date?) {
        let isAllowed = await checkRobotsAllowed(for: url)
        guard isAllowed else {
            throw NSError(domain: "MenuSourceService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Okul web sitesinin robots.txt kuralları bu sayfaya erişimi kısıtlıyor."])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("GokturkOBS/1.0 (macOS; Educational OBS Client)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf,image/*;q=0.9", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "MenuSourceService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Geçersiz sunucu yanıtı."])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "MenuSourceService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Sunucu hatası: HTTP \(httpResponse.statusCode)"])
        }

        let mimeType = httpResponse.mimeType ?? "text/html"
        var lastModified: Date? = nil
        if let lastModifiedString = httpResponse.allHeaderFields["Last-Modified"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            lastModified = formatter.date(from: lastModifiedString)
        }

        return (data, mimeType, lastModified)
    }
}
