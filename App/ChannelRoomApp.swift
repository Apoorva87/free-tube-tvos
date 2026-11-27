import SwiftUI

@main
struct ChannelRoomApp: App {
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
                .onChange(of: phase) { _, phase in
                    if phase == .background { helper.stop() }
                    if phase == .active, helper.pairedName != nil { helper.start() }
                }
                .preferredColorScheme(.dark)
                .onChange(of: account.sessionID) { _, _ in viewing.close() }
        }
    }
}
