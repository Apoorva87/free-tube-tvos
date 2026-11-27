import Observation
import SwiftUI

struct RoomInterestRow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let query: String
    var enabled: Bool

    var isCustom: Bool { id.hasPrefix("custom-") }
}

@MainActor @Observable
final class RoomDiscoverPreferences {
    private static let key = "room.discover.rows.v1"
    private let defaults: UserDefaults
    private(set) var rows: [RoomInterestRow] {
        didSet {
            if let data = try? JSONEncoder().encode(rows) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    convenience init() {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["CHANNELROOM_DISCOVER_DEFAULTS_SUITE"],
           !suite.isEmpty, let defaults = UserDefaults(suiteName: suite) {
            self.init(defaults: defaults)
            return
        }
        #endif
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RoomInterestRow].self, from: data) {
            rows = saved
        } else {
            rows = [
                RoomInterestRow(id: "education", title: "Education", query: "education science history lectures explained", enabled: true),
                RoomInterestRow(id: "economics", title: "Economics", query: "economics explained macroeconomics economic policy", enabled: true),
                RoomInterestRow(id: "health", title: "Health", query: "public health medical research explained", enabled: true),
                RoomInterestRow(id: "trending-hindi", title: "Trending Hindi songs", query: "trending Hindi songs Bollywood official music video", enabled: true),
                RoomInterestRow(id: "trending-english", title: "Trending English songs", query: "trending English pop songs official music video", enabled: true),
                RoomInterestRow(id: "personal", title: "Personal recommendations", query: "", enabled: false),
                RoomInterestRow(id: "channels", title: "From your subscriptions", query: "", enabled: false)
            ]
        }
    }

    func toggle(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].enabled.toggle()
    }

    func move(_ id: String, by step: Int) {
        guard [-1, 1].contains(step), let index = rows.firstIndex(where: { $0.id == id }),
              rows.indices.contains(index + step) else { return }
        rows.swapAt(index, index + step)
    }

    func addTopic(_ text: String) {
        let topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        rows.append(RoomInterestRow(id: "custom-" + UUID().uuidString, title: topic, query: topic, enabled: true))
    }

    func remove(_ id: String) {
        rows.removeAll { $0.id == id && $0.isCustom }
    }
}

struct RoomDiscoverSettings: View {
    let preferences: RoomDiscoverPreferences
    let focus: FocusState<RoomBrowseFocus?>.Binding
    @AppStorage(ChannelPlayback.softFadeKey) private var softFade = true
    @State private var addingTopic = false
    @State private var topic = ""

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                RoomShelfTitle(title: "Playback")
                Toggle("Soft Fade", isOn: $softFade)
                    .focused(focus, equals: .settingsFirst)
                    .accessibilityIdentifier("settings.softFade")
                Text("Overlap the next video’s audio briefly during the fade.")
                    .font(.system(size: 24)).foregroundStyle(RoomPalette.muted)
                    .padding(.bottom, 10)
                RoomShelfTitle(title: "Discover rows")
                Text("Choose which rows appear in For you and the order they appear.")
                    .font(.system(size: 24)).foregroundStyle(RoomPalette.muted)
                Button {
                    topic = ""
                    addingTopic = true
                } label: {
                    Label("Add topic", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.addTopic")
                .padding(.bottom, 12)

                ForEach(preferences.rows) { row in
                    HStack(spacing: 14) {
                        Button { preferences.toggle(row.id) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: row.enabled ? "checkmark.circle.fill" : "circle")
                                Text(row.title).lineLimit(1)
                                Spacer()
                                Text(row.enabled ? "On" : "Off").fontWeight(.regular)
                            }
                        }
                        .accessibilityLabel(row.title)
                        .accessibilityValue(row.enabled ? "On" : "Off")
                        .accessibilityIdentifier("settings.toggle." + row.id)

                        rowAction(row, action: "up", label: "Move up", icon: "arrow.up") {
                            preferences.move(row.id, by: -1)
                        }.disabled(row.id == preferences.rows.first?.id)
                        rowAction(row, action: "down", label: "Move down", icon: "arrow.down") {
                            preferences.move(row.id, by: 1)
                        }.disabled(row.id == preferences.rows.last?.id)
                        if row.isCustom {
                            rowAction(row, action: "remove", label: "Remove", icon: "trash") {
                                preferences.remove(row.id)
                            }
                        } else {
                            Color.clear.frame(width: 60, height: 1).accessibilityHidden(true)
                        }
                    }
                }
            }
            .buttonStyle(RoomToolbarStyle())
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: 1140, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $addingTopic) {
            VStack(alignment: .leading, spacing: 26) {
                RoomHeading(title: "Add topic", subtitle: "For you will show videos matching this topic.")
                TextField("Topic name", text: $topic).accessibilityIdentifier("settings.topicName")
                HStack(spacing: 20) {
                    Button("Add topic") {
                        preferences.addTopic(topic)
                        addingTopic = false
                    }
                    .accessibilityIdentifier("settings.saveTopic")
                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { addingTopic = false }
                }
            }.frame(maxWidth: 950).padding(50)
        }
    }

    private func rowAction(_ row: RoomInterestRow, action: String, label: String, icon: String,
                           perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: icon) }
            .accessibilityLabel(label + " " + row.title)
            .accessibilityIdentifier("settings." + action + "." + row.id)
    }
}
