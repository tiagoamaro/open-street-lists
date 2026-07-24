/**
 * Google Maps URL parsing for Open Street Lists.
 *
 * Exposes a global `GMaps` object (static no-build app, no modules).
 */
const GMaps = {
  /** True for goo.gl / maps.app.goo.gl short links (cannot be expanded client-side due to CORS). */
  isShortLink(url) {
    return /(?:^|\/\/)(?:maps\.app\.goo\.gl|goo\.gl)\//i.test(url);
  },

  /**
   * Parses a full Google Maps URL.
   *
   * @param {string} raw - URL pasted by the user.
   * @returns {{name: string, lat: number|null, lng: number|null, url: string}|null}
   *   name may be '' and lat/lng null when absent; null for non-Google URLs.
   */
  parseGoogleMapsUrl(raw) {
    const url = (raw || '').trim();
    if (!url) return null;

    let u;
    try { u = new URL(url); } catch (_) { return null; }
    const host = u.hostname.toLowerCase();
    const isGoogle =
      /(^|\.)google\.[a-z]{2,}(\.[a-z]{2})?$/.test(host) ||
      host === 'maps.app.goo.gl' ||
      host === 'goo.gl';
    if (!isGoogle) return null;

    // Name from the /place/<name>/ path segment
    let name = '';
    const placeMatch = u.pathname.match(/\/place\/([^/]+)/);
    if (placeMatch) {
      try { name = decodeURIComponent(placeMatch[1].replace(/\+/g, ' ')); }
      catch (_) { name = placeMatch[1].replace(/\+/g, ' '); }
    }

    // Coordinates: prefer the !3d…!4d… data pin (exact place) over the @lat,lng viewport center
    let lat = null;
    let lng = null;
    const decoded = url.replace(/%21/gi, '!');
    const pin = [...decoded.matchAll(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/g)].pop();
    const at = decoded.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
    const q = (u.searchParams.get('q') || u.searchParams.get('query') || '')
      .match(/^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/);

    if (pin) { lat = parseFloat(pin[1]); lng = parseFloat(pin[2]); }
    else if (at) { lat = parseFloat(at[1]); lng = parseFloat(at[2]); }
    else if (q) { lat = parseFloat(q[1]); lng = parseFloat(q[2]); }

    if (lat === null && !name) return null;
    return { name, lat, lng, url };
  },
};
