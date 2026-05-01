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
wrangler.jsonc     Cloudflare Workers deployment config
Makefile           Import script runner (targets: install, csv, json, selenium, help)
lists.json         Local data file (mirrors GitHub Gist)
google_takeout_scripts/
  import_takeout_csv.rb      CSV importer (stdlib only)
  import_takeout_json.rb     GeoJSON importer (stdlib only)
  import_takeout_selenium.rb Selenium-based scraper (requires gems)
  Gemfile / Gemfile.lock     Selenium gem deps
Takeout/           Local Google Takeout sample data
.tool-versions     asdf Ruby version pin
.ruby-version      Ruby version pin (rbenv/chruby compat)
```

Stack: Leaflet.js + Alpine.js + Tailwind CDN. Data: GitHub Gist (`lists.json`). Hosting: Cloudflare Pages (Workers Assets).

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
