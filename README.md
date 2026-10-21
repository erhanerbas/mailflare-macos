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
- **Mailflare Pro.** See [Licensing](#licensing).

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

## Licensing

Mailflare Pro is activated in either of two ways:

1. **Automatically.** Sign in with a Mailflare account whose server has an active Pro or Team license. The app asks each saved account's server (`/api/branding`), and one licensed account is enough to activate the app, whichever account is in view. Signing out of that account removes the activation.
2. **With a license key.** Open **Settings → License** (the **Upgrade to Pro** button above the version line opens it) and enter a Mailflare Pro key. The app activates it with [Paymug](https://app.paymug.co) for this Mac, stores the key in the Keychain, and re-validates it about twice a day. If Paymug is unreachable, an activated key keeps working for 14 days.

An activated app shows a **PRO** badge at the bottom of the sidebar. **Deactivate This Mac** frees the seat so the key can be used on another device. Keys are bought at <https://app.paymug.co/buy/mailflare-pro>.

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
| `Mailflare/Store/` | `MailStore` (app state over the core), `LicenseManager`, `AppUpdater`, `MailNotifier`, avatars, compose templates |
| `Mailflare/Views/` | Sidebar, message list, reader, composer, settings and sign-in |
| `Mailflare/Models/` | Mail models and the provider presets |
| `Mailflare/Support/` | Keychain store, settings, icons, appearance |
| `Mailflare/Theme/` | Colors and typography |

## Data and privacy

- Account secrets (device keys and app passwords) are kept in the macOS Keychain, never in the mail database.
- Mail is cached locally; **Settings → About** shows where.
- The app talks only to your mail servers, GitHub (update checks) and Paymug (license checks).

## Related projects

- [`mailflare`](https://github.com/hieunc229/mailflare): the server
- [`mailflare-core`](../mailflare-core): the shared Rust core

## License

[GNU AGPL v3](LICENSE)
