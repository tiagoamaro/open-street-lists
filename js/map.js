/**
 * Leaflet map controller.
 * Manages map initialization, marker rendering, and map interactions.
 * Depends on Leaflet (L) being loaded globally before this script.
 */
const MapController = (() => {
  let map = null;
  let layerGroups = {};

  // Caches one DivIcon per list (keyed by list.id) — invalidated when color/icon changes.
  const iconCache = {};

  /** Callback fired when the user clicks an empty spot on the map. */
  let onMapClick = null;

  /**
   * Initializes the Leaflet map inside the given DOM element ID.
   * @param {string} containerId
   * @param {function} clickCallback  (lat, lng) => void
   */
  function init(containerId, clickCallback) {
    onMapClick = clickCallback;

    map = L.map(containerId).setView([20, 0], 2);

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution:
        '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      maxZoom: 19,
    }).addTo(map);

    map.on('click', (e) => {
      if (onMapClick) onMapClick(e.latlng.lat, e.latlng.lng);
    });

    addWorldZoomControl();
  }

  /** Adds a "zoom to world" button below Leaflet's native zoom control. */
  function addWorldZoomControl() {
    const WorldZoom = L.Control.extend({
      options: { position: 'topleft' },
      onAdd() {
        const btn = L.DomUtil.create('button', 'leaflet-bar leaflet-control osl-world-zoom');
        btn.title = 'Zoom to world';
        btn.setAttribute('aria-label', 'Zoom to world');
        btn.innerHTML = '🌍';
        btn.style.cssText = 'display:block;width:34px;height:34px;line-height:34px;font-size:18px;text-align:center;cursor:pointer;background:#fff;border:1.5px solid #aaa;border-radius:6px;box-shadow:0 1px 4px rgba(0,0,0,0.2);';
        L.DomEvent.on(btn, 'click', (e) => {
          L.DomEvent.stopPropagation(e);
          map.flyTo([20, 0], 2, { duration: 0.8 });
        });
        L.DomEvent.disableClickPropagation(btn);
        return btn;
      },
    });
    new WorldZoom().addTo(map);
  }

  /**
   * Clears all markers and re-draws them from the lists array.
   * @param {Array} lists
   * @param {{ onOpen: function }} callbacks
   */
  function renderMarkers(lists, callbacks) {
    Object.values(layerGroups).forEach((g) => map.removeLayer(g));
    layerGroups = {};

    lists.forEach((list) => {
      if (!list.visible || !list.items.length) return;

      // One cluster group per list so lists stay visually separate.
      const cluster = L.markerClusterGroup({
        maxClusterRadius: 40,
        showCoverageOnHover: false,
      });

      // Cache icon per list — same color+emoji for all items in a list.
      const cacheKey = `${list.id}:${list.color}:${list.icon}`;
      if (!iconCache[list.id] || iconCache[list.id].key !== cacheKey) {
        iconCache[list.id] = { key: cacheKey, icon: buildPinIcon(list) };
      }
      const icon = iconCache[list.id].icon;

      list.items.forEach((item) => {
        const marker = L.marker([item.lat, item.lng], { icon });

        marker.on('click', (e) => {
          L.DomEvent.stopPropagation(e);
          callbacks.onOpen(list, item);
        });

        cluster.addLayer(marker);
      });

      cluster.addTo(map);
      layerGroups[list.id] = cluster;
    });
  }

  /**
   * Builds a Leaflet DivIcon shaped as an SVG map pin with the list's emoji centered.
   * @param {Object} list  must have .color (hex/CSS) and .icon (emoji)
   * @returns {L.DivIcon}
   */
  function buildPinIcon(list) {
    const color = escapeHtml(list.color);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="28" height="38" viewBox="0 0 28 38">
      <path d="M14 1 C7.37 1 2 6.37 2 13 C2 22 14 37 14 37 C14 37 26 22 26 13 C26 6.37 20.63 1 14 1Z"
            fill="${color}" stroke="white" stroke-width="2"/>
      <circle cx="14" cy="13" r="9" fill="white"/>
      <text x="14" y="14" text-anchor="middle" dominant-baseline="middle" font-size="12">${list.icon}</text>
    </svg>`;

    return L.divIcon({
      html: svg,
      className: 'osl-pin-marker',
      iconSize: [28, 38],
      iconAnchor: [14, 37],
      popupAnchor: [0, -38],
    });
  }

  /** Escapes HTML to prevent XSS in popup content. */
  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /**
   * Animates the map to fit all items of a list within the viewport.
   * @param {Array<{lat: number, lng: number}>} items
   */
  function flyToBounds(items) {
    if (!items.length) return;
    const bounds = L.latLngBounds(items.map((i) => [i.lat, i.lng]));
    map.flyToBounds(bounds, { padding: [60, 60], maxZoom: 15, duration: 0.6 });
  }

  /**
   * Animates the map to center on a single coordinate.
   * @param {number} lat
   * @param {number} lng
   */
  function flyTo(lat, lng) {
    map.flyTo([lat, lng], 18, { duration: 0.6 });
  }

  let searchMarker = null;

  /**
   * Builds the orange "+" pin icon used for search result markers.
   * @returns {L.DivIcon}
   */
  function buildSearchPinIcon() {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="28" height="38" viewBox="0 0 28 38">
      <path d="M14 1 C7.37 1 2 6.37 2 13 C2 22 14 37 14 37 C14 37 26 22 26 13 C26 6.37 20.63 1 14 1Z"
            fill="#f97316" stroke="white" stroke-width="2"/>
      <circle cx="14" cy="13" r="9" fill="white"/>
      <text x="14" y="14" text-anchor="middle" dominant-baseline="middle" font-size="16" font-weight="bold" fill="#f97316">+</text>
    </svg>`;

    return L.divIcon({
      html: svg,
      className: 'osl-pin-marker',
      iconSize: [28, 38],
      iconAnchor: [14, 37],
      popupAnchor: [0, -38],
    });
  }

  /**
   * Places an orange "+" pin at a search result location.
   * Clicking the pin directly triggers the add-to-list callback.
   * @param {number} lat
   * @param {number} lng
   * @param {string} name
   * @param {function} onAdd  called with (lat, lng) when user clicks the pin
   */
  function showSearchMarker(lat, lng, name, onAdd) {
    clearSearchMarker();

    searchMarker = L.marker([lat, lng], { icon: buildSearchPinIcon() }).addTo(map);

    searchMarker.on('click', (e) => {
      L.DomEvent.stopPropagation(e);
      onAdd(lat, lng);
    });
  }

  /** Removes the search result marker from the map. */
  function clearSearchMarker() {
    if (searchMarker) {
      map.removeLayer(searchMarker);
      searchMarker = null;
    }
  }

  return { init, renderMarkers, flyToBounds, flyTo, showSearchMarker, clearSearchMarker };
})();
