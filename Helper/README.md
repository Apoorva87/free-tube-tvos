# Free Tube laptop helper

Run the helper on the same network as your Apple TV to use Ask AI. Your laptop sends the question and selected video titles or caption excerpts to Codex through your own ChatGPT sign-in. Ask AI can answer a question, suggest videos, draft a playlist, or suggest additions to a selected playlist. Free-text routing can receive up to 40 local playlist names and IDs. A request for suggestions produces up to three YouTube search phrases. The TV retrieves actual candidates and sends those candidates back for ranking. A summary or timestamp jump needs timed captions for that exact video.

## Set up Codex

Use macOS or Linux with Python 3.9+, OpenSSL, and a running local Docker engine. macOS includes the Bonjour publisher. On Linux, install the distribution’s avahi-utils or avahi-tools package and start avahi-daemon. The TV and laptop must be able to exchange multicast DNS and reach TCP port 8714.

Run these commands from the project root. Building the image downloads the pinned CLI and base images. The build runs an offline signed-out check against the installed CLI.

```sh
docker build -t freetube-codex:0.172.0 Helper/container
python3 Helper/helper.py login --provider codex
python3 Helper/helper.py serve --provider codex
```

Follow the device sign-in shown by the official CLI. Some ChatGPT accounts require enabling device code authentication in their security settings. Only this image uses the dedicated login. Keep the final command running while you use Ask AI.

In the TV’s helper settings, select the advertised **Free Tube** name that matches the laptop and enter the complete pairing string shown in its terminal. An iPhone keyboard or paste can help with entry. The first 64 hexadecimal characters pin the TLS certificate, and the eight digits after the dot authorize pairing. The code expires after five minutes, after five unsuccessful guesses, or on its first successful use. Restart the helper for a new code. Pairing another TV replaces the previous TV’s bearer token. Restarting alone preserves an existing pairing.

## Try free-text requests and public research

Ask “What is a KV cache?” for an explanation, “Find videos on KV cache” for catalog suggestions, or “Add introductory guitar lessons to Guitar practice” to propose additions to an existing playlist. Playlist changes take effect when you save the reviewed draft on the TV.

For a signed-in research check, ask “Research the vLLM PagedAttention paper online and find introductory videos.” Review the public search terms shown on the TV, then approve the lookup. The helper starts a separate, temporary Codex turn containing just that topic. The web lookup receives no local playlists, video IDs, captions, candidate videos, or previous conversation. The TV can use the returned terms to search for playable YouTube videos.

The helper verifies live search mode, provider capability, and completed native web-search results. It accepts up to six source links that match URLs or reference IDs from those results. The model’s proposed link alone cannot establish a source. Six web actions and a two-minute timeout bound each research job. If the CLI or subscription cannot provide results, the TV receives an explicit error. [Pinned OpenAI web-search implementation](https://github.com/openai/codex/blob/rust-v0.172.0/codex-rs/ext/web-search/src/tool.rs)

## Timed captions

From the player, choose **Ask AI → Summarize this**. If the paired helper has no track, **Use public captions** checks the regular public watch page for that video. Choose this only when you have permission to use its captions with Ask AI. YouTube may return no usable track. You can also copy a permitted transcript with timestamps from **Show transcript**, paste it into Free Tube with the iPhone remote keyboard, then select **Use pasted transcript**. The Mac stores the track for that video and the original request continues.

To import from disk, use a video-relative WebVTT, SRT, or timestamped text file whose captions you own or have permission to use. Replace the sample ID and file path with yours.

```sh
python3 Helper/helper.py import-captions dQw4w9WgXcQ ./captions.vtt --permitted
```

Importing replaces that video’s track. Imported cues retain their video ID, start and end times, and cue indices. The TV obtains the selected track over the paired connection. The laptop checks each excerpt against its current imported track, including the exact text and times, before sending the requested cues to Codex.

## Status and data

- **Ready** means the isolated CLI reports a ChatGPT subscription and the service confirms ordinary included usage is available. Each ask checks again before starting the turn. The helper selects a single model, uses standard speed, and stops on a quota or provider error. Account-level usage and charges remain subject to the provider’s plan and spending settings. [Codex authentication](https://developers.openai.com/codex/auth/)
- **Signed out** means the dedicated CLI needs a ChatGPT login. Run the login command again. The helper never switches to an API key, a cloud API provider, or another model. **Unavailable** includes a stopped Docker engine, a missing image, an unsupported plan, an unconfirmed allowance, or interrupted provider connectivity.
- The default private directory is `~/.freetube-helper`. It holds the TLS identity, paired TV token digest, and imported captions. To use a different directory, put `--state-dir /path/to/private/directory` before the subcommand on every invocation. The directory must have mode 700. To revoke a TV without replacing it, stop the helper, delete `paired-tv.sha256` from this directory, and restart.
- The dedicated Docker volume is named `freetube-codex-` followed by the first 16 characters of the certificate fingerprint. The unmodified CLI handles sign-in. Its dedicated authentication file persists across requests to allow token refresh. Each run uses fresh temporary home and config directories. Removing this volume while the helper is stopped signs the helper out. The laptop’s regular CLI login and Google credentials are separate.
- The helper shares `_freetube-ai._tcp` through Bonjour. A new certificate requires pairing again. If the TV cannot find the service, check local network access, the laptop firewall, and whether the network passes multicast between its wired and wireless clients. Use `serve --provider codex --port 8715` to choose another port when needed.

## Request boundaries

The assistant process runs as a non-root user inside a read-only container with a temporary filesystem, one dedicated Docker volume, and a 90-second deadline for ordinary requests. Public research has a 120-second deadline. The host mounts no personal directory, repository, Docker socket, or Google credential. Codex receives each request as JSON in its stdio protocol with empty execution environments, no dynamic tools, a read-only sandbox, and approval disabled. Its pinned local model catalog removes shell, patch, and tool-search capabilities. Browser control, computer use, apps, plugins, subagents, hooks, image handling, and remote control are disabled in both modes. Public research alone enables the official CLI’s standalone live web search. A provider confirmation request ends the operation. Network connectivity in the container lets the CLI contact ChatGPT for sign-in, quota, and inference.

The helper processes one model request at a time and accepts 30 requests per ten minutes. Each request accepts up to 50 videos, 256 cues, 60,000 UTF-8 bytes of caption text, and a 2,000-byte prompt within a 192 KiB JSON body. Returned selections must use supplied candidate IDs, and cited cue indices must exist in the supplied track excerpt. Unsupported jumps yield an empty object. Summary points are model-generated interpretations with cue references for playback verification.

Run the local tests from the project root. These exercise a real pinned TLS handshake and HTTP requests over connected sockets with fixture account and model responses.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Helper -v
```
