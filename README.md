# Free Tube for Apple TV

Free Tube is a native tvOS app for watching public YouTube videos and browsing the channels you follow. Home brings together recent uploads and two discovery rows. You can open a recommendation without subscribing, watch at 1.5× or 2×, or keep the current video playing in the corner while you look for another. Search, playback, and custom playlists run on the TV. The optional **Ask AI** feature connects to a paired computer on your home network.

**[Try the interactive walkthrough →](https://apoorva87.github.io/free-tube-tvos/)**

## Run in Xcode

1. Clone this repository. Open `ChannelRoom.xcodeproj` in Xcode on a Mac with the tvOS SDK and Swift 6 support. **ChannelRoom** is the internal project and scheme name. The app appears on the TV as **Free Tube**.
2. Select the **ChannelRoom** scheme and an Apple TV simulator running tvOS 17.6 or later. Choose **Product → Run**. Open **Search** to look up a public channel by name or handle and follow it locally.
3. For a physical Apple TV, pair it with Xcode, select it as the run destination and choose your Apple developer team. For local signing overrides, copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig` and set `CHANNELROOM_BUNDLE_ID` and `DEVELOPMENT_TEAM` to your values. Run the app on the TV.

## Connect your subscriptions

Google sign-in is optional. To import subscriptions, configure a Google OAuth client for your own installation.

1. In Google Cloud, enable **YouTube Data API v3**, configure the OAuth consent screen, and add your Google account as a test user if the project is in testing.
2. Create an OAuth client of type **TVs and Limited Input devices**. [Google’s device authorization guide](https://developers.google.com/identity/protocols/oauth2/limited-input-device)
3. In Free Tube, open **Sign in → Set up Google client**, enter your client ID and client secret, and select **Save on this Apple TV**. The iPhone Apple TV Remote keyboard supports paste.
4. Choose **Sign in with Google**. Scan the QR code with your phone, confirm the short code displayed on the TV and authorize read-only YouTube access. If scanning is inconvenient, open the verification address shown on the TV and enter that code.
5. If subscriptions look unfamiliar, open the profile at the top of the sidebar. **Switch YouTube profile** lets you choose a different YouTube channel associated with your Google account.

The TV stores manually entered client settings and the Google refresh token in its Keychain. Access tokens are held in memory. The app keeps local follows and a per-profile discovery cache on the TV. To remove the saved sign-in, select **Sign out of this TV**. The public source ships with empty client settings. Enter credentials on the TV for a build you plan to share. Values supplied through build settings are embedded in that app bundle.

## Use the remote

| What you want to do | How |
| --- | --- |
| Explore new creators | Move down from the featured video to **Recommended** and **Creators to explore**. Move left or right within a row. |
| Move down the sidebar | From the profile icon, press **Down** for Home. Keep pressing **Down** for Subscriptions, Playlists, History, Search and Ask AI. |
| Return to your channels | Press **Back** while browsing and select **Subscriptions**. Focus a channel to filter its uploads. Press **Right** to return to the videos. |
| Adjust playback speed | Press **Up** during playback and choose the speedometer. Available rates are 0.5×, 1×, 1.25×, 1.5× and 2×. |
| Search while watching | Choose **Watch while browsing** in the player, then open **Search**. The in-app mini-player uses one-third of the screen width. The tvOS keyboard covers the picture temporarily during text entry. |
| Leave a video | Press **Back** to stop full-screen playback and return to browsing. If a transport menu is open, Back closes that menu first. |
| Watch something again | Open **History** for videos played in Free Tube on this TV. Select a thumbnail to replay it. History starts with this update, keeps your latest watches first, and is separate for each YouTube profile and for signed-out viewing. |
| Go back to full screen | Choose **Expand video** in the mini-player or sidebar. Playback keeps its current position and rate. **Close video** stops it. |

## Custom playlists

Open **Playlists → New playlist**. Hold Select on a video tile and choose **Add to playlist**, or use **Add to playlist** in the player. Open a saved playlist to browse numbered thumbnails or choose **Play all**. In **Edit playlist**, select a tile to move that video earlier or later or remove it. Playlists are shared by profiles on this installation of Free Tube and are saved on the TV. You can manage them while signed out or while your helper is asleep.

## Ask AI

Open **Ask AI** in the sidebar beside **Search**. Select **Connect or check helper** to pair a computer running the dedicated Codex helper. Both devices need to be on the same local network. On a Mac with the helper image already built, run [the login and discovery launcher](Helper/login-and-check.command). It checks the existing Codex session, offers device sign-in when needed, and verifies the advertised helper certificate. The helper signs in through its own Codex session. The session uses the configured provider for inference and receives the prompt and selected video metadata or caption excerpts. Google credentials stay on the TV. There is no automatic provider or paid API fallback. [Set up the helper](Helper/README.md)

- **Ask in your own words.** Select **Ask AI** in the sidebar and send a question or a task. For example, “Research how PagedAttention uses the KV cache, then add two visual explainers to my ML Notes playlist.” The helper can answer, find videos, propose a new playlist, or propose additions to an existing one. Browse video suggestions as thumbnail tiles, choose the destination on the TV, and review changes before saving.
- **Research a topic.** Review the proposed public search topic on the TV before starting research. The paired Codex session can use its built-in web search for that request. The TV shows the findings and available source addresses. It uses the research terms to fetch playable candidates from Free Tube’s catalog. The research request carries only the approved topic.
- **Find videos.** Describe what you want and choose **Find videos**. Pick a result to play it. While the mini-player is open, **Ask about the current video** brings up its caption and follow-up actions.
- **Build a playlist.** Try “Build a 45-minute playlist that teaches KV cache with visual explainers and no repeats.” The TV searches its video catalog, verifies the proposed IDs and uses known durations to fit the draft within the requested time. Review the actual total, reorder or remove videos, add alternatives, and save.
- **Talk about the playing video.** Open **Ask AI** in the player controls and select the question field. Hold the Siri Remote microphone button while speaking, release it, review the text, and choose **Send**. You can send from the keyboard or the player. If the helper needs captions, the remote highlights **Use public captions and answer**. Select it if you have permission to use that track. If the track is unavailable, you can paste a timestamped transcript or search for related videos. The movie pauses while you talk. The TV reads the answer aloud and shows the timestamped captions that support it. Choose **Read again** or **Stop reading** to control speech. Ask a follow-up in the same field. The last three completed exchanges stay in memory for that video until you close the conversation. The paired helper receives the submitted text and permitted caption excerpts. tvOS handles dictation and speech playback.
- **Ask during playback.** Open **Ask AI → Video tools** in the player. **Summarize this** shows takeaways alongside the timestamp and text of the supporting caption. Enter a topic such as “where they explain memory bandwidth” and choose **Find timestamp** to preview a cue and confirm the jump. **Find a good follow-up** searches for other videos.
- **Available captions.** If the helper has no imported track, choose **Use public captions** for a track you have permission to use with Ask AI. If YouTube supplies no readable track, paste timestamped text using the iPhone remote keyboard and choose **Use pasted transcript**, or import a WebVTT, SRT or timestamped text file on the Mac. If a track is missing, the TV offers related search. For long tracks it shows when an answer uses sampled excerpts.

## How it works

- **Catalog.** The read-only Google connection imports subscriptions. Home uses channel topics and recent uploads to find other creators, filters out followed channels and divides distinct creators between the two discovery rows. Results depend on the available public catalog.
- **Player.** The app resolves an available public stream and plays it with AVKit. This direct playback path does not request a separate YouTube ad player. Stream availability varies, and ads embedded in the video are part of the picture. When playback is unavailable, **Open in YouTube** hands the video to the official app, where YouTube’s own ad settings apply.
- **Browsing during playback.** A shared playback session keeps the same AVPlayer item alive while the surface moves between full screen and the corner. The mini-player works inside Free Tube.

## Source and tests

The app lives in [App](App). The checked-in Xcode project is ready to open. [project.yml](project.yml) is its XcodeGen specification. The player’s stream-selection and observation logic are adapted from [SmartTubeIOS](https://github.com/milika/SmartTubeIOS/tree/6bd85d39ab9458b3dc2582597dc7ed10c2fd8dce). Its native HLS negotiation follows the AuTube approach.

Run the stream-selection fixtures on a Mac with `swift test --package-path Vendor/SmartTubeIOS`. In Xcode, **Product → Test** runs playlist, assistant validation, helper connection, discovery, playback and remote-navigation checks. Run the helper tests with `python3 -m unittest discover -s Helper`. Live playback needs internet access. Account-dependent UI checks use the test device’s catalog.

The source is distributed under [GPL-3.0](LICENSE). The walkthrough uses an illustrative library and separately credited [NASA photographs](docs/credits.md). Free Tube is an independent project.
