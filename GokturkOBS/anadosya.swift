import SwiftUI
import Foundation
import AppKit
import PDFKit
import Combine

private let defaultPortalURL = "https://tedemkolejiobs.com"
var baseURL: URL {
    URL(string: UserDefaults.standard.string(forKey: "portalBaseURL") ?? defaultPortalURL)
        ?? URL(string: defaultPortalURL)!
}

struct AppCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                cardColor,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(borderOpacity), lineWidth: 1)
            }
    }

    private var cardColor: Color {
        if colorScheme == .light {
            return Color(nsColor: .controlBackgroundColor)
        }
        return .white.opacity(colorSchemeContrast == .increased ? 0.11 : 0.07)
    }

    private var borderOpacity: Double {
        colorSchemeContrast == .increased ? 0.9 : 0.55
    }
}

extension View {
    func appCardSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(AppCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var portalAddress = UserDefaults.standard.string(forKey: "portalBaseURL") ?? defaultPortalURL
    @Published var schedule: LessonSchedule?
    @Published var homework: [Homework] = []
    @Published var examDashboard: ExamDashboard?
    @Published var examReport: ExamSchoolReport?
    @Published var isLoadingExamReport = false
    @Published var examReportError: String?
    @Published var taramalar: [TaramaExam] = []
    @Published var taramaDetail: TaramaDetail?
    @Published var taramaSubjectAnalysis: [TaramaSubjectAnalysis] = []
    @Published var isLoadingTaramalar = false
    @Published var isLoadingTaramaDetail = false
    @Published var isLoadingTaramaAnalysis = false
    @Published var taramalarError: String?
    @Published var taramaDetailError: String?
    @Published var taramaAnalysisError: String?
    @Published var homeworkDetail: HomeworkDetail?
    @Published var isLoadingHomeworkDetail = false
    @Published var homeworkDetailError: String?
    @Published var foodListState: FoodListLoadState = .idle
    @Published var foodListSelectedDayID: FoodMenuDay.ID?
    @Published var isLoadingSchedule = true
    @Published var isLoadingHomework = true
    @Published var isLoadingExams = true
    @Published var scheduleError: String?
    @Published var homeworkError: String?
    @Published var examsError: String?
    @Published var studentProfile: StudentProfile?
    @Published var studentProfileImage: NSImage?
    @Published var isLoadingStudentProfile = false
    @Published var isLoading = true
    @Published var isLoggingIn = false
    @Published var youAreCooked = true
    @Published var authenticated = false
    @Published var error: String?
    @Published var isScreenshotMode = UserDefaults.standard.bool(forKey: "isScreenshotMode") {
        didSet {
            UserDefaults.standard.set(isScreenshotMode, forKey: "isScreenshotMode")
            client.usesScreenshotData = isScreenshotMode
            if isScreenshotMode { applyScreenshotData() }
            else { Task { await refresh() } }
        }
    }
    @Published var rememberMe = UserDefaults.standard.bool(forKey: "rememberMe") {
        didSet {
            UserDefaults.standard.set(rememberMe, forKey: "rememberMe")
            if rememberMe {
                configureAutomaticRecovery()
                return
            }
            client.disableRecovery()
            do {
                try keychain.delete()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    let client = OBSClient()
    private let keychain = KeychainService()
    private var homeworkDetailRequestToken: UUID?
    private var examReportRequestToken: UUID?
    private var taramalarRequestToken: UUID?
    private var taramaDetailRequestToken: UUID?
    private var taramaAnalysisRequestToken: UUID?
    private var loadedTaramaDetailCode: String?
    private var loadedTaramaAnalysisCode: String?
    private var hasAttemptedStudentProfileLoad = false
    private var hasStarted = false
    private var attemptedRememberedLogin = false
    private var foodPhotoPrefetchTask: Task<Void, Never>?
    private var suppressRememberedAccountOnce = false

    init() {
        client.usesScreenshotData = isScreenshotMode
        configureAutomaticRecovery()
        if isScreenshotMode { applyScreenshotData() }
    }

    private func applyScreenshotData() {
        ScreenshotData.populate(self)
    }

    private func configureAutomaticRecovery() {
        guard !UserDefaults.standard.bool(forKey: "didManuallyLogout") else {
            client.disableRecovery()
            return
        }
        client.configureRecovery { [weak self] in
            guard let self, self.rememberMe else { return nil }
            return try self.keychain.load()
        }
    }

    func start() async {
        guard !hasStarted else {
            isLoading = false
            return
        }
        hasStarted = true
        configureAutomaticRecovery()
        isLoading = true
        error = nil
        if client.loadCookies() {
            do {
                schedule = try await client.loadIndex()
                authenticated = true
                if rememberMe, let credentials = try? keychain.load() {
                    do {
                        try await client.refreshMobileProfile(
                            username: credentials.username,
                            password: credentials.password
                        )
                    } catch {
                        print("[App] Mobile profile refresh failed; continuing with PHP session")
                    }
                }
                await refresh()
            } catch OBSClientError.sessionExpired {
                do {
                    try client.clearCookies()
                    await attemptRememberedLogin()
                } catch {
                    self.error = error.localizedDescription
                }
            } catch {
                authenticated = false
                self.error = networkErrorMessage(for: error)
            }
        } else {
            authenticated = false
            await attemptRememberedLogin()
        }
        isLoading = false
    }

    func login() async {
        guard !username.isEmpty, !password.isEmpty else { return }
        guard savePortalAddress() else {
            error = "Geçerli bir AKBİM adresi girin."
            return
        }
        isLoggingIn = true
        error = nil
        let submittedUsername = username
        let submittedPassword = password
        do {
            try await client.login(username: submittedUsername, password: submittedPassword)
            var credentialError: String?
            do {
                if rememberMe {
                    try keychain.save(username: submittedUsername, password: submittedPassword, portalURL: portalAddress)
                } else {
                    try keychain.delete()
                }
            } catch {
                credentialError = error.localizedDescription
            }
            password = ""
            authenticated = true
            UserDefaults.standard.set(false, forKey: "didManuallyLogout")
            configureAutomaticRecovery()
            await refresh()
            if let credentialError {
                error = credentialError
            }
        } catch {
            self.error = networkErrorMessage(for: error)
            print("[App] Login failed")
        }
        isLoggingIn = false
    }

    @discardableResult
    private func savePortalAddress() -> Bool {
        var value = portalAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard var components = URLComponents(string: value), components.host != nil else { return false }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return false }
        let normalizedAddress = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedAddress != UserDefaults.standard.string(forKey: "portalBaseURL") {
            try? client.clearCookies()
        }
        portalAddress = normalizedAddress
        UserDefaults.standard.set(portalAddress, forKey: "portalBaseURL")
        return true
    }

    func switchAccount() {
        logout()
        UserDefaults.standard.set(false, forKey: "didManuallyLogout")
        suppressRememberedAccountOnce = true
        username = ""
        password = ""
    }

    func prepareRememberedUsername() {
        if suppressRememberedAccountOnce {
            suppressRememberedAccountOnce = false
            return
        }
        guard rememberMe else { return }
        do {
            if let credentials = try keychain.load(), username.isEmpty {
                portalAddress = credentials.portalURL
                UserDefaults.standard.set(credentials.portalURL, forKey: "portalBaseURL")
                username = credentials.username
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func attemptRememberedLogin() async {
        guard rememberMe, !attemptedRememberedLogin else { return }
        attemptedRememberedLogin = true
        do {
            guard let credentials = try keychain.load() else { return }
            portalAddress = credentials.portalURL
            UserDefaults.standard.set(credentials.portalURL, forKey: "portalBaseURL")
            username = credentials.username
            try await client.login(username: credentials.username, password: credentials.password)
            schedule = try await client.loadIndex()
            authenticated = true
            await refresh()
        } catch {
            authenticated = false
            if case OBSClientError.loginFailed = error {
                do {
                    try client.clearCookies()
                } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
            self.error = networkErrorMessage(for: error)
        }
    }

    private func networkErrorMessage(for error: Error) -> String {
        if case OBSClientError.recoveryUnavailable = error {
            return "Oturum yenilenemedi. Lütfen tekrar giriş yapın."
        }
        if case OBSClientError.loginFailed = error {
            return "Oturum yenilenemedi. Lütfen tekrar giriş yapın."
        }
        if case OBSClientError.temporaryServer = error {
            return "OBS sunucusuna ulaşılamıyor."
        }
        if let clientError = error as? OBSClientError, case .serverError = clientError {
            return "OBS sunucusuna ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin."
        }
        if error is URLError {
            return "OBS sunucusuna ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin."
        }
        return error.localizedDescription
    }

    func refresh() async {
        if isScreenshotMode {
            applyScreenshotData()
            return
        }
        guard authenticated else { return }
        var failures: [String] = []

        isLoadingSchedule = true
        scheduleError = nil
        do {
            schedule = try await client.loadIndex()
        } catch {
            if isScreenshotMode { applyScreenshotData(); return }
            if requiresExplicitLogin(after: error) {
                isLoadingSchedule = false
                authenticated = false
                self.error = "Oturum yenilenemedi. Lütfen tekrar giriş yapın."
                return
            }
            scheduleError = networkErrorMessage(for: error)
            failures.append("Ders programı alınamadı.")
        }
        isLoadingSchedule = false

        isLoadingHomework = true
        homeworkError = nil
        do {
            homework = try await client.loadHomework()
        } catch {
            if isScreenshotMode { applyScreenshotData(); return }
            homeworkError = networkErrorMessage(for: error)
            failures.append("Ödevler alınamadı.")
        }
        isLoadingHomework = false

        isLoadingExams = true
        examsError = nil
        do {
            examDashboard = try await client.loadStudentExams()
        } catch {
            if isScreenshotMode { applyScreenshotData(); return }
            if requiresExplicitLogin(after: error) {
                isLoadingExams = false
                authenticated = false
                self.error = "Oturum yenilenemedi. Lütfen tekrar giriş yapın."
                return
            }
            examsError = networkErrorMessage(for: error)
            failures.append("Sınavlar alınamadı.")
        }
        isLoadingExams = false

        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func refreshHome(forceReload: Bool = false) async {
        if isScreenshotMode {
            applyScreenshotData()
            return
        }
        guard authenticated else { return }
        if forceReload || schedule == nil || examDashboard == nil || homeworkError != nil {
            await refresh()
        }
        await loadFoodList(forceReload: forceReload)
    }

    func retryWithAutomaticLogin() async {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        error = nil
        defer { isLoggingIn = false }

        do {
            guard let credentials = try keychain.load() else {
                throw OBSClientError.recoveryUnavailable
            }
            try await client.login(
                username: credentials.username,
                password: credentials.password
            )
            authenticated = true
            UserDefaults.standard.set(false, forKey: "didManuallyLogout")
            configureAutomaticRecovery()

            hasAttemptedStudentProfileLoad = false
            studentProfile = nil
            studentProfileImage = nil
            await refreshHome(forceReload: true)
            await loadSidebarProfile()
        } catch {
            self.error = networkErrorMessage(for: error)
        }
    }

    private func requiresExplicitLogin(after error: Error) -> Bool {
        guard let clientError = error as? OBSClientError else { return false }
        switch clientError {
        case .sessionExpired, .recoveryUnavailable, .loginFailed:
            return true
        case .serverError, .temporaryServer, .invalidResponse:
            return false
        }
    }

    func loadHomeworkDetail(id: Int) async {
        let requestToken = UUID()
        homeworkDetailRequestToken = requestToken
        homeworkDetail = nil
        homeworkDetailError = nil
        isLoadingHomeworkDetail = true

        defer {
            if homeworkDetailRequestToken == requestToken {
                isLoadingHomeworkDetail = false
            }
        }

        if isScreenshotMode {
            homeworkDetail = ScreenshotData.homeworkDetail(for: id)
            if homeworkDetail == nil { homeworkDetailError = "Ödev detayı bulunamadı." }
            return
        }

        do {
            let detail = try await client.loadHomeworkDetail(id: id)
            guard homeworkDetailRequestToken == requestToken else { return }
            homeworkDetail = detail
        } catch {
            guard homeworkDetailRequestToken == requestToken else { return }
            guard !isScreenshotMode else { applyScreenshotData(); return }
            homeworkDetailError = error.localizedDescription
        }
    }

    func loadSidebarProfile() async {
        if isScreenshotMode {
            studentProfile = ScreenshotData.profile
            studentProfileImage = nil
            return
        }
        guard authenticated,
              !isLoadingStudentProfile,
              !hasAttemptedStudentProfileLoad else {
            return
        }

        hasAttemptedStudentProfileLoad = true
        isLoadingStudentProfile = true
        defer {
            isLoadingStudentProfile = false
        }

        do {
            let profile = try await client.loadCompleteStudentProfile()
            guard !isScreenshotMode else {
                studentProfile = ScreenshotData.profile
                studentProfileImage = nil
                return
            }
            studentProfile = profile
            do {
                let image = try await client.loadStudentProfileImage(for: profile)
                studentProfileImage = isScreenshotMode ? nil : image
            } catch {
                studentProfileImage = nil
            }
        } catch {
            studentProfile = nil
            studentProfileImage = nil
        }
    }

    func loadFoodList(forceReload: Bool = false) async {
        if !forceReload {
            switch foodListState {
            case .loading, .loaded, .empty:
                return
            case .idle, .error:
                break
            }
        }

        foodListState = .loading
        do {
            switch try await client.loadFoodList() {
            case .pdf(let data):
                guard let document = PDFDocument(data: data) else {
                    throw OBSClientError.invalidResponse("Yemek listesi geçerli bir PDF dosyası değil.")
                }
                let days = FoodMenuParser.parse(document)
                foodListState = .loaded(document, days)
                startFoodPhotoPrefetch(for: days)
            case .empty:
                foodPhotoPrefetchTask?.cancel()
                foodListState = .empty
            }
        } catch {
            foodListState = .error(networkErrorMessage(for: error))
        }
    }

    private func startFoodPhotoPrefetch(for days: [FoodMenuDay]) {
        foodPhotoPrefetchTask?.cancel()
        let schoolDayEnded = schedule.map {
            ScheduleDashboardResolver.hasSchoolDayEnded(in: $0)
        } ?? false
        guard let day = FoodDashboardResolver.currentOrNextMeal(
            in: days,
            beginWithNextDay: schoolDayEnded
        )?.day else {
            foodPhotoPrefetchTask = nil
            return
        }

        let mealNames = day.items
        let menuDayID = day.id
        foodPhotoPrefetchTask = Task(priority: .utility) {
            await prefetchFoodPhotos(for: mealNames, menuDayID: menuDayID)
        }
    }

    func loadExamReport(examId: String, examType: String) async {
        let requestToken = UUID()
        examReportRequestToken = requestToken
        examReport = nil
        examReportError = nil
        isLoadingExamReport = true
        defer {
            if examReportRequestToken == requestToken {
                isLoadingExamReport = false
            }
        }

        if isScreenshotMode {
            examReport = ScreenshotData.examReport
            return
        }

        do {
            let report = try await client.loadSchoolReport(examId: examId, examType: examType)
            guard examReportRequestToken == requestToken else { return }
            examReport = report
        } catch {
            guard examReportRequestToken == requestToken else { return }
            guard !isScreenshotMode else { applyScreenshotData(); return }
            examReportError = error.localizedDescription
        }
    }

    func compareExams(_ exams: [StudentExam]) async -> ExamComparisonResult? {
        guard !exams.isEmpty else { return nil }
        let studentAverage = exams.map(\.point).reduce(0, +) / Double(exams.count)
        var generalRanks: [Double] = []

        for exam in exams {
            if Task.isCancelled { return nil }
            if isScreenshotMode {
                if let rank = ScreenshotData.examReport?.generalRank {
                    generalRanks.append(Double(rank))
                }
                continue
            }
            if let report = try? await client.loadSchoolReport(examId: exam.examId, examType: exam.examType),
               let rank = report.generalRank {
                generalRanks.append(Double(rank))
            }
        }

        let generalRankAverage = generalRanks.isEmpty
            ? nil
            : generalRanks.reduce(0, +) / Double(generalRanks.count)
        return ExamComparisonResult(
            studentAverage: studentAverage,
            generalRankAverage: generalRankAverage,
            rankedExamCount: generalRanks.count
        )
    }

    func loadTaramalar(forceReload: Bool = false) async {
        guard forceReload || (taramalar.isEmpty && !isLoadingTaramalar) else { return }
        let requestToken = UUID()
        taramalarRequestToken = requestToken
        taramalarError = nil
        isLoadingTaramalar = true
        defer {
            if taramalarRequestToken == requestToken { isLoadingTaramalar = false }
        }

        do {
            let loaded = try await client.loadTaramalar()
            guard taramalarRequestToken == requestToken, !Task.isCancelled else { return }
            taramalar = Self.sortTaramalar(loaded)
        } catch {
            guard taramalarRequestToken == requestToken, !Task.isCancelled else { return }
            guard !isScreenshotMode else { applyScreenshotData(); return }
            taramalarError = taramaErrorMessage(error, fallback: "Tarama sonuçları alınamadı.")
        }
    }

    func loadTaramaDetail(examCode: String) async {
        if loadedTaramaDetailCode == examCode, taramaDetail != nil { return }
        let requestToken = UUID()
        taramaDetailRequestToken = requestToken
        loadedTaramaDetailCode = nil
        loadedTaramaAnalysisCode = nil
        taramaDetail = nil
        taramaSubjectAnalysis = []
        taramaDetailError = nil
        taramaAnalysisError = nil
        isLoadingTaramaDetail = true
        defer {
            if taramaDetailRequestToken == requestToken { isLoadingTaramaDetail = false }
        }

        do {
            let detail = try await client.loadTaramaDetail(examCode: examCode)
            guard taramaDetailRequestToken == requestToken, !Task.isCancelled else { return }
            taramaDetail = detail
            loadedTaramaDetailCode = examCode
        } catch {
            guard taramaDetailRequestToken == requestToken, !Task.isCancelled else { return }
            guard !isScreenshotMode else { applyScreenshotData(); return }
            taramaDetailError = taramaErrorMessage(error, fallback: "Tarama detayları yüklenemedi.")
        }
    }

    func loadTaramaSubjectAnalysis(examCode: String, forceReload: Bool = false) async {
        guard forceReload || loadedTaramaAnalysisCode != examCode else { return }
        guard !isLoadingTaramaAnalysis else { return }
        let requestToken = UUID()
        taramaAnalysisRequestToken = requestToken
        taramaAnalysisError = nil
        isLoadingTaramaAnalysis = true
        defer {
            if taramaAnalysisRequestToken == requestToken { isLoadingTaramaAnalysis = false }
        }

        do {
            let analysis = try await client.loadTaramaSubjectAnalysis(examCode: examCode)
            guard taramaAnalysisRequestToken == requestToken, !Task.isCancelled else { return }
            taramaSubjectAnalysis = analysis
            loadedTaramaAnalysisCode = examCode
        } catch {
            guard taramaAnalysisRequestToken == requestToken, !Task.isCancelled else { return }
            guard !isScreenshotMode else { applyScreenshotData(); return }
            taramaAnalysisError = taramaErrorMessage(error, fallback: "Kazanım analizi yüklenemedi.")
        }
    }

    private func taramaErrorMessage(_ error: Error, fallback: String) -> String {
        if let clientError = error as? OBSClientError {
            switch clientError {
            case .sessionExpired, .recoveryUnavailable, .loginFailed:
                return "Mobil OBS oturumu yenilenemedi. Lütfen yeniden giriş yapın."
            case .invalidResponse(let message):
                return message
            case .serverError, .temporaryServer:
                return clientError.localizedDescription
            }
        }
        if error is CancellationError { return fallback }
        return error.localizedDescription
    }

    private static func sortTaramalar(_ exams: [TaramaExam]) -> [TaramaExam] {
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy"]
        let locale = Locale(identifier: "tr_TR")
        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateFormat = format
                if let value = formatter.date(from: text) { return value }
            }
            return nil
        }
        return exams.enumerated().sorted { lhs, rhs in
            switch (date(lhs.element.date), date(rhs.element.date)) {
            case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func openHomeworkFile(_ file: HomeworkFile) async throws -> URL {
        let fileManager = FileManager.default
        guard let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw OBSClientError.invalidResponse("İndirilenler klasörü bulunamadı.")
        }
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let requestedName = URL(fileURLWithPath: file.fileName).lastPathComponent
        let safeName = requestedName.isEmpty || requestedName == "/"
            ? "homework-\(file.fileId)"
            : requestedName
        let existingURL = downloadsDirectory.appendingPathComponent(safeName)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: existingURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            guard NSWorkspace.shared.open(existingURL) else {
                throw OBSClientError.invalidResponse("Dosya açılamadı: \(safeName)")
            }
            return existingURL
        }

        let data = try await client.downloadHomeworkFile(file)
        let originalURL = URL(fileURLWithPath: safeName)
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension
        var suffix = 1

        while true {
            let candidateName: String
            if suffix == 1 {
                candidateName = safeName
            } else if fileExtension.isEmpty {
                candidateName = "\(baseName) (\(suffix))"
            } else {
                candidateName = "\(baseName) (\(suffix)).\(fileExtension)"
            }
            let destination = downloadsDirectory.appendingPathComponent(candidateName)

            do {
                try data.write(to: destination, options: .withoutOverwriting)
                guard NSWorkspace.shared.open(destination) else {
                    throw OBSClientError.invalidResponse("Dosya indirildi ancak varsayılan uygulamayla açılamadı.")
                }
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    func logout() {
        UserDefaults.standard.set(true, forKey: "didManuallyLogout")
        client.disableRecovery()
        authenticated = false
        error = nil
        do {
            try client.clearCookies()
        } catch {
            self.error = error.localizedDescription
        }
        schedule = nil
        homework = []
        examDashboard = nil
        isLoadingSchedule = true
        isLoadingHomework = true
        isLoadingExams = true
        scheduleError = nil
        homeworkError = nil
        examsError = nil
        examReport = nil
        examReportRequestToken = nil
        isLoadingExamReport = false
        examReportError = nil
        taramalar = []
        taramaDetail = nil
        taramaSubjectAnalysis = []
        taramalarRequestToken = nil
        taramaDetailRequestToken = nil
        taramaAnalysisRequestToken = nil
        loadedTaramaDetailCode = nil
        loadedTaramaAnalysisCode = nil
        isLoadingTaramalar = false
        isLoadingTaramaDetail = false
        isLoadingTaramaAnalysis = false
        taramalarError = nil
        taramaDetailError = nil
        taramaAnalysisError = nil
        homeworkDetail = nil
        homeworkDetailRequestToken = nil
        isLoadingHomeworkDetail = false
        homeworkDetailError = nil
        foodPhotoPrefetchTask?.cancel()
        foodPhotoPrefetchTask = nil
        foodListState = .idle
        foodListSelectedDayID = nil
        studentProfile = nil
        studentProfileImage = nil
        isLoadingStudentProfile = false
        hasAttemptedStudentProfileLoad = false
        username = ""
        password = ""
    }
}

struct HomeworkView: View {
    @ObservedObject var model: AppModel
    @State private var selectedHomework: Homework?

    var body: some View {
        NavigationStack {
            Group {
                if model.homework.isEmpty {
                    ContentUnavailableView(
                        model.error == nil ? "Ödev yok" : "Ödevler alınamadı",
                        systemImage: "book",
                        description: Text(model.error ?? "Gösterilecek ödev bulunamadı.")
                    )
                } else {
                    List(model.homework) { item in
                        Button {
                            selectedHomework = item
                        } label: {
                            HomeworkRowView(homework: item)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Ödevler")
            .sheet(item: $selectedHomework) { homework in
                HomeworkDetailSheet(homework: homework, model: model)
            }
        }
    }
}

private struct HomeworkDetailSheet: View {
    let homework: Homework
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Ödev Ayrıntısı")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HomeworkDetailView(homework: homework, model: model)

            Divider()

            HStack {
                Spacer()
                Button("Bitti") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 680)
    }
}

private struct HomeworkRowView: View {
    let homework: Homework

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(homework.title).font(.headline)
                Spacer()
                Text(homework.statusName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            HStack {
                Text(homework.lesson).font(.subheadline)
                Spacer()
                Text(homework.isActive ? "Aktif" : "Pasif")
                    .font(.caption)
                    .foregroundStyle(homework.isActive ? .green : .secondary)
            }
            Text(homework.teaNameSurname)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Label("Başlangıç: \(homework.startDate)", systemImage: "calendar")
                Spacer()
                Label("Bitiş: \(homework.endDate)", systemImage: "calendar.badge.clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            statusColor.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusColor.opacity(0.60), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ödev ayrıntılarını açar")
    }

    private var statusColor: Color {
        let normalizedStatus = homework.statusName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))

        if normalizedStatus.contains("değerlendirilmedi") || normalizedStatus.contains("değelendirilmedi") {
            return hasDeadlinePassed ? .green : .gray
        }
        if normalizedStatus.contains("yapılmadı") {
            return .red
        }
        if normalizedStatus.contains("eksik") {
            return .yellow
        }
        if normalizedStatus.contains("yapıldı")
            || normalizedStatus.contains("tamamlandı")
            || normalizedStatus.contains("teslim edildi") {
            return .green
        }
        return .gray
    }

    private var hasDeadlinePassed: Bool {
        guard let endDate = parsedEndDate else { return false }

        if homework.endDate.contains(":") {
            return endDate < Date()
        }
        return endDate < Calendar.current.startOfDay(for: Date())
    }

    private var parsedEndDate: Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd/MM/yyyy HH:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy",
            "dd/MM/yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: homework.endDate) {
                return date
            }
        }
        return nil
    }
}

private struct HomeworkDetailView: View {
    let homework: Homework
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let detail = model.homeworkDetail, detail.id == homework.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "book.closed.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(detail.title)
                                    .font(.title2.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Label(detail.lesson, systemImage: "graduationcap")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            Text(detail.statusName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusTint(for: detail.statusName))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    statusTint(for: detail.statusName).opacity(0.15),
                                    in: Capsule()
                                )
                        }
                        .padding(16)
                        .appCardSurface(cornerRadius: 14)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            detailItem("Öğretmen", value: detail.teaNameSurname, icon: "person.fill")
                            detailItem("Başlangıç", value: detail.startDate, icon: "calendar")
                            detailItem("Bitiş", value: detail.endDate, icon: "calendar.badge.clock")
                            detailItem("Tür", value: detail.typeName, icon: "tag.fill")
                            if let topic = detail.konuAd, !topic.isEmpty {
                                detailItem("Konu", value: topic, icon: "text.book.closed.fill")
                            }
                            if !detail.score.isEmpty, detail.score != "-" {
                                detailItem("Puan", value: detail.score, icon: "star.fill")
                            }
                            detailItem(
                                "Etkinlik",
                                value: detail.isActive ? "Aktif" : "Pasif",
                                icon: detail.isActive ? "checkmark.circle.fill" : "minus.circle.fill"
                            )
                        }

                        if !detail.description.isEmpty {
                            GroupBox {
                                Text(detail.description)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            } label: {
                                Label("Açıklama", systemImage: "text.alignleft")
                                    .font(.headline)
                            }
                        }

                        if !detail.teacherComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            GroupBox {
                                Text(detail.teacherComment)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            } label: {
                                Label("Öğretmen yorumu", systemImage: "quote.bubble.fill")
                                    .font(.headline)
                            }
                        }

                        filesSection("Ödev ekleri", files: detail.attachFiles)
                        filesSection("Yüklediğim dosyalar", files: detail.studentAttachFiles)
                        filesSection("Cevap dosyaları", files: detail.answerFiles)
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if model.isLoadingHomeworkDetail {
                ProgressView("Ödev yükleniyor...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.homeworkDetailError {
                ContentUnavailableView("Ödev yüklenemedi", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ProgressView("Ödev yükleniyor...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: homework.id) {
            await model.loadHomeworkDetail(id: homework.id)
        }
    }

    private func detailItem(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "—" : value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .appCardSurface(cornerRadius: 10)
    }

    private func filesSection(_ title: String, files: [HomeworkFile]) -> some View {
        GroupBox {
            if files.isEmpty {
                Label("Dosya bulunmuyor", systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(files) { file in
                        HomeworkFileDownloadRow(file: file, model: model)
                    }
                }
            }
        } label: {
            Label(title, systemImage: "paperclip")
                .font(.headline)
        }
    }

    private func statusTint(for status: String) -> Color {
        let normalizedStatus = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))

        if normalizedStatus.contains("yapılmadı") { return .red }
        if normalizedStatus.contains("eksik") { return .yellow }
        if normalizedStatus.contains("yapıldı")
            || normalizedStatus.contains("tamamlandı")
            || normalizedStatus.contains("teslim edildi") {
            return .green
        }
        return .secondary
    }
}

private struct HomeworkFileDownloadRow: View {
    let file: HomeworkFile
    @ObservedObject var model: AppModel
    @State private var isDownloading = false
    @State private var savedFilename: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(file.fileName.isEmpty ? "Dosya \(file.fileId)" : file.fileName, systemImage: "doc")
                    .textSelection(.enabled)
                Spacer()
                if isDownloading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await download() }
                } label: {
                    Label("Aç / İndir", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .disabled(isDownloading)
            }
            if let savedFilename {
                Label("Açıldı: \(savedFilename)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .appCardSurface(cornerRadius: 9)
    }

    @MainActor
    private func download() async {
        isDownloading = true
        savedFilename = nil
        errorMessage = nil
        defer { isDownloading = false }

        do {
            let url = try await model.openHomeworkFile(file)
            savedFilename = url.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum AppSection: Hashable {
    case home
    case schedule
    case practiceExams
    case taramalar
    case homework
    case foodList
    case messages
    case attendance
    case teachers
    case announcements
    case events
    case profile
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selection: AppSection? = .home

    var body: some View {
        GeometryReader { proxy in
            let maximumSidebarWidth = min(320, max(180, proxy.size.width * 0.34))
            let idealSidebarWidth = min(sidebarContentWidth, maximumSidebarWidth)

            NavigationSplitView {
            AppSidebarView(
                selection: $selection,
                profile: model.studentProfile,
                profileImage: model.studentProfileImage,
                isLoadingProfile: model.isLoadingStudentProfile,
                isScreenshotMode: $model.isScreenshotMode
            ) {
                selection = .profile
            } switchAccount: {
                model.switchAccount()
            }
            .navigationTitle("GöktürkOBS")
            .task {
                await model.loadSidebarProfile()
            }
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: idealSidebarWidth,
                max: maximumSidebarWidth
            )
            } detail: {
            Group {
                if selection == .home {
                    HomeDashboardView(model: model, selection: $selection)
                } else {
                    switch selection {
                    case .schedule:
                    if let schedule = model.schedule {
                        ScheduleView(schedule: schedule) {
                            Task { await model.refresh() }
                        }
                    } else {
                        ContentUnavailableView(
                            "Ders programı yok",
                            systemImage: "calendar",
                            description: Text(model.error ?? "Gösterilecek ders programı bulunamadı.")
                        )
                    }
                    case .practiceExams:
                        ExamsView(model: model)
                    case .taramalar:
                        TaramalarView(model: model)
                    case .homework:
                        HomeworkView(model: model)
                    case .foodList:
                        FoodListView(model: model)
                    case .messages:
                        MessagesView(client: model.client)
                    case .attendance:
                        AttendanceView(client: model.client)
                    case .teachers:
                        TeachersView(client: model.client)
                    case .announcements:
                        AnnouncementsView(client: model.client)
                    case .events:
                        EventsView(client: model.client)
                    case .profile:
                        ProfileDetailView(
                            profile: model.studentProfile,
                            image: model.studentProfileImage
                        )
                    case .home:
                        EmptyView()
                    case nil:
                        ContentUnavailableView("Bir bölüm seçin", systemImage: "sidebar.left")
                    }
                }
            }.toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        Task { await model.retryWithAutomaticLogin() }
                    } label: {
                        Label("Yeniden Dene", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoggingIn)
                    Button { model.logout() } label: {
                        Label("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var sidebarContentWidth: CGFloat {
        let nameLength = model.studentProfile?.name.count ?? 0
        return min(300, 215 + CGFloat(max(nameLength - 14, 0)) * 5.5)
    }

}

@MainActor
enum ScreenshotData {
    static func populate(_ model: AppModel) {
        model.error = nil
        model.scheduleError = nil
        model.homeworkError = nil
        model.examsError = nil
        model.homeworkDetailError = nil
        model.examReportError = nil
        model.taramalarError = nil
        model.taramaDetailError = nil
        model.taramaAnalysisError = nil
        model.isLoadingSchedule = false
        model.isLoadingHomework = false
        model.isLoadingExams = false
        model.isLoadingHomeworkDetail = false
        model.isLoadingExamReport = false
        model.isLoadingTaramalar = false
        model.isLoadingTaramaDetail = false
        model.isLoadingTaramaAnalysis = false
        model.isLoadingStudentProfile = false
        model.studentProfile = profile
        model.studentProfileImage = nil
        model.schedule = decode(LessonSchedule.self, json: scheduleJSON)
        model.examDashboard = decode(ExamDashboard.self, json: examsJSON)
        model.homework = decode([Homework].self, json: homeworkJSON) ?? []
        model.taramalar = decode([TaramaExam].self, json: taramalarJSON) ?? []
        model.foodListState = .loaded(
            PDFDocument(),
            [
                FoodMenuDay(heading: "26 Ekim 2026 Pazartesi", items: ["MERCİMEK ÇORBASI", "FIRINDA TAVUK", "BULGUR PİLAVI", "MEVSİM SALATA", "AYRAN"], pageIndex: 0),
                FoodMenuDay(heading: "27 Ekim 2026 Salı", items: ["EZOGELİN ÇORBASI", "KÖFTE", "PİRİNÇ PİLAVI", "CACIK", "MEYVE"], pageIndex: 0),
                FoodMenuDay(heading: "28 Ekim 2026 Çarşamba", items: ["YAYLA ÇORBASI", "TAVUK SOTE", "MAKARNA", "YOĞURT", "TATLI"], pageIndex: 0)
            ]
        )
    }

    static let profile = StudentProfile(stuNo: "1234", classId: "7-A", name: "Göktürk", photoURL: nil)
    static var examReport: ExamSchoolReport? {
        decode(ExamSchoolReport.self, json: examReportJSON)
    }

    static func homeworkDetail(for id: Int) -> HomeworkDetail? {
        guard let item = (decode([Homework].self, json: homeworkJSON) ?? []).first(where: { $0.id == id }) else {
            return nil
        }
        let descriptions: [Int: String] = [
            901: "Ders kitabındaki problem çözme bölümünden 42–48. soruları işlem basamaklarını göstererek çözünüz.",
            902: "Verilen iki metni okuyup paragraf sorularını cevaplayınız. Bilmediğiniz sözcükleri defterinize yazınız.",
            903: "Kuvvet ve hareket ünitesiyle ilgili araştırmanızı görsellerle destekleyerek kısa bir rapor hâline getiriniz.",
            904: "Kültür ve miras ünitesinden seçtiğiniz bir tarihî eseri tanıtan beş dakikalık sunum hazırlayınız.",
            905: "Unit 3 kelimelerini çalışma kağıdına yazıp her kelimeyle birer örnek cümle kurunuz.",
            906: "Yüzdeler konusu değerlendirme testini çözünüz ve yanlış yaptığınız soruları tekrar inceleyiniz.",
            907: "Okuduğunuz kitabın karakter, olay ve ana fikir bölümlerini inceleme formuna doldurunuz.",
            908: "Kurulan elektrik devresinin şemasını çizip deney sonuçlarını rapor formatında teslim ediniz."
        ]
        let topics: [Int: String] = [901: "Problemler", 902: "Paragrafta Anlam", 903: "Kuvvet ve Hareket", 904: "Kültür ve Miras", 905: "Vocabulary", 906: "Yüzdeler", 907: "Metin İnceleme", 908: "Elektrik Devreleri"]
        let object: [String: Any] = [
            "id": item.id,
            "title": item.title,
            "description": descriptions[item.id] ?? "Ödev açıklamasını okuyup belirtilen çalışmayı tamamlayınız.",
            "startDate": item.startDate,
            "analysed": item.status == 2 ? 1 : 0,
            "endDate": item.endDate,
            "konuAd": topics[item.id] ?? item.lesson,
            "willBeScored": item.willBeScored,
            "teaNameSurname": item.teaNameSurname,
            "typeName": item.typeName,
            "lesson": item.lesson,
            "score": item.score,
            "teacherComment": item.status == 2 ? "Çalışma düzenli ve eksiksiz hazırlanmış." : "",
            "status": item.status,
            "statusName": item.statusName,
            "iconClass": item.iconClass,
            "isActive": item.isActive,
            "stuCanAttachFile": item.stuCanAttachFile,
            "seen": true,
            "studentAttachFiles": [],
            "attachFiles": [],
            "answerFiles": []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(HomeworkDetail.self, from: data)
    }

    static let teachers = records([
        ["teaNameSurname": "Ayşe Yılmaz", "lesson": "Matematik"],
        ["teaNameSurname": "Mehmet Demir", "lesson": "Türkçe"],
        ["teaNameSurname": "Elif Kaya", "lesson": "Fen Bilimleri"]
    ])
    static let announcements = records([
        ["title": "Veli Bilgilendirme Toplantısı", "date": "30.10.2026", "content": "Toplantımız konferans salonunda gerçekleştirilecektir.", "publisherPersonName": "Okul Yönetimi"],
        ["title": "Kulüp Çalışmaları Başlıyor", "date": "27.10.2026", "content": "Kulüp başvuruları cuma günü sona erecektir.", "publisherPersonName": "Öğrenci İşleri"],
        ["title": "Kütüphane Çalışma Saatleri", "date": "25.10.2026", "content": "Kütüphanemiz hafta içi 17.30'a kadar açıktır.", "publisherPersonName": "Kütüphane Birimi"]
    ])
    static let events = records([
        ["title": "Bilim Şenliği", "date": "05.11.2026", "time": "10.00", "location": "Okul Bahçesi", "description": "Öğrenci projeleri sergisi"],
        ["title": "Kitap Söyleşisi", "date": "12.11.2026", "time": "13.30", "location": "Konferans Salonu", "description": "Yazar buluşması"]
    ])
    static let inbox = records([
        ["mailId": "m-1", "mailTitle": "Haftalık Ders Programı", "sender": "Okul Yönetimi", "mailPreview": "Gelecek haftanın çalışma programı yayınlanmıştır.", "mailContent": "Gelecek haftanın çalışma programı yayınlanmıştır. Ders saatlerinde herhangi bir değişiklik bulunmamaktadır.", "sendDate": "24.10.2026 15:40"],
        ["mailId": "m-2", "mailTitle": "Matematik Etüt Çalışması", "sender": "Ayşe Yılmaz", "mailPreview": "Salı günü yapılacak etüt için çalışma kağıdını getiriniz.", "mailContent": "Salı günü yapılacak matematik etüdü için dağıtılan çalışma kağıdını yanınızda getiriniz.", "sendDate": "23.10.2026 12:15"],
        ["mailId": "m-3", "mailTitle": "Bilim Şenliği Bilgilendirmesi", "sender": "Öğrenci İşleri", "mailPreview": "Proje teslimleri 2 Kasım Pazartesi günü tamamlanacaktır.", "mailContent": "Bilim şenliği proje teslimleri 2 Kasım Pazartesi günü öğrenci işlerine yapılacaktır.", "sendDate": "21.10.2026 09:05"]
    ])
    static let sent = records([
        ["mailId": "s-1", "mailTitle": "Ödev hakkında", "recipient": "Mehmet Demir", "mailPreview": "Ödev dosyasını sisteme yükledim.", "mailContent": "Merhaba öğretmenim, ödev dosyasını sisteme yükledim.", "sendDate": "20.10.2026 18:22"]
    ])
    static let attendance = AttendanceSnapshot(periodDescription: "2026–2027 · 1. Dönem", records: records([
        ["lesson": "Matematik", "lessonNo": "2", "absenceDate": "14.10.2026", "teaNameSurname": "Ayşe Yılmaz", "description": "İzinli"],
        ["lesson": "Türkçe", "lessonNo": "1", "absenceDate": "06.10.2026", "teaNameSurname": "Mehmet Demir", "description": "Geç kaldı"]
    ]))

    private static func records(_ values: [[String: String]]) -> [PortalRecord] {
        values.enumerated().map { index, record in
            PortalRecord(values: record.mapValues(JSONValue.string), fallbackID: "screenshot-\(index)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static let homeworkJSON = #"""
    [
      {"id":901,"title":"Problem Çalışması","teaNameSurname":"Ayşe Yılmaz","typeName":"Çalışma","startDate":"22.10.2026","endDate":"28.10.2026","lesson":"Matematik","score":"-","statusName":"Eksik","status":1,"willBeScored":false,"isActive":true},
      {"id":902,"title":"Paragraf Soruları","teaNameSurname":"Mehmet Demir","typeName":"Test","startDate":"23.10.2026","endDate":"30.10.2026","lesson":"Türkçe","score":"-","statusName":"Yapılmadı","status":0,"willBeScored":false,"isActive":true},
      {"id":903,"title":"Kuvvet ve Hareket","teaNameSurname":"Elif Kaya","typeName":"Araştırma","startDate":"18.10.2026","endDate":"24.10.2026","lesson":"Fen Bilimleri","score":"100","statusName":"Yapıldı","status":2,"willBeScored":true,"isActive":false},
      {"id":904,"title":"Kültür ve Miras Sunumu","teaNameSurname":"Can Yıldız","typeName":"Sunum","startDate":"24.10.2026","endDate":"31.10.2026","lesson":"Sosyal Bilgiler","score":"-","statusName":"Eksik","status":1,"willBeScored":true,"isActive":true},
      {"id":905,"title":"Unit 3 Vocabulary","teaNameSurname":"Zeynep Aydın","typeName":"Çalışma","startDate":"25.10.2026","endDate":"02.11.2026","lesson":"İngilizce","score":"-","statusName":"Yapılmadı","status":0,"willBeScored":false,"isActive":true},
      {"id":906,"title":"Yüzdeler Testi","teaNameSurname":"Ayşe Yılmaz","typeName":"Test","startDate":"20.10.2026","endDate":"27.10.2026","lesson":"Matematik","score":"95","statusName":"Yapıldı","status":2,"willBeScored":true,"isActive":true},
      {"id":907,"title":"Kitap İnceleme Formu","teaNameSurname":"Mehmet Demir","typeName":"Proje","startDate":"19.10.2026","endDate":"29.10.2026","lesson":"Türkçe","score":"-","statusName":"Değerlendirilmedi","status":3,"willBeScored":true,"isActive":true},
      {"id":908,"title":"Elektrik Devreleri Raporu","teaNameSurname":"Elif Kaya","typeName":"Deney","startDate":"26.10.2026","endDate":"05.11.2026","lesson":"Fen Bilimleri","score":"-","statusName":"Yapılmadı","status":0,"willBeScored":true,"isActive":true}
    ]
    """#

    private static let taramalarJSON = #"""
    [
      {"examType":"TARAMA","sinavKod":"T-103","sinavAd":"Matematik Tarama","sinavTarih":"24.10.2026","point":92},
      {"examType":"TARAMA","sinavKod":"T-102","sinavAd":"Fen Bilimleri Tarama","sinavTarih":"21.10.2026","point":88},
      {"examType":"TARAMA","sinavKod":"T-101","sinavAd":"Türkçe Tarama","sinavTarih":"18.10.2026","point":90},
      {"examType":"TARAMA","sinavKod":"T-100","sinavAd":"Sosyal Bilgiler Tarama","sinavTarih":"15.10.2026","point":84},
      {"examType":"TARAMA","sinavKod":"T-099","sinavAd":"İngilizce Tarama","sinavTarih":"12.10.2026","point":94},
      {"examType":"TARAMA","sinavKod":"T-098","sinavAd":"Matematik Kazanım Tarama","sinavTarih":"09.10.2026","point":86},
      {"examType":"TARAMA","sinavKod":"T-097","sinavAd":"Fen Bilimleri Kazanım Tarama","sinavTarih":"06.10.2026","point":91},
      {"examType":"TARAMA","sinavKod":"T-096","sinavAd":"Türkçe Kazanım Tarama","sinavTarih":"03.10.2026","point":89}
    ]
    """#

    private static let examsJSON = #"""
    {
      "success":true,
      "exams":[
        {"examId":"D-104","examName":"Genel Deneme Sınavı","examDate":"18.10.2026","point":462.5,"net":78.25,"dogru":86,"yanlis":11,"bos":3,"questionCount":100,"successRate":86,"examType":"SBS"},
        {"examId":"D-103","examName":"Sayısal Değerlendirme","examDate":"11.10.2026","point":448.75,"net":74.5,"dogru":82,"yanlis":15,"bos":3,"questionCount":100,"successRate":82,"examType":"SBS"},
        {"examId":"D-102","examName":"Haftalık Deneme","examDate":"04.10.2026","point":455,"net":76,"dogru":84,"yanlis":14,"bos":2,"questionCount":100,"successRate":84,"examType":"SBS"},
        {"examId":"D-101","examName":"Türkiye Geneli Deneme","examDate":"27.09.2026","point":437.25,"net":71.75,"dogru":80,"yanlis":18,"bos":2,"questionCount":100,"successRate":80,"examType":"SBS"},
        {"examId":"D-100","examName":"Kazanım Değerlendirme","examDate":"20.09.2026","point":471.5,"net":81.5,"dogru":89,"yanlis":10,"bos":1,"questionCount":100,"successRate":89,"examType":"SBS"},
        {"examId":"D-099","examName":"Sözel Bölüm Denemesi","examDate":"13.09.2026","point":443,"net":73.25,"dogru":81,"yanlis":16,"bos":3,"questionCount":100,"successRate":81,"examType":"SBS"},
        {"examId":"D-098","examName":"Sayısal Bölüm Denemesi","examDate":"06.09.2026","point":429.75,"net":69.5,"dogru":78,"yanlis":20,"bos":2,"questionCount":100,"successRate":78,"examType":"SBS"},
        {"examId":"D-097","examName":"Dönem Başlangıç Denemesi","examDate":"30.08.2026","point":418.5,"net":66.75,"dogru":75,"yanlis":22,"bos":3,"questionCount":100,"successRate":75,"examType":"SBS"}
      ],
      "kpi":{"examCount":8,"avgPoint":445.78,"lastPoint":462.5,"lastPointDelta":13.75,"maxPoint":471.5,"maxPointExamName":"Kazanım Değerlendirme","avgSuccess":82},
      "lessonSuccess":[{"lesson":"Matematik","successRate":91},{"lesson":"Türkçe","successRate":84},{"lesson":"Fen Bilimleri","successRate":88},{"lesson":"Sosyal Bilgiler","successRate":79},{"lesson":"İngilizce","successRate":86},{"lesson":"Din Kültürü","successRate":83}],
      "trend":{"point":[418.5,429.75,443,471.5,437.25,455,448.75,462.5]},"lessons":[]
    }
    """#

    private static let examReportJSON = #"""
    {
      "success": true,
      "data": {
        "Puan": 462.5, "KurumOrt": 421.75, "N7": 78.25, "D7": 86, "Y7": 11, "B7": 3, "SR7": 100, "SD": 2, "GD": 148,
        "SR1": 20, "D1": 18, "Y1": 2, "B1": 0, "N1": 17.33, "SC1": "ABCDABCDABCDABCDABCD", "OC1": "ABCDABCDABCDABCDABcd",
        "SR2": 20, "D2": 17, "Y2": 2, "B2": 1, "N2": 16.33, "SC2": "BCDABCDABCDABCDABCDA", "OC2": "BCDABCDABCDABCDABbc ",
        "SR3": 10, "D3": 9, "Y3": 1, "B3": 0, "N3": 8.67, "SC3": "CDABCDABCD", "OC3": "CDABCDABCd",
        "SR4": 20, "D4": 18, "Y4": 1, "B4": 1, "N4": 17.67, "SC4": "DABCDABCDABCDABCDABC", "OC4": "DABCDABCDABCDABCDAc ",
        "SR5": 10, "D5": 9, "Y5": 1, "B5": 0, "N5": 8.67, "SC5": "ABCDABCDAB", "OC5": "ABCDABCDAa",
        "SR6": 20, "D6": 15, "Y6": 4, "B6": 1, "N6": 13.67, "SC6": "BCDABCDABCDABCDABCDA", "OC6": "BCDABCDABCDABCDdabc "
      },
      "subanal": [
        {"lesson":"Matematik","topic":"Oran ve Orantı","questionCount":8,"correct":7,"wrong":1,"successRate":87.5},
        {"lesson":"Matematik","topic":"Yüzdeler","questionCount":6,"correct":5,"wrong":1,"successRate":83.3},
        {"lesson":"Türkçe","topic":"Paragrafta Anlam","questionCount":10,"correct":9,"wrong":1,"successRate":90},
        {"lesson":"Türkçe","topic":"Fiiller","questionCount":6,"correct":5,"wrong":1,"successRate":83.3},
        {"lesson":"Fen Bilimleri","topic":"Kuvvet ve Enerji","questionCount":10,"correct":9,"wrong":1,"successRate":90},
        {"lesson":"Fen Bilimleri","topic":"Hücre ve Bölünmeler","questionCount":8,"correct":7,"wrong":0,"successRate":87.5},
        {"lesson":"Sosyal Bilgiler","topic":"Kültür ve Miras","questionCount":10,"correct":9,"wrong":1,"successRate":90},
        {"lesson":"İngilizce","topic":"Biographies","questionCount":10,"correct":8,"wrong":2,"successRate":80}
      ],
      "graphs": {}
    }
    """#

    private static let scheduleJSON = #"""
    {
      "periodList":[{"id":1,"description":"2026–2027 Eğitim Öğretim Yılı"}],"periodId":1,
      "data":{"xInfo":[["1. Ders","09.00–09.40"],["2. Ders","09.50–10.30"],["3. Ders","10.40–11.20"],["4. Ders","11.30–12.10"],["5. Ders","13.00–13.40"],["6. Ders","13.50–14.30"],["7. Ders","14.40–15.20"],["8. Ders","15.30–16.10"]],
      "yInfo":[["Pazartesi"],["Salı"],["Çarşamba"],["Perşembe"],["Cuma"]],
      "data":[
        {"x":1,"y":1,"id":"1-1","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Problemler"}},
        {"x":2,"y":1,"id":"2-1","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Paragraf"}},
        {"x":3,"y":1,"id":"3-1","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Kuvvet ve Hareket"}},
        {"x":4,"y":1,"id":"4-1","text":["Can Yıldız","Sosyal Bilgiler"],"data":{"headerTitle":"Kültür ve Miras"}},
        {"x":5,"y":1,"id":"5-1","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Daily Routines"}},
        {"x":6,"y":1,"id":"6-1","text":["Selin Aksoy","Görsel Sanatlar"],"data":{"headerTitle":"Renk Çalışmaları"}},
        {"x":7,"y":1,"id":"7-1","text":["Burak Çetin","Beden Eğitimi"],"data":{"headerTitle":"Takım Sporları"}},
        {"x":8,"y":1,"id":"8-1","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Oran Orantı"}},
        {"x":1,"y":2,"id":"1-2","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Unit 3"}},
        {"x":2,"y":2,"id":"2-2","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Oran Orantı"}},
        {"x":3,"y":2,"id":"3-2","text":["Can Yıldız","Sosyal Bilgiler"],"data":{"headerTitle":"Kültür ve Miras"}},
        {"x":4,"y":2,"id":"4-2","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Enerji"}},
        {"x":5,"y":2,"id":"5-2","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Fiiller"}},
        {"x":6,"y":2,"id":"6-2","text":["Murat Koç","Din Kültürü"],"data":{"headerTitle":"Ahlaki Davranışlar"}},
        {"x":7,"y":2,"id":"7-2","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Biographies"}},
        {"x":8,"y":2,"id":"8-2","text":["Burak Çetin","Beden Eğitimi"],"data":{"headerTitle":"Atletizm"}},
        {"x":1,"y":3,"id":"1-3","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Enerji"}},
        {"x":2,"y":3,"id":"2-3","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Fiiller"}},
        {"x":3,"y":3,"id":"3-3","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Yüzdeler"}},
        {"x":4,"y":3,"id":"4-3","text":["Can Yıldız","Sosyal Bilgiler"],"data":{"headerTitle":"İnsanlar ve Yerler"}},
        {"x":5,"y":3,"id":"5-3","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Environment"}},
        {"x":6,"y":3,"id":"6-3","text":["Selin Aksoy","Müzik"],"data":{"headerTitle":"Ritim Çalışması"}},
        {"x":7,"y":3,"id":"7-3","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Madde ve Isı"}},
        {"x":8,"y":3,"id":"8-3","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Metin Türleri"}},
        {"x":1,"y":4,"id":"1-4","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Yüzdeler"}},
        {"x":2,"y":4,"id":"2-4","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Daily Routines"}},
        {"x":3,"y":4,"id":"3-4","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Hücre ve Bölünmeler"}},
        {"x":4,"y":4,"id":"4-4","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Sözcükte Anlam"}},
        {"x":5,"y":4,"id":"5-4","text":["Can Yıldız","Sosyal Bilgiler"],"data":{"headerTitle":"Bilim ve Teknoloji"}},
        {"x":6,"y":4,"id":"6-4","text":["Murat Koç","Din Kültürü"],"data":{"headerTitle":"İbadetler"}},
        {"x":7,"y":4,"id":"7-4","text":["Burak Çetin","Beden Eğitimi"],"data":{"headerTitle":"Voleybol"}},
        {"x":8,"y":4,"id":"8-4","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Doğrular ve Açılar"}},
        {"x":1,"y":5,"id":"1-5","text":["Can Yıldız","Sosyal Bilgiler"],"data":{"headerTitle":"İnsanlar ve Yerler"}},
        {"x":2,"y":5,"id":"2-5","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Madde ve Isı"}},
        {"x":3,"y":5,"id":"3-5","text":["Mehmet Demir","Türkçe"],"data":{"headerTitle":"Yazım Kuralları"}},
        {"x":4,"y":5,"id":"4-5","text":["Zeynep Aydın","İngilizce"],"data":{"headerTitle":"Dreams"}},
        {"x":5,"y":5,"id":"5-5","text":["Ayşe Yılmaz","Matematik"],"data":{"headerTitle":"Cebirsel İfadeler"}},
        {"x":6,"y":5,"id":"6-5","text":["Selin Aksoy","Görsel Sanatlar"],"data":{"headerTitle":"Perspektif"}},
        {"x":7,"y":5,"id":"7-5","text":["Murat Koç","Din Kültürü"],"data":{"headerTitle":"Peygamberler"}},
        {"x":8,"y":5,"id":"8-5","text":["Elif Kaya","Fen Bilimleri"],"data":{"headerTitle":"Elektrik Devreleri"}}
      ]}
    }
    """#
}

private struct ScreenshotProtectedSectionView: View {
    let section: AppSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: sectionImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .appCardSurface(cornerRadius: 9)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sectionTitle)
                            .font(.title2.weight(.semibold))
                    }
                }

                LazyVStack(spacing: 10) {
                    ForEach(records) { record in
                        ScreenshotRecordCard(record: record)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(sectionTitle)
    }

    private var records: [ScreenshotRecord] {
        switch section {
        case .schedule:
            [
                .init(icon: "1.circle.fill", title: "Matematik", subtitle: "09.00–09.40", detail: "Derslik 7-A"),
                .init(icon: "2.circle.fill", title: "Türkçe", subtitle: "09.50–10.30", detail: "Derslik 7-A"),
                .init(icon: "3.circle.fill", title: "Fen Bilimleri", subtitle: "10.40–11.20", detail: "Fen Laboratuvarı")
            ]
        case .practiceExams:
            [
                .init(icon: "doc.text.fill", title: "Genel Deneme Sınavı", subtitle: "18 Ekim 2026", detail: "462,50 puan · 78,25 net"),
                .init(icon: "doc.text.fill", title: "Sayısal Değerlendirme", subtitle: "11 Ekim 2026", detail: "448,75 puan · 74,50 net"),
                .init(icon: "doc.text.fill", title: "Haftalık Deneme", subtitle: "4 Ekim 2026", detail: "455,00 puan · 76,00 net")
            ]
        case .taramalar:
            [
                .init(icon: "checklist", title: "Matematik Tarama", subtitle: "20 soru", detail: "18 doğru · 1 yanlış · 1 boş"),
                .init(icon: "checklist", title: "Fen Bilimleri Tarama", subtitle: "15 soru", detail: "13 doğru · 2 yanlış"),
                .init(icon: "checklist", title: "Türkçe Tarama", subtitle: "20 soru", detail: "17 doğru · 3 yanlış")
            ]
        case .homework:
            [
                .init(icon: "book.closed.fill", title: "Problem Çalışması", subtitle: "Matematik", detail: "Teslim edildi"),
                .init(icon: "book.closed.fill", title: "Paragraf Soruları", subtitle: "Türkçe", detail: "28 Ekim'e kadar"),
                .init(icon: "book.closed.fill", title: "Kuvvet ve Hareket", subtitle: "Fen Bilimleri", detail: "Değerlendirilmedi")
            ]
        case .foodList:
            [
                .init(icon: "fork.knife", title: "Mercimek Çorbası", subtitle: "Bugünün menüsü", detail: "Başlangıç"),
                .init(icon: "fork.knife", title: "Fırında Tavuk", subtitle: "Bugünün menüsü", detail: "Ana yemek"),
                .init(icon: "fork.knife", title: "Bulgur Pilavı", subtitle: "Bugünün menüsü", detail: "Yardımcı yemek")
            ]
        case .messages:
            [
                .init(icon: "envelope.fill", title: "Okul Yönetimi", subtitle: "Haftalık bilgilendirme", detail: "Bugün, 15.30"),
                .init(icon: "envelope.fill", title: "Sınıf Rehber Öğretmeni", subtitle: "Ders programı hakkında", detail: "Dün, 17.45")
            ]
        case .attendance:
            [
                .init(icon: "checkmark.circle.fill", title: "Ekim ayı özeti", subtitle: "Devamsızlık bulunmuyor", detail: "0 tam gün · 0 yarım gün"),
                .init(icon: "calendar", title: "Dönem özeti", subtitle: "Düzenli katılım", detail: "Son güncelleme: 24 Ekim")
            ]
        case .teachers:
            [
                .init(icon: "person.crop.circle.fill", title: "Ayşe Yılmaz", subtitle: "Matematik Öğretmeni", detail: "7-A sınıfı"),
                .init(icon: "person.crop.circle.fill", title: "Mehmet Demir", subtitle: "Türkçe Öğretmeni", detail: "7-A sınıfı"),
                .init(icon: "person.crop.circle.fill", title: "Elif Kaya", subtitle: "Fen Bilimleri Öğretmeni", detail: "7-A sınıfı")
            ]
        case .announcements:
            [
                .init(icon: "megaphone.fill", title: "Veli Bilgilendirme Toplantısı", subtitle: "Okul Yönetimi", detail: "30 Ekim 2026 · Konferans Salonu"),
                .init(icon: "megaphone.fill", title: "Kulüp Çalışmaları Başlıyor", subtitle: "Öğrenci İşleri", detail: "Başvurular cuma günü sona eriyor"),
                .init(icon: "megaphone.fill", title: "Kütüphane Çalışma Saatleri", subtitle: "Kütüphane Birimi", detail: "Hafta içi 08.30–17.30")
            ]
        case .events:
            [
                .init(icon: "calendar.badge.clock", title: "Bilim Şenliği", subtitle: "5 Kasım 2026", detail: "Okul Bahçesi"),
                .init(icon: "calendar.badge.clock", title: "Kitap Söyleşisi", subtitle: "12 Kasım 2026", detail: "Konferans Salonu")
            ]
        case .profile:
            [
                .init(icon: "person.crop.circle.fill", title: "Göktürk", subtitle: "7-A sınıfı", detail: "Öğrenci no: 1234"),
                .init(icon: "building.2.fill", title: "Özel Tedem Ortaokulu", subtitle: "2026–2027 Eğitim Yılı", detail: "Ortaokul öğrencisi")
            ]
        case .home, nil:
            []
        }
    }

    private var sectionTitle: String {
        switch section {
        case .schedule: "Ders Programı"
        case .practiceExams: "Deneme Sınavları"
        case .taramalar: "Taramalar"
        case .homework: "Ödevler"
        case .foodList: "Yemek Listesi"
        case .messages: "Mesajlar"
        case .attendance: "Devamsızlık"
        case .teachers: "Öğretmenlerim"
        case .announcements: "Duyurular"
        case .events: "Etkinlikler"
        case .profile: "Profil"
        case .home: "Ana Sayfa"
        case nil: "Bölüm"
        }
    }

    private var sectionImage: String {
        switch section {
        case .schedule: "calendar"
        case .practiceExams: "doc.text"
        case .taramalar: "checklist"
        case .homework: "book"
        case .foodList: "fork.knife"
        case .messages: "envelope"
        case .attendance: "calendar.badge.exclamationmark"
        case .teachers: "person.2"
        case .announcements: "megaphone"
        case .events: "calendar.day.timeline.left"
        case .profile: "person.crop.circle"
        case .home: "house"
        case nil: "eye.slash"
        }
    }
}

private struct ScreenshotRecord: Identifiable {
    let icon: String
    let title: String
    let subtitle: String
    let detail: String

    var id: String { "\(title)|\(subtitle)" }
}

private struct ScreenshotRecordCard: View {
    let record: ScreenshotRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.headline)
                Text(record.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(record.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Group {
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("i am groot").foregroundStyle(.secondary)
                }
            } else if model.authenticated {
                MainView(model: model)
            } else {
                LoginView(model: model)
            }
        }
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }
}

@main
struct GokturkOBSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model).task {
                NSApplication.shared.activate(ignoringOtherApps: true)
                await model.start()
            }
        }
        .windowResizability(.contentMinSize)
    }
}
