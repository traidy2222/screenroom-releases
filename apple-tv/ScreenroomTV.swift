import SwiftUI
import AVKit

struct TVEpisode: Codable, Identifiable {
    var id: String
    var title: String?
    var season: Int?
    var episode: Int?
}
struct TVItem: Codable, Identifiable {
    var id: String
    var type: String
    var name: String
    var description: String?
    var poster: String?
    var url: String?
    var attribution: String?
    var videos: [TVEpisode]?
    var isEpisode: Bool?
    var key: String { type + ":" + id }
}
struct TVCatalog: Codable { var id: String; var type: String; var searchable: Bool }
struct TVAddon: Codable, Identifiable {
    var id: String
    var name: String
    var url: String
    var resources: [String]
    var catalogs: [TVCatalog]
}
struct TVHistory: Codable, Identifiable {
    var item: TVItem
    var position: Double
    var duration: Double
    var completed: Bool
    var updatedAt: Date
    var id: String { item.key }
}
struct TVSnapshot: Codable { var revision = 0; var addons: [TVAddon] = []; var history: [TVHistory] = [] }
struct TVStream: Identifiable {
    var id: String { url.absoluteString }
    var label: String
    var url: URL
    var rank: Int
}
enum TVFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum TVNetwork {
    static func safeURL(_ text: String) throws -> URL {
        guard let u = URL(string: text), u.scheme == "https", u.user == nil, u.password == nil,
              u.port == nil || u.port == 443, let host = u.host, host.contains("."),
              host.range(of: #"^(localhost|\d|\[)|\.(local|internal|invalid|test)$"#, options: .regularExpression) == nil
        else { throw TVFailure.message("Use a public HTTPS address.") }
        return u
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 9
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
    static func json(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: safeURL(url.absoluteString))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304 else {
            throw TVFailure.message("Provider returned an unavailable or oversized response.")
        }
        return data
    }
    static func endpoint(_ addon: TVAddon, resource: String, type: String, id: String, search: String? = nil) throws -> URL {
        guard var c = URLComponents(url: try safeURL(addon.url), resolvingAgainstBaseURL: false) else { throw TVFailure.message("Invalid add-on.") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        c.percentEncodedPath = c.percentEncodedPath.replacingOccurrences(of: "/manifest.json", with: "") + "/" + resource + "/" + enc(type) + "/" + enc(id) + (search.map { "/search=" + enc($0) } ?? "") + ".json"
        guard let url = c.url else { throw TVFailure.message("Invalid add-on endpoint.") }
        return url
    }
    static func review(_ text: String) async throws -> TVAddon {
        var components = URLComponents(url: try safeURL(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "stremio://", with: "https://")), resolvingAgainstBaseURL: false)!
        if !components.path.hasSuffix("/manifest.json") { components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json"; if !components.path.hasPrefix("/") { components.path = "/" + components.path } }
        guard let u = components.url,
              let raw = try JSONSerialization.jsonObject(with: await json(u)) as? [String: Any],
              let id = raw["id"] as? String, let name = raw["name"] as? String,
              let resources = raw["resources"] as? [Any], raw["types"] is [String] else { throw TVFailure.message("Unsupported add-on manifest.") }
        if (raw["behaviorHints"] as? [String: Any])?["configurationRequired"] as? Bool == true { throw TVFailure.message("Configure this add-on on its website first.") }
        let names = resources.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["name"] as? String }
        let catalogs = (raw["catalogs"] as? [[String: Any]] ?? []).prefix(20).compactMap { row -> TVCatalog? in
            guard let id = row["id"] as? String, let type = row["type"] as? String, ["movie", "series"].contains(type) else { return nil }
            let extras = row["extra"] as? [Any] ?? []
            return TVCatalog(id: id, type: type, searchable: extras.contains { ($0 as? String == "search") || (($0 as? [String: Any])?["name"] as? String == "search") })
        }
        return TVAddon(id: id, name: name, url: u.absoluteString, resources: names, catalogs: catalogs)
    }
}

@MainActor final class TVStore: ObservableObject {
    @Published var state = TVSnapshot()
    @Published var titles: [TVItem] = []
    @Published var status = "Open films and your chosen add-ons."
    private var films: [TVItem] = []
    private var generation = 0
    init() {
        let decoder = JSONDecoder()
        let snapshots = (0...1).compactMap { UserDefaults.standard.data(forKey: "screenroom.public.tv.\($0)") }.compactMap { try? decoder.decode(TVSnapshot.self, from: $0) }
        if let latest = snapshots.max(by: { $0.revision < $1.revision }) { state = latest }
        if let file = Bundle.main.url(forResource: "open-films", withExtension: "json"), let data = try? Data(contentsOf: file) { films = (try? decoder.decode([TVItem].self, from: data)) ?? [] }
        titles = films
    }
    func persist() {
        var next = state; next.revision += 1
        do {
            let data = try JSONEncoder().encode(next)
            UserDefaults.standard.set(data, forKey: "screenroom.public.tv.\(next.revision % 2)")
            state = next
        } catch { status = "Could not encode saved progress: \(error.localizedDescription)" }
    }
    func install(_ addon: TVAddon) {
        state.addons.removeAll { $0.id == addon.id }; state.addons.append(addon); persist()
    }
    func remove(_ id: String) { state.addons.removeAll { $0.id == id }; persist() }
    func progress(_ item: TVItem) -> TVHistory? { state.history.first { $0.id == item.key } }
    func record(_ item: TVItem, position: Double, duration: Double, ended: Bool = false) {
        guard position.isFinite, duration.isFinite, duration > 0, position > 0 else { return }
        state.history.removeAll { $0.id == item.key }
        state.history.insert(TVHistory(item: item, position: min(position, duration), duration: duration, completed: ended || position / duration >= 0.95, updatedAt: Date()), at: 0)
        if state.history.count > 500 { state.history = Array(state.history.prefix(500)) }
        persist()
    }
    func refresh(search: String? = nil) async {
        generation += 1; let owner = generation
        titles = films.filter { search == nil || $0.name.localizedCaseInsensitiveContains(search!) }
        status = "Loading your add-on catalogues…"
        var all = titles; var seen = Set(all.map(\.key)); var failures = 0
        let connections = Array(state.addons.prefix(12))
        for addon in connections {
            for c in addon.catalogs.prefix(4) where search == nil || c.searchable {
                guard owner == generation, !Task.isCancelled else { return }
                do {
                    let data = try await TVNetwork.json(TVNetwork.endpoint(addon, resource: "catalog", type: c.type, id: c.id, search: search))
                    struct CatalogResponse: Decodable { var metas: [TVItem] }
                    let result = try JSONDecoder().decode(CatalogResponse.self, from: data)
                    for item in result.metas.prefix(100) where !seen.contains(item.key) { seen.insert(item.key); all.append(item) }
                    guard owner == generation else { return }; titles = Array(all.prefix(300))
                } catch { failures += 1 }
            }
        }
        guard owner == generation else { return }
        status = failures > 0 ? "Some providers could not load. Showing available titles." : "\(titles.count) titles · Progress stays on this Apple TV."
    }
    func episodes(_ item: TVItem) async throws -> [TVItem] {
        var videos = item.videos ?? []
        if videos.isEmpty {
            for addon in state.addons where addon.resources.contains("meta") {
                if let data = try? await TVNetwork.json(TVNetwork.endpoint(addon, resource: "meta", type: item.type, id: item.id)) {
                    struct MetaResponse: Decodable { var meta: TVItem }
                    if let meta = try? JSONDecoder().decode(MetaResponse.self, from: data) { videos = meta.meta.videos ?? []; if !videos.isEmpty { break } }
                }
            }
        }
        return videos.filter { ($0.episode ?? 0) > 0 }.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }.map { episode in
            TVItem(id: episode.id, type: "series", name: "\(item.name) · S\(episode.season ?? 0) E\(episode.episode ?? 0)", isEpisode: true)
        }
    }
    func streams(_ item: TVItem) async throws -> [TVStream] {
        if let url = item.url { return [TVStream(label: "Blender open film", url: try TVNetwork.safeURL(url), rank: 100)] }
        var found: [TVStream] = []
        for addon in state.addons where addon.resources.contains("stream") {
            do {
                let data = try await TVNetwork.json(TVNetwork.endpoint(addon, resource: "stream", type: item.type, id: item.id))
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                for stream in (raw?["streams"] as? [[String: Any]] ?? []).prefix(50) {
                    guard stream["infoHash"] == nil, stream["drm"] == nil, stream["externalUrl"] == nil,
                          (stream["behaviorHints"] as? [String: Any])?["proxyHeaders"] == nil,
                          let text = stream["url"] as? String, let url = try? TVNetwork.safeURL(text) else { continue }
                    let label = "\(addon.name) · \(stream["name"] as? String ?? stream["title"] as? String ?? "HTTPS stream")"
                    if label.range(of: "2160|4K", options: [.regularExpression, .caseInsensitive]) != nil { continue }
                    let quality = label.contains("1080") ? 1080 : label.contains("720") ? 720 : 0
                    let english = ["en", "eng", "english"].contains((stream["language"] as? String ?? "").lowercased())
                    found.append(TVStream(label: label, url: url, rank: quality + (english ? 10_000 : 0)))
                }
            } catch { continue }
        }
        return found.sorted { $0.rank > $1.rank }
    }
}

@MainActor final class PlaybackSession: ObservableObject {
    let player: AVPlayer
    private var observer: Any?
    private var finished: NSObjectProtocol?
    let store: TVStore
    let item: TVItem
    init(store: TVStore, item: TVItem, stream: TVStream) {
        self.store = store; self.item = item; self.player = AVPlayer(url: stream.url)
        if let saved = store.progress(item), !saved.completed { player.seek(to: CMTime(seconds: saved.position, preferredTimescale: 600)) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.save() } }
        finished = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.save(ended: true) } }
    }
    func save(ended: Bool = false) { store.record(item, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0, ended: ended) }
    func close() { save(); player.pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil }; if let finished { NotificationCenter.default.removeObserver(finished); self.finished = nil } }
}
struct PlayerScreen: View {
    @StateObject private var session: PlaybackSession
    @Environment(\.scenePhase) private var scenePhase
    init(store: TVStore, item: TVItem, stream: TVStream) { _session = StateObject(wrappedValue: PlaybackSession(store: store, item: item, stream: stream)) }
    var body: some View {
        VideoPlayer(player: session.player).ignoresSafeArea().onAppear { session.player.play() }.onDisappear { session.close() }.onChange(of: scenePhase) { phase in if phase != .active { session.save(); session.player.pause() } }
    }
}
struct PlaybackChoice: Identifiable { let id = UUID(); var item: TVItem; var stream: TVStream }
struct TitleScreen: View {
    @EnvironmentObject var store: TVStore
    let item: TVItem
    @State private var episodes: [TVItem] = []
    @State private var streams: [TVStream] = []
    @State private var message = "Finding compatible sources…"
    @State private var choice: PlaybackChoice?
    var body: some View {
        List {
            Text(item.name).font(.title)
            if let description = item.description { Text(description).foregroundStyle(.secondary) }
            if let attribution = item.attribution { Text(attribution).font(.caption) }
            ForEach(episodes, id: \.key) { episode in NavigationLink(episode.name) { TitleScreen(item: episode) } }
            ForEach(streams) { stream in Button(stream.label) { choice = PlaybackChoice(item: item, stream: stream) } }
            Text(message).foregroundStyle(.secondary)
        }.task {
            do {
                if item.type == "series" && item.isEpisode != true { episodes = try await store.episodes(item); message = episodes.isEmpty ? "No episodes found. Install a compatible metadata add-on." : "Choose an episode." }
                else { streams = try await store.streams(item); message = streams.isEmpty ? "No compatible HTTPS source. Install a streaming add-on; metadata does not provide playback." : "Choose a source. Native player controls offer available audio and subtitle tracks." }
            } catch { message = error.localizedDescription }
        }.fullScreenCover(item: $choice) { choice in PlayerScreen(store: store, item: choice.item, stream: choice.stream) }
    }
}
struct CatalogScreen: View {
    @EnvironmentObject var store: TVStore
    @State private var search = ""
    var body: some View {
        NavigationStack { List {
            TextField("Search installed catalogues", text: $search).onSubmit { Task { await store.refresh(search: search.isEmpty ? nil : search) } }
            Text(store.status).foregroundStyle(.secondary)
            ForEach(store.titles, id: \.key) { item in NavigationLink(item.name) { TitleScreen(item: item) } }
        }.navigationTitle("Screenroom").task { await store.refresh() } }
    }
}
struct AddonsScreen: View {
    @EnvironmentObject var store: TVStore
    @State private var address = ""
    @State private var pending: TVAddon?
    @State private var message = "Connections go directly from this Apple TV. Install only providers you trust."
    @State private var reviewing = false
    var body: some View {
        NavigationStack { List {
            Text(message)
            TextField("HTTPS manifest.json link", text: $address).textContentType(.URL).autocorrectionDisabled()
            Button(reviewing ? "Checking…" : "Review add-on") { reviewing = true; Task { do { pending = try await TVNetwork.review(address) } catch { message = error.localizedDescription }; reviewing = false } }.disabled(reviewing)
            if let addon = pending {
                Text("\(addon.name) · \(URL(string: addon.url)?.host ?? "") receives your IP address, searches and requested title IDs. Access rights are not included.")
                Button("Trust and install") { store.install(addon); pending = nil; address = ""; message = "Installed. Return Home to load the catalogue." }
                Button("Cancel") { pending = nil }
            }
            ForEach(store.state.addons) { addon in Section(addon.name) { Button("Remove add-on") { store.remove(addon.id) } } }
        }.navigationTitle("Your add-ons") }
    }
}
@main struct ScreenroomTVApp: App {
    @StateObject private var store = TVStore()
    var body: some Scene {
        WindowGroup { TabView {
            CatalogScreen().tabItem { Label("Home", systemImage: "house") }
            NavigationStack { List(store.state.history) { h in NavigationLink(h.item.name + (h.completed ? " · Watched" : " · Resume \(Int(h.position / 60)) min")) { TitleScreen(item: h.item) } }.navigationTitle("Continue watching") }.tabItem { Label("Continue watching", systemImage: "play.circle") }
            AddonsScreen().tabItem { Label("Add-ons", systemImage: "plus.app") }
        }.environmentObject(store).preferredColorScheme(.dark) }
    }
}
