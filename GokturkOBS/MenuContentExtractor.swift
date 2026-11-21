//
//  MenuContentExtractor.swift
//  GokturkOBS
//
//  Created for GokturkOBS AI Cafeteria Intelligence.
//

import Foundation
import PDFKit
import Vision
#if canImport(AppKit)
// PlatformImage is defined in PlatformCompat.swift
#endif

public struct ExtractedMenuContent: Sendable {
    public enum SourceFormat: String, Sendable {
        case htmlTable
        case htmlText
        case pdf
        case imageOCR
        case plainText
    }

    public var format: SourceFormat
    public var rawText: String
    public var structuredRows: [[String]] // For tabular representations
    public var metadata: [String: String]

    public init(
        format: SourceFormat,
        rawText: String,
        structuredRows: [[String]] = [],
        metadata: [String: String] = [:]
    ) {
        self.format = format
        self.rawText = rawText
        self.structuredRows = structuredRows
        self.metadata = metadata
    }
}

public final class MenuContentExtractor: Sendable {
    public static let shared = MenuContentExtractor()

    public init() {}

    // MARK: - Auto-Detection & Extraction Entry Point

    public func extract(from data: Data, mimeType: String? = nil, url: URL? = nil) async throws -> ExtractedMenuContent {
        let type = (mimeType ?? "").lowercased()
        let ext = url?.pathExtension.lowercased() ?? ""

        if type.contains("pdf") || ext == "pdf" {
            return try extractFromPDF(data: data)
        } else if type.contains("image") || ["jpg", "jpeg", "png", "webp", "heic"].contains(ext) {
            return try await extractFromImage(data: data)
        } else {
            // Assume HTML or plain text
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .windowsCP1254)
                ?? ""

            if text.contains("<table") || text.contains("<html") || text.contains("<div") {
                return extractFromHTML(html: text)
            } else {
                return extractFromPlainText(text: text)
            }
        }
    }

    // MARK: - HTML Extraction (Tables & Lists)

    public func extractFromHTML(html: String) -> ExtractedMenuContent {
        // 1. Try to extract table cells
        var structuredRows: [[String]] = []
        let cleanHTML = removeScriptsAndStyles(from: html)

        let tableRowRegex = try? NSRegularExpression(pattern: #"<tr[^>]*>(.*?)<\/tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let cellRegex = try? NSRegularExpression(pattern: #"<(?:td|th)[^>]*>(.*?)<\/(?:td|th)>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

        if let tableRowRegex = tableRowRegex, let cellRegex = cellRegex {
            let rowMatches = tableRowRegex.matches(in: cleanHTML, options: [], range: NSRange(cleanHTML.startIndex..., in: cleanHTML))
            for rowMatch in rowMatches {
                guard let rowRange = Range(rowMatch.range(at: 1), in: cleanHTML) else { continue }
                let rowContent = String(cleanHTML[rowRange])

                let cellMatches = cellRegex.matches(in: rowContent, options: [], range: NSRange(rowContent.startIndex..., in: rowContent))
                var cells: [String] = []
                for cellMatch in cellMatches {
                    guard let cellRange = Range(cellMatch.range(at: 1), in: rowContent) else { continue }
                    let cellRaw = String(rowContent[cellRange])
                    let cellClean = stripTags(cellRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cellClean.isEmpty {
                        cells.append(cellClean)
                    }
                }
                if !cells.isEmpty {
                    structuredRows.append(cells)
                }
            }
        }

        // Build normalized plain text
        var textLines: [String] = []
        if !structuredRows.isEmpty {
            for row in structuredRows {
                textLines.append(row.joined(separator: " | "))
            }
            return ExtractedMenuContent(
                format: .htmlTable,
                rawText: textLines.joined(separator: "\n"),
                structuredRows: structuredRows,
                metadata: ["tableRowCount": "\(structuredRows.count)"]
            )
        } else {
            let stripped = stripTags(cleanHTML)
            let lines = stripped.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return ExtractedMenuContent(
                format: .htmlText,
                rawText: lines.joined(separator: "\n"),
                structuredRows: [],
                metadata: [:]
            )
        }
    }

    // MARK: - PDF Extraction (PDFKit)

    public func extractFromPDF(data: Data) throws -> ExtractedMenuContent {
        guard let document = PDFDocument(data: data) else {
            throw NSError(domain: "MenuContentExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF dosyası açılamadı."])
        }

        var fullText = ""
        var structuredRows: [[String]] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageString = page.string {
                fullText += "\n--- Sayfa \(pageIndex + 1) ---\n" + pageString

                // Split lines into structured rows
                let lines = pageString.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.split(separator: "\t").map(String.init)
                    if parts.count > 1 {
                        structuredRows.append(parts)
                    } else {
                        structuredRows.append([line])
                    }
                }
            }
        }

        return ExtractedMenuContent(
            format: .pdf,
            rawText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            structuredRows: structuredRows,
            metadata: ["pageCount": "\(document.pageCount)"]
        )
    }

    // MARK: - Image OCR Extraction (Vision Framework)

    public func extractFromImage(data: Data) async throws -> ExtractedMenuContent {
        #if canImport(Vision)
        guard let platformImage = PlatformImage(data: data) else {
            throw NSError(domain: "MenuContentExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Görsel verisi yüklenemedi."])
        }
        #if os(macOS)
        guard let cgImage = platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "MenuContentExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Görsel verisi yüklenemedi."])
        }
        #else
        guard let cgImage = platformImage.cgImage else {
            throw NSError(domain: "MenuContentExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Görsel verisi yüklenemedi."])
        }
        #endif
        #else
        throw NSError(domain: "MenuContentExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Platform görsel işlemeyi desteklemiyor."])
        #endif

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: ExtractedMenuContent(format: .imageOCR, rawText: "", structuredRows: []))
                    return
                }

                // Sort text observations by vertical position (top to bottom) then horizontal (left to right)
                let sorted = observations.sorted { obs1, obs2 in
                    let y1 = obs1.boundingBox.origin.y
                    let y2 = obs2.boundingBox.origin.y
                    // Tolerance for same row
                    if abs(y1 - y2) > 0.02 {
                        return y1 > y2 // Vision coordinates are 0,0 at bottom-left
                    }
                    return obs1.boundingBox.origin.x < obs2.boundingBox.origin.x
                }

                var lines: [String] = []
                for obs in sorted {
                    if let topCandidate = obs.topCandidates(1).first {
                        lines.append(topCandidate.string)
                    }
                }

                let text = lines.joined(separator: "\n")
                continuation.resume(returning: ExtractedMenuContent(
                    format: .imageOCR,
                    rawText: text,
                    structuredRows: lines.map { [$0] },
                    metadata: ["recognizedObservations": "\(observations.count)"]
                ))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["tr-TR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Plain Text Extraction

    public func extractFromPlainText(text: String) -> ExtractedMenuContent {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let rows = lines.map { line -> [String] in
            if line.contains("|") {
                return line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.contains("\t") {
                return line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                return [line]
            }
        }

        return ExtractedMenuContent(
            format: .plainText,
            rawText: text,
            structuredRows: rows,
            metadata: [:]
        )
    }

    // MARK: - Helpers

    private func removeScriptsAndStyles(from html: String) -> String {
        var result = html
        let scriptPattern = #"<(script|style)[^>]*>[\s\S]*?<\/\1>"#
        if let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private func stripTags(_ string: String) -> String {
        var str = string.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        str = str.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        str = str.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        str = str.replacingOccurrences(of: "&nbsp;", with: " ")
        str = str.replacingOccurrences(of: "&amp;", with: "&")
        str = str.replacingOccurrences(of: "&quot;", with: "\"")
        str = str.replacingOccurrences(of: "&#39;", with: "'")
        return str
    }
}
