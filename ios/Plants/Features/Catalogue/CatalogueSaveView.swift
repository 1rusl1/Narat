import SwiftUI
import UIKit

private struct CatalogueViewIntent {
    let input: CatalogueInput
    let flowId: UUID
    let operationId: UUID
}

private enum CatalogueViewNotice {
    case invalidInput, unavailable, sessionChanged, nativeCancelled, authenticationFailed
}

/// Private form state belongs to one actual SDK snapshot, including its event epoch.
@MainActor
struct CatalogueSaveView<SpeciesDetails: View>: View {
    let connection: CatalogueConnection
    let speciesSlug: String
    let displayName: String
    let scientificName: String
    let polish: Bool
    @Binding var selectionLocked: Bool
    @ViewBuilder let speciesDetails: () -> SpeciesDetails

    @State private var scope: CatalogueSDKSnapshot?
    @State private var model: CatalogueSaveModel?
    @State private var intent: CatalogueViewIntent?
    @State private var name = ""
    @State private var previousFlow: UUID?
    @State private var notice: CatalogueViewNotice?
    @State private var restoreFailed = false
    @State private var working = false
    @State private var nativeInFlight = false
    @State private var active = false
    @State private var revision = 0
    @State private var work: Task<Void, Never>?
    @State private var presenter: UIViewController?

    private var scopeIsCurrent: Bool {
        scope != nil && connection.snapshot == scope
    }

    private var shouldLockSelection: Bool {
        if working || nativeInFlight { return true }
        guard let model else { return false }
        switch model.state {
        case .pending, .busy: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if nativeInFlight {
                publicHeading
                ProgressView(polish ? "Logowanie i zapisywanie…" : "Signing in and saving…")
                    .accessibilityIdentifier("catalogue.save.native.busy")
            } else if !scopeIsCurrent {
                publicHeading
                Text(polish ? "Sesja uległa zmianie. Wczytaj bieżące konto." : "Session changed. Load the current account.")
                    .accessibilityIdentifier("catalogue.save.unavailable")
                Button(polish ? "Wczytaj konto" : "Load account") { synchronize() }
                    .accessibilityIdentifier("catalogue.save.restore")
            } else if let model, case .saved = model.state {
                VStack(alignment: .leading, spacing: 12) { savedCard(model) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(operationIdentifier)
            } else {
                publicHeading
                speciesDetails()
                if restoreFailed {
                    Text(polish ? "Nie udało się przywrócić zapisu." : "Couldn’t restore your save.")
                        .accessibilityIdentifier("catalogue.save.unavailable")
                    Button(polish ? "Spróbuj ponownie" : "Try again") { synchronize() }
                        .accessibilityIdentifier("catalogue.save.restore")
                } else {
                    saveForm
                }
                if let notice { noticeText(notice) }
            }
        }
        .background {
            CatalogueWindowPresenter(controller: $presenter)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            active = true
            synchronize()
        }
        .onChange(of: connection.snapshot) { _, current in
            // The native helper alone reconciles its intentional SDK transition.
            guard !nativeInFlight, current != scope else { return }
            synchronize()
        }
        .onChange(of: shouldLockSelection, initial: true) { _, locked in
            selectionLocked = locked
        }
        .onDisappear {
            active = false
            revision += 1
            work?.cancel()
            model?.cancel()
            work = nil
            model = nil
            intent = nil
            name = ""
            previousFlow = nil
            notice = nil
            scope = nil
            working = false
            nativeInFlight = false
            selectionLocked = false
        }
    }

    private var publicHeading: some View {
        VStack(alignment: .leading) {
            Text(displayName).font(.title)
            Text(scientificName).italic()
                .accessibilityIdentifier("catalogue.selected.scientific")
        }
    }

    private var formName: String {
        if let model { return model.input?.personalName ?? "" }
        return intent?.input.personalName ?? name
    }

    private var operationIdentifier: String {
        guard let envelope = model?.envelope else { return "catalogue.save.form" }
        return "catalogue.save.operation." + envelope.operationId.uuidString.lowercased()
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(polish ? "Zapisz w kolekcji" : "Save to collection").font(.headline)
            Text(polish ? "Nazwa rośliny (opcjonalnie)" : "Plant name (optional)")
            if model == nil || model?.input != nil {
                TextField(
                    polish ? "Nazwa rośliny (opcjonalnie)" : "Plant name (optional)",
                    text: Binding(
                        get: { formName },
                        set: { if !working, model == nil, intent == nil, scopeIsCurrent { name = $0 } }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(working || model != nil || intent != nil)
                .accessibilityIdentifier("catalogue.save.name")
            }
            if let model {
                saveControls(model)
            } else {
                Button(polish ? "Zapisz roślinę" : "Save plant") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    .accessibilityIdentifier("catalogue.save.submit")
                if intent != nil {
                    editButton
                }
            }
            if working && !nativeInFlight { ProgressView() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(operationIdentifier)
    }

    @ViewBuilder
    private func saveControls(_ model: CatalogueSaveModel) -> some View {
        switch model.state {
        case .ready:
            retrySaveButton
            editButton
        case .busy:
            Text(polish ? "Zapisywanie…" : "Saving…")
                .accessibilityIdentifier("catalogue.save.busy")
        case .signInRequired:
            Text(polish ? "Zaloguj się, aby zapisać wybraną roślinę." : "Sign in to save your chosen plant.")
                .accessibilityIdentifier("catalogue.save.signInRequired")
            Button(polish ? "Kontynuuj z Apple" : "Continue with Apple") { signIn(.apple) }
                .accessibilityIdentifier("catalogue.save.apple")
                .disabled(working || presenter?.viewIfLoaded?.window == nil)
            Button(polish ? "Kontynuuj z Google" : "Continue with Google") { signIn(.google) }
                .accessibilityIdentifier("catalogue.save.google")
                .disabled(working || presenter?.viewIfLoaded?.window == nil)
            editButton
        case .pending:
            if model.pendingAPIError?.error.code == "COLLECTION_LIMIT_REACHED" {
                Text(polish
                     ? "Serwer odrzucił zapis: limit kolekcji został osiągnięty. Roślina nie jest zapisana."
                     : "The server rejected this save: collection limit reached. The plant is not saved.")
                    .accessibilityIdentifier("catalogue.save.serverLimit")
            } else {
                Text(model.pendingAPIError?.error.code == "INTERNAL_ERROR"
                     ? (polish ? "Usługa nie potwierdziła zapisu. Zapis oczekuje na ponowienie." : "The service couldn’t confirm the save. It is pending a retry.")
                     : (polish ? "Oczekuje na zapis. Nie potwierdzono jeszcze zapisania rośliny." : "Save pending. The plant has not been confirmed saved yet."))
                    .accessibilityIdentifier("catalogue.save.pending")
            }
            retrySaveButton
        case .collectionLimitNotEnqueued:
            Text(polish
                 ? "Bezpłatna kolekcja mieści 3 rośliny. Nie wysłano nowej rośliny."
                 : "The free collection holds 3 plants. This plant was not submitted.")
                .accessibilityIdentifier("catalogue.save.limit")
            retrySaveButton
            editButton
        case let .unavailable(reason):
            Text(reason == .sessionChanged
                 ? (polish ? "Sesja uległa zmianie." : "Session changed.")
                 : (polish ? "Zapis jest niedostępny. Nie potwierdzono zapisania rośliny." : "Save unavailable. The plant has not been confirmed saved."))
                .accessibilityIdentifier("catalogue.save.unavailable")
            if reason == .storageOrServiceUnavailable {
                // Queue truth may be unknown after a storage failure: keep this operation.
                retrySaveButton
            } else {
                Button(polish ? "Przywróć zapis" : "Restore save") { synchronize() }
                    .accessibilityIdentifier("catalogue.save.restore")
            }
        case .saved:
            EmptyView()
        }
    }

    private var retrySaveButton: some View {
        Button(polish ? "Ponów ten sam zapis" : "Retry this save") { save() }
            .disabled(working)
            .accessibilityIdentifier("catalogue.save.retry")
    }

    private var editButton: some View {
        Button(polish ? "Edytuj jako nowy zapis" : "Edit as a new save") { editAsNewIntent() }
            .disabled(working)
            .accessibilityIdentifier("catalogue.save.edit")
    }

    @ViewBuilder
    private func savedCard(_ model: CatalogueSaveModel) -> some View {
        // No receipt or captured private summary is passed to a destination.
        Text(polish ? "Roślina zapisana" : "Plant saved").font(.headline)
            .accessibilityIdentifier("catalogue.save.saved")
        if let summary = model.cardSummary {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.personalName ?? (polish ? "Roślina" : "Plant")).font(.title)
                    .accessibilityIdentifier("catalogue.saved.name")
                Text(summary.speciesSlug == speciesSlug ? displayName : summary.speciesSlug)
                    .accessibilityIdentifier("catalogue.saved.species")
                if summary.speciesSlug == speciesSlug {
                    Text(scientificName).italic()
                        .accessibilityIdentifier("catalogue.selected.scientific")
                    speciesDetails()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("catalogue.saved.card." + summary.id.uuidString.lowercased())
        } else {
            switch model.cardState {
            case .idle, .loading:
                ProgressView(polish ? "Wczytywanie szczegółów…" : "Loading details…")
            case .unavailable:
                Text(polish ? "Roślina jest zapisana. Szczegóły są niedostępne." : "Your plant is saved. Details are unavailable.")
                    .accessibilityIdentifier("catalogue.saved.detailsUnavailable")
                Button(polish ? "Wczytaj szczegóły ponownie" : "Retry details") { loadDetails(model) }
                    .disabled(working)
                    .accessibilityIdentifier("catalogue.saved.retry")
            case .loaded:
                EmptyView()
            }
        }
    }

    private func noticeText(_ notice: CatalogueViewNotice) -> some View {
        let text: String
        switch notice {
        case .invalidInput:
            text = polish ? "Sprawdź nazwę rośliny i spróbuj ponownie." : "Check the plant name and try again."
        case .unavailable:
            text = polish ? "Nie udało się zapisać. Spróbuj ponownie." : "Couldn’t save. Try again."
        case .sessionChanged:
            text = polish ? "Sesja uległa zmianie. Wczytaj bieżące konto." : "Session changed. Load the current account."
        case .nativeCancelled:
            text = polish ? "Logowanie anulowane. Wybrane dane zostały zachowane." : "Sign-in cancelled. Your chosen input has been retained."
        case .authenticationFailed:
            text = polish ? "Logowanie nie powiodło się. Spróbuj ponownie lub wróć." : "Sign-in failed. Try again or go back."
        }
        return Text(text).accessibilityIdentifier("catalogue.save.notice")
    }

    private func isCurrent(_ ticket: Int, _ expected: CatalogueSDKSnapshot) -> Bool {
        active && revision == ticket && !Task.isCancelled && scope == expected && connection.snapshot == expected
    }

    private func synchronize() {
        guard active, !nativeInFlight else { return }
        revision += 1
        let ticket = revision
        work?.cancel()
        model?.cancel()
        model = nil
        intent = nil
        name = ""
        previousFlow = nil
        notice = nil
        restoreFailed = false
        scope = connection.snapshot
        guard let expected = scope else { working = false; return }
        working = true
        work = Task { @MainActor in
            defer { if revision == ticket { working = false; work = nil } }
            do {
                previousFlow = try connection.resumableFlow(expected: expected)
                if let flow = previousFlow {
                    let result = await connection.restoreModel(
                        ownerId: expected.session.userId, flowId: flow, expected: expected
                    )
                    guard isCurrent(ticket, expected) else { return }
                    switch result {
                    case let .restored(restored):
                        if restored.input?.speciesSlug == speciesSlug {
                            model = restored
                            await loadIfSaved(restored)
                        }
                    case .absent: break
                    case .unavailable: restoreFailed = true
                    }
                }
            } catch {
                if isCurrent(ticket, expected) { restoreFailed = true }
            }
        }
    }

    private func save() {
        guard !working, scopeIsCurrent, let expected = scope else { return }
        if model == nil && intent == nil {
            let input = CatalogueInput(speciesSlug: speciesSlug, personalName: name.isEmpty ? nil : name)
            let chosen = CatalogueViewIntent(input: input, flowId: UUID(), operationId: UUID())
            do { _ = try input.makeEnvelope(operationId: chosen.operationId) }
            catch { notice = .invalidInput; return }
            intent = chosen
        }
        let ticket = revision
        working = true
        notice = nil
        work = Task { @MainActor in
            defer { if revision == ticket { working = false; work = nil } }
            do {
                let target: CatalogueSaveModel
                if let model {
                    target = model
                } else if let intent {
                    target = try await connection.makeModel(
                        input: intent.input, flowId: intent.flowId,
                        operationId: intent.operationId, expected: expected
                    )
                } else { return }
                guard isCurrent(ticket, expected) else { return }
                model = target
                if let oldFlow = previousFlow, let intent, oldFlow != intent.flowId {
                    _ = try connection.forgetResumableFlow(
                        ownerId: expected.session.userId, expectedFlowId: oldFlow, expected: expected
                    )
                }
                let checkpoint = try await connection.rememberModel(target, expected: expected)
                guard isCurrent(ticket, expected) else { return }
                previousFlow = checkpoint.flowId
                await target.save()
                guard isCurrent(ticket, expected) else { return }
                await loadIfSaved(target)
            } catch {
                if isCurrent(ticket, expected) { notice = .unavailable }
            }
        }
    }

    private func editAsNewIntent() {
        guard !working, scopeIsCurrent, let expected = scope else { return }
        if let model {
            switch model.state {
            case .ready, .signInRequired, .collectionLimitNotEnqueued: break
            default: return
            }
        }
        do {
            let editableName = model?.input?.personalName ?? intent?.input.personalName ?? name
            if let flow = previousFlow {
                _ = try connection.forgetResumableFlow(
                    ownerId: expected.session.userId, expectedFlowId: flow, expected: expected
                )
            }
            guard connection.snapshot == expected else { throw CatalogueSaveUnavailable.sessionChanged }
            model?.cancel()
            model = nil
            intent = nil
            previousFlow = nil
            name = editableName
            notice = nil
        } catch { notice = .unavailable }
    }

    private func signIn(_ provider: NativeAuthProvider) {
        guard !working, scopeIsCurrent, let expected = scope, let original = model,
              case .signInRequired = original.state,
              let presenter, presenter.viewIfLoaded?.window != nil else { return }
        let ticket = revision
        working = true
        nativeInFlight = true
        notice = nil
        work = Task { @MainActor in
            defer {
                if revision == ticket {
                    if connection.snapshot != scope { clearPrivateState() }
                    working = false
                    nativeInFlight = false
                    work = nil
                }
            }
            do {
                _ = try await connection.rememberModel(original, expected: expected)
                let outcome = await connection.signInAndSave(original, with: provider, presenting: presenter)
                guard active, revision == ticket, !Task.isCancelled else { return }
                switch outcome {
                case let .continued(verified):
                    try await adopt(verified, ticket: ticket)
                case let .inputRetained(verified, reason):
                    try await adopt(verified, ticket: ticket)
                    notice = reason == .cancelled ? .nativeCancelled : .authenticationFailed
                case .busy:
                    notice = .authenticationFailed
                case let .unavailable(reason):
                    if connection.snapshot == expected, original.input != nil {
                        notice = reason == .cancelled ? .nativeCancelled : .authenticationFailed
                    } else {
                        clearPrivateState()
                    }
                }
            } catch {
                guard active, revision == ticket, !Task.isCancelled else { return }
                if connection.snapshot == expected, original.input != nil {
                    notice = .authenticationFailed
                } else {
                    clearPrivateState()
                }
            }
        }
    }

    private func adopt(_ verified: CatalogueSaveModel, ticket: Int) async throws {
        let expected = try await connection.sessionSnapshot()
        guard active, revision == ticket, !Task.isCancelled,
              let store = connection.store, let api = connection.apiClient else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        try verified.validateScope(
            of: store, apiClient: api, session: expected.session, isAnonymous: expected.isAnonymous
        )
        guard connection.snapshot == expected, verified.input?.speciesSlug == speciesSlug else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        if let old = model, old !== verified { old.cancel() }
        scope = expected
        model = verified
        intent = nil
        name = ""
        previousFlow = verified.checkpoint?.flowId
        await loadIfSaved(verified)
    }

    private func clearPrivateState() {
        model?.cancel()
        model = nil
        intent = nil
        name = ""
        previousFlow = nil
        scope = nil
        notice = .sessionChanged
    }

    private func loadIfSaved(_ model: CatalogueSaveModel) async {
        if case .saved = model.state { await model.loadCard() }
    }

    private func loadDetails(_ target: CatalogueSaveModel) {
        guard !working, scopeIsCurrent else { return }
        let ticket = revision
        working = true
        work = Task { @MainActor in
            defer { if revision == ticket { working = false; work = nil } }
            await target.loadCard()
        }
    }
}

/// A mounted controller in the app's real window supplies the native presentation anchor.
@MainActor
private struct CatalogueWindowPresenter: UIViewControllerRepresentable {
    @Binding var controller: UIViewController?

    func makeUIViewController(context: Context) -> WindowController {
        let result = WindowController()
        result.didAppear = { controller = $0 }
        return result
    }

    func updateUIViewController(_ uiViewController: WindowController, context: Context) {}

    final class WindowController: UIViewController {
        var didAppear: ((UIViewController) -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if view.window != nil { didAppear?(self) }
        }
    }
}
