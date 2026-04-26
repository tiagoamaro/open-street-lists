# open-street-lists

## Structure

Static no-build app. Entry: `index.html`.

```
js/app.js          Alpine.js root component (state, modals, CRUD)
js/map.js          MapController — Leaflet map, markers, zoom
js/gist.js         GitHub Gist sync (read/write lists.json)
css/leaflet.css    Leaflet styles
icons/icon.svg     App icon
manifest.json      PWA manifest
Makefile           Dev tasks
bin/               Import scripts (symlinks → google_takeout_scripts/)
google_takeout_scripts/
  import_takeout_csv.rb      CSV importer (stdlib only)
  import_takeout_json.rb     GeoJSON importer (stdlib only)
  import_takeout_selenium.rb Selenium-based scraper
Takeout/           Local Google Takeout sample data
.tool-versions     asdf Ruby version pin
```

Stack: Leaflet.js + Alpine.js + Tailwind CDN. Data: GitHub Gist (`lists.json`). Hosting: Cloudflare Pages.

## Git Workflow

### Query history

```bash
git log --oneline -20
git log --oneline -- path/to/file
git show <sha>
git diff <sha1>..<sha2>
git log --oneline --grep="keyword"
git show <sha>:path/to/file
git blame path/to/file
```

### Atomic commits

One logical change per commit. Message: `type: description` (Conventional Commits).
Types: `feat` `fix` `chore` `perf` `refactor` `docs`.
Stage selectively: `git add -p`. Never mix whitespace + logic.

### Git commands

Run automatically.
