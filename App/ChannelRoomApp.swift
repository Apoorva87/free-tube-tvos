import AVFoundation
import SwiftUI

@main
struct ChannelRoomApp: App {
    @State private var account = ChannelAccount()
    @State private var viewing = RoomViewingSession()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottomTrailing) {
                ChannelHomeView(account: account) { video, queue in
                    viewing.open(video, in: queue)
                }
                .disabled(viewing.presentation == .full)
                .accessibilityHidden(viewing.presentation == .full)
                if viewing.presentation != .closed {
                    ChannelPlayerView(session: viewing)
                        .frame(width: viewing.presentation == .mini ? ChannelPlayerView.miniVideoWidth : nil,
                               height: viewing.presentation == .mini ? ChannelPlayerView.miniHeight : nil)
                        .padding(viewing.presentation == .mini ? 22 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPlayPauseCommand(perform: viewing.presentation == .mini ? {
                let player = viewing.playback.player
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            } : nil)
            .environment(viewing)
            .preferredColorScheme(.dark)
            .onChange(of: account.sessionID) { _, _ in viewing.close() }
        }
    }
}
