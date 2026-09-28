# Pennant

Native macOS 14+ menu-bar app that updates your Slack status from calendar events using ordered regex rules.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 (for building the `.app`)
- A Slack user token (`xoxp-`) from a Slack app with these user scopes:
  - `users.profile:read`
  - `users.profile:write`
  - `dnd:read`
  - `dnd:write`

## Create a Slack app and token

1. Open [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**.
2. Paste [`slack-app-manifest.yaml`](slack-app-manifest.yaml).
3. Install the app to your workspace.
4. Under **OAuth & Permissions**, copy the **User OAuth Token** (`xoxp-…`).
5. Paste that token into **Settings** in the app. The app validates `auth.test` and required scopes before saving it to Keychain.

## Build and run

### With Xcode (recommended for Calendar permission testing)

1. Open `Pennant.xcodeproj` in Xcode 16.
2. Select the **Pennant** scheme.
3. Run the app. It appears only in the menu bar (no Dock icon).
4. Open **Settings** from the menu, grant **Calendar Full Access**, paste the token, and Save.

### Check script (unsigned / CI fallback)

```bash
chmod +x scripts/check.sh
./scripts/check.sh
```

When full Xcode is unavailable, the script falls back to the SwiftPM `TestRunner` executable, which exercises the domain, persistence, Slack client, action executor, coordinator, and settings view-model suites.

## Install

Download the latest `Pennant-x.y.z.zip` from [Releases](https://github.com/adamjhc/pennant/releases/latest), unzip it, and move `Pennant.app` to Applications. Pennant checks for updates daily with [Sparkle](https://sparkle-project.org). Choose **Check for Updates…** from the menu to check now.

## Releases

Every push to `main` that changes more than Markdown or YAML files triggers `.github/workflows/release.yml`. The workflow tests, archives, signs with Developer ID, notarizes, and publishes a GitHub release. It then adds the release to the Sparkle feed at `https://adamjhc.github.io/pennant/appcast.xml`, which lives on the `gh-pages` branch.

The version is `MARKETING_VERSION` from the project plus the commit count on `main`, for example `1.0.42`. Change `MARKETING_VERSION` to bump the major or minor version. Release notes are the commit subjects since the previous tag.

The workflow needs these repository secrets:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate and private key, exported as `.p12`, base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | Password for that `.p12` |
| `NOTARY_API_KEY` | Contents of an App Store Connect API key `.p8` file |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The App Store Connect issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key. Export it with `generate_keys --account com.adamcox.pennant -x <file>` |

The matching Sparkle public key is `SUPublicEDKey` in `Pennant/Info.plist`. Do not lose the private key. Without it, installed copies cannot verify new updates.

The app is sandboxed, so `Pennant/Info.plist` sets `SUEnableInstallerLauncherService` and `Pennant/Pennant.entitlements` allows the `-spks` and `-spki` mach lookups Sparkle's installer needs.

## Behavior summary

- Rules are ordered; the first matching case-insensitive regex wins for an event title.
- Overlapping matches: highest rule priority, then most recently started event.
- Status expires at the event end (Slack `status_expiration`). No prior-status restore.
- DND-on rules preserve a longer existing snooze; DND-off rules leave DND alone.
- Global **Pause** is menu-only and persists across relaunch. **Sync Now** force-reapplies and works while paused.
- Manual Slack status changes are respected until a different controlling event, Settings save, or Sync Now.

## Reset

**Settings → Reset App** deletes local `settings.json`, `runtime-state.json`, and the Keychain token, and unregisters Launch at Login. It does **not** revoke Calendar consent or the Slack token remotely.

## Known limitations

- Slack `dnd.setSnooze` accepts whole minutes. The app rounds up, then ends app-owned DND at the exact event boundary while the Mac is awake.
- Changing the bundle ID later may require re-granting Calendar access and re-entering the Slack token.
- Standard Slack emoji catalogs are not fully exposed by the API; emoji fields validate shortcode shape only (`:name:`).

## Manual smoke tests

See [docs/SMOKE_TEST.md](docs/SMOKE_TEST.md).

## Project layout

- `Pennant/` — app + core sources
- `PennantTests/` — unit tests / TestRunner
- `Package.swift` — SwiftPM library + TestRunner for CLI checks
- `Pennant.xcodeproj` — Xcode app project
