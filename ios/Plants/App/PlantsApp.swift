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

    @State private var catalogue: CatalogueConnection?
    @State private var starting = false
    @State private var startupFailed = false
#if DEBUG
    @State private var fixtureContext: CatalogueUIFixtureContext?
#endif

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

                if startupFailed {
                    Text(isPolish ? "Katalog jest niedostępny." : "Catalogue unavailable.")
                        .accessibilityIdentifier("catalogue.error")
                }
                switch analysisModel.router.flowState.currentStep {
                case .selectIntent:
                    welcomeIntentSection
                case .selectCareMethod:
                    careMethodPickerSection
                case .selectCatalogueSpecies:
                    if let catalogue {
                        GuestCatalogueView(connection: catalogue, polish: isPolish) {
                            analysisModel.router.navigateBack()
                        }
                    } else {
                        if !startupFailed { ProgressView() }
                        Button(isPolish ? "Wstecz" : "Back") {
                            analysisModel.router.navigateBack()
                        }
                        .accessibilityIdentifier("catalogue.back")
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
        .task { await prepareCatalogue() }
    }

    @MainActor
    private func prepareCatalogue() async {
        guard !starting else { return }
        starting = true
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureFlags = arguments.filter {
            $0.hasPrefix("--catalogue-fixture") || $0.hasPrefix("--catalogue-namespace")
        }
        if !fixtureFlags.isEmpty {
            func value(_ flag: String) -> String? {
                let positions = arguments.indices.filter { arguments[$0] == flag }
                guard positions.count == 1, let index = positions.first,
                      arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            guard fixtureFlags.count == 2,
                  Set(fixtureFlags) == Set(["--catalogue-fixture", "--catalogue-namespace"]),
                  let name = value("--catalogue-fixture"),
                  let scenario = CatalogueUIFixtureScenario(rawValue: name),
                  let namespace = value("--catalogue-namespace"),
                  let id = UUID(uuidString: namespace),
                  id.uuidString.lowercased() == namespace.lowercased() else {
                startupFailed = true
                return
            }
            do {
                let context = try await CatalogueUIFixtures.make(namespace: namespace, scenario: scenario)
                fixtureContext = context
                catalogue = context.connection
            } catch {
                startupFailed = true
                return
            }
        } else {
            catalogue = CatalogueConnection()
        }
#else
        catalogue = CatalogueConnection()
#endif
        guard let catalogue else { return }
        do {
            _ = try await catalogue.sessionOwner()
            guard analysisModel.router.flowState.currentStep == .selectIntent else { return }
            let expected = try await catalogue.sessionSnapshot()
            guard analysisModel.router.flowState.currentStep == .selectIntent,
                  let flow = try catalogue.resumableFlow(expected: expected) else { return }
            let result = await catalogue.restoreModel(
                ownerId: expected.session.userId, flowId: flow, expected: expected
            )
            // Only an actual current-owner SQLite input resumes the existing catalogue route.
            guard catalogue.snapshot == expected, case let .restored(model) = result,
                  model.input != nil,
                  analysisModel.router.flowState.currentStep == .selectIntent else { return }
            analysisModel.router.selectIntent(.care)
            analysisModel.router.selectCareMethod(.catalogue)
        } catch {
            // Preserve the default welcome and the catalogue's ordinary unavailable path.
        }
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
