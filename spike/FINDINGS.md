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
