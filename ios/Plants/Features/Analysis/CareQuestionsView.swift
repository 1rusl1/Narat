import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct AnalysisAccessSource {
    let connection: CatalogueConnection
    let repository: AnalysisAccessRepository
    let guestCredential: String?
}

private struct PlantCameraPicker: UIViewControllerRepresentable {
    enum Result {
        case photo(Data)
        case unreadable
        case unavailable
    }

    let finish: @MainActor (Result?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let coordinator = context.coordinator
            Task { @MainActor in coordinator.complete(.unavailable) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var finish: (@MainActor (Result?) -> Void)?

        init(finish: @escaping @MainActor (Result?) -> Void) {
            self.finish = finish
        }

        @MainActor
        func complete(_ result: Result?) {
            let callback = finish
            finish = nil
            callback?(result)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            complete(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            let data = image?.jpegData(compressionQuality: 0.95)
            complete(data.map(Result.photo) ?? .unreadable)
        }
    }
}

/// Presentation only: access and owner validation remain in the existing read lease.
enum AnalysisQuotaDenialPresentation: Equatable {
    case unavailable
    case temporary
    case guestExhausted(AnalysisAccessWireDTO.AnalysisMode)

    init(access: AnalysisAccessWireDTO?, mode: AnalysisAccessWireDTO.AnalysisMode) {
        guard let access, let quota = access.modes[mode.rawValue] else {
            self = .unavailable
            return
        }
        let starterKind: AnalysisAccessWireDTO.QuotaKind = mode == .diagnosis
            ? .starterDiagnosis : .starterIdentification
        guard access.isGuest, quota.mode == mode, !quota.allowed,
              quota.activeQuotaKind == starterKind, quota.reason == .starterExhausted,
              quota.remaining == 0, quota.inProgressJobId == nil else {
            self = .temporary
            return
        }
        self = .guestExhausted(mode)
    }

    var showsRetry: Bool {
        if case .guestExhausted = self { return false }
        return true
    }

    func message(locale: SupportedLocale) -> String {
        switch self {
        case .unavailable:
            return locale == .pl
                ? "Nie udało się sprawdzić limitu analiz." : "Couldn’t check analysis quota."
        case .temporary:
            return locale == .pl
                ? "Analiza zdjęcia jest teraz niedostępna." : "Photo analysis is currently unavailable."
        case .guestExhausted(.diagnosis):
            return locale == .pl
                ? "Bezpłatna diagnoza dla gościa została już wykorzystana. Nadal możesz przeglądać katalog."
                : "Your free guest diagnosis has already been used. You can still browse the catalogue."
        case .guestExhausted(.identification):
            return locale == .pl
                ? "Bezpłatne rozpoznanie gatunku dla gościa zostało już wykorzystane. Nadal możesz przeglądać katalog."
                : "Your free guest identification has already been used. You can still browse the catalogue."
        }
    }
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
                        denial(access: access, identifier: "analysis.access.denied")
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
        denial(access: nil, identifier: "analysis.access.error")
    }

    private func denial(access: AnalysisAccessWireDTO?, identifier: String) -> some View {
        let presentation = AnalysisQuotaDenialPresentation(access: access, mode: mode)
        return VStack(alignment: .leading, spacing: 8) {
            Text(presentation.message(locale: locale))
                .accessibilityIdentifier(identifier)
            if presentation.showsRetry { retryButton }
        }
    }

    private var retryButton: some View {
        Button(isPolish ? "Spróbuj ponownie" : "Retry quota check") { attempt += 1 }
            .accessibilityIdentifier("analysis.access.retry")
    }
}

enum PhotoCameraAccess: Equatable {
    case ready, request, denied, unavailable

    init(available: Bool, authorization: AVAuthorizationStatus) {
        switch authorization {
        case .denied, .restricted: self = .denied
        case .authorized: self = available ? .ready : .unavailable
        case .notDetermined: self = available ? .request : .unavailable
        @unknown default: self = .unavailable
        }
    }
}

public struct CareQuestionsView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private let accessSource: AnalysisAccessSource?
    private let returnToPlant: (() -> Void)?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var cameraPermissionTask: Task<Void, Never>?
    @State private var cameraNotice: PhotoCameraAccess?
    @State private var showingCamera = false
    @State private var cameraScope: CatalogueSDKSnapshot?
    @State private var cameraResult: PlantCameraPicker.Result?

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
                        photoSection
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
        .fullScreenCover(isPresented: $showingCamera, onDismiss: finishCameraSelection) {
            PlantCameraPicker { result in
                cameraResult = result
                showingCamera = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            cameraNotice = nil
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
            cameraPermissionTask?.cancel()
            cameraPermissionTask = nil
            photoLoadTask?.cancel()
            if model.isPreparingPhoto { model.cancelAnalysis() }
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let accessSource {
                AnalysisQuotaGate(
                    source: accessSource,
                    mode: model.router.flowState.intent == .problem ? .diagnosis : .identification,
                    locale: languageStore.currentLocale
                ) { photoChoices }
            } else {
                photoChoices
            }
            if let cameraNotice {
                Text(cameraNotice == .denied
                     ? "Camera access is off. You can still choose a photo."
                     : "Camera is unavailable. You can still choose a photo.")
                    .accessibilityIdentifier("photo.camera.notice")
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
            if model.isReplacingQuestionPhoto {
                Button(isPolish ? "Wstecz" : "Back") { model.navigateBack() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("care.photo.replacement.back")
            } else {
                AnalysisExitButtons(model: model, polish: isPolish, returnToPlant: returnToPlant)
            }
        }
    }

    private var photoChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isPolish || model.isReplacingQuestionPhoto {
                Button(isPolish ? "Zrób zdjęcie" : "Take photo", action: openCamera)
                    .buttonStyle(.bordered)
                    .disabled(model.isPreparingPhoto || cameraPermissionTask != nil)
                    .accessibilityIdentifier("photo.select.camera")
            }
            photoPicker
                .disabled(cameraPermissionTask != nil)
        }
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Text(isPolish ? "Wybierz zdjęcie" : "Choose photo")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("photo.select.gallery")
    }

    private func openCamera() {
        let scope = accessSource?.connection.snapshot
        cameraNotice = nil
        let access = PhotoCameraAccess(
            available: UIImagePickerController.isSourceTypeAvailable(.camera),
            authorization: AVCaptureDevice.authorizationStatus(for: .video)
        )
        switch access {
        case .ready:
            presentCamera(scope: scope)
        case .request:
            cameraPermissionTask = Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                cameraPermissionTask = nil
                guard model.router.flowState.currentStep == .selectPhoto,
                      accessSource?.connection.snapshot == scope else { return }
                if granted {
                    presentCamera(scope: scope)
                } else {
                    cameraNotice = .denied
                }
            }
        case .denied, .unavailable:
            cameraNotice = access
        }
    }

    private func presentCamera(scope: CatalogueSDKSnapshot?) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraNotice = .unavailable
            return
        }
        cameraResult = nil
        cameraScope = scope
        showingCamera = true
    }

    private func finishCameraSelection() {
        let result = cameraResult
        cameraResult = nil
        let scope = cameraScope
        cameraScope = nil
        guard model.router.flowState.currentStep == .selectPhoto,
              accessSource?.connection.snapshot == scope else { return }
        switch result {
        case let .photo(data):
            photoLoadTask?.cancel()
            model.selectPhotoData(data, locale: languageStore.currentLocale)
        case .unreadable:
            model.failPhotoSelection(model.beginPhotoSelection())
        case .unavailable:
            cameraNotice = .unavailable
        case .none:
            break
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

            if model.router.flowState.intent == .problem && model.repeatDiagnosisTarget == nil {
                if let photo = model.preparedPhoto,
                   let image = UIImage(data: photo.cloudNormalizedJPEG) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .accessibilityLabel(isPolish ? "Wybrane zdjęcie rośliny" : "Selected plant photo")
                        .accessibilityIdentifier("care.photo.preview")
                }
                Button(isPolish ? "Zmień zdjęcie" : "Replace photo") {
                    model.replaceQuestionPhoto()
                }
                .buttonStyle(.bordered)
                .accessibilityHint(isPolish
                    ? "Wybierz aparat lub galerię. Odpowiedzi zostaną zachowane."
                    : "Choose camera or gallery. Your answers will be kept.")
                .accessibilityIdentifier("care.photo.replace")
            }

            if step == 1 {
                lightingQuestionView
            } else if step == 2 {
                wateringHabitQuestionView
            } else {
                drainageQuestionView
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
                .disabled(model.router.flowState.intent == .problem && model.preparedPhoto == nil)
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

    private var drainageQuestionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isPolish ? "3. Czy doniczka ma otwory odpływowe?" : "3. Does the pot have drainage holes?")
                .font(.title3.bold())
                .accessibilityIdentifier("care.question.drainage.title")

            ForEach(DrainageAnswer.allCases, id: \.self) { answer in
                let isSelected = model.router.flowState.conditions.drainage == answer
                Button {
                    model.selectDrainage(answer)
                } label: {
                    HStack {
                        Text(labelForDrainage(answer))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .primary)
                .accessibilityIdentifier("care.drainage.option.\(answer.rawValue)")
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

    private func labelForDrainage(_ answer: DrainageAnswer) -> String {
        switch answer {
        case .yes:
            return isPolish ? "Tak" : "Yes"
        case .no:
            return isPolish ? "Nie" : "No"
        case .unknown:
            return isPolish ? "Nie wiem" : "I don't know"
        }
    }

}
