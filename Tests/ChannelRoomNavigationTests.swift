import XCTest

@MainActor
final class ChannelRoomNavigationTests: XCTestCase {
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
        remote.press(.up)
        XCTAssertTrue(app.buttons["nav-assistant"].hasFocus)
        remote.press(.up)
        XCTAssertTrue(app.buttons["nav-search"].hasFocus)
        remote.press(.select)
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
        XCTAssertTrue(app.descendants(matching: .any)["native-playback"].waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        // The first Back press can dismiss AVKit's transport controls.
        for _ in 0..<2 where !expand.exists { remote.press(.menu) }
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        remote.press(.menu)
        let stop = app.buttons["drawer-mini-close"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        selectWithRemote(stop, in: app)
        XCTAssertFalse(close.exists)
        XCTAssertFalse(app.descendants(matching: .any)["native-playback"].exists)
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
