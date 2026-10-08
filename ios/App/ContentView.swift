import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .input: InputView()
                case .summary: SummaryView()
                case .review: ReviewView()
                case .destination: DestinationView()
                case .spotify: SpotifyView()
                case .done: DoneView()
                case .demus: DemusView()
                }
            }
            .navigationTitle("Playlist Importer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.step != .input {
                    ToolbarItem(placement: .topBarLeading) { Button("Ricomincia") { model.reset() } }
                }
            }
            .alert("Errore", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.error ?? "") }
        }
    }
}

/// Paste or import a .txt, then ANALIZZA.
struct InputView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false

    var body: some View {
        VStack(spacing: 16) {
            TextEditor(text: $model.text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Artista - Titolo\nun brano per riga").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("\(model.lineCount) brani").font(.headline)
                Spacer()
                Menu("Importa") {
                    Button("File .txt…") { importing = true }
                    Button("Playlist rock/metal (165)") { model.loadBundledPlaylist() }
                }
            }
            if !model.invalid.isEmpty {
                Text("Righe non valide (manca \" - \"): " + model.invalid.map { "\($0.lineNumber)" }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.busy {
                ProgressView(value: Double(model.progress), total: Double(max(model.lineCount, 1)))
                Text("Cerco \(model.progress) / \(model.lineCount)…").font(.footnote).foregroundStyle(.secondary)
            } else {
                BigButton(model.spotify.isLoggedIn ? "ANALIZZA" : "ACCEDI A SPOTIFY E ANALIZZA") {
                    Task { await model.analyze() }
                }
                .disabled(model.lineCount == 0)
            }
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { model.text = text }
        }
    }
}

struct SummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("\(model.items.count) brani").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 10) {
                let found = model.count(.found), verify = model.count(.verify), missing = model.count(.missing)
                Label("\(found) \(found == 1 ? "trovato" : "trovati")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("\(verify) da verificare", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Label("\(missing) non \(missing == 1 ? "trovato" : "trovati")", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            .font(.title3)
            Spacer()
            BigButton("CONTINUA") { model.next() }
        }
        .padding()
    }
}

/// One card per song to check: suggested versions, manual search, or skip.
struct ReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(model.pending) { item in
                ReviewCard(item: item)
            }
            if model.pending.isEmpty {
                Text("Tutto verificato.").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // on an opaque bar, so it never covers the last card
            VStack(spacing: 6) {
                if !model.pending.isEmpty {
                    Text("Scegli una versione o salta: \(model.pending.count) da sistemare")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                BigButton("CONTINUA") { model.next() }.disabled(!model.pending.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }
}

struct ReviewCard: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.Item
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(item.status == .missing ? "Non trovato" : "Da verificare",
                  systemImage: item.status == .missing ? "xmark.circle" : "exclamationmark.triangle")
                .font(.caption.bold()).foregroundStyle(item.status == .missing ? .red : .orange)
            Text(item.line.artist).font(.headline)
            Text(item.line.title).foregroundStyle(.secondary)
            ForEach(options, id: \.id) { track in
                Button { model.choose(track, for: item) } label: {
                    VStack(alignment: .leading) {
                        Text(track.label)
                        Text(track.album).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("Cerca manualmente", text: $query).textFieldStyle(.roundedBorder).submitLabel(.search)
                    .onSubmit { search() }
                Button { search() } label: { searching ? AnyView(ProgressView()) : AnyView(Image(systemName: "magnifyingglass")) }
                    .disabled(query.isEmpty || searching)
            }
            Button("Salta questo brano", role: .destructive) { model.skip(item) }.font(.footnote)
        }
        .padding(.vertical, 6)
        .onAppear { if query.isEmpty { query = "\(item.line.artist) \(Matcher.baseTitle(item.line.title))" } }
    }

    /// Suggested versions first, then manual search results, each track once.
    private var options: [Track] {
        var seen = Set<String>()
        return (item.alternatives + results).filter { seen.insert($0.id).inserted }
    }

    private func search() {
        searching = true
        Task {
            results = await model.manualSearch(query)
            searching = false
        }
    }
}

struct DestinationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("\(model.readyTracks.count) / \(model.items.count) brani pronti").font(.title2.bold())
            Text("Dove vuoi creare la playlist?").foregroundStyle(.secondary)
            Spacer()
            BigButton("SPOTIFY") { model.step = .spotify }
            BigButton("DEMUS", secondary: true) { model.step = .demus }
        }
        .padding()
    }
}

struct SpotifyView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("\(model.readyTracks.count) / \(model.items.count) brani pronti").font(.title2.bold())
            TextField("Nome playlist", text: $model.playlistName)
                .textFieldStyle(.roundedBorder).font(.title3).textInputAutocapitalization(.characters)
            Spacer()
            if model.busy { ProgressView("Creo la playlist…") } else {
                BigButton("CREA PLAYLIST") { Task { await model.createPlaylist() } }
                    .disabled(model.readyTracks.isEmpty || model.playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

struct DoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Playlist creata.").font(.title.bold())
            Text("\(model.createdCount) brani").foregroundStyle(.secondary)
            Spacer()
            BigButton("APRI SPOTIFY") { model.openInSpotify() }
            if let url = model.created?.url {
                ShareLink("Condividi link (anche per Demus)", item: url)
            }
        }
        .padding()
    }
}

/// Demus has no documented import or API: the list in order, ready to copy, share or save as .txt.
struct DemusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Demus non ha un'importazione automatica documentata. Copia l'elenco e cerca i brani in Demus nell'ordine; se hai già creato la playlist Spotify, puoi provare a incollarne il link in Demus.")
                .font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                Text(model.demusText).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            BigButton(copied ? "COPIATO ✓" : "COPIA ELENCO") {
                UIPasteboard.general.string = model.demusText
                copied = true
            }
            ShareLink(item: model.demusText) { Label("Condividi o salva come testo", systemImage: "square.and.arrow.up") }
                .frame(maxWidth: .infinity)
        }
        .padding()
    }
}

struct BigButton: View {
    let title: String
    var secondary = false
    let action: () -> Void

    init(_ title: String, secondary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.secondary = secondary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(secondary ? .gray : .accentColor)
    }
}
