import SwiftUI

@main
struct freeTubeApp: App {
    @AppStorage(ChannelPlayback.overlapKey) private var overlap = ChannelPlayback.defaultOverlap
    @AppStorage(ChannelPlayback.softFadeKey) private var softFade = true
    @State private var account = ChannelAccount()
    @State private var viewing = RoomViewingSession()
    @State private var playlists = RoomPlaylistStore()
    @State private var helper = RoomAIHelper()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ChannelHomeView(account: account, onPlay: viewing.open)
                .environment(viewing)
                .environment(account)
                .environment(playlists)
                .environment(helper)
                .onChange(of: overlap, initial: true) { _, seconds in
                    viewing.playback.configureOverlap(seconds: seconds)
                }
                .onChange(of: softFade, initial: true) { _, enabled in
                    viewing.playback.configureSoftFade(enabled, next: viewing.next)
                }
                .onChange(of: phase) { _, phase in
                    if phase == .background { helper.stop() }
                    if phase == .active, helper.pairedName != nil { helper.start() }
                }
                .preferredColorScheme(.dark)
                .onChange(of: account.sessionID) { _, _ in viewing.close() }
        }
    }
}
