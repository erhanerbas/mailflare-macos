<img src="docs/icon.png" alt="Mailflare" width="128" height="128">

# Mailflare for macOS

  A fast, native Mac mail client for your Mailflare server, and for Gmail, Outlook, iCloud and any IMAP account.

![](docs/demo.png)

Mailflare for macOS is the desktop companion to [Mailflare](https://github.com/hieunc229/mailflare), the self-hosted mail platform that runs on Cloudflare. It is a SwiftUI app on a shared Rust core ([`mailflare-core`](../mailflare-core)) that handles the mail protocols, sync and the local database, so mail opens instantly from a local cache and keeps working offline.

## Features

- **Mailflare first.** Signs in with your account password (with TOTP or recovery-code MFA), an app password, or a QR code. Uses JMAP, and picks up your server's name for the sidebar.
- **Any other mail account.** Built-in presets for Gmail, Outlook, iCloud, Yahoo, AOL, Zoho, Yandex, GMX, Fastmail and Mail.ru, plus manual IMAP/SMTP setup for other servers.
- **Multiple accounts and inboxes.** Switch accounts from the sidebar header; a Mailflare account shows one inbox per address, or all of them together.
- **Offline-first.** Mail is cached locally and actions are queued while offline, then synced when you reconnect.
- **Compose.** Rich-text editor, Cc/Bcc, From picker, attachments, drafts, reply, reply all and forward, and reusable templates.
- **Organize.** Archive, trash, junk, star, move to folders, mark read, undo, and unsubscribe from newsletters.
- **Search.** Search from the title bar, with filters for unread and flagged mail.
- **Reading.** Remote content can be blocked, HTML is rendered safely, and the original message source can be viewed.
- **Notifications and Dock badge.** New-mail alerts with optional previews and sounds, and an unread count on the Dock icon.
- **Native feel.** Light and dark mode, a hidden title bar, a collapsible sidebar and keyboard shortcuts.
- **Updates.** Checks GitHub releases and updates itself in place.
- **AI assistant.** A chat panel (sparkles button in the title bar) that can search and read your mail, draft replies and organize messages with tools. See [AI assistant](#ai-assistant).

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New message |
| `⌘,` | Settings |
| `⌘R` / `⇧⌘R` | Reply / Reply all |
| `⇧⌘F` | Forward |
| `⌘⌥F` | Focus search |
| `⌘⌫` | Delete |
| `⌘↩` | Send |
| `⎋` | Back to inbox (from Settings) |

## AI assistant

The assistant appears once an AI provider is set up in **Settings → AI Providers**. It never sends mail: when a draft is ready it opens in the composer for you to review and send.

- **Providers.** Add as many as you like: OpenAI, Anthropic, OpenRouter, Groq, a local Ollama model, or any OpenAI-compatible address. Keys are stored in the Keychain, one per provider. "Load Models" fetches a provider's model list, and long lists load lazily and can be searched by typing.
- **Chat panel.** Pick the provider and model from the dropdown at the top right of the panel. A new chat offers starter prompts (about the open email when one is open) and your recent conversations, which are saved per account on this Mac. On a narrow window the sidebar closes while the panel is open and returns when it closes.
- **Tools.** `get_current_email`, `list_emails`, `get_email`, `get_thread`, `search_emails`, `draft_email`, `draft_reply`, `edit_draft`, `review_draft_send`, `discard_draft`, `mark_email_read`, `move_email` and `move_emails`, all on the account in view.
- **Writing preferences.** Add your tone or sign-off in the AI Providers page and the assistant follows it when drafting.

The mail the assistant reads is sent to the provider you choose. Pick a local Ollama model to keep it on your Mac.

## Requirements

- macOS 15.3 or later
- To build: Xcode 16 or later, and the Rust toolchain for the core

## Building

The app depends on `mailflare-core` as a local Swift package at `../mailflare-core`, so clone both repositories side by side:

```text
mailflare/
├── mailflare-core/    # Rust core and Swift bindings
└── mailflare-macos/   # this repository
```

Build the core's XCFramework with its macOS slice, then build the app:

```bash
cd ../mailflare-core
scripts/build-ios.sh --macos      # add --debug for a faster, unoptimized build
```

```bash
cd ../mailflare-macos
xcodebuild -project Mailflare.xcodeproj -scheme Mailflare -configuration Debug build
```

You can also open `Mailflare.xcodeproj` in Xcode and run the **Mailflare** scheme. Swift packages (Hugeicons) resolve automatically.

## Project layout

| Path | Contents |
| --- | --- |
| `Mailflare/MailflareApp.swift` | App entry, window and menu commands |
| `Mailflare/Store/` | `MailStore` (app state over the core), `AppUpdater`, `MailNotifier`, avatars, compose templates |
| `Mailflare/Views/` | Sidebar, message list, reader, composer, settings and sign-in |
| `Mailflare/Models/` | Mail models and the provider presets |
| `Mailflare/Support/` | Keychain store, settings, icons, appearance |
| `Mailflare/AI/` | Provider settings, streaming client, mail tools and the chat model |
| `Mailflare/Theme/` | Colors and typography |

## Data and privacy

- Account secrets (device keys and app passwords) are kept in the macOS Keychain, never in the mail database.
- Mail is cached locally; **Settings → About** shows where.
- The app talks only to your mail servers, GitHub (update checks) and, when you use the assistant, the AI provider you set up.

## Related projects

- [`mailflare`](https://github.com/hieunc229/mailflare): the server
- [`mailflare-core`](../mailflare-core): the shared Rust core

## License

[GNU AGPL v3](LICENSE)
