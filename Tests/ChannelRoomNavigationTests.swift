import XCTest
import UIKit

@MainActor
final class ChannelRoomNavigationTests: XCTestCase {
    func testProfileDownReachesHomeAndHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        let profile = app.buttons["account"]
        XCTAssertTrue(profile.waitForExistence(timeout: 6))
        XCTAssertTrue(focusWithRemote(profile, in: app))
        for id in ["nav-home", "nav-channels", "nav-playlists", "nav-history"] {
            remote.press(.down)
            XCTAssertTrue(app.buttons[id].hasFocus, "Expected focus on \(id)")
        }
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 6))
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'"))
        XCTAssertTrue(app.buttons["history-browse"].exists || tiles.count > 0)
    }

    func testCompactProfileMovesDownToHomeAndSubscriptions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-playlists"], in: app)
        let create = app.buttons["playlist-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 6))
        XCTAssertTrue(focusWithRemote(create, in: app))
        remote.press(.left)
        let profile = app.buttons["show-menu"]
        for _ in 0..<7 where !profile.hasFocus { remote.press(.up) }
        XCTAssertTrue(profile.hasFocus)
        remote.press(.down)
        XCTAssertTrue(app.buttons["compact-home"].hasFocus)
        remote.press(.down)
        XCTAssertTrue(app.buttons["compact-channels"].hasFocus)
    }

    func testBackStopsPlaybackAndHistorySurvivesRelaunch() async throws {
        continueAfterFailure = false
        let app = try playSampleMovie()
        let remote = XCUIRemote.shared
        let videoID = "aqz-KE-bpKQ"
        let player = app.descendants(matching: .any)["native-playback"]
        try await Task.sleep(for: .seconds(3))
        remote.press(.menu)
        if !player.waitForNonExistence(timeout: 2) { remote.press(.menu) }
        if !player.waitForNonExistence(timeout: 4) {
            attachHierarchy(app, named: "Full screen after Back")
            XCTFail("Back should dismiss playback.")
            return
        }
        XCTAssertFalse(app.buttons["mini-expand"].exists)
        app.terminate()
        app.launch()
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-history"], in: app)
        let watched = app.buttons["video-" + videoID]
        XCTAssertTrue(watched.waitForExistence(timeout: 6))
        selectWithRemote(watched, in: app)
        XCTAssertTrue(player.waitForExistence(timeout: 30))
        selectTransportAction("Watch while browsing", in: app)
        let expand = app.buttons["mini-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 6))
        try await Task.sleep(for: .seconds(4))
        remote.press(.menu)
        selectWithRemote(app.buttons["drawer-mini-expand"], in: app)
        XCTAssertTrue(player.waitForExistence(timeout: 6))
        XCTAssertFalse(expand.exists)
        let elapsed = app.descendants(matching: .any)["AXElapsedTime"]
        if !elapsed.exists { remote.press(.up) }
        XCTAssertTrue(elapsed.waitForExistence(timeout: 4))
        let seconds = elapsed.label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        XCTAssertGreaterThanOrEqual(seconds, 4, "The video should keep playing while minimized.")
    }

    func testVideoTalkUsesTheRemoteTextField() throws {
        continueAfterFailure = false
        let app = try playSampleMovie()
        selectTransportAction("Ask AI", in: app)
        let field = app.textFields["video-talk-prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["video-talk-send"].isEnabled)
        selectWithRemote(field, in: app)
        app.typeText("What is happening in this video?")
        if app.keyboards.firstMatch.exists { XCUIRemote.shared.press(.menu) }
        XCTAssertTrue(field.value as? String == "What is happening in this video?")
        XCTAssertTrue(app.buttons["video-talk-tools"].exists)
        if app.buttons["Connect or check helper"].exists {
            selectWithRemote(app.buttons["video-talk-send"], in: app)
            XCTAssertTrue(app.staticTexts["Laptop helper"].waitForExistence(timeout: 6))
        }
    }

    func testVideoTalkSendWithMissingCaptionsFocusesTheNextAction() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FREETUBE_EMPTY_TALK_TEST"] == "1",
                          "Requires an empty paired helper with a permitted sample caption fixture.")
        continueAfterFailure = false
        let app = try playSampleMovie()
        selectTransportAction("Ask AI", in: app)
        let field = app.textFields["video-talk-prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        selectWithRemote(field, in: app)
        app.typeText("What signal marks the crossing?")
        if app.keyboards.firstMatch.exists { XCUIRemote.shared.press(.menu) }
        let send = app.buttons["video-talk-send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        selectWithRemote(send, in: app)
        let captions = app.buttons["video-public-captions"]
        XCTAssertTrue(captions.waitForExistence(timeout: 20))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: captions)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 6), .completed,
                       "Send should reveal and focus the caption choice for the current question.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["video-talk-stop"].waitForExistence(timeout: 160))
        XCTAssertTrue(app.descendants(matching: .any)["video-talk-citation"].exists)
    }

    func testPairedVideoTalkReadsTwoCitedReplies() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FREETUBE_LIVE_TALK_TEST"] == "1",
                          "Requires a paired test helper with permitted captions for the sample movie.")
        continueAfterFailure = false
        let app = try playSampleMovie()
        selectTransportAction("Ask AI", in: app)
        let field = app.textFields["video-talk-prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let stop = app.buttons["video-talk-stop"]
        let replay = app.buttons["video-talk-replay"]
        let questions = ["What signal marks the crossing?", "What does it tell the crew?"]
        for (index, question) in questions.enumerated() {
            selectWithRemote(field, in: app)
            app.typeText(question)
            if index == 0 {
                app.typeText("\n")
            } else {
                // tvOS places its submit button beside the keyboard in a separate window.
                let keyboardSend = app.buttons.matching(NSPredicate(
                    format: "label ==[c] 'Send' AND identifier != %@", "video-talk-send"
                )).firstMatch
                XCTAssertTrue(keyboardSend.waitForExistence(timeout: 5))
                selectWithRemote(keyboardSend, in: app)
            }
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                      object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 6), .completed,
                           "The keyboard must dismiss so the player can show progress and replies.")
            XCTAssertTrue(stop.waitForExistence(timeout: 160), "The validated answer should automatically start reading.")
            XCTAssertTrue(app.staticTexts[question].exists)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "video-talk-citation").count > 0)
            XCTAssertTrue(replay.waitForExistence(timeout: 90), "The system speech synthesizer should finish the answer.")
        }
        XCTAssertTrue(app.staticTexts["What signal marks the crossing?"].exists)
        selectWithRemote(replay, in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        selectWithRemote(stop, in: app)
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
    }

    func testPlaylistThumbnailTilesNavigateAndReorderWithRemote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let playlistID = UUID()
        let titles = ["KV cache basics", "Memory bandwidth", "Paged attention"]
        let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange]
        let videos: [[String: Any]] = titles.enumerated().map { index, title in
            let bounds = CGRect(x: 0, y: 0, width: 16, height: 9)
            let artwork = UIGraphicsImageRenderer(bounds: bounds).pngData { context in
                colors[index].setFill()
                context.fill(bounds)
            }
            return ["id": "sampleTile0" + String(index), "title": title, "channelID": "sample-channel",
             "channelTitle": "Systems Lab", "publishedAt": Date(), "durationSeconds": 150 + index,
             "thumbnail": ["relative": "data:image/png;base64," + artwork.base64EncodedString()]]
        }
        let archive: [String: Any] = ["version": 1, "playlists": [
            ["id": playlistID.uuidString, "title": "Systems playlist", "videos": videos]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        // NSArgumentDomain supplies this archive for this launch only.
        app.launchArguments = ["-room.playlists.v1", "<" + data.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-playlists"], in: app)
        let cover = app.descendants(matching: .any)["playlist-" + playlistID.uuidString]
        XCTAssertTrue(cover.waitForExistence(timeout: 6))
        selectWithRemote(cover, in: app)
        let first = app.buttons["video-sampleTile00"], second = app.buttons["video-sampleTile01"]
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 5)
        XCTAssertLessThan(first.frame.maxX, second.frame.minX)
        XCTAssertTrue(focusWithRemote(first, in: app))
        remote.press(.right)
        XCTAssertTrue(second.hasFocus)
        capture("Playlist thumbnail tiles")
        selectWithRemote(app.buttons["Edit playlist"], in: app)
        let editable = app.descendants(matching: .any)["playlist-edit-sampleTile01"]
        XCTAssertTrue(editable.waitForExistence(timeout: 6))
        selectWithRemote(editable, in: app)
        let earlier = element(labeled: "Move earlier", in: app)
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        selectWithRemote(earlier, in: app)
        let previous = app.descendants(matching: .any)["playlist-edit-sampleTile00"]
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editable.frame.midX < previous.frame.midX
        }, object: nil)
        if XCTWaiter.wait(for: [reordered], timeout: 5) != .completed {
            attachHierarchy(app, named: "Playlist order after moving earlier")
            XCTFail("The second video should occupy the first tile.")
        }
        selectWithRemote(app.buttons["Cancel"], in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        XCTAssertLessThan(first.frame.midX, second.frame.midX)
    }

    func testPlaylistEditorAndAskAIAreReachableWithTheRemote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        remote.press(.menu)
        let playlists = app.buttons["nav-playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 8))
        selectWithRemote(playlists, in: app)
        let create = app.buttons["playlist-new"]
        XCTAssertTrue(create.waitForExistence(timeout: 6))
        selectWithRemote(create, in: app)
        XCTAssertTrue(app.textFields["playlist-name"].waitForExistence(timeout: 6))
        selectWithRemote(app.buttons["Cancel"], in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 6))
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-assistant"], in: app)
        let send = app.buttons["assistant-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 6))
        XCTAssertTrue(app.textFields["assistant-prompt"].exists)
        XCTAssertTrue(app.buttons["assistant-research"].exists)
        XCTAssertFalse(send.isEnabled)
        let find = app.buttons["Find videos"]
        XCTAssertTrue(find.exists)
        XCTAssertTrue(app.buttons["Build playlist"].exists)
        XCTAssertFalse(find.isEnabled)
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        let ask = app.buttons["search-ask-ai"]
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        selectWithRemote(ask, in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["assistant-prompt"].exists)
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(app.buttons["Build playlist"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    func testBackOpensNavigationAndRightRestoresTheTile() throws {
        let app = XCUIApplication()
        app.launch()
        let videos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-' OR identifier BEGINSWITH 'discovery-'"))
        guard videos.firstMatch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires a TV with at least one followed channel and a loaded upload.")
        }
        capture("ChannelRoom Home")
        let remote = XCUIRemote.shared
        let focusedVideos = videos.matching(NSPredicate(format: "hasFocus == true"))
        for _ in 0..<4 where !focusedVideos.firstMatch.exists { remote.press(.down) }
        XCTAssertTrue(focusedVideos.firstMatch.exists)
        remote.press(.right)
        let selected = focusedVideos.firstMatch.identifier
        XCTAssertFalse(selected.isEmpty)
        capture("ChannelRoom browsing")
        let home = app.buttons["nav-home"]
        XCTAssertFalse(home.exists)
        remote.press(.menu)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.hasFocus)
        capture("ChannelRoom navigation")
        remote.press(.right)
        let restored = app.buttons[selected]
        let focus = NSPredicate(format: "hasFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focus, object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertFalse(home.exists)
    }

    func testRecommendationOpensPlayerWithoutFollowing() throws {
        let app = XCUIApplication()
        app.launch()
        let picks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-'"))
        guard picks.firstMatch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires recommendations on the signed-in TV.")
        }
        let focused = picks.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<5 where !focused.exists { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(focused.exists)
        XCUIRemote.shared.press(.select)
        let player = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["playing-title", "native-playback"]))
        XCTAssertTrue(player.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCUIRemote.shared.press(.menu)
    }

    func testRemoteMovesAcrossAndBetweenDiscoveryShelves() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-'"))
        let watch = app.buttons["featured-watch"]
        guard watch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires a Home video on the signed-in TV.")
        }
        let remote = XCUIRemote.shared
        guard focusWithRemote(watch, in: app) else { return }
        remote.press(.down)
        guard tiles.firstMatch.waitForExistence(timeout: 30) else {
            attachHierarchy(app, named: "Discovery rows unavailable")
            throw XCTSkip("The current Home feed has no loaded recommendation tiles.")
        }
        // Recommendations can arrive after focus has landed on a subscription.
        // Start the directional checks from the same place in either case.
        guard focusWithRemote(watch, in: app) else { return }
        remote.press(.down)
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists)
        let first = focused.identifier
        XCTAssertTrue(first.hasPrefix("discovery-discover-"))
        remote.press(.right)
        let neighbor = focused.identifier
        XCTAssertTrue(neighbor.hasPrefix("discovery-discover-"))
        XCTAssertNotEqual(neighbor, first)
        remote.press(.left)
        XCTAssertEqual(focused.identifier, first)
        remote.press(.down)
        let creator = focused.identifier
        XCTAssertTrue(creator.hasPrefix("discovery-explore-"))
        capture("Creators to explore with remote focus")
        remote.press(.right)
        XCTAssertTrue(focused.identifier.hasPrefix("discovery-explore-"))
        XCTAssertNotEqual(focused.identifier, creator)
        remote.press(.left)
        XCTAssertEqual(focused.identifier, creator)
        remote.press(.up)
        XCTAssertEqual(focused.identifier, first)
    }

    func testMoviePlaybackSpeedChoicesWithTheRemote() throws {
        continueAfterFailure = false
        let app = try playFeaturedMovie()
        selectTransportAction("Playback Speed", in: app)
        for speed in ["1.5×", "2×"] {
            let choice = element(labeled: speed, in: app)
            XCTAssertTrue(choice.waitForExistence(timeout: 4), "Missing speed option \(speed)")
            selectWithRemote(choice, in: app)
            XCTAssertTrue(app.descendants(matching: .any)["native-playback"].exists)
            selectTransportAction("Playback Speed", in: app)
            let selected = app.cells.matching(NSPredicate(
                format: "(label ==[c] %@ AND selected == true) OR label ==[c] %@", speed, "selected, \(speed)"
            )).firstMatch
            attachHierarchy(app, named: "Speed menu after selecting \(speed)")
            XCTAssertTrue(selected.exists, "AVKit did not mark \(speed) as the selected rate")
        }
    }

    func testMovieKeepsPlayingWhileBrowsingAndSearching() async throws {
        continueAfterFailure = false
        let app = try playFeaturedMovie()
        let remote = XCUIRemote.shared
        selectTransportAction("Watch while browsing", in: app)
        let expand = app.buttons["mini-expand"]
        let close = app.buttons["mini-close"]
        XCTAssertTrue(expand.waitForExistence(timeout: 6))
        XCTAssertTrue(close.exists)
        capture("Enlarged mini-player on Home")
        remote.press(.menu)
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        selectWithRemote(app.buttons["nav-search"], in: app)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.exists)
        selectWithRemote(field, in: app)
        app.typeText("@BlenderOfficial\n")
        let blender = app.buttons["Blender"]
        XCTAssertTrue(blender.waitForExistence(timeout: 20), "The channel search did not return Blender")
        // Return submits the search, but tvOS keeps its fullscreen text editor
        // in front of the results until the viewer presses Back.
        remote.press(.menu)
        guard focusWithRemote(blender, in: app) else { return }
        XCTAssertTrue(expand.exists)
        let miniFrame = app.descendants(matching: .any)["native-playback"].frame
        let screen = try XCTUnwrap(app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width < $1.width })
        XCTAssertEqual(miniFrame.width / screen.width, 1.0 / 3.0, accuracy: 0.04)
        XCTAssertGreaterThan(miniFrame.midX, screen.midX)
        XCTAssertGreaterThan(miniFrame.midY, screen.midY)
        capture("Search results with mini-player frame one")
        try await Task.sleep(for: .seconds(4))
        XCTAssertTrue(expand.exists)
        capture("Search results with mini-player frame two")

        remote.press(.menu)
        let restore = app.buttons["drawer-mini-expand"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        selectWithRemote(restore, in: app)
        let player = app.descendants(matching: .any)["native-playback"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        // The first Back press can dismiss AVKit's transport controls.
        remote.press(.menu)
        if !player.waitForNonExistence(timeout: 2) { remote.press(.menu) }
        XCTAssertTrue(player.waitForNonExistence(timeout: 5), "Back should close the full-screen player.")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Back should return to Search.")
        XCTAssertTrue(field.isEnabled)
        XCTAssertFalse(expand.exists, "Back should stop playback without opening the mini-player.")
        XCTAssertFalse(close.exists)
        remote.press(.menu)
        XCTAssertTrue(app.buttons["nav-search"].waitForExistence(timeout: 5))
        XCTAssertFalse(restore.exists)
        XCTAssertFalse(app.buttons["drawer-mini-close"].exists)
    }

    func testSubscriptionsFiltersAndVideoFocus() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["featured-watch"].waitForExistence(timeout: 45))
        let remote = XCUIRemote.shared
        remote.press(.menu)
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        remote.press(.down)
        XCTAssertTrue(app.buttons["nav-channels"].hasFocus)
        remote.press(.select)
        let all = app.buttons["filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 8))
        let relevant = app.staticTexts["Most relevant"]
        XCTAssertTrue(relevant.waitForExistence(timeout: 10))
        remote.press(.down)
        let activeChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filter-UC' AND hasFocus == true")).firstMatch
        XCTAssertTrue(activeChannel.exists)
        remote.press(.up)
        XCTAssertTrue(all.hasFocus)
        capture("ChannelRoom subscriptions")
        remote.press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-' AND hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 8))
        XCTAssertFalse(all.exists)
    }

    func testHomeVideoOpensAPlayerOnTheTV() async throws {
        let app = XCUIApplication()
        app.launch()
        let watch = app.buttons["featured-watch"]
        guard watch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires a Home video on the signed-in TV.")
        }
        let remote = XCUIRemote.shared
        selectWithRemote(watch, in: app)

        let nativePlayer = app.descendants(matching: .any)["native-playback"]
        let openYouTube = app.buttons["youtube-playback"]
        let deadline = ContinuousClock.now + .seconds(28)
        while !nativePlayer.exists && !openYouTube.exists && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        if nativePlayer.exists {
            capture("ChannelRoom native Home frame one")
            try await Task.sleep(for: .seconds(4))
            XCTAssertTrue(nativePlayer.exists)
            capture("ChannelRoom native Home frame two")
            return
        }

        XCTAssertTrue(openYouTube.exists)
        XCTAssertTrue(openYouTube.hasFocus)
        capture("ChannelRoom actual playback choice")
        remote.press(.select)
        let youtube = XCUIApplication(bundleIdentifier: "com.google.ios.youtube")
        if !youtube.wait(for: .runningForeground, timeout: 3) {
            // tvOS can ask the viewer to confirm the first handoff.
            let system = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
            guard system.buttons["Open"].exists || !app.buttons["youtube-playback"].hasFocus else {
                XCTFail("The selected video did not open in YouTube")
                return
            }
            remote.press(.select)
        }
        XCTAssertTrue(youtube.wait(for: .runningForeground, timeout: 10))
        capture("ChannelRoom actual handoff")
    }

    private func playSampleMovie() throws -> XCUIApplication {
        let app = XCUIApplication()
        let id = UUID()
        let videoID = "aqz-KE-bpKQ"
        let video: [String: Any] = ["id": videoID, "title": "Big Buck Bunny", "channelID": "UCSMOQeBJ2RAnuFungnQOxLg",
                                    "channelTitle": "Blender", "publishedAt": Date()]
        let archive: [String: Any] = ["version": 1, "playlists": [
            ["id": id.uuidString, "title": "Playback test", "videos": [video]]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        app.launchArguments = ["-room.playlists.v1", "<" + data.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-playlists"], in: app)
        selectWithRemote(app.descendants(matching: .any)["playlist-" + id.uuidString], in: app)
        selectWithRemote(app.buttons["Play all"], in: app)
        let player = app.descendants(matching: .any)["native-playback"]
        XCTAssertTrue(player.waitForExistence(timeout: 30), "Requires a playable public stream for Big Buck Bunny.")
        return app
    }

    private func playFeaturedMovie() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let watch = app.buttons["featured-watch"]
        guard watch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires a featured video on the signed-in TV.")
        }
        selectWithRemote(watch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["native-playback"].waitForExistence(timeout: 30),
                      "The featured video did not start in AVKit.")
        return app
    }

    private func element(labeled title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    private func selectTransportAction(_ title: String, in app: XCUIApplication) {
        let action = element(labeled: title, in: app)
        let remote = XCUIRemote.shared
        // tvOS puts the action cells in the accessibility tree even while the
        // transport bar is hidden. Up enters the transport controls.
        remote.press(.up)
        if !action.exists {
            // AVKit can collapse custom actions into More depending on space.
            let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'More'")).firstMatch
            if more.exists { selectWithRemote(more, in: app) }
        }
        guard action.waitForExistence(timeout: 3) else {
            attachHierarchy(app, named: "Missing transport action \(title)")
            XCTFail("AVKit did not reveal \(title).")
            return
        }
        selectWithRemote(action, in: app)
    }

    private func selectWithRemote(_ target: XCUIElement, in app: XCUIApplication) {
        guard focusWithRemote(target, in: app) else { return }
        XCUIRemote.shared.press(.select)
    }

    // Both cached Home content and AVKit menus can change the starting focus.
    private func focusWithRemote(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        if target.exists, target.hasFocus { return true }
        let remote = XCUIRemote.shared
        let focus = NSPredicate(format: "hasFocus == true")
        let focusedElements = app.descendants(matching: .any).matching(focus)
        let controls = focusedElements.matching(NSPredicate(format: "elementType IN %@",
            [XCUIElement.ElementType.button, .cell, .textField, .slider, .menuItem].map(\.rawValue)))
        for _ in 0..<10 {
            guard target.exists else { break }
            // Dismissing the system keyboard briefly leaves the app without a
            // focused element while tvOS returns focus to the text field.
            if !focusedElements.firstMatch.exists,
               !focusedElements.firstMatch.waitForExistence(timeout: 4) { break }
            let focused = controls.firstMatch.exists ? controls.firstMatch : focusedElements.firstMatch
            if target.hasFocus || (!target.label.isEmpty && target.label == focused.label) {
                return true
            }
            let source = focused.frame
            let destination = target.frame
            if source.contains(destination) && source.height > 2 * destination.height {
                remote.press(.up)
            } else if source.maxY <= destination.minY { remote.press(.down) }
            else if source.minY >= destination.maxY { remote.press(.up) }
            else if source.midX < destination.midX { remote.press(.right) }
            else { remote.press(.left) }
        }
        attachHierarchy(app, named: "Unreachable control")
        let current = focusedElements.firstMatch
        XCTFail("Could not focus \(target) with the remote. Current focus: \(current.exists ? current.debugDescription : "none")")
        return false
    }

    private func attachHierarchy(_ app: XCUIApplication, named name: String) {
        capture(name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
