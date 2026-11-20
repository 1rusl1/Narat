import SwiftUI
import UIKit

/// Source dates are labels, never instants converted from UTC midnight.
struct TodayCalendar {
    enum Status: Equatable { case unavailable, empty, unknown, paused, pending, noSchedule, scheduled }
    struct Check: Identifiable {
        let id: String
        let plantId: UUID
        let title: String
        let due: String
        let followUp: Bool
        let source: PlantCareRecommendation.Source
    }
    struct Section: Identifiable {
        var id: String { day }
        let day: String
        let checks: [Check]
    }
    let today: String
    let status: Status
    let sections: [Section]

    static func calendar(timeZone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        return result
    }

    static func day(_ now: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func boundary(now: Date, deadline: Date?, timeZone: TimeZone) -> Date {
        let calendar = calendar(timeZone: timeZone)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return deadline.map { $0 > now ? min($0, midnight) : midnight } ?? midnight
    }

    init(state: CareOverviewViewState?, now: Date, timeZone: TimeZone = .current, polish: Bool = false) {
        let today = Self.day(now, timeZone: timeZone)
        self.today = today
        guard let state else { status = .unavailable; sections = []; return }
        let expired = state.verifiedAccessUntil.map { $0 <= now } == true || state.access == .expired
        var checks: [Check] = []
        if !expired {
            for plant in state.plants where plant.automatedActionsAllowed && plant.cardLinkAvailable {
                let title = plant.card.personalName ?? plant.card.speciesSlug ?? (polish ? "Roślina" : "Plant")
                if let routine = plant.routine, let source = plant.routineSource,
                   SQLCalendarDay.date(from: routine.dueLocalDate) != nil {
                    checks.append(Check(id: "r/\(plant.card.id)/\(routine.ruleId)/\(routine.dueLocalDate)",
                                        plantId: plant.card.id, title: title, due: routine.dueLocalDate,
                                        followUp: false, source: source))
                }
                for control in plant.controls where SQLCalendarDay.date(from: control.dueOn) != nil {
                    checks.append(Check(id: "f/\(plant.card.id)/\(control.id)/\(control.dueOn)",
                                        plantId: plant.card.id, title: title, due: control.dueOn,
                                        followUp: true, source: control.source))
                }
            }
        }
        let current = checks.filter { $0.due <= today }
        let nearest = checks.map(\.due).filter { $0 > today }.min()
        let visible = current.isEmpty ? checks.filter { $0.due == nearest } : current
        let grouped = Dictionary(grouping: visible, by: \.due)
        sections = grouped.keys.sorted().map { day in
            Section(day: day, checks: grouped[day]!.sorted { $0.id < $1.id })
        }
        if !visible.isEmpty { status = .scheduled }
        else if !state.pending.isEmpty { status = .pending }
        else if expired { status = .paused }
        else if state.access == .unknown { status = .unknown }
        else if state.availability != .available || state.failure != nil { status = .unavailable }
        else { status = state.plants.isEmpty ? .empty : .noSchedule }
    }
}

struct TodayHomeView: View {
    let model: TodayModel
    let visible: Bool
    let unavailable: Bool
    let polish: Bool
    let busy: Bool
    let retry: () -> Void
    let localBoundary: () -> Void
    let openPlant: (UUID) -> Void
    let collection: () -> Void
    let browse: () -> Void
    let check: () -> Void
    let identify: () -> Void
    private struct ClockRead: Equatable {
        let scope: TodayModel.Scope?
        let deadline: Date
    }
    @State private var clock = Date()

    private var state: CareOverviewViewState? { visible ? model.state : nil }
    private var now: Date { max(clock, Date()) }
    private var boundary: Date {
        TodayCalendar.boundary(now: clock, deadline: state?.verifiedAccessUntil, timeZone: .current)
    }

    var body: some View {
        let projection = TodayCalendar(state: state, now: now, polish: polish)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(polish ? "Dzisiaj" : "Today").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Button(polish ? "Moje rośliny" : "My plants", action: collection)
                    .accessibilityIdentifier("collection.open")
                Button(polish ? "Sprawdź roślinę" : "Check a plant", action: check)
                    .accessibilityIdentifier("welcome.check")
                Button(polish ? "Dodaj / przeglądaj katalog" : "Add / browse catalogue", action: browse)
                    .accessibilityIdentifier("welcome.catalogue")
                Button(polish ? "Rozpoznaj roślinę" : "Identify a plant", action: identify)
                    .accessibilityIdentifier("welcome.identify")
                if unavailable {
                    Text(polish ? "Opieka jest niedostępna." : "Care is unavailable.")
                } else if model.hasError {
                    Text(polish ? "Nie udało się odświeżyć opieki." : "Couldn’t refresh care.")
                } else if state == nil {
                    ProgressView(polish ? "Wczytywanie opieki…" : "Loading care…")
                }
                if model.refreshing { ProgressView(polish ? "Odświeżanie…" : "Refreshing…") }
                if state?.origin == .cache {
                    Text(polish ? "Zapisana opieka." : "Saved care.").foregroundStyle(.secondary)
                }
                if let state, !state.pending.isEmpty {
                    Text(state.pending.contains { $0.status == .retryRequired }
                         ? (polish ? "Zmiany wymagają ponowienia." : "Saved changes need a retry.")
                         : (polish ? "Zmiany oczekują na synchronizację." : "Changes pending sync."))
                }
                if state != nil, !model.hasError { status(projection.status) }
                ForEach(projection.sections) { section in
                    Text(section.day == projection.today ? (polish ? "Dzisiaj" : "Today") : section.day)
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(section.checks) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { openPlant(item.plantId) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).font(.headline)
                                    Text(item.followUp ? (polish ? "Kontrola pierwszej pomocy" : "First aid follow-up")
                                         : (polish ? "Sprawdź podłoże" : "Check soil"))
                                    Text(item.due)
                                }
                            }
                            if item.source.isVerifiedLink {
                                Link(item.source.locator, destination: item.source.url)
                            }
                        }
                    }
                }
                if let state {
                    ForEach(state.plants.filter { $0.cardLinkAvailable && $0.manualJournalAvailable }, id: \.card.id) { plant in
                        Button { openPlant(plant.card.id) } label: {
                            Text((plant.card.personalName ?? plant.card.speciesSlug ?? (polish ? "Roślina" : "Plant"))
                                 + (polish ? " — karta i dziennik" : " — card and journal"))
                        }
                    }
                }
                Button(polish ? "Spróbuj ponownie" : "Refresh care", action: retry)
                    .accessibilityIdentifier("today.retry")
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task(id: ClockRead(scope: model.scope, deadline: boundary)) {
            let scope = model.scope
            let deadline = boundary
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, model.scope == scope else { return }
            clock = Date()
            localBoundary() // synchronous invalidation; Root owns the independent read
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            clock = Date(); localBoundary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            clock = Date(); localBoundary()
        }
    }

    @ViewBuilder private func status(_ status: TodayCalendar.Status) -> some View {
        switch status {
        case .empty: Text(polish ? "Nie masz jeszcze roślin." : "You haven’t saved any plants yet.")
        case .noSchedule: Text(polish ? "Brak zaplanowanych kontroli." : "No scheduled checks.")
        case .paused: Text(polish ? "Automatyczna opieka jest wstrzymana." : "Automatic care is paused.")
        case .unknown: Text(polish ? "Dostęp do opieki nie jest potwierdzony." : "Care access is not confirmed.")
        case .unavailable: Text(polish ? "Harmonogram wymaga odświeżenia." : "Schedule needs revalidation.")
        case .pending, .scheduled: EmptyView()
        }
    }
}
