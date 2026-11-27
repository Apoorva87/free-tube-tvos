import SwiftUI

struct RoomSubscriptionsView: View {
    let library: ChannelLibrary
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    let openChannel: (RoomChannel) -> Void
    let findChannels: () -> Void
    @State private var selectedID: String?
    @State private var showingFilters = true

    private var channel: RoomChannel? { library.channels.first { $0.id == selectedID } }

    private struct Shelf: Identifiable {
        let title: String
        let videos: [ChannelVideo]
        var portrait = false
        var id: String { title }
    }

    private var rows: [Shelf] {
        let scoped = library.videos.filter { selectedID == nil || $0.channelID == selectedID }
        let shorts = scoped.filter { library.videoFacts[$0.id]?.short == true }
        let uploads = scoped.filter { library.videoFacts[$0.id]?.short != true }
        var rows = [Shelf]()
        if selectedID == nil {
            var creators = Set<String>()
            let highlights = Array(uploads.filter { creators.insert($0.channelID).inserted }.prefix(10))
            let ids = Set(highlights.map(\.id))
            if !highlights.isEmpty { rows.append(Shelf(title: "Most relevant", videos: highlights)) }
            if !shorts.isEmpty { rows.append(Shelf(title: "Shorts", videos: shorts, portrait: true)) }
            let recent = uploads.filter { !ids.contains($0.id) }
            if !recent.isEmpty { rows.append(Shelf(title: "Recently uploaded", videos: recent)) }
        } else {
            if !uploads.isEmpty { rows.append(Shelf(title: "Videos", videos: uploads)) }
            if !shorts.isEmpty { rows.append(Shelf(title: "Shorts", videos: shorts, portrait: true)) }
        }
        return rows
    }

    var body: some View {
        let feed = rows
        HStack(alignment: .top, spacing: showingFilters ? 32 : 0) {
            if showingFilters {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        filter(nil, firstVideo: feed.first?.videos.first)
                        ForEach(library.channels) { filter($0, firstVideo: feed.first?.videos.first) }
                    }
                }
                .scrollIndicators(.hidden).focusSection().frame(width: 390)
                Divider().overlay(Color.white.opacity(0.14))
            }
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        if feed.isEmpty {
                            if library.isLoading { RoomLoading(text: "Loading subscriptions…") }
                            else if let warning = library.warning { RoomNotice(message: warning) }
                            else { Text("No uploads available").foregroundStyle(RoomPalette.muted) }
                        }
                        ForEach(feed) { row in
                            VStack(alignment: .leading, spacing: 14) {
                                RoomShelfTitle(title: row.title)
                                RoomVideoShelf(videos: row.videos, focus: focus, portrait: row.portrait,
                                               columns: showingFilters ? 3 : 5, openMenu: returnToFilters) {
                                    play($0, row.videos)
                                }
                            }.id(row.id)
                        }
                        if let channel {
                            Button("View channel") { openChannel(channel) }.buttonStyle(RoomToolbarStyle())
                        } else if library.channels.isEmpty && !library.isLoading {
                            Button("Find a channel", action: findChannels).buttonStyle(RoomToolbarStyle())
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 8)
                }
                .scrollClipDisabled()
                .onChange(of: selectedID) { _, _ in
                    if let first = feed.first { reader.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        .modifier(SubscriptionFocus(focus: focus, selectedID: $selectedID, showingFilters: $showingFilters))
        .onChange(of: library.followed) { _, followed in
            if let selectedID, !followed.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func filter(_ item: RoomChannel?, firstVideo: ChannelVideo?) -> some View {
        Button {
            selectedID = item?.id
            if let firstVideo { focus.wrappedValue = .video(firstVideo.id) }
        } label: {
            HStack(spacing: 18) {
                if let item { RoomAvatar(channel: item, symbol: "person.fill", size: 49) }
                else { Image(systemName: "list.bullet").frame(width: 49) }
                Text(item?.title ?? "All").font(.system(size: 27, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).frame(height: 70)
        }
        .buttonStyle(SubscriptionFilterStyle(selected: selectedID == item?.id))
        .focused(focus, equals: .subscriptionFilter(item?.id))
        .accessibilityIdentifier("filter-" + (item?.id ?? "all"))
    }

    private func returnToFilters() {
        showingFilters = true
        Task { @MainActor in
            await Task.yield()
            focus.wrappedValue = .subscriptionFilter(selectedID)
        }
    }
}

// Observe remote focus outside the feed builder so moving between videos doesn't regroup the library.
private struct SubscriptionFocus: ViewModifier {
    let focus: FocusState<RoomBrowseFocus?>.Binding
    @Binding var selectedID: String?
    @Binding var showingFilters: Bool

    func body(content: Content) -> some View {
        content.onChange(of: focus.wrappedValue) { _, target in
            switch target {
            case .subscriptionFilter(let id):
                if selectedID != id { selectedID = id }
                if !showingFilters { showingFilters = true }
            case .video:
                if showingFilters { showingFilters = false }
            default: break
            }
        }
    }
}

private struct SubscriptionFilterStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(focused ? .black : .white)
            .background(focused ? .white : (selected ? RoomPalette.surface : .clear),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}
