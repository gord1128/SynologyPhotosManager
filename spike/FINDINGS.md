# Phase 0 Spike — Findings (real NAS, DSM)

Captured live from <nas-host>:5001 (personal space, 2687 items). Raw responses
in `fixtures/`. All calls here are **read-only**; write/delete behavior is NOT yet
tested (deliberately deferred — see open questions).

## Resolved

**All Foto APIs live at `entry.cgi`.** Present + max versions:
`SYNO.Foto.Browse.Item` v7 · `.Browse.Timeline` v6 · `.Browse.Album` v5 ·
`.Browse.Folder` v2 · `.Thumbnail` v2 · `.Download` v2 · `.Search.Search` v7 ·
`.Streaming` v2 · `SYNO.FotoTeam.Browse.Item`/`.Timeline` (shared space exists).

**Auth** `SYNO.API.Auth` v7. Login with stored creds succeeds (no 2FA on this account).

**Timeline** — `SYNO.Foto.Browse.Timeline get` (no params). Returns
`data.section: [{ offset, limit, list: [{ year, month, day, item_count }] }]`.
21 sections for 2687 items. This is the basis for the timeline + date scrubber.
(`method=list` → 103 not-found; only `get` exists.)

**Item** — `SYNO.Foto.Browse.Item list` with `offset,limit,sort_by=takentime,
sort_direction=desc`. Item keys: `id, filename, filesize, folder_id,
owner_user_id, time (unix s), indexed_time (ms), type ("photo"/"video")`.
`method=count` → `data.count`.
`additional` is a JSON-array param; **valid keys**: `thumbnail, resolution,
orientation, video_convert, video_meta, provider_user_id, exif, tag, gps,
address`. ⚠️ `person` is INVALID here → error 600 (needs a different API).
  - `additional.thumbnail`: `{ cache_key, unit_id, sm/m/xl/preview: "ready"|"broken" }`
  - `additional.resolution`: `{ width, height }`
  - `additional.exif`: `{ aperture, camera, exposure_time, focal_length, iso, lens }`
  - `additional.gps`: `{ latitude, longitude }`
  - `additional.address`: `{ city, country, route, village, state, county, ... }` (localized)

**Thumbnail** — `SYNO.Foto.Thumbnail get id=<unit_id> cache_key=<cache_key>
type=unit size=<sm|m|xl>` → binary JPEG (sm was 33 KB). **`cache_key` comes from
the item's `additional.thumbnail`** — this answers the cache-invalidation question:
the key changes with the item version, so it doubles as the cache-busting token.

**Folder** — `SYNO.Foto.Browse.Folder get id=0` → root (`id:2, name:"/"`).
`...Folder list id=<n> offset limit` → children. Keys: `id, name, parent,
owner_user_id, passphrase, shared, sort_by, sort_direction`.

## Error codes seen (Foto-specific)
- `600` invalid parameter (e.g. bad `additional` key)
- `120` param condition failure (`{errors:{name,reason}}`)
- `103` method does not exist

## Still open (need write tests / more data — do carefully)
- **Delete** behavior (permanent vs trash) — NOT tested (destructive).
- **Download** Range (resume) + multi-item zip — NOT tested.
- **Upload** duplicate policy, album-direct upload — NOT tested.
- **Album** schema — this space has 0 albums, so `Browse.Album list` returned
  `[]`; real album fields still unverified. Build Album models only after
  capturing a populated response.
- **Item move** across folders — API not identified yet.

---

## T3 map-view spike (`swift run MapSpike`, read-only) — 2026-07-18

Goal: cheapest way to collect photo coordinates for a map view. Live NAS
(2813 items). Result: **paging with `additional=["gps"]` is trivially cheap →
load all coords up front, cluster client-side. No place-index needed.**

- **Probe A — page all with `additional=["gps"]`**: the WHOLE library (2813
  items) paged in **6 pages of 500, 0.78 s, 648 KB** (~230 B/item). **84 % have
  GPS → ~2353 geolocated photos.** So a one-shot "load every coordinate" is
  <1 s / <1 MB here — no server-side geo query needed. (GPS shape:
  `additional.gps = {latitude, longitude}`; (0,0) treated as none.)
- **Probe B — geocoding facet** (`SYNO.Foto.Search.Filter list_in_similar` v4,
  `setting` geocoding:true): returns a place TREE — nodes are
  `{id, level, name, children}` ONLY, **no per-place count**. Levels: 1=country
  (대한민국/일본), 3=city/county (a city/a county…), 5=town. So the facet can drive a
  "browse by place" list but can't show counts without querying, and isn't
  needed for map pins.
- **Probe C — `Browse.SimilarItem list_with_filter` v2 `geocoding=[id]`**:
  returns that place's items with **GPS + full address inline**
  (`additional.address` has city/country/county/district/landmark/route/state/
  town/village + *_id each). Good for a "tap a place → its photos" drill-down,
  but Probe A already yields everything for the map.

**T3 decision:** load all items once with `additional=["gps","thumbnail"]`,
keep the ~2353 with coords in memory, cluster client-side (grid/zoom buckets),
tap a cluster → filter the in-memory set by region (no extra query). Optional
later: a "browse by place" list from the geocoding tree (Probe B) + drill-down
(Probe C). All read-only, all on already-verified calls.
