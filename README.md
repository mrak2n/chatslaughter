# chatslaughter

Native macOS utility for bulk management of Telegram chats. SwiftUI interface,
local TDLib session, no application server, no analytics.

**Status: development preview.** Demo mode and local TDLib lifecycle are tested.
Live account sign-in and destructive operations still require end-to-end
validation on a disposable test account. Do not call this a stable release yet.

[Русская инструкция](README.ru.md) · [Architecture](docs/architecture.md) · [Git practice](docs/git-guide.ru.md)

## Features

- Native sidebar and multiselect table; Command/Shift selection.
- Search, type, archive and inactivity filters. Select all applies to visible results.
- Review an immutable list of actions before executing.
- Private chats and bots: delete history **only for yourself** (`revoke=false`).
- Groups and channels: leave; remove the remaining entry if TDLib permits.
- Saved Messages, secret chats and owned groups/channels are protected.
- Serial execution, bounded flood-wait retries, stop after the current chat.
- Per-chat outcomes, including partial success. No automatic replay after a timeout.
- Offline demo with fictional chats. No account needed.

## Build and run

Source requires macOS 13+, Swift 5.9+ and Apple's Command Line Tools.
The bundled app's minimum OS can be higher, depending on the installed TDLib
and OpenSSL binaries. See `dist/build-info.json`.

```sh
xcode-select --install  # only if developer tools are missing
brew install tdlib
./scripts/test.sh
CHATSLAUGHTER_TEST_TDLIB=1 ./scripts/test.sh --filter TDLibLifecycleTests
./scripts/build-app.sh
open dist/chatslaughter.app
```

The script bundles TDLib and its non-system dynamic dependencies; Homebrew is
not required on the receiving Mac. The result is built for the host architecture,
ad hoc signed and **not notarized**. Developer ID signing and notarization are
still required for a normal public download experience. CI uploads build artifacts;
it does not publish releases automatically.

## Telegram authorization

1. Obtain your own `api_id` and `api_hash` at https://my.telegram.org/apps.
2. Enter them in the app, then complete phone/code/2FA authorization.
3. Select chats, review actions, and explicitly confirm the batch.

Never paste login codes, API Hash, session files or a 2FA password into GitHub
issues. This utility uses your user account through TDLib, not the Bot API.
Phone and email authorization states are handled where supported by the loaded
TDLib version. Account registration, QR/passkey sign-in and Premium-purchase
flows are not implemented.

The integration has legacy parameter handling for TDLib 1.8.0 (Homebrew stable)
and current flattened parameters. Local runtime validation used 1.8.0. Modern
upstream TDLib and live server authorization are not yet certified. You can supply
a different compatible library via `TDLIB_PATH` when bundling or
`CHATSLAUGHTER_TDLIB_PATH` when developing.

## Privacy

- API credentials and a random 256-bit database encryption key: macOS Keychain.
- TDLib session: `~/Library/Application Support/ChatSlaughter/tdlib`, directory mode 0700.
- No deliberate message-content database, media downloads, telemetry or application server.
  TDLib still receives chat metadata and may retain data needed for its operation.
- TDLib logging disabled. Batch results are held in memory and are not replayed after restart.
- “Завершить сессию” invokes Telegram `logOut`. Quitting alone keeps the session
  available for the next launch. Keychain credentials are retained locally.

An external participant sending another message can make a deleted private chat
appear again. Leaving a private group/channel can require a new invitation to return.
Stopping a batch cannot undo completed deletions.

## Development

```sh
git switch -c feat/your-change
./scripts/test.sh
git diff --check
git add Sources Tests docs
git commit -m "Describe the behavior change"
git push -u origin feat/your-change
```

See [the Git walkthrough](docs/git-guide.ru.md) for working tree, staging,
commits, branches, remotes and pull requests explained using this repository.

## License and affiliation

MIT. TDLib and bundled OpenSSL retain their own licenses; see
[third party notices](THIRD_PARTY_NOTICES.md). Independent, unofficial tool using
the Telegram API. Not affiliated with or endorsed by Telegram.
