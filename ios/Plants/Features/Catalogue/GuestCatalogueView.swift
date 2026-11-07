import Supabase
import SwiftUI

@MainActor
@Observable
final class CatalogueConnection {
    let client: SupabaseClient?
    private var pending: Task<UUID, Error>?

    init() {
        client = (try? NativeAuthConfiguration()).map {
            SupabaseClient(supabaseURL: $0.supabaseURL, supabaseKey: $0.supabasePublishableKey)
        }
    }

    func sessionOwner() async throws -> UUID {
        guard let client else { throw NativeAuthFailure.configurationMissing }
        if let pending { return try await pending.value }
        let task = Task {
            do {
                return try await client.auth.session.user.id
            } catch AuthError.sessionMissing {
                return try await client.auth.signInAnonymously().user.id
            }
        }
        pending = task
        defer { pending = nil }
        return try await task.value
    }
}

private struct SpeciesCard: Decodable, Identifiable {
    struct Description: Decodable {
        let text: String
        let attribution: String?
        let source_url: URL?
    }

    struct Photo: Decodable {
        let download_url: URL?
        let source_page: URL?
        let attribution: String?
    }

    let plant_id: String
    let display_name: String
    let scientific_name: String
    let description: Description?
    let hero_image: Photo?
    var id: String { plant_id }
}

private struct SpeciesPage: Decodable {
    let items: [SpeciesCard]
}

struct GuestCatalogueView: View {
    let connection: CatalogueConnection
    let polish: Bool
    let back: () -> Void
    @State private var cards: [SpeciesCard] = []
    @State private var selected: SpeciesCard?
    @State private var ownerKey: String?
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack {
            if loading {
                ProgressView()
            } else if failed {
                Text(polish ? "Nie udało się pobrać katalogu." : "Couldn’t load the catalogue.")
                Button(polish ? "Spróbuj ponownie" : "Try again") { retry += 1 }
            } else if let card = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.display_name).font(.title)
                        Text(card.scientific_name).italic()
                            .accessibilityIdentifier("catalogue.selected.scientific")
                        if let photo = card.hero_image, let url = photo.download_url {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFit()
                            } placeholder: { Color.clear }
                            .frame(maxHeight: 240)
                            if let source = photo.source_page, let credit = photo.attribution {
                                Link(credit, destination: source).font(.caption)
                            }
                        }
                        if let description = card.description {
                            Text(description.text)
                            if let source = description.source_url {
                                Link(description.attribution ?? (polish ? "Źródło" : "Source"), destination: source)
                                    .font(.caption)
                            }
                        }
                    }.padding()
                }
                Button(polish ? "Wybierz inny gatunek" : "Choose another species") {
                    if let ownerKey { UserDefaults.standard.removeObject(forKey: ownerKey) }
                    selected = nil
                }.accessibilityIdentifier("catalogue.change")
            } else {
                TextField(polish ? "Szukaj gatunku" : "Search species", text: $query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal)
                List(cards.filter { query.isEmpty || ($0.scientific_name + " " + $0.display_name).localizedStandardContains(query) }) { card in
                    Button {
                        if let ownerKey { UserDefaults.standard.set(card.id, forKey: ownerKey) }
                        selected = card
                    } label: {
                        VStack(alignment: .leading) {
                            Text(card.display_name)
                            Text(card.scientific_name).font(.caption)
                        }
                    }.accessibilityIdentifier("catalogue.species." + card.id)
                }
            }
            Button(polish ? "Wstecz" : "Back", action: back)
        }
        .task(id: "\(polish)-\(retry)") {
            loading = true
            failed = false
            do {
                let owner = try await connection.sessionOwner()
                guard let client = connection.client else { throw NativeAuthFailure.configurationMissing }
                let page: SpeciesPage = try await client.rpc("search_catalogue_species", params: ["p_locale": polish ? "pl" : "en"]).execute().value
                try Task.checkCancellation()
                let key = "catalogue.selection." + owner.uuidString
                ownerKey = key
                cards = page.items
                selected = cards.first { $0.id == UserDefaults.standard.string(forKey: key) }
            } catch {
                if Task.isCancelled { return }
                failed = true
            }
            loading = false
        }
    }
}
