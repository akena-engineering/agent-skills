# camofox-browser

Drive an anti-detection browser from Claude Code, with the container included.

## Purpose

A normal headless browser is easy to detect. Playwright and Puppeteer leak
automation markers, and a form that is completed with no keyboard events is
itself a bot signal. This skill gives the agent a browser that resists that
detection, and it ships the container that runs it.

The skill is self-contained. It starts its own container, keeps its own browser
state, and needs no MCP server and no configuration outside this directory.

## What it does

- Runs `ghcr.io/jo-inc/camofox-browser` (Camoufox/Firefox behind a REST API) in
  Docker, pinned to `1.13.0` by digest. Playwright drives the browser and
  humanizes cursor movement.
- Starts the container on demand. Every action command checks the container
  first, starts it if needed, and waits for `/health`.
- Never downloads the image implicitly. If the image is absent, the script stops
  and prints the `pull` command for you to approve.
- Refuses to drive a Camofox instance it does not own. The check compares the
  published host port of its own container with the port it is about to call.
- Types with real key events. `mode=keyboard` sends per-character
  `keydown`/`keypress`/`beforeinput`/`input`/`keyup` with `isTrusted: true`.
- Aligns locale, timezone, and geolocation with the host's real egress location,
  through a local `geo` plugin. See "Location consistency" below.
- Exposes every REST route, including the 26 that the upstream MCP adapter does
  not cover.

## Files

| Path | Purpose |
| --- | --- |
| `SKILL.md` | The command table, the typing rules, and the gotchas. |
| `scripts/camofox.sh` | The only entry point. Container lifecycle plus every browser action. |
| `docker/docker-compose.yml` | The container. Name `camofox-skill`, host port 9378. |
| `docker/camofox.config.json` | Plugin allowlist and the `geo` values. |
| `docker/plugins/geo/index.js` | The local `geo` plugin. |
| `docker/data/` | Persistent profiles, cookies, and local storage. Git-ignored. |

## Installation

```sh
git clone git@github.com:akena-engineering/agent-skills.git
mv agent-skills/claude-skills/camofox-browser ~/.claude/skills/camofox-browser
```

Docker must be running. Nothing else is needed.

Download the image once. The skill never does this on its own, because the image
needs about 2.1 GB of disk and the download takes minutes:

```sh
~/.claude/skills/camofox-browser/scripts/camofox.sh pull
```

Until the image is present, every other command stops with this message:

```
camofox.sh: the container image is not present on this machine:
      ghcr.io/jo-inc/camofox-browser:1.13.0@sha256:34ea51e...
    This script does not download it. Approve the download, then run:
      ./scripts/camofox.sh pull
```

## Example usage

Ask Claude for the work, not for the commands:

```
> log in to example.com with these credentials and screenshot the dashboard
> fill this form and submit it, the site scores typing behaviour
> what does my browser fingerprint expose on this page
```

You can also run the script by hand. It is a normal CLI.

Start the container and see its state:

```sh
~/.claude/skills/camofox-browser/scripts/camofox.sh up
```

```
camofox.sh: starting container camofox-skill on 127.0.0.1:9378
camofox.sh: healthy after 2s
container: camofox-skill (running), publishes port 9378
base url:  http://127.0.0.1:9378
user id:   camofox-skill
health:    {"ok":true,"engine":"camoufox","browserConnected":true,...}
```

Open a page and read it:

```sh
TAB=$(~/.claude/skills/camofox-browser/scripts/camofox.sh open https://example.com)
~/.claude/skills/camofox-browser/scripts/camofox.sh snapshot "$TAB"
```

```
- heading "Example Domain" [level=1]
- paragraph: This domain is for use in documentation examples...
- paragraph:
  - link "Learn more" [e1]:
    - /url: https://iana.org/domains/example
```

Type into a field with real key events, then submit:

```sh
scripts/camofox.sh type "$TAB" '#login' 'user@example.com' --delay 40 --clear
scripts/camofox.sh type "$TAB" '#password' 'secret' --enter
```

Save a screenshot and close the tab:

```sh
scripts/camofox.sh screenshot "$TAB" ./dashboard.png
scripts/camofox.sh close "$TAB"
```

Call a route that has no subcommand:

```sh
scripts/camofox.sh rest GET  "/tabs/$TAB/links"
scripts/camofox.sh rest POST "/tabs/$TAB/viewport" '{"width":1280,"height":800}'
```

Stop the container. Browser state in `docker/data/` survives:

```sh
scripts/camofox.sh down
```

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `CAMOFOX_HOST_PORT` | `9378` | Host port. Change it if 9378 is taken. |
| `CAMOFOX_CONTAINER` | `camofox-skill` | Container name. |
| `CAMOFOX_USER_ID` | `camofox-skill` | REST session id. Tabs and logins are keyed by it. |
| `CAMOFOX_START_TIMEOUT` | `90` | Seconds to wait for `/health`. |
| `CAMOFOX_BASE_URL` | unset | Operator override. It skips the container management and the ownership check. |

The port inside the container stays 9377. `CAMOFOX_HOST_PORT` only moves the
published host port. After you change it, run `down` and then `up`, because the
running container keeps its old mapping.

## Location consistency

Upstream `server.js` hardcodes a US Pacific browser context whenever no proxy is
configured:

```js
if (!CONFIG.proxy.host) {
  contextOptions.locale = 'en-US';
  contextOptions.timezoneId = 'America/Los_Angeles';
  contextOptions.geolocation = { latitude: 37.7749, longitude: -122.4194 };
}
```

Traffic still leaves from the host's real IP, so the browser contradicts its own
network location. Camoufox's `geoip` would derive these values from the exit IP,
but it is gated behind `geoip: !!launchProxy` and cannot be enabled without a
proxy. Upstream declined a fix in `jo-inc/camofox-browser#3109`, pending a
session-scoped API redesign.

The local `geo` plugin overrides those three values on the `session:creating`
hook, which fires immediately before `newContext()`. The values live in
`docker/camofox.config.json` under `plugins.geo`, and
`CAMOFOX_GEO_LOCALE`, `CAMOFOX_GEO_TZ`, `CAMOFOX_GEO_LAT`, and `CAMOFOX_GEO_LON`
override them. Invalid locales, non-IANA timezones, and out-of-range coordinates
are logged and ignored. The plugin disables itself when a proxy is configured,
so a future proxy defers to camoufox's `geoip`.

Two supporting details, both load-bearing:

- `TZ` in `docker/docker-compose.yml` must match `plugins.geo.timezone`.
  Playwright's per-context `timezoneId` does not reach ServiceWorker and
  SharedWorker scopes, which fall through to the container's system timezone.
  Without `TZ` the main thread reports the configured zone and the workers
  report UTC. The plugin logs a warning if the two disagree.
- `intl.accept_languages` is set at launch to the bare locale, which matches the
  single-entry `navigator.languages` that Playwright's per-context `locale`
  produces. A weighted list (`pl-PL,pl;q=0.8,en-US;q=0.5,en;q=0.3`) was tried
  and rejected, because it makes worker scopes disagree with the main thread.

Both plugin mounts are read-only and the image is untouched. Delete the two
volume lines and the `TZ` entry to revert to upstream behaviour completely.

## Deliberately not addressed

- **WebRTC still exposes the real IP** through STUN `srflx` candidates. A
  server-wide block is itself a fingerprint, and with no proxy the address is
  already visible over TCP, so suppressing ICE costs entropy while hiding
  nothing.
- **`os`, UA family, WebGL renderer, and screen dimensions** are not
  configurable from a plugin. `browser:launching` fires after `camoufox-js` has
  generated the fingerprint and serialised it into chunked `CAMOU_CONFIG_*`
  environment variables. Changing them requires patching the image.
- **The font set** (Arimo, Cousine, Tinos plus Noto script coverage) is
  Camoufox's own bundled Linux profile. Installing system fonts does not change
  what pages observe.
- **`DNT: 1` and `GPC: true`** are Camoufox defaults and remain set.

## Security and scope

- The API is published on `127.0.0.1` only. It is not reachable from the LAN.
- Crash and hang telemetry is disabled (`CAMOFOX_CRASH_REPORT_ENABLED=false`).
- `docker/data/` holds profiles, cookies, local storage, uploads, and traces. It
  is Git-ignored and must never be committed or copied into a report.
- The deployment is headless. No VNC, proxy, metrics endpoint, or cookie-import
  key is configured.
- `rm -rf docker/data` deletes every stored login. Do this only to reset the
  browser on purpose.

## Requirements

- Docker with Compose v2.
- `bash`, `curl`, and `jq`.
- About 2.1 GB of disk for the image, plus the browser profiles in
  `docker/data/`.

Tested on macOS with Docker Desktop on arm64. The pinned digest selects the
official `linux/arm64` manifest, so another architecture needs a different
digest in `docker/docker-compose.yml`.

## Upgrade

1. Select a published upstream image version and read its changelog.
2. Replace the image reference in `docker/docker-compose.yml` with the exact
   `tag@sha256:<digest>` for your architecture.
3. Run `scripts/camofox.sh down`, `scripts/camofox.sh pull`, then
   `scripts/camofox.sh up`.
4. Re-check the schema divergences listed in `SKILL.md`. They are undocumented
   server behaviour and can change between versions.
