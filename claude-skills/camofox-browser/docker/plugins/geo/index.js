/**
 * Local `geo` plugin for camofox-browser.
 *
 * Purpose
 * -------
 * Upstream `server.js` hardcodes a US Pacific browser context whenever no
 * proxy is configured:
 *
 *   if (!CONFIG.proxy.host) {
 *     contextOptions.locale = 'en-US';
 *     contextOptions.timezoneId = 'America/Los_Angeles';
 *     contextOptions.geolocation = { latitude: 37.7749, longitude: -122.4194 };
 *   }
 *
 * Every request still exits from the host's real IP, so the browser
 * contradicts its own network location — a trivially detectable mismatch.
 * `geoip` (which would derive these from the exit IP) is gated behind
 * `geoip: !!launchProxy`, so it cannot be enabled without a proxy.
 *
 * This plugin overrides those three values on the `session:creating` hook,
 * which fires immediately before `browser.newContext(contextOptions)`. Pair it
 * with `TZ` in the environment: Playwright's `timezoneId` emulation does not
 * reach ServiceWorker scopes, which fall through to the container's system
 * timezone, so both are needed for main thread and workers to agree.
 *
 * Configuration (camofox.config.json), env vars take precedence:
 *
 *   "geo": {
 *     "enabled": true,
 *     "locale": "pl-PL",              CAMOFOX_GEO_LOCALE
 *     "timezone": "Europe/Warsaw",    CAMOFOX_GEO_TZ
 *     "latitude": 52.4064,            CAMOFOX_GEO_LAT
 *     "longitude": 16.9252            CAMOFOX_GEO_LON
 *   }
 *
 * Deliberately out of scope
 * -------------------------
 * No WebRTC blocking. Upstream declined a server-wide WebRTC kill on the
 * grounds that the block is itself a fingerprint (jo-inc/camofox-browser#3109),
 * and with no proxy the real IP is already visible over TCP, so suppressing ICE
 * candidates costs entropy while hiding nothing.
 *
 * `browser:launching` fires after camoufox-js has generated the fingerprint and
 * serialised it into chunked CAMOU_CONFIG_* env vars, so `os`, UA family,
 * WebGL renderer and screen dimensions cannot be changed from a plugin.
 */

function isValidTimezone(tz) {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

function isValidLocale(locale) {
  try {
    return Intl.getCanonicalLocales(locale).length === 1;
  } catch {
    return false;
  }
}

function coord(value, fallback) {
  const n = parseFloat(value);
  return Number.isFinite(n) ? n : fallback;
}

export async function register(app, ctx, pluginConfig = {}) {
  const { events, log } = ctx;

  // Upstream only applies its US Pacific defaults when no proxy is set. If a
  // proxy is ever configured, camoufox's geoip derives location from the exit
  // IP -- overriding it with a fixed profile would reintroduce the exact
  // mismatch this plugin exists to remove.
  if (ctx.config?.proxy?.host) {
    log('info', 'geo plugin inactive: proxy configured, deferring to camoufox geoip');
    return;
  }

  const locale = process.env.CAMOFOX_GEO_LOCALE || pluginConfig.locale || null;
  const timezone = process.env.CAMOFOX_GEO_TZ || pluginConfig.timezone || null;
  const latitude = coord(process.env.CAMOFOX_GEO_LAT, coord(pluginConfig.latitude, null));
  const longitude = coord(process.env.CAMOFOX_GEO_LON, coord(pluginConfig.longitude, null));

  const applied = {};

  if (locale) {
    if (isValidLocale(locale)) applied.locale = locale;
    else log('warn', 'geo plugin: ignoring invalid locale', { locale });
  }

  if (timezone) {
    if (isValidTimezone(timezone)) applied.timezoneId = timezone;
    else log('warn', 'geo plugin: ignoring invalid IANA timezone', { timezone });
  }

  const hasCoords = latitude !== null && longitude !== null;
  const inBounds = hasCoords
    && latitude >= -90 && latitude <= 90
    && longitude >= -180 && longitude <= 180;
  if (hasCoords) {
    if (inBounds) applied.geolocation = { latitude, longitude };
    else log('warn', 'geo plugin: ignoring out-of-range coordinates', { latitude, longitude });
  }

  if (Object.keys(applied).length === 0) {
    log('info', 'geo plugin registered with nothing to apply; leaving upstream defaults');
    return;
  }

  // System TZ backs the worker scopes that Playwright's timezoneId misses. A
  // mismatch here is worth surfacing, since it is precisely the inconsistency
  // this plugin is meant to close.
  if (applied.timezoneId && process.env.TZ && process.env.TZ !== applied.timezoneId) {
    log('warn', 'geo plugin: TZ env differs from context timezone; workers will disagree', {
      TZ: process.env.TZ,
      timezoneId: applied.timezoneId,
    });
  } else if (applied.timezoneId && !process.env.TZ) {
    log('warn', 'geo plugin: TZ env unset; worker scopes will report UTC', {
      timezoneId: applied.timezoneId,
    });
  }

  log('info', 'geo plugin registered', applied);

  // Playwright's per-context `locale` reaches the main thread and dedicated
  // Workers, but not ServiceWorker/SharedWorker scopes -- those read the
  // browser-level locale and would keep reporting en-US, producing exactly the
  // kind of main-vs-worker disagreement this plugin exists to remove. Setting
  // the pref at launch is safe here because the server runs a single global
  // browser instance shared by every session.
  if (applied.locale) {
    // Deliberately the bare locale rather than a realistic weighted list
    // ("pl-PL,pl;q=0.8,en-US;q=0.5,en;q=0.3"). Playwright's per-context locale
    // forces navigator.languages to a single entry on the main thread, so a
    // longer pref list makes worker scopes disagree with it. A one-entry list
    // is merely uncommon; a main-vs-worker mismatch is positive evidence of
    // spoofing, and it is also what upstream already produced with en-US.
    const acceptLanguages = applied.locale;
    events.on('browser:launching', ({ options }) => {
      options.firefoxUserPrefs = options.firefoxUserPrefs || {};
      options.firefoxUserPrefs['intl.accept_languages'] = acceptLanguages;
      options.firefoxUserPrefs['intl.locale.requested'] = applied.locale;
      log('info', 'geo plugin set browser-level locale prefs', { acceptLanguages });
    });
  }

  events.on('session:creating', ({ userId, contextOptions }) => {
    Object.assign(contextOptions, applied);
    log('debug', 'geo plugin applied context overrides', { userId, ...applied });
  });
}

export default register;
