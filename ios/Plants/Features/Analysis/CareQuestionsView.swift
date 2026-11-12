import SwiftUI
import PhotosUI

struct AnalysisAccessSource {
    let connection: CatalogueConnection
    let repository: AnalysisAccessRepository
    let guestCredential: String?
}

private struct AnalysisQuotaGate<Content: View>: View {
    let source: AnalysisAccessSource
    let mode: AnalysisAccessWireDTO.AnalysisMode
    let locale: SupportedLocale
    @ViewBuilder let content: () -> Content

    @State private var attempt = 0
    @State private var result: Loaded?

    private struct Read: Equatable {
        let snapshot: CatalogueSDKSnapshot?
        let attempt: Int
    }

    private struct Loaded {
        let read: Read
        let access: AnalysisAccessWireDTO?
    }

    private var isPolish: Bool { locale == .pl }

    var body: some View {
        let read = Read(snapshot: source.connection.snapshot, attempt: attempt)
        VStack(alignment: .leading, spacing: 8) {
            if read.snapshot == nil {
                unavailable
            } else if let result, result.read == read {
                if let access = result.access, let quota = access.modes[mode.rawValue] {
                    summary(access, quota: quota)
                    if quota.allowed {
                        content()
                    } else {
                        Text(isPolish ? "Analiza zdjęcia jest teraz niedostępna." : "Photo analysis is currently unavailable.")
                            .accessibilityIdentifier("analysis.access.denied")
                        retryButton
                    }
                } else {
                    unavailable
                }
            } else {
                ProgressView(isPolish ? "Sprawdzanie limitu analiz" : "Checking analysis quota")
                    .accessibilityIdentifier("analysis.access.loading")
            }
        }
        .task(id: read) {
            guard let snapshot = read.snapshot else {
                _ = try? await source.connection.sessionSnapshot()
                return
            }
            let access = try? await source.connection.analysisAccess(
                using: source.repository, expected: snapshot, guestCredential: source.guestCredential
            )
            guard !Task.isCancelled, source.connection.snapshot == snapshot, attempt == read.attempt else { return }
            result = Loaded(read: read, access: access)
        }
    }

    @ViewBuilder
    private func summary(_ access: AnalysisAccessWireDTO, quota: AnalysisAccessWireDTO.Mode) -> some View {
        if quota.activeQuotaKind == .starterIdentification || quota.activeQuotaKind == .starterDiagnosis {
            Text(isPolish
                 ? "Analiza startowa: \(quota.remaining) z \(quota.limit)"
                 : "Starter analysis: \(quota.remaining) of \(quota.limit)")
                .accessibilityIdentifier("analysis.access.starter")
        }
        if let remaining = access.monthly.remaining, let limit = access.monthly.limit {
            Text(isPolish ? "Analizy miesięczne: \(remaining) z \(limit)" : "Monthly analyses: \(remaining) of \(limit)")
                .accessibilityIdentifier("analysis.access.monthly")
        } else if !access.isGuest {
            Text(isPolish ? "Limit miesięczny niedostępny." : "Monthly quota unavailable.")
                .accessibilityIdentifier("analysis.access.monthly.unavailable")
        }
        if let periodEnd = access.monthly.periodEnd, let date = SQLTimestamp.date(from: periodEnd) {
            let display = date.formatted(.dateTime.month(.abbreviated).day().year().locale(locale.locale))
            Text(isPolish ? "Limit odnowi się: \(display)" : "Resets on \(display)")
                .accessibilityIdentifier("analysis.access.reset")
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isPolish ? "Nie udało się sprawdzić limitu analiz." : "Couldn’t check analysis quota.")
                .accessibilityIdentifier("analysis.access.error")
            retryButton
        }
    }

    private var retryButton: some View {
        Button(isPolish ? "Spróbuj ponownie" : "Retry quota check") { attempt += 1 }
            .accessibilityIdentifier("analysis.access.retry")
    }
}

public struct CareQuestionsView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private let accessSource: AnalysisAccessSource?
    private let returnToPlant: (() -> Void)?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLoadTask: Task<Void, Never>?

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.init(model: model, languageStore: languageStore, accessSource: nil)
    }

    init(
        model: AnalysisFlowModel, languageStore: LanguageStore, accessSource: AnalysisAccessSource?,
        returnToPlant: (() -> Void)? = nil
    ) {
        self.model = model
        self.languageStore = languageStore
        self.accessSource = accessSource
        self.returnToPlant = returnToPlant
    }

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.router.flowState.currentStep == .selectPhoto {
                    if model.hasAnalysisService {
                        gallerySection
                    } else {
                        AnalysisUnavailableSection(model: model, languageStore: languageStore, returnToPlant: returnToPlant)
                    }
                } else {
                    questionStepSection
                }
            }
            .padding()
        }
        .navigationTitle(isPolish ? "Pierwsza pomoc" : "First Help")
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            photoLoadTask?.cancel()
            let selectionId = model.beginPhotoSelection()
            photoLoadTask = Task { @MainActor in
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        model.failPhotoSelection(selectionId)
                        return
                    }
                    guard !Task.isCancelled else { return }
                    model.completePhotoSelection(
                        data, selectionId: selectionId,
                        locale: languageStore.currentLocale
                    )
                } catch {
                    model.failPhotoSelection(selectionId)
                }
            }
        }
        .onDisappear {
            photoLoadTask?.cancel()
            if model.isPreparingPhoto { model.cancelAnalysis() }
        }
    }

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let accessSource {
                AnalysisQuotaGate(
                    source: accessSource,
                    mode: model.router.flowState.intent == .problem ? .diagnosis : .identification,
                    locale: languageStore.currentLocale
                ) { photoPicker }
            } else {
                photoPicker
            }

            if model.isPreparingPhoto {
                ProgressView(isPolish ? "Wczytywanie zdjęcia" : "Loading photo")
            }
            if model.photoError != nil {
                Text(isPolish
                     ? "Nie można odczytać zdjęcia. Wybierz inne."
                     : "Unable to read this photo. Choose another.")
                    .accessibilityIdentifier("photo.error")
            }
            AnalysisExitButtons(model: model, polish: isPolish, returnToPlant: returnToPlant)
        }
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Text(isPolish ? "Wybierz zdjęcie" : "Choose photo")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("photo.select.gallery")
    }

    private var questionStepSection: some View {
        let step = model.router.flowState.questionIndex
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isPolish ? "Krok \(step) z 3" : "Step \(step) of 3")
                    .font(.headline)
                    .accessibilityIdentifier("care.questions.progress")
                Spacer()
                if model.preparedPhoto != nil {
                    Text(isPolish ? "Zdjęcie gotowe" : "Photo ready")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("care.photo.ready.badge")
                }
            }

            if step == 1 {
                lightingQuestionView
            } else if step == 2 {
                wateringHabitQuestionView
            } else {
                lastWateredQuestionView
            }

            HStack(spacing: 12) {
                Button {
                    model.navigateBack()
                } label: {
                    Text(isPolish ? "Wstecz" : "Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("care.navigation.back")

                Button {
                    model.advanceQuestionOrStartAnalysis(locale: languageStore.currentLocale)
                } label: {
                    Text(
                        step < 3
                            ? (isPolish ? "Dalej" : "Next")
                            : (isPolish ? "Analizuj roślinę" : "Analyze plant")
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("care.navigation.next")
            }
        }
    }

    private var lightingQuestionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isPolish ? "1. Jakie światło ma roślina?" : "1. What light does the plant receive?")
                .font(.title3.bold())
                .accessibilityIdentifier("care.question.light.title")

            ForEach(LightLevel.allCases, id: \.self) { level in
                let isSelected = model.router.flowState.conditions.lightLevel == level
                Button {
                    model.selectLightLevel(level)
                } label: {
                    HStack {
                        Text(labelForLight(level))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .primary)
                .accessibilityIdentifier("care.light.option.\(level.rawValue)")
            }

        }
    }

    private var wateringHabitQuestionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isPolish ? "2. Jak często podlewasz roślinę?" : "2. How often do you water the plant?")
                .font(.title3.bold())
                .accessibilityIdentifier("care.question.watering.title")

            ForEach(WateringHabit.allCases, id: \.self) { habit in
                let isSelected = model.router.flowState.conditions.wateringHabit == habit
                Button {
                    model.selectWateringHabit(habit)
                } label: {
                    HStack {
                        Text(labelForWateringHabit(habit))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .primary)
                .accessibilityIdentifier("care.watering.option.\(habit.rawValue)")
            }
        }
    }

    private var lastWateredQuestionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isPolish ? "3. Kiedy ostatnio była podlewana?" : "3. When was it last watered?")
                .font(.title3.bold())
                .accessibilityIdentifier("care.question.last_watered.title")

            ForEach(LastWateredBucket.allCases, id: \.self) { bucket in
                let isSelected = model.router.flowState.conditions.lastWatered == bucket
                Button {
                    model.selectLastWatered(bucket)
                } label: {
                    HStack {
                        Text(labelForLastWatered(bucket))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .primary)
                .accessibilityIdentifier("care.last_watered.option.\(bucket.rawValue)")
            }
        }
    }

    private func labelForLight(_ level: LightLevel) -> String {
        switch level {
        case .brightDirect:
            return isPolish ? "Pełne słońce" : "Direct sun"
        case .brightIndirect:
            return isPolish ? "Jasne rozproszone" : "Bright indirect"
        case .medium:
            return isPolish ? "Półcień / umiarkowane" : "Medium light"
        case .low:
            return isPolish ? "Cień / słabe światło" : "Low light"
        case .unknown:
            return isPolish ? "Nie wiem" : "I don't know"
        }
    }

    private func labelForWateringHabit(_ habit: WateringHabit) -> String {
        switch habit {
        case .frequent:
            return isPolish ? "Często (co kilka dni)" : "Frequently (every few days)"
        case .moderate:
            return isPolish ? "Umiarkowanie (raz w tygodniu)" : "Moderately (about once a week)"
        case .sparse:
            return isPolish ? "Rzadko (co 2–3 tygodnie)" : "Sparsely (every 2–3 weeks)"
        case .unknown:
            return isPolish ? "Nie wiem" : "I don't know"
        }
    }

    private func labelForLastWatered(_ bucket: LastWateredBucket) -> String {
        switch bucket {
        case .today:
            return isPolish ? "Dzisiaj / wczoraj" : "Today / yesterday"
        case .within3Days:
            return isPolish ? "2–3 dni temu" : "2–3 days ago"
        case .within7Days:
            return isPolish ? "W tym tygodniu" : "Within the last week"
        case .over7Days:
            return isPolish ? "Ponad tydzień temu" : "More than a week ago"
        case .unknown:
            return isPolish ? "Nie wiem" : "I don't know"
        }
    }

}
