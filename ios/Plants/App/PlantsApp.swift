import SwiftUI

@main
struct PlantsApp: App {
    @State private var languageStore = LanguageStore()
    @State private var analysisModel = AnalysisFlowModel()

    var body: some Scene {
        WindowGroup {
            RootContainerView(
                languageStore: languageStore,
                analysisModel: analysisModel
            )
            .environment(\.locale, languageStore.currentLocale.locale)
            .onOpenURL { url in
                _ = NativeIdentityProvider.handleCallbackURL(url)
            }
        }
    }
}

struct RootContainerView: View {
    @Bindable var languageStore: LanguageStore
    @Bindable var analysisModel: AnalysisFlowModel

    @State private var catalogue = CatalogueConnection()

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("profile.language.picker", selection: $languageStore.currentLocale) {
                    Text("Polski").tag(SupportedLocale.pl)
                    Text("English").tag(SupportedLocale.en)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("welcome.language.picker")

                switch analysisModel.router.flowState.currentStep {
                case .selectIntent:
                    welcomeIntentSection
                case .selectCareMethod:
                    careMethodPickerSection
                case .selectCatalogueSpecies:
                    GuestCatalogueView(connection: catalogue, polish: isPolish) {
                        analysisModel.router.navigateBack()
                    }
                case .selectPhoto, .careQuestions:
                    CareQuestionsView(model: analysisModel, languageStore: languageStore)
                case .analyzing, .preliminaryResult, .diagnosticRefinement:
                    PreliminaryResultView(model: analysisModel, languageStore: languageStore)
                default:
                    welcomeIntentSection
                }
            }
        }
        .task { _ = try? await catalogue.sessionOwner() }
    }

    private var welcomeIntentSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(isPolish ? "Narat" : "Narat")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("welcome.title")

            Text(
                isPolish
                    ? "Wybierz, w czym możemy dziś pomóc Twojej roślinie."
                    : "Choose how we can help your plant today."
            )
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("welcome.subtitle")

            VStack(spacing: 12) {
                Button {
                    analysisModel.router.selectIntent(.problem)
                } label: {
                    Text(
                        isPolish
                            ? "Zdiagnozuj problem z rośliną"
                            : "Diagnose a plant problem"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome.intent.problem")

                Button {
                    analysisModel.router.selectIntent(.care)
                } label: {
                    Text(
                        isPolish
                            ? "Dobierz pielęgnację i harmonogram"
                            : "Set up care and schedule"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("welcome.intent.care")
            }
            .padding(.horizontal)
            Spacer()
        }
        .padding()
    }

    private var careMethodPickerSection: some View {
        VStack(spacing: 16) {
            Text(
                isPolish
                    ? "Jak chcesz dodać roślinę do pielęgnacji?"
                    : "How would you like to add your plant for care?"
            )
            .font(.title3.bold())
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("care.method.title")

            Button {
                analysisModel.router.selectCareMethod(.scan)
            } label: {
                Text(isPolish ? "Rozpoznaj gatunek ze zdjęcia" : "Identify species from photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("care.method.scan")

            Button {
                analysisModel.router.selectCareMethod(.catalogue)
            } label: {
                Text(isPolish ? "Wybierz gatunek z katalogu (bez zdjęcia)" : "Choose species from catalogue (no photo)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("care.method.catalogue")

            Button {
                analysisModel.router.navigateBack()
            } label: {
                Text(isPolish ? "Wstecz" : "Back")
            }
            .accessibilityIdentifier("care.navigation.back")
        }
        .padding()
    }
}
