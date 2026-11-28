# freeTube for Apple TV

freeTube is an independent YouTube client for Apple TV. Open **Discover** to see what your channels just published and find new creators through your subscriptions and recent likes. Select a thumbnail to play it, hold Select to follow its channel on this TV or save it to a playlist, or keep it playing in the corner while you search.

[Try the interactive walkthrough](https://apoorva87.github.io/free-tube-tvos/) · [Build for Apple TV](#run-in-xcode) · [Connect your subscriptions](#connect-your-subscriptions)

## Start in Discover

Discover opens on **For you**. The first three rows are **Education**, **Economics**, and **Health**, followed by **Trending Hindi songs** and **Trending English songs**. Each topic uses public video search. The music rows search for trending songs in each language and do not represent an official chart.

Open **Settings → Discover rows** in the sidebar to show or hide any row, move it up or down, or add your own search topic. Turn on **Personal recommendations** for suggestions from likes and followed channels, or **From your subscriptions** for recent uploads grouped by creator. Changes are saved on this Apple TV. Explore, Music, Gaming, News, Sports, and Live remain available across the top of Discover.

Under **Discover → Music**, recent songs on this profile can add **More like [song]** and **Artists to discover** above the public Music rows. If the mix contains only familiar artists, **Play it again** features recent songs instead.

Opening a creator from Search or the player shows **Recent uploads** and **Most viewed**. Two additional rows highlight shorter and longer watches when the channel has enough videos. Channels with similar runtimes can show earlier uploads and other picks instead.

The native tvOS player supports speeds from 0.5× to 2×. Search, viewing history, and playlists work directly on the TV. **Ask AI** adds video research and playlist drafting through an optional paired computer.

Hold Select on a video tile and choose **Add to Quick Playlist**. The same menu includes **Visit Creator** when the channel is available. Queued picks play next in the order you add them. Standalone videos then autoplay from each video’s related recommendations. Starting a saved playlist follows its saved order. The Quick Playlist is also saved under **Playlists** for later.

**Settings → Playback → Soft Fade** is on by default. Use **Audio overlap** to choose 0.25, 0.55 (default), 1, 2, 4, or 6 seconds. At 2 seconds, for example, the next song starts quietly when the current one has two seconds left. At the handoff, the picture switches to the point you’re already hearing in the next song. Turn Soft Fade off for the previous transition, which preloads the next item, fades the outgoing picture and audio over 0.35 seconds and starts the next item at the handoff.

Search remembers the last six searches for each profile on this TV. Select a recent term to search again, use **Clear search** to reset the field and results, or choose **Clear history** to erase recent terms.

## DJ Mode

Open **DJ Mode** in the sidebar. Choose a recommended song from your listening history or music interests, or use the search field to start with a genre, mood, or song. Try **songs like Gulabi Sadi**. If several recordings match, pick the one you mean. In regular Search you can also hold Select on the recording and choose **Play in DJ** to start with that exact video.

The current song plays in the corner while you browse **Up next**. Enter **more Marathi wedding songs** to change what plays next. Choose **Play Now** on a tile when you want an immediate switch. The station fetches more tracks as the queue runs low. Likes influence the upcoming order, and disliked tracks are excluded from future recommendations for that profile.

**Flow** uses available mood and published tempo metadata. **Popular Shuffle** draws from highly viewed matches. A word-based station starts with English and Hindi by default. A station based on a specific recording uses the language the catalog can identify. Use the globe control to choose a language yourself.

DJ spaces its catalog requests at least six seconds apart and runs one at a time. It reads the information on song tiles first and looks up missing details while music plays. Public song details stay in a local cache for seven days. Search and radio results can be reused for 15 minutes.

If YouTube limits requests, DJ holds the queue and shows when you can try **Retry**. It honors YouTube’s requested wait and uses a 15-minute pause when YouTube gives no time. Choose **Open in YouTube** to try the selected recording in the official app.

## Run in Xcode

1. Clone this repository. Open `freeTube.xcodeproj` in Xcode on a Mac with the tvOS SDK and Swift 6 support.
2. Select the **freeTube** scheme and an Apple TV simulator running tvOS 17.6 or later. Choose **Product → Run**. Open **Search** to look up a public channel by name or handle and follow it locally.
3. For a physical Apple TV, pair it with Xcode, select it as the run destination and choose your Apple developer team. For local signing overrides, copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig` and set `CHANNELROOM_BUNDLE_ID` and `DEVELOPMENT_TEAM` to your values. Run the app on the TV.

## Connect your subscriptions

Google sign-in is optional. To import subscriptions, configure a Google OAuth client for your own installation.

1. In Google Cloud, enable **YouTube Data API v3**, configure the OAuth consent screen, and add your Google account as a test user if the project is in testing.
2. Create an OAuth client of type **TVs and Limited Input devices**. [Google’s device authorization guide](https://developers.google.com/identity/protocols/oauth2/limited-input-device)
3. In freeTube, open **Sign in → Set up Google client**, enter your client ID and client secret, and select **Save on this Apple TV**. The iPhone Apple TV Remote keyboard supports paste.
4. Choose **Sign in with Google**. Scan the QR code with your phone, confirm the short code displayed on the TV and authorize read-only YouTube access. If scanning is inconvenient, open the verification address shown on the TV and enter that code.
5. If subscriptions look unfamiliar, open the profile at the top of the sidebar. **Switch YouTube profile** lets you choose a different YouTube channel associated with your Google account.

The TV stores manually entered client settings and the Google refresh token in its Keychain. Access tokens are held in memory. The app keeps local follows and a per-profile discovery cache on the TV. To remove the saved sign-in, select **Sign out of this TV**. The public source ships with empty client settings. Enter credentials on the TV for a build you plan to share. Values supplied through build settings are embedded in that app bundle.

## Use the remote

| What you want to do | How |
| --- | --- |
| Browse Discover | Choose a category, press **Down** to enter its rows, then **Left** or **Right** to browse thumbnails. Press **Select** to play a recommendation without following its channel. |
| Move down the sidebar | From the profile icon, press **Down** for Discover, then Home, Subscriptions, Playlists, History, DJ Mode, Search, Ask AI, and Settings. |
| Return to your channels | Press **Back** while browsing and select **Subscriptions**. Focus a channel to filter its uploads. Press **Right** to return to the videos. |
| Adjust playback speed | Press **Up** during playback and choose the speedometer. Available rates are 0.5×, 1×, 1.25×, 1.5× and 2×. |
| Visit the creator | Choose **View creator** in the player controls. Play another upload, follow the channel on this TV, or select **Subscribe on YouTube** and scan the code to subscribe on your phone. When you close the code, freeTube refreshes the subscriptions for its signed-in profile. |
| Read the description | Choose **Description** in the player controls. Use the remote to scroll the creator’s text. **Back** returns to the video. |
| Find a similar song or video | Choose the right-hand **Show more options** control, or swipe up on the Siri Remote while the controls are hidden. Browse left or right in the compact thumbnail row across the bottom of the video. Select a thumbnail to play it, or hold Select and choose **Add to playlist** to save it. Suggestions come from the current video’s YouTube recommendations. |
| Search while watching | Hold **Play/Pause**, then release to switch between full screen and the in-app mini-player. A quick press pauses or resumes. You can also choose **Watch while browsing** in the player and open **Search**. The mini-player uses one-third of the screen width. The tvOS keyboard covers the picture during text entry. |
| Leave a video | Press **Back** to stop full-screen playback and return to browsing. If a transport menu is open, Back closes that menu first. |
| Watch something again | Open **History** and select a thumbnail. Your latest watches come first. Each YouTube profile and signed-out viewing have their own history on this TV. |
| Go back to full screen | Choose **Expand video** in the mini-player or sidebar. Playback keeps its current position and rate. **Close video** stops it. |

## Custom playlists

Open **Playlists → New playlist**. Hold Select on a video tile and choose **Add to playlist**, or use **Add to playlist** in the player. Open a saved playlist to browse numbered thumbnails or choose **Play all**. In **Edit playlist**, select a tile to move that video earlier or later or remove it. Playlists are shared by profiles on this installation of freeTube and are saved on the TV. You can manage them while signed out or while your helper is asleep.

## Ask AI

Open **Ask AI** from the sidebar or the Search screen. Select **Connect or check helper** to pair a computer running the dedicated Codex helper. Both devices need to be on the same local network. On a Mac with the helper image already built, run [the login and discovery launcher](Helper/login-and-check.command). It checks the existing Codex session, offers device sign-in when needed, and verifies the advertised helper certificate. The helper signs in through its own Codex session. The session uses the configured provider for inference and receives the prompt and selected video metadata. Google credentials stay on the TV. There is no automatic provider or paid API fallback. [Set up the helper](Helper/README.md)

- **Ask in your own words.** Select **Ask AI** in the sidebar and send a question or a task. For example, “Research how PagedAttention uses the KV cache, then add two visual explainers to my ML Notes playlist.” The helper can answer, find videos, propose a new playlist, or propose additions to an existing one. Browse video suggestions as thumbnail tiles, choose the destination on the TV, and review changes before saving.
- **Research a topic.** Review the proposed public search topic on the TV before starting research. The paired Codex session can use its built-in web search for that request. The TV shows the findings and available source addresses. It uses the research terms to fetch playable candidates from freeTube’s catalog. The research request carries only the approved topic.
- **Find videos.** Describe what you want and choose **Find videos**. Pick a result to play it.
- **Build a playlist.** Try “Build a 45-minute playlist that teaches KV cache with visual explainers and no repeats.” The TV searches its video catalog, verifies the proposed IDs and uses known durations to fit the draft within the requested time. Review the actual total, reorder or remove videos, add alternatives, and save.

## How it works

- **Recommendations.** The TV interleaves results from several source videos so one popular upload does not fill a whole row. If a source returns too few videos, Discover can draw on followed-channel topics. Recommendations are cached per profile on the TV.
- **Player.** The app resolves an available public stream and plays it with AVKit. This direct playback path does not request a separate YouTube ad player. Stream availability varies, and ads embedded in the video are part of the picture. When playback is unavailable, **Open in YouTube** hands the video to the official app, where YouTube’s own ad settings apply.
- **Browsing during playback.** A shared playback session keeps the same AVPlayer item alive while the surface moves between full screen and the corner. The mini-player works inside freeTube.

## Source and tests

The app lives in [App](App). The checked-in Xcode project is ready to open. [project.yml](project.yml) is its XcodeGen specification. The player’s stream-selection and observation logic are adapted from [SmartTubeIOS](https://github.com/milika/SmartTubeIOS/tree/6bd85d39ab9458b3dc2582597dc7ed10c2fd8dce). Its native HLS negotiation follows the AuTube approach.

Run the stream-selection fixtures on a Mac with `swift test --package-path Vendor/SmartTubeIOS`. In Xcode, **Product → Test** runs playlist, assistant validation, helper connection, discovery, playback and remote-navigation checks. Run the helper tests with `python3 -m unittest discover -s Helper`. Live playback needs internet access. Account-dependent UI checks use the test device’s catalog.

The source is distributed under [GPL-3.0](LICENSE). The walkthrough uses an illustrative library and separately credited [NASA photographs](docs/credits.md). freeTube is an independent project.
