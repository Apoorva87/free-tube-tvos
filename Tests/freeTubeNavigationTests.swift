import CoreImage
import XCTest
import UIKit

@MainActor
final class freeTubeNavigationTests: XCTestCase {
    func testDiscoverOpensOnLaunchAndBrowsesMusicWithTheRemote() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let music = app.buttons["discover-category-music"]
        XCTAssertTrue(music.waitForExistence(timeout: 10), "Discover should be the opening screen.")
        for category in ["for-you", "explore", "gaming", "news", "sports", "live"] {
            XCTAssertTrue(app.buttons["discover-category-" + category].exists)
        }
        selectWithRemote(music, in: app)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 50), "Music should show videos from the public catalog.")
        let remote = XCUIRemote.shared
        remote.press(.down)
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let first = focused.identifier
        remote.press(.right)
        let selected = focused.identifier
        XCTAssertFalse(selected.isEmpty)
        XCTAssertNotEqual(first, selected)
        capture("Discover Music")
        remote.press(.menu)
        let discover = app.buttons["nav-discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(discover.hasFocus)
        remote.press(.right)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"),
                                                  object: app.buttons[selected])
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 6), .completed)
    }

    func testMusicShowsTwoRowsForARecentlyPlayedSong() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test seeds an isolated guest watch history.")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        let seed = "dQw4w9WgXcQ"
        let video: [String: Any] = ["id": seed, "title": "Never Gonna Give You Up",
                                    "channelTitle": "Rick Astley", "channelID": "UCuAXFkgsw1L7xaCfnd5JJOw",
                                    "publishedAt": Date()]
        let history = try PropertyListSerialization.data(fromPropertyList: [["owner": "guest", "video": video]],
                                                         format: .binary, options: 0)
        app.launchArguments = ["-room.watch-history.v1", "<" + history.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        selectWithRemote(app.buttons["discover-category-music"], in: app)
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-music-similar-'")).firstMatch
        let artists = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-music-discover-artists-'")).firstMatch
        XCTAssertTrue(similar.waitForExistence(timeout: 45))
        XCTAssertTrue(artists.waitForExistence(timeout: 8))
        XCTAssertNotEqual(similar.label, artists.label)
    }

    func testSearchOpensCreatorWithFourVideoShelves() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        selectWithRemote(app.textFields.firstMatch, in: app)
        app.typeText("@BlenderOfficial\n")
        let channel = app.buttons["Blender"]
        XCTAssertTrue(channel.waitForExistence(timeout: 30))
        remote.press(.menu)
        selectWithRemote(channel, in: app)
        XCTAssertTrue(app.staticTexts["Recent uploads"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Most viewed"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Under 10 minutes"].exists)
        XCTAssertTrue(app.staticTexts["20 minutes or more"].exists)
    }

    func testAudioOverlapDurationCanBeChangedInSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-settings"], in: app)
        let picker = app.descendants(matching: .any)["settings.overlap"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let choice = element(labeled: "2 s", in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        selectWithRemote(choice, in: app)
        XCTAssertTrue(app.staticTexts["The next song starts quietly with 2 seconds left in the current one."].waitForExistence(timeout: 5))
        selectWithRemote(element(labeled: "0.55 s", in: app), in: app)
    }

    func testSoftFadeSettingPersistsAcrossLaunches() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        func openSettings() -> XCUIElement {
            app.launch()
            remote.press(.menu)
            selectWithRemote(app.buttons["nav-settings"], in: app)
            let setting = app.descendants(matching: .any)["settings.softFade"].firstMatch
            XCTAssertTrue(setting.waitForExistence(timeout: 5))
            return setting
        }
        let setting = openSettings()
        let original = setting.value as? String
        XCTAssertNotNil(original)
        selectWithRemote(setting, in: app)
        let changed = setting.value as? String
        XCTAssertNotEqual(original, changed)
        app.terminate()
        let reopened = openSettings()
        XCTAssertEqual(reopened.value as? String, changed)
        selectWithRemote(reopened, in: app)
        XCTAssertEqual(reopened.value as? String, original)
    }

    func testForYouInterestRowsReflectSettingsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CHANNELROOM_DISCOVER_DEFAULTS_SUITE"] = "freeTube.UITests." + UUID().uuidString
        app.launch()
        let remote = XCUIRemote.shared
        let forYou = app.buttons["discover-category-for-you"]
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-'"))
        let education = tiles.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-education-'")).firstMatch
        let economics = tiles.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-economics-'")).firstMatch
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch

        func checkFirstRow(_ tile: XCUIElement, prefix: String) {
            XCTAssertTrue(forYou.waitForExistence(timeout: 10))
            XCTAssertTrue(forYou.isSelected, "Discover should open with For you selected.")
            XCTAssertTrue(tile.waitForExistence(timeout: 75), "Expected public videos for \(prefix).")
            XCTAssertTrue(focusWithRemote(forYou, in: app))
            remote.press(.down)
            XCTAssertTrue(focused.waitForExistence(timeout: 5))
            XCTAssertTrue(focused.identifier.hasPrefix(prefix), "First row focused \(focused.identifier)")
        }

        checkFirstRow(education, prefix: "discovery-education-")
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-settings"], in: app)
        let toggle = app.buttons["settings.toggle.education"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        selectWithRemote(toggle, in: app)
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-discover"], in: app)
        checkFirstRow(economics, prefix: "discovery-economics-")
        XCTAssertFalse(education.exists)

        app.terminate()
        app.launch()
        checkFirstRow(economics, prefix: "discovery-economics-")
        XCTAssertFalse(education.exists)
    }

    func testDiscoverBuildsPersonalRowsFromLocalFollows() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Supply local follows and opt into their two row groups for this launch.
        let channels = [
            ["id": "UCSMOQeBJ2RAnuFungnQOxLg", "title": "Blender", "topics": ["Animation"]],
            ["id": "UCLA_DiR1FfKNvjuUpBHmylQ", "title": "NASA", "topics": ["Spaceflight"]]
        ] as [[String: Any]]
        let rowIDs = ["education", "economics", "health", "trending-hindi", "trending-english", "personal", "channels"]
        let rows: [[String: Any]] = rowIDs.map { id in
            ["id": id, "title": id, "query": "", "enabled": id == "personal" || id == "channels"]
        }
        func launchData(_ items: [[String: Any]]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: items)
            return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
        }
        app.launchArguments = ["-ChannelRoom.LocalFollows.1", try launchData(channels),
                               "-room.discover.rows.v1", try launchData(rows)]
        app.launch()
        let recommended = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-for-you-'")).firstMatch
        let related = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-from-subscriptions-'")).firstMatch
        XCTAssertTrue(recommended.waitForExistence(timeout: 75), "A followed channel should produce personalized recommendations.")
        XCTAssertTrue(related.waitForExistence(timeout: 60), "A second row should show distinct recommendations.")
        let channelRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-channel-'"))
        for _ in 0..<5 where !channelRows.firstMatch.exists { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(channelRows.firstMatch.waitForExistence(timeout: 30), "Followed channels should have their own upload rows.")
        capture("Discover For you")
        selectWithRemote(recommended, in: app)
        let playing = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["playing-title", "native-playback"]))
        XCTAssertTrue(playing.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testSearchVideoSelectStartsPlaybackAndHoldOffersActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ChannelRoom.LocalFollows.1", "<5b5d>"]
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        selectWithRemote(app.textFields.firstMatch, in: app)
        app.typeText("Big Buck Bunny Blender\n")
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 40))
        remote.press(.menu)
        XCTAssertTrue(focusWithRemote(tile, in: app))
        remote.press(.select, forDuration: 1.2)
        XCTAssertTrue(element(labeled: "Add to playlist", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(labeled: "Follow channel on this TV", in: app).exists)
        remote.press(.menu)
        selectWithRemote(tile, in: app)
        let player = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["native-playback", "playing-title"]))
        XCTAssertTrue(player.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testDJStartsGulabiSadiAndSteersWhileItPlays() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        app.launch()
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-dj"], in: app)
        let field = app.textFields["dj-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        selectWithRemote(field, in: app)
        app.typeText("songs like Gulabi Sadi\n")

        let seedID = "B_6d3RBiEN0"
        let now = app.staticTexts["dj-now-" + seedID]
        let choice = app.buttons["discovery-dj-choices-" + seedID]
        let resolved = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
            ["dj-now-" + seedID, "discovery-dj-choices-" + seedID])).firstMatch
        XCTAssertTrue(resolved.waitForExistence(timeout: 45))
        remote.press(.menu) // Dismiss the system text editor.
        if !now.exists { selectWithRemote(choice, in: app) }
        XCTAssertTrue(now.waitForExistence(timeout: 12))
        let upcoming = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovery-dj-upcoming-'"))
        XCTAssertTrue(upcoming.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Now playing"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["dj-language"].label.contains("Marathi"))
        XCTAssertTrue(app.buttons["mini-expand"].exists)
        capture("DJ Mode - Gulabi Sadi and Marathi up next")

        let queuedID = upcoming.firstMatch.identifier
        selectWithRemote(app.buttons[queuedID], in: app)
        let remove = app.buttons["dj-remove-upcoming"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dj-play-next"].exists)
        XCTAssertEqual(app.buttons["dj-queue-end"].label, "Move to End of Queue")
        selectWithRemote(remove, in: app)
        XCTAssertTrue(app.buttons[queuedID].waitForNonExistence(timeout: 5))
        XCTAssertTrue(now.exists)

        selectWithRemote(field, in: app)
        app.typeText("more Marathi wedding songs\n")
        let direction = app.staticTexts["dj-direction"]
        let steered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ==[c] %@", "more Marathi wedding songs"),
                                                object: direction)
        XCTAssertEqual(XCTWaiter.wait(for: [steered], timeout: 55), .completed)
        remote.press(.menu)
        XCTAssertTrue(now.exists, "Steering should leave the current song playing.")
        XCTAssertTrue(upcoming.firstMatch.waitForExistence(timeout: 45))
        capture("DJ Mode - steering toward Marathi wedding songs")
    }

    func testSearchPlayInDJUsesTheExactSongImmediately() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        app.launch()
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        selectWithRemote(app.textFields.firstMatch, in: app)
        // Use the video's exact ID so changing text-search rankings don't choose the recording for this test.
        let seedID = "B_6d3RBiEN0"
        app.typeText(seedID + "\n")
        let tile = app.buttons["video-" + seedID]
        XCTAssertTrue(tile.waitForExistence(timeout: 45))
        remote.press(.menu)
        XCTAssertTrue(focusWithRemote(tile, in: app))
        remote.press(.select, forDuration: 1.2)
        let action = app.cells.containing(NSPredicate(format: "label == %@", "Play in DJ")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 6))
        for _ in 0..<6 where !action.hasFocus { remote.press(.down) }
        XCTAssertTrue(action.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["dj-now-" + seedID].waitForExistence(timeout: 12))
        XCTAssertTrue(app.textFields["dj-query"].exists)
        XCTAssertTrue(app.buttons["mini-expand"].exists)
        let transport = app.staticTexts["dj-playing-state"]
        let startedOrDeclined = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label IN %@", ["Now playing", "Playback unavailable"]), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [startedOrDeclined], timeout: 50), .completed)
        if transport.label == "Playback unavailable" {
            XCTAssertTrue(app.staticTexts["dj-playback-error"].exists)
            XCTAssertTrue(app.buttons["dj-retry"].exists)
        }
        XCTAssertTrue(app.staticTexts["dj-now-" + seedID].exists)
    }

    func testMiniPlayerSearchHoldQueuesAndVisitsCreator() throws {
        continueAfterFailure = false
        let app = try playSampleMovie(includingQueuePick: true)
        selectTransportAction("Watch while browsing", in: app)
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.buttons["mini-expand"].waitForExistence(timeout: 5))
        remote.press(.menu) // Leave the sample playlist detail.
        XCTAssertTrue(app.buttons["playlist-new"].waitForExistence(timeout: 5))
        remote.press(.menu) // Open the navigation drawer.
        selectWithRemote(app.buttons["nav-search"], in: app)
        selectWithRemote(app.textFields.firstMatch, in: app)
        app.typeText("Sintel Blender\n")
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 45))
        remote.press(.menu)
        XCTAssertTrue(focusWithRemote(tile, in: app))
        remote.press(.select, forDuration: 1.2)
        let quick = app.cells.containing(NSPredicate(format: "label == %@", "Add to Quick Playlist")).firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        XCTAssertTrue(element(labeled: "Add to playlist", in: app).exists)
        XCTAssertTrue(element(labeled: "Visit Creator", in: app).exists)
        selectWithRemote(quick, in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Queued ·'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(focusWithRemote(tile, in: app))
        remote.press(.select, forDuration: 1.2)
        let creator = app.cells.containing(NSPredicate(format: "label == %@", "Visit Creator")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 5))
        for _ in 0..<3 where !creator.hasFocus { remote.press(.down) }
        XCTAssertTrue(creator.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["player-creator-title"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["mini-expand"].exists)
    }

    func testRecentSearchCanBeReusedAndCleared() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        selectWithRemote(app.textFields.firstMatch, in: app)
        app.typeText("Solar eclipse\n")
        let recent = app.buttons["Solar eclipse"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        remote.press(.menu)
        selectWithRemote(app.buttons["Clear search"], in: app)
        XCTAssertFalse(app.buttons["Clear search"].exists)
        XCTAssertTrue(recent.exists)
        selectWithRemote(recent, in: app)
        XCTAssertTrue(app.buttons["Clear search"].waitForExistence(timeout: 3))
        selectWithRemote(app.buttons["Clear history"], in: app)
        XCTAssertFalse(recent.exists)
        XCTAssertFalse(app.buttons["Clear history"].exists)
    }

    func testProfileDownReachesHomeAndHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        let profile = app.buttons["account"]
        XCTAssertTrue(profile.waitForExistence(timeout: 6))
        XCTAssertTrue(focusWithRemote(profile, in: app))
        for id in ["nav-discover", "nav-home", "nav-channels", "nav-playlists", "nav-history"] {
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
        XCTAssertTrue(app.buttons["compact-discover"].hasFocus)
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

    func testPlayerOffersSaveAndMiniPlayerWithoutAskAI() throws {
        continueAfterFailure = false
        let app = try playSampleMovie()
        let remote = XCUIRemote.shared
        let player = app.descendants(matching: .any)["native-playback"]
        let save = transportAction("Add to playlist", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(player.cells["Ask AI"].exists, "Ask AI should be absent from the player transport controls.")
        selectWithRemote(save, in: app)
        let currentPlaylist = app.buttons["Playback test"]
        XCTAssertTrue(currentPlaylist.waitForExistence(timeout: 5))
        XCTAssertEqual(currentPlaylist.value as? String, "Already added")
        XCTAssertFalse(currentPlaylist.isEnabled)
        selectWithRemote(app.buttons["New playlist"], in: app)
        XCTAssertTrue(app.textFields["Playlist name"].waitForExistence(timeout: 5))
        selectWithRemote(app.buttons["Cancel"], in: app)
        XCTAssertTrue(currentPlaylist.waitForNonExistence(timeout: 5))

        selectTransportAction("Watch while browsing", in: app)
        let expand = app.buttons["mini-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 6))
        // Playback started in playlist details. Back returns to the library before opening the sidebar.
        let assistant = app.buttons["nav-assistant"]
        remote.press(.menu)
        if !assistant.waitForExistence(timeout: 2) { remote.press(.menu) }
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        selectWithRemote(assistant, in: app)
        XCTAssertTrue(app.textFields["assistant-prompt"].waitForExistence(timeout: 6))
        XCTAssertTrue(expand.exists)
        XCTAssertFalse(app.buttons["video-talk-start"].exists, "Sidebar Ask AI should not offer a shortcut for the playing video.")
        remote.press(.menu)
        selectWithRemote(app.buttons["drawer-mini-expand"], in: app)
        XCTAssertTrue(player.waitForExistence(timeout: 6))
        XCTAssertFalse(expand.exists)
    }

    func testPlayerDescriptionShowsPublishedTextAndBackRestoresPlayback() throws {
        continueAfterFailure = false
        let app = try playSampleMovie()
        selectTransportAction("Description", in: app)
        let panel = app.descendants(matching: .any)["player-panel-description"]
        XCTAssertTrue(panel.waitForExistence(timeout: 6))
        XCTAssertEqual(panel.staticTexts["player-panel-video-title"].label, "Big Buck Bunny")
        let body = panel.descendants(matching: .any)["player-description-text"]
        guard body.waitForExistence(timeout: 30) else {
            attachHierarchy(app, named: "Missing published description")
            XCTFail("Blender's public movie has a description. An empty or error state is a failure here.")
            return
        }
        let content = [body.label, body.value as? String ?? ""].joined(separator: " ")
        // Published phrases from separate paragraphs catch a truncated preview.
        XCTAssertTrue(content.localizedCaseInsensitiveContains("UHD High Frame rate version"))
        XCTAssertTrue(content.localizedCaseInsensitiveContains("Learn more about this UHD high frame-rate version"))
        XCTAssertGreaterThan(body.frame.height, 450, "The full description needs a visible reading area on TV.")
        XCTAssertGreaterThan(body.frame.width, 800)
        XCTAssertTrue(focusWithRemote(body, in: app), "The reader must accept remote scrolling.")
        capture("Published movie description")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["native-playback"].waitForExistence(timeout: 6))
        selectTransportAction("View creator", in: app)
        XCTAssertTrue(app.staticTexts["player-creator-title"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["player-creator-title"].label, "Blender")
    }

    func testPlayerCreatorCanFollowUnfollowAndPlayAnUpload() throws {
        continueAfterFailure = false
        let app = try playSampleMovie(requiringEmptyGuestLibrary: true)
        selectTransportAction("View creator", in: app)
        let creator = app.descendants(matching: .any)["player-panel-creator"]
        XCTAssertTrue(creator.waitForExistence(timeout: 6))
        XCTAssertEqual(creator.staticTexts["player-creator-title"].label, "Blender")
        let follow = creator.buttons["player-creator-follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 8))
        XCTAssertEqual(follow.label, "Follow on this TV")
        selectWithRemote(creator.buttons["player-creator-subscribe"], in: app)
        let subscription = app.descendants(matching: .any)["player-creator-subscribe-sheet"]
        XCTAssertTrue(subscription.waitForExistence(timeout: 6))
        let qrImage = try XCTUnwrap(CIImage(image: subscription.screenshot().image))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: qrImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(codes, ["https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg"])
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(subscription.waitForNonExistence(timeout: 5))
        XCTAssertTrue(follow.waitForExistence(timeout: 6))
        XCTAssertEqual(follow.label, "Follow on this TV")
        selectWithRemote(follow, in: app)
        XCTAssertTrue(follow.wait(for: \.label, toEqual: "Unfollow on this TV", timeout: 6))
        selectWithRemote(follow, in: app)
        XCTAssertTrue(follow.wait(for: \.label, toEqual: "Follow on this TV", timeout: 6))
        playPanelTile(in: creator, app: app)
        selectTransportAction("View creator", in: app)
        XCTAssertTrue(creator.waitForExistence(timeout: 6))
        XCTAssertEqual(creator.staticTexts["player-creator-title"].label, "Blender")
        XCTAssertEqual(creator.buttons["player-creator-follow"].label, "Follow on this TV")
    }

    func testPlayerMoreLikeThisPlaysSelectedTileWithoutFollowing() throws {
        continueAfterFailure = false
        let app = try playSampleMovie(requiringEmptyGuestLibrary: true)
        selectTransportAction("Show more options.", in: app)
        let similar = app.descendants(matching: .any)["player-panel-similar"]
        XCTAssertTrue(similar.waitForExistence(timeout: 6))
        XCTAssertTrue(similar.staticTexts["Similar videos"].exists)
        XCTAssertTrue(similar.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'")).firstMatch
            .waitForExistence(timeout: 45), "The public movie should have related results.")
        XCTAssertFalse(similar.buttons["video-aqz-KE-bpKQ"].exists)
        playPanelTile(in: similar, app: app)
        selectTransportAction("View creator", in: app)
        let follow = app.buttons["player-creator-follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 8))
        XCTAssertEqual(follow.label, "Follow on this TV", "Playing a recommendation must keep its creator unfollowed.")
    }

    func testNativePlayerOverlayReturnsToTheSameVideo() throws
    {
        continueAfterFailure = false
        let app = try playSampleMovie()
        // AVKit presents the same custom overlay for its swipe gesture and its transport button.
        selectTransportAction("Show more options.", in: app)
        let panel = app.descendants(matching: .any)["player-panel-similar"]
        XCTAssertTrue(panel.waitForExistence(timeout: 6))
        XCTAssertTrue(panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'")).firstMatch.waitForExistence(timeout: 30))
        let tiles = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'"))
        let first = tiles.element(boundBy: 0)
        XCTAssertTrue(focusWithRemote(first, in: app))
        XCTAssertTrue(panel.frame.contains(first.frame))
        capture("Bottom similar videos")
        XCUIRemote.shared.press(.right)
        let second = tiles.element(boundBy: 1)
        XCTAssertTrue(second.hasFocus)
        XCTAssertGreaterThan(second.frame.midX, first.frame.midX)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 40)
        XCTAssertGreaterThan(panel.frame.width, app.frame.width * 0.85)
        XCTAssertGreaterThan(panel.frame.minY, app.frame.height * 0.60)
        XCTAssertGreaterThan(panel.frame.height, app.frame.height * 0.22)
        let visible = Set(tiles.allElementsBoundByIndex.filter { panel.frame.contains($0.frame) }.map(\.identifier))
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<10 where visible.contains(focused.identifier) { XCUIRemote.shared.press(.right) }
        XCTAssertFalse(visible.contains(focused.identifier))
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        let add = element(labeled: "Add to playlist", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        let playlist = app.buttons["Playback test"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertTrue(playlist.isEnabled)
        selectWithRemote(playlist, in: app)
        XCTAssertTrue(playlist.waitForNonExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 6))
        selectTransportAction("Description", in: app)
        XCTAssertTrue(app.staticTexts["player-panel-video-title"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["player-panel-video-title"].label, "Big Buck Bunny")
    }

    private func playPanelTile(in panel: XCUIElement, app: XCUIApplication) {
        let tiles = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-'"))
        let tile = tiles.matching(NSPredicate(format: "identifier != 'video-aqz-KE-bpKQ'")).firstMatch
        guard tile.waitForExistence(timeout: 45) else {
            attachHierarchy(app, named: "Missing player panel results")
            XCTFail("The public video should have playable thumbnail results.")
            return
        }
        XCTAssertFalse(panel.descendants(matching: .any)["player-panel-error"].exists)
        XCTAssertTrue(focusWithRemote(tile, in: app))
        var chosenLabel = tile.label
        let artwork = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.hasThumbnailArtwork(tile.screenshot().image)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [artwork], timeout: 12), .completed, "The video tile should display thumbnail artwork.")
        capture("Player thumbnails for " + panel.identifier)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 6))
        let player = app.descendants(matching: .any)["native-playback"]
        let next = app.buttons["next-after-unavailable"]
        // A live recommendation can be withdrawn between listing and playback.
        for _ in 0..<3 {
            let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in player.exists || next.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 30), .completed)
            if player.exists { break }
            let unavailableTitle = app.staticTexts["playing-title"].label
            XCTAssertFalse(unavailableTitle.isEmpty)
            XCTAssertTrue(chosenLabel.contains(unavailableTitle))
            chosenLabel = next.value as? String ?? ""
            XCTAssertFalse(chosenLabel.isEmpty)
            selectWithRemote(next, in: app)
        }
        XCTAssertTrue(player.waitForExistence(timeout: 30), "A selected video from the real results should start in AVKit.")
        selectTransportAction("Description", in: app)
        let title = app.staticTexts["player-panel-video-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        XCTAssertFalse(title.label.isEmpty)
        XCTAssertNotEqual(title.label, "Big Buck Bunny")
        XCTAssertTrue(chosenLabel.contains(title.label), "The player should show the title the viewer selected.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }

    // Artwork is decorative in the accessibility tree. Sample the interior of the
    // 16:9 thumbnail, above the title and away from the centered placeholder icon.
    private nonisolated static func hasThumbnailArtwork(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = CGFloat(cgImage.width)
        let artworkHeight = width * 9 / 16
        let region = CGRect(x: width * 0.12, y: artworkHeight * 0.12,
                            width: width * 0.76, height: artworkHeight * 0.27)
        guard let crop = cgImage.cropping(to: region) else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 8 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 16, height: 8))
            var tones = Set<Int>()
            for i in stride(from: 0, to: bytes.count, by: 4) {
                tones.insert((Int(bytes[i] >> 4) << 8) | (Int(bytes[i + 1] >> 4) << 4) | Int(bytes[i + 2] >> 4))
            }
            return tones.count >= 4
        }
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
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-home"], in: app)
        let videos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-' OR identifier BEGINSWITH 'discovery-'"))
        guard videos.firstMatch.waitForExistence(timeout: 45) else {
            throw XCTSkip("Requires a TV with at least one followed channel and a loaded upload.")
        }
        capture("freeTube Home")
        let remote = XCUIRemote.shared
        let focusedVideos = videos.matching(NSPredicate(format: "hasFocus == true"))
        for _ in 0..<4 where !focusedVideos.firstMatch.exists { remote.press(.down) }
        XCTAssertTrue(focusedVideos.firstMatch.exists)
        remote.press(.right)
        let selected = focusedVideos.firstMatch.identifier
        XCTAssertFalse(selected.isEmpty)
        capture("freeTube browsing")
        let home = app.buttons["nav-home"]
        XCTAssertFalse(home.exists)
        remote.press(.menu)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.hasFocus)
        capture("freeTube navigation")
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
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-home"], in: app)
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

    func testHoldPlayPauseTogglesPictureInPicture() throws {
        continueAfterFailure = false
        let app = try playFeaturedMovie()
        let remote = XCUIRemote.shared
        let expand = app.buttons["mini-expand"]
        remote.press(.playPause, forDuration: 1.0)
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "Holding Play/Pause should open the mini-player.")
        remote.press(.menu)
        selectWithRemote(app.buttons["nav-search"], in: app)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        remote.press(.playPause)
        XCTAssertTrue(expand.exists, "A short press should keep the mini-player open.")
        remote.press(.playPause, forDuration: 1.0)
        XCTAssertTrue(expand.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["native-playback"].waitForExistence(timeout: 5))
        remote.press(.playPause)
        XCTAssertFalse(expand.exists, "A short press should keep the full-screen player open.")
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
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-home"], in: app)
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
        capture("freeTube subscriptions")
        remote.press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video-' AND hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 8))
        XCTAssertFalse(all.exists)
    }

    func testHomeVideoOpensAPlayerOnTheTV() async throws {
        let app = XCUIApplication()
        app.launch()
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-home"], in: app)
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
            capture("freeTube native Home frame one")
            try await Task.sleep(for: .seconds(4))
            XCTAssertTrue(nativePlayer.exists)
            capture("freeTube native Home frame two")
            return
        }

        XCTAssertTrue(openYouTube.exists)
        XCTAssertTrue(openYouTube.hasFocus)
        capture("freeTube actual playback choice")
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
        capture("freeTube actual handoff")
    }

    private func playSampleMovie(requiringEmptyGuestLibrary: Bool = false, includingQueuePick: Bool = false) throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        try XCTSkipIf(requiringEmptyGuestLibrary, "Local follow checks use an isolated guest simulator.")
        #endif
        let app = XCUIApplication()
        let id = UUID()
        let videoID = "aqz-KE-bpKQ"
        let video: [String: Any] = ["id": videoID, "title": "Big Buck Bunny", "channelID": "UCSMOQeBJ2RAnuFungnQOxLg",
                                    "channelTitle": "Blender", "publishedAt": Date()]
        var samples = [video]
        if includingQueuePick {
            samples.append(["id": "eRsGyueVLvQ", "title": "Sintel", "channelID": "UCSMOQeBJ2RAnuFungnQOxLg",
                            "channelTitle": "Blender", "publishedAt": Date()])
        }
        let archive: [String: Any] = ["version": 1, "playlists": [
            ["id": id.uuidString, "title": "Playback test", "videos": samples]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        app.launchArguments = ["-room.playlists.v1", "<" + data.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        let remote = XCUIRemote.shared
        remote.press(.menu)
        if requiringEmptyGuestLibrary {
            let profile = app.buttons["account"]
            XCTAssertTrue(profile.waitForExistence(timeout: 6))
            try XCTSkipUnless(profile.label.contains("Sign in"), "Use a signed-out simulator for local follow checks.")
            selectWithRemote(app.buttons["nav-channels"], in: app)
            try XCTSkipUnless(app.buttons["Find a channel"].waitForExistence(timeout: 10),
                              "Use a guest simulator with an empty subscription library.")
            remote.press(.menu)
        }
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
        XCUIRemote.shared.press(.menu)
        selectWithRemote(app.buttons["nav-home"], in: app)
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

    private func transportAction(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let player = app.descendants(matching: .any)["native-playback"]
        let interactiveTypes = [XCUIElement.ElementType.cell, .button, .menuItem].map(\.rawValue)
        let match = NSPredicate(format: "elementType IN %@ AND label ==[c] %@ AND enabled == true", interactiveTypes, title)
        let direct = player.descendants(matching: .any).matching(match).firstMatch
        // AVKit exposes button cells even while the transport bar is hidden.
        XCUIRemote.shared.press(.up)
        if direct.exists { return direct }
        // tvOS can collapse actions into a separate system popover.
        let overflow = player.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@ AND label BEGINSWITH[c] 'More' AND label !=[c] 'More like this'",
            interactiveTypes
        )).firstMatch
        if overflow.exists {
            selectWithRemote(overflow, in: app)
            return app.descendants(matching: .any).matching(match).firstMatch
        }
        return direct
    }

    private func selectTransportAction(_ title: String, in app: XCUIApplication) {
        let action = transportAction(title, in: app)
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
