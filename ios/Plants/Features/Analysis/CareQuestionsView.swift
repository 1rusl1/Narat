import SwiftUI
import UIKit

public struct CareQuestionsView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                quotaStatusBanner

                if model.router.flowState.currentStep == .selectPhoto {
                    photoSelectionSection
                } else {
                    questionStepSection
                }
            }
            .padding()
        }
        .navigationTitle(isPolish ? "Pierwsza pomoc" : "First Help")
    }

    private var quotaStatusBanner: some View {
        let diagRem = model.accessState.diagnosisQuota.remaining
        let idRem = model.accessState.identificationQuota.remaining
        return VStack(alignment: .leading, spacing: 6) {
            Text(
                isPolish
                    ? "Dostępne bezpłatne skany startowe: diagnoza \(diagRem)/1 · rozpoznanie gatunku \(idRem)/1"
                    : "Available free starter scans: diagnosis \(diagRem)/1 · species ID \(idRem)/1"
            )
            .font(.footnote.weight(.medium))
            .accessibilityIdentifier("quota.starter.banner")

            Text(
                isPolish
                    ? "Katalog roślin oraz podstawowa pielęgnacja (do 3 roślin) są zawsze dostępne bezpłatnie."
                    : "The plant catalogue and basic care (up to 3 plants) are always available for free."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("quota.free.catalogue.note")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var photoSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                isPolish
                    ? "Wskazówka: uchwyć na zdjęciu całą roślinę oraz wyraźnie widoczny objaw na liściu lub łodydze w świetle dziennym."
                    : "Tip: capture both the whole plant and the visible symptom on the leaf or stem in daylight."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("photo.capture.tip")

            if let photoError = model.photoError {
                Text(
                    isPolish
                        ? "Plik zdjęcia jest uszkodzony lub nieczytelny. Wybierz inne zdjęcie."
                        : "The photo file is corrupt or unreadable. Please choose another photo."
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(photoError)
            }

            Button {
                let sampleData = Self.makeSampleImageData(largeOver10MB: false)
                model.selectPhotoData(sampleData, identifier: "sample_standard_photo")
            } label: {
                Text(isPolish ? "Dodaj zdjęcie rośliny" : "Add plant photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("photo.select.standard")

            Button {
                let largeData = Self.makeSampleImageData(largeOver10MB: true)
                model.selectPhotoData(largeData, identifier: "sample_large_12mb_photo")
            } label: {
                Text(
                    isPolish
                        ? "Dodaj duże zdjęcie (> 10 MB, automatyczna kompresja)"
                        : "Add large photo (> 10 MB, auto-compressed)"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("photo.select.large")

            Button {
                model.router.navigateBack()
            } label: {
                Text(isPolish ? "Wstecz" : "Back")
            }
            .accessibilityIdentifier("care.navigation.back")
        }
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
                    model.router.navigateBack()
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
                    model.selectLightLevel(level, source: .manual)
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

            Button {
                model.applyEstimatedLighting(.brightIndirect)
            } label: {
                Label(
                    isPolish ? "Oceń światło aparatem (wskazówka)" : "Estimate light with camera (hint)",
                    systemImage: "camera.metering.matrix"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("care.lighting.estimate.button")
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

    /// Generates a valid image data buffer; when largeOver10MB is true, appends trailing padding bytes
    /// after the PNG/BMP container so rawData.count > 10 MB while UIImage(data:) remains readable.
    public static func makeSampleImageData(largeOver10MB: Bool) -> Data {
        let size = CGSize(width: 600, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        var data = renderer.pngData { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        if largeOver10MB && data.count < (11 * 1024 * 1024) {
            let paddingCount = (11 * 1024 * 1024) - data.count
            data.append(Data(repeating: 0, count: paddingCount))
        }
        return data
    }
}
