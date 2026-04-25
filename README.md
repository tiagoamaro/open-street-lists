# Open Street Lists

A personal favorite-places web app built on OpenStreetMap. Organize saved locations into named, color-coded lists, sync data to a private GitHub Gist, and access it from any device — no backend required.

## Features

- **OpenStreetMap** rendering via [Leaflet.js](https://leafletjs.com)
- **Multiple lists** — each with a name, emoji icon, and color
- **CRUD** for lists and individual places
- **Click map to add** a place (coordinates pre-filled)
- **Place search** — Photon by Komoot (free, no key) or Geoapify (richer data, API key required)
- **Offline-first** — data cached in `localStorage`, synced to Gist when online
- **GitHub Gist as database** — one secret Gist holds a single `lists.json` file
- **JSON export** — download your data at any time
- **No build step** — pure HTML/JS/CSS, open `index.html` or deploy as-is

## Data model

```json
{
  "version": 1,
  "lists": [
    {
      "id": "uuid",
      "name": "Restaurants",
      "icon": "🍽️",
      "color": "#e74c3c",
      "visible": true,
      "items": [
        {
          "id": "uuid",
          "name": "Great Sushi Place",
          "lat": 37.7749,
          "lng": -122.4194,
          "notes": "Omakase on Thursdays",
          "google_maps_url": "https://maps.google.com/?q=37.7749,-122.4194"
        }
      ]
    }
  ]
}
```

## Setup

### 1. Create a GitHub Personal Access Token

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Create a new token with **only `gist` write permission** (no repo access needed)
3. Copy the token (`ghp_…`)

### 2. Deploy to Cloudflare Pages

1. Push this repo to GitHub
2. Go to [Cloudflare Pages](https://pages.cloudflare.com) → **Create a project** → **Connect to Git**
3. Select this repository; set **build command** to _(empty)_ and **output directory** to `/`
4. Deploy — your URL will be `https://open-street-lists.pages.dev`

### 3. First run

1. Open the app and click **⚙️ Settings**
2. Paste your GitHub PAT — leave Gist ID empty
3. Click **Connect Gist**
4. Add a list, add some places, then click **🔄 Sync**
5. A secret Gist is created automatically; its ID is saved locally

On subsequent visits the app loads data from the Gist automatically.

## Importing from Google Takeout

Export your Google Maps saved places via [Google Takeout](https://takeout.google.com) (select **Maps (your places)**), then run one of the Ruby import scripts. No gems required — stdlib only.

### CSV export

```sh
ruby bin/import_takeout_csv.rb [TAKEOUT_DIR] [OUTPUT_FILE] [OPTIONS]
```

### JSON export (GeoJSON)

```sh
ruby bin/import_takeout_json.rb [TAKEOUT_DIR] [OUTPUT_FILE] [OPTIONS]
```

Both scripts share the same options:

| Option | Description |
|---|---|
| `TAKEOUT_DIR` | Directory containing Takeout files (default: `./Takeout`) |
| `OUTPUT_FILE` | Output path (default: `./lists.json`) |
| `--google-api-key=KEY` | Use Google Geocoding API for places missing inline coordinates |
| `--no-geocode` | Skip geocoding; only import entries whose URL contains coordinates |
| `-h`, `--help` | Show usage |

**Coordinate resolution order:**

1. Inline coords extracted from the URL
2. Google Geocoding API (if `--google-api-key` provided)
3. Nominatim free geocoder (1 req/sec, auto-fallback)

Both scripts are **resumable** — if the output file already exists, entries whose `google_maps_url` is already present are skipped, so you can safely re-run after an interruption.

## Local development

No build step needed — just open `index.html` in a browser.

> **Note:** The GitHub Gist API requires HTTPS for CORS. When running locally via `file://`, Gist sync will be blocked by the browser. Use a local server instead:
> ```sh
> python3 -m http.server 8080
> # then open http://localhost:8080
> ```

## Stack

| Layer | Technology |
|---|---|
| Map | [Leaflet.js 1.9](https://leafletjs.com) + OpenStreetMap tiles |
| UI reactivity | [Alpine.js 3](https://alpinejs.dev) |
| Styling | [Tailwind CSS v4](https://tailwindcss.com) (browser CDN) |
| Database | GitHub Gist (secret, `lists.json`) |
| Hosting | [Cloudflare Pages](https://pages.cloudflare.com) (free) |
