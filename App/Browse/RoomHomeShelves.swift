import SwiftUI

private struct VideoFactsKey: EnvironmentKey {
    static let defaultValue: [String: RoomVideoFacts] = [:]
}

extension EnvironmentValues {
    var roomVideoFacts: [String: RoomVideoFacts] {
        get { self[VideoFactsKey.self] }
        set { self[VideoFactsKey.self] = newValue }
    }
}

struct RoomHomeShelves: View {
    let library: ChannelLibrary
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    let discover: (ChannelVideo) -> Void
    let options: () -> Void
    let openMenu: () -> Void

    private struct Shelf: Identifiable {
        let id: String
        let title: String
        var detail: String? = nil
        var recommended = false
        var portrait = false
        let videos: [ChannelVideo]
    }

    private var shelves: [Shelf] {
        let rest = library.videos.dropFirst()
        let fullLength = rest.filter { library.videoFacts[$0.id]?.short != true }
        let latest = Array(fullLength.prefix(10))
        var rows = [Shelf]()
        if !library.discoveryTopics.isEmpty {
            let reason = library.discoveryTopics.count <= 2 ? "Based on " + library.discoveryTopics.joined(separator: " and ") :
                "Based on your subscription topics"
            rows.append(Shelf(id: "discover", title: "Recommended", detail: reason,
                              recommended: true, videos: library.discoveries))
        }
        if !library.creatorsToExplore.isEmpty {
            rows.append(Shelf(id: "explore", title: "Creators to explore", detail: "More channels covering your interests",
                              recommended: true, videos: library.creatorsToExplore))
        }
        if !latest.isEmpty {
            rows.append(Shelf(id: "latest", title: "Recently uploaded", detail: "From your subscriptions", videos: latest))
        }
        for topic in library.topicShelves {
            rows.append(Shelf(id: "topic-" + topic.id, title: topic.id, recommended: true, videos: topic.videos))
        }
        let shorts = rest.filter { library.videoFacts[$0.id]?.short == true }
        if !shorts.isEmpty { rows.append(Shelf(id: "shorts", title: "Shorts", detail: "From your subscriptions", portrait: true, videos: shorts)) }
        let remaining = Dictionary(grouping: fullLength.dropFirst(latest.count), by: \.channelID)
        let active = remaining.values.sorted { ($0.first?.publishedAt ?? .distantPast) > ($1.first?.publishedAt ?? .distantPast) }
        for videos in active.prefix(8) {
            guard let first = videos.first else { continue }
            rows.append(Shelf(id: first.channelID, title: first.channelTitle, videos: videos))
        }
        return rows
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 38) {
                if let feature = library.videos.first {
                    RoomFeaturedVideo(video: feature, owner: library.channels.first { $0.id == feature.channelID },
                                      focus: focus, watch: { play(feature, library.videos) }, options: options)
                        .focusSection()
                } else if library.isLoading {
                    RoomLoading(text: "Loading subscriptions…").padding(.vertical, 38)
                } else if library.warning == nil {
                    Text("No recent uploads").font(.title3)
                }
                if let warning = library.warning {
                    RoomNotice(message: warning).padding(.trailing, 28)
                }
                ForEach(shelves) { row in
                    VStack(alignment: .leading, spacing: 14) {
                        RoomShelfTitle(title: row.title, detail: row.detail)
                            .accessibilityIdentifier("shelf-" + row.id)
                        if row.videos.isEmpty {
                            if library.discoveryLoading { RoomLoading(text: "Finding videos…") }
                            else {
                                Text(library.discoveryFailed ? "Recommendations couldn’t load. Refresh Home to try again." :
                                        "No new channels matched these topics today.")
                                    .font(.system(size: 24)).foregroundStyle(RoomPalette.muted)
                            }
                        } else {
                            RoomVideoShelf(videos: row.videos, focus: focus, discoveryShelfID: row.recommended ? row.id : nil,
                                           portrait: row.portrait, openMenu: openMenu) { video in
                                if row.recommended { discover(video) } else { play(video, library.videos) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 7).padding(.bottom, 32)
        }
        .scrollClipDisabled()
        .onChange(of: library.videos.isEmpty) { _, empty in
            if !empty, focus.wrappedValue == nil || focus.wrappedValue == .menu { focus.wrappedValue = .featured }
        }
    }
}

struct RoomVideoShelf: View {
    let videos: [ChannelVideo]
    let focus: FocusState<RoomBrowseFocus?>.Binding
    var discoveryShelfID: String? = nil
    var portrait = false
    var columns = 5
    let openMenu: () -> Void
    let action: (ChannelVideo) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 22) {
                ForEach(videos) { video in
                    RoomVideoTile(video: video, focus: focus, discoveryShelfID: discoveryShelfID, portrait: portrait) { action(video) }
                        .containerRelativeFrame(.horizontal, count: typeSize.isAccessibilitySize ? min(3, columns) : columns, span: 1, spacing: 22)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .focusSection()
        .onMoveCommand { direction in
            if direction == .left, let first = videos.first,
               focus.wrappedValue == .video(first.id, in: discoveryShelfID) { openMenu() }
        }
    }
}

struct RoomAvatar: View {
    let channel: RoomChannel?
    let symbol: String
    let size: CGFloat
    var body: some View {
        RoomArtwork(url: channel?.thumbnail, placeholder: symbol)
            .frame(width: size, height: size).clipShape(Circle())
    }
}

private struct RoomFeaturedVideo: View {
    let video: ChannelVideo
    let owner: RoomChannel?
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let watch: () -> Void
    let options: () -> Void

    var body: some View {
        GeometryReader { bounds in
            ZStack(alignment: .bottomLeading) {
                RoomArtwork(url: video.coverThumbnail ?? video.thumbnail, placeholder: "play.rectangle")
                    .frame(width: bounds.size.width * 0.81, height: bounds.size.height)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .black, location: 0.32)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.22),
                                       .init(color: .black.opacity(0.43), location: 0.67),
                                       .init(color: RoomPalette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 14) {
                    RoomAvatar(channel: owner, symbol: "play.rectangle.fill", size: 58)
                    Text(video.title).font(.system(size: 46, weight: .bold)).tracking(-1.0)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Text(video.channelTitle).bold()
                        RoomVideoMetadata(video: video)
                    }
                    .font(.system(size: 24)).foregroundStyle(Color(white: 0.86))
                    HStack(spacing: 16) {
                        RoomPlayButton("Watch", action: watch)
                            .focused(focus, equals: .featured)
                            .accessibilityIdentifier("featured-watch")
                        Button(action: options) { Image(systemName: "ellipsis").rotationEffect(.degrees(90)) }
                            .buttonStyle(FeatureOptionsStyle()).accessibilityLabel("More options")
                    }.padding(.top, 9)
                }
                .frame(maxWidth: bounds.size.width * 0.68, alignment: .leading)
                .padding(.bottom, 16)
            }
        }
        .frame(height: 535)
        .padding(.trailing, -54)
    }
}

struct RoomPlayButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(decorative: "PlayMark")
                    .resizable().scaledToFit().frame(width: 50, height: 28)
                Text(title)
            }
            .padding(.horizontal, 23).frame(minHeight: 68)
        }
        .buttonStyle(RoomPlayButtonStyle())
        .accessibilityLabel(Text(title))
    }
}

private struct RoomPlayButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let colors = focused ? [Color.white, Color(white: 0.90)] : [Color(white: 0.23), Color(white: 0.12)]
        configuration.label
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(focused ? 0.95 : 0.23), lineWidth: focused ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.35), radius: focused ? 6 : 3, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : (focused ? 1.04 : 1)))
    }
}

private struct FeatureOptionsStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 26, weight: .semibold))
            .frame(minWidth: 68, minHeight: 68)
            .foregroundStyle(focused ? .black : .white)
            .background(focused ? Color.white : Color(white: 0.18), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct RoomVideoMetadata: View {
    let video: ChannelVideo
    @Environment(\.roomVideoFacts) private var facts
    var body: some View {
        let views = facts[video.id]?.views.map { $0.formatted(.number.notation(.compactName)) + " views" }
        let age: String? = video.publishedAt == .distantPast ? nil :
            video.publishedAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        Text([views, age].compactMap { $0 }.joined(separator: " • ")).lineLimit(1)
    }
}

struct RoomVideoTile: View {
    let video: ChannelVideo
    let focus: FocusState<RoomBrowseFocus?>.Binding
    var discoveryShelfID: String? = nil
    var portrait = false
    var position: Int? = nil
    var seconds: Int? = nil
    let action: () -> Void
    @State private var addingToPlaylist = false

    var body: some View {
        Button(action: action) {
            RoomVideoTileLabel(video: video, portrait: portrait, position: position, seconds: seconds)
        }
        .buttonStyle(VideoButtonStyle()).focused(focus, equals: .video(video.id, in: discoveryShelfID))
        .contextMenu {
            Button { addingToPlaylist = true } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
        }
        .sheet(isPresented: $addingToPlaylist) { RoomAddToPlaylistView(video: video, durationSeconds: seconds ?? video.durationSeconds) }
        .accessibilityIdentifier((discoveryShelfID.map { "discovery-" + $0 + "-" } ?? "video-") + video.id)
    }
}

struct RoomVideoTileLabel: View {
    let video: ChannelVideo
    var portrait = false
    var position: Int? = nil
    var seconds: Int? = nil
    @Environment(\.isFocused) private var selected
    @Environment(\.roomVideoFacts) private var facts
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let fact = facts[video.id]
            let duration = fact?.duration ?? (seconds ?? video.durationSeconds).map(RoomPlaylist.clock)
            RoomTileArtwork(url: video.thumbnail ?? video.coverThumbnail, placeholder: "play.rectangle",
                            portrait: portrait, position: position, duration: duration, live: fact?.live == true)
            Text(video.title).font(typeSize.isAccessibilitySize ? .headline : .system(size: 26, weight: .semibold))
                .foregroundStyle(selected ? .white : Color(white: 0.90))
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            Text(video.channelTitle).lineLimit(1).foregroundStyle(RoomPalette.muted)
            RoomVideoMetadata(video: video).foregroundStyle(RoomPalette.muted)
        }
        .font(typeSize.isAccessibilitySize ? .caption : .system(size: 21))
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5)
    }
}

struct RoomTileArtwork: View {
    let url: URL?
    let placeholder: String
    var portrait = false
    var position: Int? = nil
    var duration: String? = nil
    var live = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        Color.clear.aspectRatio(portrait ? 9.0 / 14.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay { RoomArtwork(url: url, placeholder: placeholder) }
            .overlay(alignment: .topLeading) {
                if let position {
                    badge(String(position)).accessibilityLabel("Position \(position)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if live { badge("LIVE", color: .red) }
                else if let duration { badge(duration) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 18).strokeBorder(.white, lineWidth: 5).padding(-5) }
            }
            .padding(.bottom, 7)
    }

    private func badge(_ text: String, color: Color = .black.opacity(0.84)) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            .monospacedDigit().padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4)).padding(7)
    }
}

struct VideoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}
