# Usage Pill for Claude

A tiny always-on pill that shows your Claude usage and how long until it resets — on every tab, without opening Settings → Usage.

- **Floating pill** on every page: `23% · 2h 14m`. Sits in the bottom-right corner — drag it anywhere (double-click to send it back); hover for session + weekly limits.
- **Live toolbar icon**: the ring fills as you use your limit, the badge counts down to the reset.
- **⌥⇧U** (Alt+Shift+U) shows / hides the pill. "Hide on this site" for pages where it's in the way.
- Turns amber at 50% and red at 80%.

## Install (developer mode)

1. Open `chrome://extensions` and switch on **Developer mode** (top right).
2. Click **Load unpacked** and pick this folder.
3. Pin it from the puzzle-piece menu so the icon stays in your toolbar.
4. Make sure you're logged in at [claude.ai](https://claude.ai).

## How it works

It reads the same endpoint claude.ai's own usage page uses (`/api/organizations/{org}/usage`), with your existing browser login. It checks every 2 minutes, plus whenever you hover the pill or open the popup.

**Privacy:** no servers, no analytics, no API keys. The only network requests go to `claude.ai`. The pill runs on every site so it can be shown there, but it only draws itself from extension storage and never reads the page.

## Notes

- Unofficial and not affiliated with Anthropic. The usage endpoint is undocumented and could change.
- Chrome extensions can only draw inside Chrome, so the pill isn't shown over other apps.
