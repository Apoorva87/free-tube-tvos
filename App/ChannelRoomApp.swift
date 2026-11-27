import AVFoundation
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
            ZStack(alignment: .bottomTrailing) {
                ChannelHomeView(account: account) { video, queue in
                    viewing.open(video, in: queue)
                }
                if viewing.presentation == .mini {
                    ChannelPlayerView(session: viewing, mini: true)
                        .frame(width: ChannelPlayerView.miniVideoWidth, height: ChannelPlayerView.miniHeight)
                        .padding(22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPlayPauseCommand(perform: viewing.presentation == .mini ? {
                let player = viewing.playback.player
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            } : nil)
            .fullScreenCover(isPresented: Binding(
                get: { viewing.presentation == .full },
                set: { if !$0, viewing.presentation == .full { viewing.close() } }
            )) {
                ChannelPlayerView(session: viewing, mini: false)
            }
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
