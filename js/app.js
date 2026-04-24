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
    modal: null,        // 'settings' | 'list' | 'item' | null
    editMode: false,
    editListId: null,
    editItemId: null,

    // ── Form models ───────────────────────────────────────────────────
    formSettings: { token: '', gistId: '' },
    settingsError: '',
    settingsSuccess: '',

    formList: { name: '', icon: '📍', color: '#3b82f6' },

    formItem: {
      listId: '',
      originalListId: '',
      name: '',
      lat: '',
      lng: '',
      notes: '',
      google_maps_url: '',
    },

    // ── Sync ──────────────────────────────────────────────────────────
    syncStatus: 'idle', // idle | syncing | synced | error | dirty | offline

    // ── Pickers ───────────────────────────────────────────────────────
    iconOptions: [
      '📍','🍽️','🏖️','🛍️','🏛️','🌳','🏠','⭐','❤️','🎯',
      '🎭','🎵','🍺','☕','🏋️','🏨','🚂','✈️','🌊','🏔️',
    ],
    colorOptions: [
      '#3b82f6','#ef4444','#10b981','#f59e0b','#8b5cf6',
      '#ec4899','#06b6d4','#84cc16','#f97316','#6b7280',
    ],

    // ── Computed ──────────────────────────────────────────────────────
    get syncMessage() {
      return {
        idle:    'Not synced',
        syncing: 'Syncing…',
        synced:  'Synced',
        error:   'Sync error',
        dirty:   'Unsaved changes',
        offline: 'Offline',
      }[this.syncStatus] ?? '';
    },

    get syncStatusClass() {
      return {
        idle:    'bg-gray-100 text-gray-500',
        syncing: 'bg-blue-100 text-blue-700',
        synced:  'bg-green-100 text-green-700',
        error:   'bg-red-100 text-red-700',
        dirty:   'bg-yellow-100 text-yellow-700',
        offline: 'bg-orange-100 text-orange-700',
      }[this.syncStatus] ?? '';
    },

    // ── Lifecycle ─────────────────────────────────────────────────────
    init() {
      const savedSettings = localStorage.getItem('osl_settings');
      if (savedSettings) {
        const s = JSON.parse(savedSettings);
        this.formSettings = { token: s.token || '', gistId: s.gistId || '' };
      }

      const cachedData = localStorage.getItem('osl_data');
      if (cachedData) {
        try {
          const data = JSON.parse(cachedData);
          this.lists = data.lists || [];
        } catch (_) { /* ignore corrupt cache */ }
      }

      this.$nextTick(() => {
        MapController.init('map', (lat, lng) => this.openAddItem(null, lat, lng));
        this.renderMap();

        const { token, gistId } = this.formSettings;
        if (token && gistId) this.loadFromGist();
      });
    },

    // ── Internal helpers ──────────────────────────────────────────────
    settings() {
      return JSON.parse(localStorage.getItem('osl_settings') || '{}');
    },

    saveLocal() {
      localStorage.setItem('osl_data', JSON.stringify({ version: 1, lists: this.lists }));
      this.syncStatus = 'dirty';
    },

    renderMap() {
      MapController.renderMarkers(this.lists, {
        onEdit:   (listId, itemId) => this.openEditItem(listId, itemId),
        onDelete: (listId, itemId) => this.deleteItem(listId, itemId),
      });
    },

    async loadFromGist() {
      const { token, gistId } = this.formSettings;
      try {
        this.syncStatus = 'syncing';
        const data = await Gist.load(gistId, token);
        this.lists = data.lists || [];
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
        const data = { version: 1, lists: this.lists };

        if (!gistId) {
          const newId = await Gist.create(token, data);
          this.formSettings.gistId = newId;
          localStorage.setItem('osl_settings', JSON.stringify(this.formSettings));
        } else {
          await Gist.save(gistId, token, data);
        }

        localStorage.setItem('osl_data', JSON.stringify(data));
        this.syncStatus = 'synced';
      } catch (_) {
        this.syncStatus = navigator.onLine ? 'error' : 'offline';
      }
    },

    // ── Settings ──────────────────────────────────────────────────────
    async saveSettings() {
      this.settingsError = '';
      this.settingsSuccess = '';

      if (!this.formSettings.token.trim()) {
        this.settingsError = 'A GitHub token is required.';
        return;
      }

      localStorage.setItem('osl_settings', JSON.stringify(this.formSettings));

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
    openAddItem(listId = null, lat = '', lng = '') {
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
        name: '',
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

      const item = {
        id: this.editItemId || crypto.randomUUID(),
        name: name.trim(),
        lat: parseFloat(lat),
        lng: parseFloat(lng),
        notes: this.formItem.notes.trim(),
        google_maps_url:
          this.formItem.google_maps_url.trim() ||
          `https://maps.google.com/?q=${lat},${lng}`,
      };

      if (this.editMode) {
        // Remove from original list (handles moving between lists)
        const origList = this.lists.find((l) => l.id === this.formItem.originalListId);
        if (origList) origList.items = origList.items.filter((i) => i.id !== this.editItemId);
      }

      const targetList = this.lists.find((l) => l.id === this.formItem.listId);
      if (targetList) targetList.items.push(item);

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

    // ── Export ────────────────────────────────────────────────────────
    exportJSON() {
      const blob = new Blob(
        [JSON.stringify({ version: 1, lists: this.lists }, null, 2)],
        { type: 'application/json' }
      );
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'open-street-lists.json';
      a.click();
      URL.revokeObjectURL(url);
    },
  }));
});
