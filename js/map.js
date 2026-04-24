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
   * @param {{ onEdit: function, onDelete: function }} callbacks
   */
  function renderMarkers(lists, callbacks) {
    Object.values(layerGroups).forEach((g) => map.removeLayer(g));
    layerGroups = {};

    lists.forEach((list) => {
      if (!list.visible || !list.items.length) return;

      const group = L.layerGroup().addTo(map);
      layerGroups[list.id] = group;

      list.items.forEach((item) => {
        const marker = L.circleMarker([item.lat, item.lng], {
          color: list.color,
          fillColor: list.color,
          fillOpacity: 0.85,
          radius: 8,
          weight: 2,
        });

        marker.bindPopup(() => buildPopup(list, item));

        marker.on('popupopen', () => {
          const editBtn = document.getElementById(`osl-edit-${item.id}`);
          const deleteBtn = document.getElementById(`osl-delete-${item.id}`);
          editBtn?.addEventListener('click', () => callbacks.onEdit(list.id, item.id));
          deleteBtn?.addEventListener('click', () => callbacks.onDelete(list.id, item.id));
        });

        group.addLayer(marker);
      });
    });
  }

  /**
   * Builds the HTML string for a marker popup.
   * @param {Object} list
   * @param {Object} item
   * @returns {string}
   */
  function buildPopup(list, item) {
    const notes = item.notes
      ? `<p style="color:#555;font-size:12px;margin:4px 0 8px">${escapeHtml(item.notes)}</p>`
      : '';

    return `
      <div style="min-width:190px;font-family:sans-serif">
        <p style="font-weight:600;font-size:14px;margin:0 0 2px">
          ${escapeHtml(list.icon)} ${escapeHtml(item.name)}
        </p>
        ${notes}
        <div style="display:flex;gap:6px;margin-top:8px;flex-wrap:wrap">
          <a href="${item.google_maps_url}" target="_blank" rel="noopener"
             style="background:#4285F4;color:#fff;padding:4px 10px;border-radius:6px;font-size:12px;text-decoration:none">
            Google Maps
          </a>
          <button id="osl-edit-${item.id}"
            style="background:#6b7280;color:#fff;padding:4px 10px;border-radius:6px;font-size:12px;border:none;cursor:pointer">
            Edit
          </button>
          <button id="osl-delete-${item.id}"
            style="background:#ef4444;color:#fff;padding:4px 10px;border-radius:6px;font-size:12px;border:none;cursor:pointer">
            Delete
          </button>
        </div>
      </div>`;
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
    map.flyToBounds(bounds, { padding: [60, 60], maxZoom: 15 });
  }

  /**
   * Animates the map to center on a single coordinate.
   * @param {number} lat
   * @param {number} lng
   */
  function flyTo(lat, lng) {
    map.flyTo([lat, lng], 15);
  }

  return { init, renderMarkers, flyToBounds, flyTo };
})();
