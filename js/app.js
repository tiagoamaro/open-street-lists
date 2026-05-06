/**
 * Alpine.js root component for Open Street Lists.
 * Registered via alpine:init so it's available before Alpine boots.
 *
 * Depends on: Gist (gist.js), MapController (map.js), Alpine (CDN)
 */
document.addEventListener('alpine:init', () => {
  Alpine.data('app', () => ({
    // ── Data ──────────────────────────────────────────────────────────
    lists: [],
    expandedLists: [],
    sidebarOpen: window.innerWidth >= 768,

    // ── Modal state ───────────────────────────────────────────────────
    modal: null,        // 'settings' | 'list' | 'item' | 'marker' | null
    editMode: false,
    editListId: null,
    editItemId: null,

    // ── Marker modal ──────────────────────────────────────────────────
    markerList: null,
    markerItem: null,

    // ── Form models ───────────────────────────────────────────────────
    formSettings: { token: '', gistId: '', searchEngine: 'nominatim', geoapifyKey: '' },
    settingsError: '',
    settingsSuccess: '',

    formList: { name: '', icon: '', color: '#3b82f6' },

    formItem: {
      listId: '',
      originalListId: '',
      name: '',
      lat: '',
      lng: '',
      notes: '',
      google_maps_url: '',
    },

    // ── Sidebar resize ───────────────────────────────────────────────
    sidebarWidth: parseInt(localStorage.getItem('sidebarWidth') ?? '288', 10),
    _sidebarResizing: false,

    // ── Reorder ───────────────────────────────────────────────────────
    reorderingLists: false,
    reorderingListId: null,
    _itemContainers: {},
    _sortableInstances: {},
    _listsSortable: null,

    // ── Theme ─────────────────────────────────────────────────────────
    darkMode: false,

    // ── Sync ──────────────────────────────────────────────────────────
    syncStatus: 'idle', // idle | syncing | synced | error | dirty | offline
    syncVersion: 0,

    // ── Geolocation ───────────────────────────────────────────────────
    locating: false,

    // ── Place search ──────────────────────────────────────────────────
    searchQuery: '',
    searchResults: [],
    searching: false,
    searchOpen: false,
    _searchTimer: null,

    // ── List item search ──────────────────────────────────────────────
    listItemSearch: '',

    // ── Pickers ───────────────────────────────────────────────────────
    iconOptions: ['✈️','⭐','📍','❤️'],
    colorOptions: [
      '#3b82f6','#ef4444','#10b981','#f59e0b','#8b5cf6',
      '#ec4899','#06b6d4','#84cc16','#f97316','#6b7280',
    ],

    // ── Computed ──────────────────────────────────────────────────────
    get syncMessage() {
      return {
        idle:    '🔄 Sync',
        syncing: '🔄 Syncing…',
        synced:  '✓ Synced',
        error:   '⚠ Error',
        dirty:   '🔄 Sync',
        offline: '📵 Offline',
      }[this.syncStatus] ?? '🔄 Sync';
    },

    get syncSymbol() {
      return {
        idle:    '🔄',
        syncing: '🔄',
        synced:  '✓',
        error:   '⚠',
        dirty:   '🔄',
        offline: '📵',
      }[this.syncStatus] ?? '🔄';
    },

    /** Returns [{list, item}] matching listItemSearch across name and notes. */
    get listItemSearchResults() {
      const q = this.listItemSearch.trim().toLowerCase();
      if (!q) return [];
      const results = [];
      for (const list of this.lists) {
        for (const item of list.items) {
          if (
            item.name.toLowerCase().includes(q) ||
            (item.notes && item.notes.toLowerCase().includes(q))
          ) {
            results.push({ list, item });
          }
        }
      }
      return results;
    },

    get syncButtonClass() {
      return {
        idle:    'bg-blue-600 text-white hover:bg-blue-700',
        syncing: 'bg-blue-600 text-white',
        synced:  'bg-green-600 text-white hover:bg-green-700',
        error:   'bg-red-600 text-white hover:bg-red-700',
        dirty:   'bg-blue-600 text-white hover:bg-blue-700',
        offline: 'bg-orange-500 text-white hover:bg-orange-600',
      }[this.syncStatus] ?? 'bg-blue-600 text-white hover:bg-blue-700';
    },

    // ── Lifecycle ─────────────────────────────────────────────────────
    init() {
      const savedSettings = localStorage.getItem('osl_settings');
      if (savedSettings) {
        const s = JSON.parse(savedSettings);
        this.formSettings = {
          token: s.token || '',
          gistId: s.gistId || '',
          searchEngine: s.searchEngine || 'nominatim',
          geoapifyKey: s.geoapifyKey || '',
        };
      }

      this.darkMode = localStorage.getItem('osl_dark') === 'true';
      this._applyDark();

      const cachedData = localStorage.getItem('osl_data');
      if (cachedData) {
        try {
          const data = JSON.parse(cachedData);
          this.lists = data.lists || [];
          this.syncVersion = data.syncVersion || 0;
          this.sortAllLists();
          this.ensurePositions();
        } catch (_) { /* ignore corrupt cache */ }
      }

      this.$nextTick(() => {
        MapController.init('map', (lat, lng) => this.openAddItem(null, lat, lng));
        this.renderMap();

        const { token, gistId } = this.formSettings;
        if (token && gistId) this.loadFromGist();

        // Sidebar drag-to-resize (desktop only)
        const onMouseMove = (e) => {
          if (!this._sidebarResizing) return;
          const w = Math.min(600, Math.max(180, e.clientX));
          this.sidebarWidth = w;
          localStorage.setItem('sidebarWidth', w);
        };
        const onMouseUp = () => { this._sidebarResizing = false; };
        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
      });
    },

    // ── Theme ─────────────────────────────────────────────────────────
    toggleDark() {
      this.darkMode = !this.darkMode;
      localStorage.setItem('osl_dark', this.darkMode);
      this._applyDark();
    },

    _applyDark() {
      document.documentElement.classList.toggle('dark', this.darkMode);
    },

    // ── Internal helpers ──────────────────────────────────────────────
    settings() {
      return JSON.parse(localStorage.getItem('osl_settings') || '{}');
    },

    /** Sorts a list's items by position; falls back to newest-first by created_at for legacy data. */
    sortItems(list) {
      list.items.sort((a, b) => {
        if (a.position !== undefined && b.position !== undefined) return a.position - b.position;
        if (a.position !== undefined) return -1;
        if (b.position !== undefined) return 1;
        if (!a.created_at && !b.created_at) return 0;
        if (!a.created_at) return 1;
        if (!b.created_at) return -1;
        return b.created_at.localeCompare(a.created_at);
      });
    },

    sortAllLists() {
      this.lists.sort((a, b) => {
        if (a.position !== undefined && b.position !== undefined) return a.position - b.position;
        if (a.position !== undefined) return -1;
        if (b.position !== undefined) return 1;
        return 0;
      });
      this.lists.forEach((l) => this.sortItems(l));
    },

    /** Stamps position on any list or item that lacks one (migration for existing data). */
    ensurePositions() {
      this.lists.forEach((list, li) => {
        if (list.position === undefined) list.position = li;
        list.items.forEach((item, ii) => {
          if (item.position === undefined) item.position = ii;
        });
      });
    },

    saveLocal() {
      localStorage.setItem('osl_data', JSON.stringify({ version: 1, syncVersion: this.syncVersion, lists: this.lists }));
      this.syncStatus = 'dirty';
    },

    renderMap() {
      MapController.renderMarkers(this.lists, {
        onOpen: (list, item) => this.openMarkerModal(list, item),
      });
    },

    openMarkerModal(list, item) {
      this.markerList = list;
      this.markerItem = item;
      this.modal = 'marker';
      MapController.flyTo(item.lat, item.lng);
    },

    async loadFromGist() {
      const { token, gistId } = this.formSettings;
      try {
        this.syncStatus = 'syncing';
        const data = await Gist.load(gistId, token);
        this.lists = data.lists || [];
        this.syncVersion = data.syncVersion || 0;
        this.sortAllLists();
        this.ensurePositions();
        localStorage.setItem('osl_data', JSON.stringify(data));
        this.syncStatus = 'synced';
        this.renderMap();
      } catch (_) {
        this.syncStatus = navigator.onLine ? 'error' : 'offline';
      }
    },

    // ── Sync ──────────────────────────────────────────────────────────
    async sync() {
      const { token, gistId } = this.formSettings;
      if (!token) { this.modal = 'settings'; return; }

      try {
        this.syncStatus = 'syncing';

        if (!gistId) {
          const data = { version: 1, syncVersion: 1, lists: this.lists };
          const newId = await Gist.create(token, data);
          this.formSettings.gistId = newId;
          this.syncVersion = 1;
          localStorage.setItem('osl_settings', JSON.stringify(this.formSettings));
          localStorage.setItem('osl_data', JSON.stringify(data));
        } else {
          // Pull first; if remote is ahead, adopt remote data before pushing.
          const remote = await Gist.load(gistId, token);
          const remoteSyncVersion = remote.syncVersion || 0;

          if (remoteSyncVersion > this.syncVersion) {
            this.lists = remote.lists || [];
            this.sortAllLists();
            this.ensurePositions();
            this.renderMap();
          }

          const nextVersion = Math.max(remoteSyncVersion, this.syncVersion) + 1;
          const data = { version: 1, syncVersion: nextVersion, lists: this.lists };
          await Gist.save(gistId, token, data);
          this.syncVersion = nextVersion;
          localStorage.setItem('osl_data', JSON.stringify(data));
        }

        this.syncStatus = 'synced';
      } catch (_) {
        this.syncStatus = navigator.onLine ? 'error' : 'offline';
      }
    },

    // ── Settings ──────────────────────────────────────────────────────
    async saveSettings() {
      this.settingsError = '';
      this.settingsSuccess = '';

      localStorage.setItem('osl_settings', JSON.stringify(this.formSettings));

      if (!this.formSettings.token.trim()) {
        this.settingsSuccess = 'Settings saved.';
        return;
      }

      if (this.formSettings.gistId) {
        try {
          const data = await Gist.load(this.formSettings.gistId, this.formSettings.token);
          this.lists = data.lists || [];
          this.saveLocal();
          this.syncStatus = 'synced';
          this.settingsSuccess = 'Connected! Data loaded from Gist.';
          this.renderMap();
        } catch (e) {
          this.settingsError = `Could not load Gist: ${e.message}`;
        }
      } else {
        this.settingsSuccess = 'Token saved. Click Sync to create a new Gist.';
      }
    },

    // ── List CRUD ─────────────────────────────────────────────────────
    openAddList() {
      this.editMode = false;
      this.editListId = null;
      this.formList = { name: '', icon: '📍', color: '#3b82f6' };
      this.modal = 'list';
    },

    openEditList(listId) {
      const list = this.lists.find((l) => l.id === listId);
      if (!list) return;
      this.editMode = true;
      this.editListId = listId;
      this.formList = { name: list.name, icon: list.icon, color: list.color };
      this.modal = 'list';
    },

    saveList() {
      if (!this.formList.name.trim()) return;

      if (this.editMode) {
        const list = this.lists.find((l) => l.id === this.editListId);
        if (list) Object.assign(list, { name: this.formList.name, icon: this.formList.icon, color: this.formList.color });
      } else {
        this.lists.push({
          id: crypto.randomUUID(),
          name: this.formList.name,
          icon: this.formList.icon,
          color: this.formList.color,
          visible: true,
          items: [],
          position: this.lists.length,
        });
      }

      this.modal = null;
      this.saveLocal();
      this.renderMap();
    },

    deleteList(listId) {
      if (!confirm('Delete this list and all its places?')) return;
      this.lists = this.lists.filter((l) => l.id !== listId);
      this.modal = null;
      this.saveLocal();
      this.renderMap();
    },

    toggleList(listId) {
      const list = this.lists.find((l) => l.id === listId);
      if (list) list.visible = !list.visible;
      this.saveLocal();
      this.renderMap();
    },

    toggleExpand(listId) {
      if (this.expandedLists.includes(listId)) {
        this.expandedLists = this.expandedLists.filter((id) => id !== listId);
      } else {
        this.expandedLists.push(listId);
      }
    },

    flyToList(listId) {
      const list = this.lists.find((l) => l.id === listId);
      if (list?.items.length) MapController.flyToBounds(list.items);
    },

    // ── Item CRUD ─────────────────────────────────────────────────────
    openAddItem(listId = null, lat = '', lng = '', name = '') {
      if (!this.lists.length) {
        alert('Create a list first before adding places.');
        return;
      }

      this.editMode = false;
      this.editItemId = null;

      const defaultListId = listId || this.lists[0].id;
      const fLat = lat !== '' ? parseFloat(Number(lat).toFixed(6)) : '';
      const fLng = lng !== '' ? parseFloat(Number(lng).toFixed(6)) : '';

      this.formItem = {
        listId: defaultListId,
        originalListId: defaultListId,
        name: name,
        lat: fLat,
        lng: fLng,
        notes: '',
        google_maps_url: fLat !== '' ? `https://maps.google.com/?q=${fLat},${fLng}` : '',
      };
      this.modal = 'item';
    },

    openEditItem(listId, itemId) {
      const list = this.lists.find((l) => l.id === listId);
      const item = list?.items.find((i) => i.id === itemId);
      if (!item) return;

      this.editMode = true;
      this.editItemId = itemId;
      this.formItem = {
        listId,
        originalListId: listId,
        name: item.name,
        lat: item.lat,
        lng: item.lng,
        notes: item.notes || '',
        google_maps_url: item.google_maps_url,
      };
      this.modal = 'item';
    },

    updateGoogleMapsUrl() {
      const { lat, lng } = this.formItem;
      if (lat !== '' && lng !== '') {
        this.formItem.google_maps_url = `https://maps.google.com/?q=${lat},${lng}`;
      }
    },

    saveItem() {
      const { name, lat, lng } = this.formItem;
      if (!name.trim() || lat === '' || lng === '') return;

      // Preserve created_at and position on edit; stamp now / append at end on create.
      let createdAt = new Date().toISOString();
      let position;
      if (this.editMode) {
        const origList = this.lists.find((l) => l.id === this.formItem.originalListId);
        const existing = origList?.items.find((i) => i.id === this.editItemId);
        if (existing?.created_at) createdAt = existing.created_at;
        // Keep position only when staying in the same list
        if (existing?.position !== undefined && this.formItem.listId === this.formItem.originalListId) {
          position = existing.position;
        }
      }
      if (position === undefined) {
        // New item or moved to a different list — append at end
        const targetList = this.lists.find((l) => l.id === this.formItem.listId);
        position = targetList ? targetList.items.length : 0;
      }

      const item = {
        id: this.editItemId || crypto.randomUUID(),
        name: name.trim(),
        lat: parseFloat(lat),
        lng: parseFloat(lng),
        notes: this.formItem.notes.trim(),
        google_maps_url:
          this.formItem.google_maps_url.trim() ||
          `https://maps.google.com/?q=${lat},${lng}`,
        created_at: createdAt,
        position,
      };

      if (this.editMode) {
        // Remove from original list (handles moving between lists)
        const origList = this.lists.find((l) => l.id === this.formItem.originalListId);
        if (origList) origList.items = origList.items.filter((i) => i.id !== this.editItemId);
      }

      const targetList = this.lists.find((l) => l.id === this.formItem.listId);
      if (targetList) {
        targetList.items.push(item);
        this.sortItems(targetList);
      }

      this.modal = null;
      this.saveLocal();
      this.renderMap();
    },

    deleteItem(listId, itemId) {
      if (!confirm('Delete this place?')) return;
      const list = this.lists.find((l) => l.id === listId);
      if (list) list.items = list.items.filter((i) => i.id !== itemId);
      this.modal = null;
      this.saveLocal();
      this.renderMap();
    },

    flyToItem(item) {
      MapController.flyTo(item.lat, item.lng);
    },

    // ── Place search ──────────────────────────────────────────────────
    onSearchInput() {
      clearTimeout(this._searchTimer);
      if (!this.searchQuery.trim()) {
        this.searchResults = [];
        return;
      }
      this._searchTimer = setTimeout(() => this.doSearch(), 400);
    },

    async doSearch() {
      this.searching = true;
      try {
        const engine = this.formSettings.searchEngine || 'nominatim';
        if (engine === 'photon') {
          await this._searchPhoton();
        } else if (engine === 'geoapify') {
          await this._searchGeoapify();
        } else {
          await this._searchNominatim();
        }
      } catch (_) {
        this.searchResults = [];
      } finally {
        this.searching = false;
      }
    },

    async _searchNominatim() {
      const q = encodeURIComponent(this.searchQuery.trim());
      const res = await fetch(
        `https://nominatim.openstreetmap.org/search?q=${q}&format=json&limit=6&addressdetails=0`,
        { headers: { Accept: 'application/json' } }
      );
      // Nominatim already returns { place_id, display_name, lat, lon }
      this.searchResults = await res.json();
    },

    async _searchPhoton() {
      const q = encodeURIComponent(this.searchQuery.trim());
      const res = await fetch(`https://photon.komoot.io/api/?q=${q}&limit=6`);
      const data = await res.json();
      this.searchResults = (data.features || []).map((f, i) => ({
        place_id: `photon-${i}-${f.geometry.coordinates.join(',')}`,
        display_name: [f.properties.name, f.properties.city, f.properties.state, f.properties.country]
          .filter(Boolean).join(', '),
        lat: f.geometry.coordinates[1],
        lon: f.geometry.coordinates[0],
      }));
    },

    async _searchGeoapify() {
      const key = this.formSettings.geoapifyKey;
      if (!key) { this.searchResults = []; return; }
      const q = encodeURIComponent(this.searchQuery.trim());
      const res = await fetch(
        `https://api.geoapify.com/v1/geocode/autocomplete?text=${q}&limit=6&apiKey=${key}`
      );
      const data = await res.json();
      this.searchResults = (data.features || []).map((f) => ({
        place_id: f.properties.place_id || `${f.properties.lat},${f.properties.lon}`,
        display_name: f.properties.formatted,
        lat: f.properties.lat,
        lon: f.properties.lon,
      }));
    },

    selectSearchResult(result) {
      const lat = parseFloat(result.lat);
      const lng = parseFloat(result.lon);
      MapController.flyTo(lat, lng);
      MapController.showSearchMarker(lat, lng, result.display_name, (lat, lng) => {
        MapController.clearSearchMarker();
        this.openAddItem(null, lat, lng, result.display_name);
      });
      this.searchQuery = '';
      this.searchResults = [];
    },

    clearSearch() {
      this.searchQuery = '';
      this.searchResults = [];
      MapController.clearSearchMarker();
    },

    // ── Drag-and-drop reordering ──────────────────────────────────────
    registerItemContainer(el, listId) {
      this._itemContainers[listId] = el;
    },

    toggleListReorder() {
      this.reorderingLists = !this.reorderingLists;
      if (this.reorderingLists) {
        this.$nextTick(() => {
          const el = this.$refs.listsContainer;
          if (!el) return;
          this._listsSortable = Sortable.create(el, {
            animation: 150,
            handle: '.list-drag-handle',
            draggable: '[data-list-id]',
            onEnd: (evt) => this.onListReorder(evt),
          });
        });
      } else {
        this._listsSortable?.destroy();
        this._listsSortable = null;
      }
    },

    toggleItemReorder(listId) {
      if (this.reorderingListId === listId) {
        this._sortableInstances[listId]?.destroy();
        delete this._sortableInstances[listId];
        this.reorderingListId = null;
      } else {
        if (this.reorderingListId !== null) {
          this._sortableInstances[this.reorderingListId]?.destroy();
          delete this._sortableInstances[this.reorderingListId];
        }
        this.reorderingListId = listId;
        this.$nextTick(() => {
          const el = this._itemContainers[listId];
          if (!el) return;
          this._sortableInstances[listId] = Sortable.create(el, {
            animation: 150,
            handle: '.item-drag-handle',
            draggable: '[data-item-id]',
            onEnd: (evt) => this.onItemReorder(listId, evt),
          });
        });
      }
    },

    onListReorder() {
      // Read new order directly from DOM to avoid template-element index offsets
      const el = this.$refs.listsContainer;
      const ordered = Array.from(el.querySelectorAll('[data-list-id]'))
        .map((node) => node.dataset.listId);
      this.lists = ordered.map((id) => this.lists.find((l) => l.id === id)).filter(Boolean);
      this.lists.forEach((list, i) => { list.position = i; });
      this.saveLocal();
    },

    onItemReorder(listId) {
      const list = this.lists.find((l) => l.id === listId);
      if (!list) return;
      const el = this._itemContainers[listId];
      const ordered = Array.from(el.querySelectorAll('[data-item-id]'))
        .map((node) => node.dataset.itemId);
      list.items = ordered.map((id) => list.items.find((i) => i.id === id)).filter(Boolean);
      list.items.forEach((item, i) => { item.position = i; });
      this.saveLocal();
    },

    // ── Geolocation ───────────────────────────────────────────────────
    locateMe() {
      if (!navigator.geolocation) {
        alert('Geolocation is not supported by your browser.');
        return;
      }
      this.locating = true;
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          MapController.flyTo(pos.coords.latitude, pos.coords.longitude);
          this.locating = false;
        },
        () => {
          alert('Could not get your location. Check browser permissions.');
          this.locating = false;
        },
        { enableHighAccuracy: true, timeout: 10000 }
      );
    },
  }));
});
