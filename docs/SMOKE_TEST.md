# Smoke test matrix

Run these against a signed local build (Personal Team is fine) with a real calendar and Slack user token.

## Setup

1. Install to `/Applications` or run from Xcode with your Development team selected.
2. Quit any previous instance.
3. Launch → Settings opens with setup checklist.
4. Request Calendar Full Access → confirm the app appears under System Settings → Privacy & Security → Calendars.
5. Paste a valid `xoxp-` token with all required scopes → Save.
6. Confirm Launch at Login registration (or approval pending) matches the toggle after Save.

## Cases

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Timed event title matches a rule | Status + optional DND applied within ~60s / at boundary |
| 2 | Launch while matching event already active | Status applied for remaining duration |
| 3 | Two overlapping matches | Higher-priority rule wins; else later start |
| 4 | Recurring event next occurrence | Treated as new; previous day not reapplied after restart |
| 5 | Free / personal event | Eligible if accepted or organizer/personal |
| 6 | Tentative / declined / all-day | Ignored |
| 7 | Manually change Slack status mid-event | App leaves it until Sync Now / new controlling event / Settings save |
| 8 | Edit event end or title while active | Updates only if Slack still matches app-owned status |
| 9 | Delete/cancel controlling event | Clears status/DND only if still app-owned |
| 10 | Preexisting longer DND | App does not shorten it |
| 11 | Sleep across event end | On wake, status/DND reconciled |
| 12 | Disconnect network at event start | Retries with backoff until event ends; menu shows error |
| 13 | Revoke a required scope | Settings/sync surfaces auth/scope error |
| 14 | Revoke Calendar access | Setup/error state; no crash |
| 15 | Pause then Sync Now | Automatic sync skipped; Sync Now force-applies |
| 16 | Reset App | Token/settings/runtime cleared; Calendar consent remains |

## Signing note

Calendar TCC prompts require a properly signed `.app`. Unsigned CLI checks only cover unit tests via `scripts/check.sh`.
