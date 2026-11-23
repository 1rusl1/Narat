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
    let needsRevalidation: Bool

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
        guard let state else {
            status = .unavailable; sections = []; needsRevalidation = false
            return
        }
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
        needsRevalidation = state.availability == .readOnly
            && (state.failure != nil || status != .unavailable)
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

    private var state: CareOverviewViewState? { visible && !unavailable ? model.state : nil }
    private var now: Date { max(clock, Date()) }
    private var boundary: Date {
        TodayCalendar.boundary(now: clock, deadline: state?.verifiedAccessUntil, timeZone: .current)
    }

    var body: some View {
        let projection = TodayCalendar(state: state, now: now, polish: polish)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(polish ? "Dzisiaj" : "Today").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("today.title")
                Button(action: collection) {
                    QuietGardenActionLabel(title: polish ? "Moje rośliny" : "My plants", symbol: "leaf")
                }
                    .accessibilityIdentifier("collection.open")
                Button(action: check) {
                    QuietGardenActionLabel(title: polish ? "Sprawdź roślinę" : "Check a plant", symbol: "camera")
                }
                    .buttonStyle(QuietGardenPrimaryButtonStyle())
                    .accessibilityIdentifier("welcome.check")
                Button(action: browse) {
                    QuietGardenActionLabel(title: polish ? "Dodaj / przeglądaj katalog" : "Add / browse catalogue", symbol: "books.vertical")
                }
                    .accessibilityIdentifier("welcome.catalogue")
                Button(action: identify) {
                    QuietGardenActionLabel(title: polish ? "Rozpoznaj roślinę" : "Identify a plant", symbol: "viewfinder")
                }
                    .accessibilityIdentifier("welcome.identify")
                if unavailable {
                    Text(polish ? "Opieka jest niedostępna." : "Care is unavailable.")
                        .qgNotice(.error)
                        .accessibilityIdentifier("today.failed")
                } else if model.hasError {
                    Text(polish ? "Nie udało się odświeżyć opieki." : "Couldn’t refresh care.")
                        .qgNotice(.error)
                        .accessibilityIdentifier("today.failed")
                } else if state == nil {
                    ProgressView(polish ? "Wczytywanie opieki…" : "Loading care…")
                }
                if model.refreshing { ProgressView(polish ? "Odświeżanie…" : "Refreshing…") }
                if state?.origin == .cache, state?.lastCheckedAt != nil {
                    Text(polish ? "Zapisana opieka." : "Saved care.").foregroundStyle(QuietGarden.secondaryText)
                        .qgNotice(.neutral)
                        .accessibilityIdentifier("today.cached")
                }
                if let checked = state?.lastCheckedAt {
                    lastChecked(checked)
                }
                if projection.needsRevalidation {
                    Text(polish ? "Harmonogram wymaga odświeżenia." : "Schedule needs revalidation.")
                        .qgNotice(.warning)
                        .accessibilityIdentifier("today.stale")
                }
                if let state, !state.pending.isEmpty {
                    Text(state.pending.contains { $0.status == .retryRequired }
                         ? (polish ? "Zmiany wymagają ponowienia." : "Saved changes need a retry.")
                         : (polish ? "Zmiany oczekują na synchronizację." : "Changes pending sync."))
                        .qgNotice(.warning)
                        .accessibilityIdentifier("today.pending")
                }
                if state != nil, !model.hasError,
                   !(projection.needsRevalidation && projection.status == .unavailable) {
                    status(projection.status)
                }
                ForEach(projection.sections) { section in
                    let kind = section.day == projection.today ? "today"
                        : (section.day < projection.today ? "overdue" : "future")
                    Text(section.day == projection.today ? (polish ? "Dzisiaj" : "Today")
                         : ((section.day < projection.today ? (polish ? "Zaległe" : "Overdue")
                             : (polish ? "Następna kontrola" : "Next check")) + " — " + section.day))
                        .qgSectionTitle()
                        .accessibilityIdentifier("today.section." + kind + "." + section.day)
                    ForEach(section.checks) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            Button { openPlant(item.plantId) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).font(.headline)
                                    Text(item.followUp ? (polish ? "Kontrola pierwszej pomocy" : "First aid follow-up")
                                         : (polish ? "Sprawdź podłoże" : "Check soil"))
                                    Text(item.due).font(.subheadline).foregroundStyle(QuietGarden.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("today.task." + item.id)
                            if item.source.isVerifiedLink {
                                Link(item.source.locator, destination: item.source.url)
                                    .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                            }
                        }
                        .qgCard()
                    }
                }
                if let state {
                    ForEach(state.plants.filter { $0.cardLinkAvailable && $0.manualJournalAvailable }, id: \.card.id) { plant in
                        Button { openPlant(plant.card.id) } label: {
                            Text((plant.card.personalName ?? plant.card.speciesSlug ?? (polish ? "Roślina" : "Plant"))
                                 + (polish ? " — karta i dziennik" : " — card and journal"))
                        }
                        .buttonStyle(QuietGardenSecondaryButtonStyle())
                        .accessibilityIdentifier("today.plant." + plant.card.id.uuidString.lowercased())
                    }
                }
                Button(polish ? "Spróbuj ponownie" : "Refresh care", action: retry)
                    .accessibilityIdentifier("today.retry")
            }
            .buttonStyle(QuietGardenSecondaryButtonStyle())
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .qgScreen()
        .accessibilityIdentifier("today.root")
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

    private func checkedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: polish ? "pl_PL" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return (polish ? "Ostatnio sprawdzono: " : "Last checked: ") + formatter.string(from: date)
    }

    private func lastChecked(_ date: Date) -> some View {
        let text = Text(checkedText(date)).foregroundStyle(QuietGarden.secondaryText)
            .accessibilityIdentifier("today.lastChecked")
        #if DEBUG
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return text.accessibilityValue(formatter.string(from: date))
        #else
        return text
        #endif
    }

    @ViewBuilder private func status(_ status: TodayCalendar.Status) -> some View {
        switch status {
        case .empty: Text(polish ? "Nie masz jeszcze roślin." : "You haven’t saved any plants yet.")
            .qgNotice(.neutral)
            .accessibilityIdentifier("today.empty")
        case .noSchedule: Text(polish ? "Brak zaplanowanych kontroli." : "No scheduled checks.")
            .qgNotice(.neutral)
            .accessibilityIdentifier("today.noSchedule")
        case .paused: Text(polish ? "Automatyczna opieka jest wstrzymana." : "Automatic care is paused.")
            .qgNotice(.warning)
            .accessibilityIdentifier("today.paused")
        case .unknown: Text(polish ? "Dostęp do opieki nie jest potwierdzony." : "Care access is not confirmed.")
            .qgNotice(.warning)
            .accessibilityIdentifier("today.unknown")
        case .unavailable: Text(polish ? "Harmonogram wymaga odświeżenia." : "Schedule needs revalidation.")
            .qgNotice(.warning)
            .accessibilityIdentifier("today.stale")
        case .pending, .scheduled: EmptyView()
        }
    }
}
