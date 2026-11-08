import SwiftUI

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
                if model.router.flowState.currentStep == .selectPhoto {
                    AnalysisUnavailableSection(model: model, languageStore: languageStore)
                } else {
                    questionStepSection
                }
            }
            .padding()
        }
        .navigationTitle(isPolish ? "Pierwsza pomoc" : "First Help")
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
