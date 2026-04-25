/**
 * Leaflet map controller.
 * Manages map initialization, marker rendering, and map interactions.
 * Depends on Leaflet (L) being loaded globally before this script.
 */
const MapController = (() => {
  let map = null;
  let layerGroups = {};

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

      const group = L.layerGroup().addTo(map);
      layerGroups[list.id] = group;

      list.items.forEach((item) => {
        const marker = L.marker([item.lat, item.lng], { icon: buildPinIcon(list) });

        marker.on('click', (e) => {
          L.DomEvent.stopPropagation(e);
          callbacks.onOpen(list, item);
        });

        group.addLayer(marker);
      });
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
      <text x="14" y="14" text-anchor="middle" dominant-baseline="middle" font-size="13">${list.icon}</text>
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
    map.flyTo([lat, lng], 15, { duration: 0.6 });
  }

  let searchMarker = null;

  /**
   * Places a distinct orange marker at a search result location.
   * The popup includes an "Add to list" button that triggers the callback.
   * @param {number} lat
   * @param {number} lng
   * @param {string} name
   * @param {function} onAdd  called with (lat, lng) when user clicks "Add to list"
   */
  function showSearchMarker(lat, lng, name, onAdd) {
    clearSearchMarker();

    searchMarker = L.circleMarker([lat, lng], {
      color: '#f97316',
      fillColor: '#f97316',
      fillOpacity: 0.9,
      radius: 10,
      weight: 3,
    }).addTo(map);

    const popup = L.popup({ offset: [0, -5] }).setContent(`
      <div style="min-width:180px;font-family:sans-serif">
        <p style="font-weight:600;font-size:13px;margin:0 0 8px">${escapeHtml(name)}</p>
        <button id="osl-search-add"
          style="background:#3b82f6;color:#fff;padding:4px 12px;border-radius:6px;font-size:12px;border:none;cursor:pointer;width:100%">
          + Add to list
        </button>
      </div>`);

    searchMarker.bindPopup(popup).openPopup();

    searchMarker.on('popupopen', () => {
      document.getElementById('osl-search-add')
        ?.addEventListener('click', () => onAdd(lat, lng));
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
