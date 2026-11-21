import SwiftUI
import PDFKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Printable Schedule View

struct SchedulePrintView: View {
    let schedule: LessonSchedule
    let colorMode: Bool

    private var days: [ScheduleDay] {
        ScheduleLayout.days(for: schedule)
    }

    private var lessonNumbers: [Int] {
        let maximumLessonPeriod = schedule.data.data.map(\.x).max() ?? 0
        let periodCount = max(schedule.data.xInfo.count, maximumLessonPeriod)
        return periodCount > 0 ? Array(1...periodCount) : []
    }

    private var dayColors: [Color] {
        if colorMode {
            return [Color.blue, Color.green, Color.orange, Color.purple, Color.pink, Color.teal, Color.indigo]
        } else {
            return [Color.gray, Color.gray, Color.gray, Color.gray, Color.gray, Color.gray, Color.gray]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DERS PROGRAMI")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(colorMode ? .blue : .black)
                    if let desc = schedule.periodList.first?.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Date(), format: .dateTime.day().month().year())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Divider
            Rectangle()
                .fill(colorMode ? Color.blue.opacity(0.3) : Color.black.opacity(0.2))
                .frame(height: 2)
                .padding(.horizontal, 24)

            // Grid
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                // Header row
                GridRow {
                    Text("Saat")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 70, height: 32)
                        .background(colorMode ? Color.blue : Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        Text(day.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(width: 120, height: 32)
                            .background(colorMode ? dayColors[index % dayColors.count] : Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Lesson rows
                ForEach(lessonNumbers, id: \.self) { lessonNumber in
                    GridRow {
                        Text(timeText(for: lessonNumber))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 70, height: 60)
                            .background(colorMode ? Color.blue.opacity(0.7) : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        ForEach(days) { day in
                            let lesson = lessonFor(x: lessonNumber, y: day.id)
                            if let lesson {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lesson.subject)
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(2)
                                    Text(lesson.teacher)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if !lesson.title.isEmpty {
                                        Text(lesson.title)
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(4)
                                .frame(width: 120, height: 60, alignment: .topLeading)
                                .background(colorMode ? Color.blue.opacity(0.08) : Color.gray.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(colorMode ? Color.blue.opacity(0.2) : Color.black.opacity(0.1), lineWidth: 0.5)
                                )
                            } else {
                                Color.clear
                                    .frame(width: 120, height: 60)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Spacer()

            // Footer
            HStack {
                Text("GokturkOBS ile olusturuldu")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(colorMode ? "Renkli" : "Siyah-Beyaz")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color.white)
        .frame(width: 1100, height: 780)
    }

    private func lessonFor(x: Int, y: Int) -> Lesson? {
        schedule.data.data.first { $0.x == x && $0.y == y }
    }

    private func timeText(for x: Int) -> String {
        let index = x - 1
        guard schedule.data.xInfo.indices.contains(index) else { return "" }
        return schedule.data.xInfo[index].first ?? ""
    }
}

// MARK: - Export Functions

enum ScheduleExportHelper {
    @MainActor
    static func createPDF(schedule: LessonSchedule, colorMode: Bool) -> Data? {
        let printView = SchedulePrintView(schedule: schedule, colorMode: colorMode)
        let renderer = ImageRenderer(content: printView)
        renderer.scale = 2.0

        #if os(macOS)
        guard let image = renderer.nsImage else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        context.endPDFPage()
        context.closePDF()
        return pdfData as Data
        #else
        guard let uiImage = renderer.uiImage else { return nil }
        let format = UIGraphicsPDFRendererFormat()
        let pageRect = CGRect(x: 0, y: 0, width: uiImage.size.width, height: uiImage.size.height)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            uiImage.draw(in: pageRect)
        }
        #endif
    }

    @MainActor
    static func printSchedule(schedule: LessonSchedule, colorMode: Bool) {
        #if os(macOS)
        let printView = SchedulePrintView(schedule: schedule, colorMode: colorMode)
        let renderer = ImageRenderer(content: printView)
        renderer.scale = 2.0
        guard let image = renderer.nsImage else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.orientation = .landscape
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        let printOp = NSPrintOperation(view: NSImageView(image: image))
        printOp.printInfo = printInfo
        printOp.run()
        #else
        guard let pdfData = createPDF(schedule: schedule, colorMode: colorMode) else { return }
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = "Ders Programi"
        printController.printInfo = printInfo
        printController.printingItem = pdfData
        printController.present(animated: true, completionHandler: nil)
        #endif
    }
}