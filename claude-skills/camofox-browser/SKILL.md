---
name: camofox-browser
description: Use when a task needs a real browser that resists bot detection - filling a form, logging in, submitting a search, scraping a site that scores behaviour, or taking a page screenshot - or when questions arise about what the browser session exposes to fingerprinting. The skill runs its own Camofox container and drives it over REST. No MCP server is required.
---

# Camofox Browser

## Overview

Camofox is an anti-detection browser (Camoufox/Firefox) behind a REST API.
Playwright drives it and humanizes cursor movement by default.

This skill owns its container. `scripts/camofox.sh` starts the container if it
does not run, waits for `/health`, then sends the request. The container is
`camofox-skill` on `127.0.0.1:9378`, built from `docker/docker-compose.yml`.

The skill never attaches to another Camofox instance. If something else answers
on the port, the script stops with an error instead of driving a browser it does
not own.

## Use the script

    ~/.claude/skills/camofox-browser/scripts/camofox.sh <command> [args]

No start-up step is needed. Every action command calls the start-up check first.
A cold start adds a few seconds, because the container and the browser must
start.

**Never download the image on your own.** If the image is absent, the script
stops and prints the `pull` command. Show that command to the user and ask for
approval. Run it only after the user agrees. The download is about 2.1 GB and
takes minutes.

| Need | Command |
|---|---|
| Open a page, get a tabId | `open <url>` |
| List the session's tabs | `tabs` |
| Go to another URL in a tab | `navigate <tabId> <url>` |
| Read the page (accessibility tree with `[eN]` refs) | `snapshot <tabId>` |
| Click | `click <tabId> '#selector'` or `click <tabId> --ref e3` |
| Type with real key events | `type <tabId> '#selector' 'text'` |
| Press a single key | `press <tabId> Enter` |
| Scroll | `scroll <tabId> --amount 800` |
| Extract fields into JSON | `extract <tabId> '<json-schema>'` |
| Run JavaScript | `evaluate <tabId> '<expression>'` |
| Save a PNG | `screenshot <tabId> [out.png]` |
| Close a tab | `close <tabId>` |
| Container state and health | `status` |
| Download the image (ask the user first) | `pull` |
| Stop the container | `down` |
| Container log | `logs [lines]` |
| Any other route | `rest <METHOD> <path> [json]` |

Read the page with `snapshot` before you click or type. `snapshot` prints the
accessibility tree with `[eN]` refs, and `--ref eN` is more stable than a CSS
selector on a page that generates class names.

## Typing

`type` sends `mode=keyboard`: real per-character `keydown`/`keypress`/
`beforeinput`/`input`/`keyup`, `isTrusted: true`, correct `code` values
(`KeyH`, `Space`), at jittered intervals near 45 to 66 ms.

The alternative is `mode=fill`, which sets the value through Playwright's
`fill()`. It emits a single `input` event and **zero key events**. Pages with
key listeners (search-as-you-type, React `onKeyDown`, contenteditable) see
nothing, and a form completed with no keyboard events is itself a bot signal.
`fill` is much faster, so it is the right choice only when nothing scores
behaviour and no listener depends on keys. Reach it with:

    rest POST /tabs/<tabId>/type '{"selector":"#q","text":"...","mode":"fill"}'

## Gotchas

- **Keyboard mode appends.** It focuses the element but does not select existing
  text. Use `--clear` to replace a value.
- **`--delay` is a floor, not the actual interval.** `--delay 40` measured about
  52 ms mean once per-character overhead is included.
- **The server's OpenAPI schema disagrees with the server in three places.**
  `mode`, `delay`, and `pressEnter` on `/type` are absent from the schema and
  implemented. The `clear` flag is present in the schema and ignored by the
  handler, so `--clear` emulates it with an empty `fill()` first. The
  `/screenshot` route returns raw `image/png`, not the JSON the schema claims.
- **Sessions are keyed by `userId`, fixed here to `camofox-skill`.** Tabs and
  logins persist for as long as the container lives. Two Claude Code sessions
  running this skill share tabs and see each other in `tabs`.
- **`localhost` inside the container is the container.** Use
  `http://host.docker.internal:<port>` to open an app served by the host, and
  bind that app to `0.0.0.0`.

## Do not mix in the MCP tools

If a `camofox-browser` MCP server is registered, it points at its own
`CAMOFOX_BASE_URL` and invents a hidden random `mcp-<uuid>` session id. Its
tools then drive a different browser, or the same browser under a session id
this script cannot see. Tabs opened with `camofox_create_tab` do not appear in
`tabs`, and a `tabId` from one side is not usable on the other.

Pick one interface per task. The REST API has 37 route and method pairs. The MCP
adapter exposes 11 of them, and this script reaches all 37 through `rest`.

## Fingerprint caveats

Known and deliberate. Read `README.md` in this skill before you change any of
them.

- **WebRTC exposes the real IP** via STUN `srflx` candidates, despite the rest
  of the fingerprint being coherent. No proxy is configured.
- **Fonts resolve 2/51.** This is Camoufox's bundled Linux set, not a container
  deficiency. Installing system fonts changes nothing pages can observe.
- **A local `geo` plugin** pins locale, timezone, and geolocation to
  pl-PL / Europe/Warsaw / Poznań, so the browser agrees with the real exit IP.
  Change the values in `docker/camofox.config.json`, and keep `TZ` in
  `docker/docker-compose.yml` equal to `plugins.geo.timezone`. A main-thread
  versus worker mismatch is stronger evidence of spoofing than an
  unusual-but-consistent value.
- **Screen and GPU re-roll on each browser launch.** One global browser instance
  serves every session, so all sessions of one container share one fingerprint.
