# Book Fetch: KOReader plugin spec (v0.1)

Book Fetch searches Anna's Archive and downloads books **directly on the device**. It uses
the owner's Anna's Archive membership (fast downloads), with LibGen as a fallback.

Target: Kobo Libra Colour running KOReader v2026.07.1. That build has LuaJIT, LuaSocket and
LuaSec, and a CA bundle at `<koreader>/data/ca-bundle.crt`. **There is no `curl` on the
device.** `/mnt/onboard` is vfat, so file permissions don't exist. Don't assume Kindle paths.

## Hard requirements

1. **No shell, ever.** No `os.execute`, `io.popen`, `Trapper:dismissablePopen`, `wget`,
   `curl` or `unzip`. Do all networking with LuaSocket/LuaSec (`socket.http`, `ssl.https`,
   `ltn12`, KOReader `socketutil` timeouts). Do file operations with `lfs`/`io`.
2. **TLS verified.** HTTPS requests use `verify = "peer"`, with `cafile` set to KOReader's
   `data/ca-bundle.crt` (resolve the path through `DataStorage` or the install dir). Never
   fall back to skipping verification.
3. **No unrequested network calls.** Nothing on plugin load: no update checks, no
   telemetry, no Wikipedia mirror discovery. The network is used only on explicit user
   action, and only after `NetworkMgr:runWhenOnline`.
4. **Module namespace** `bookfetch.*` (plugin dir `bookfetch.koplugin`), with no globals.
   It must coexist with any annas/zlibrary plugins.
5. **Secret key** lives in the plugin's own LuaSettings file (`settings/bookfetch.lua`).
   Never log it: redact it in all logger output, including URLs that contain `key=`. Never
   send it over plain HTTP, and never put it in a filename.
6. **The UI never freezes** during network work. Search, resolve and download run in a
   KOReader background subprocess (`Trapper:dismissableRunInSubprocess` or
   `ffiUtil.runInSubProcess` plus polling), with a progress indicator and a working Cancel.

## Sources

Each source is an adapter in `bookfetch/sources/*.lua` behind a common interface.

### Anna's Archive (primary)
- Base URL is configurable; the default is `https://annas-archive.pk`. The user can edit a
  list of mirror base URLs, which are tried in order.
- **Login**: `POST /account/` with form field `key=<secret>` returns a session cookie
  (`aa_*`). Keep the cookie jar in memory, including inside the subprocess. On a 403, a
  redirect to `?check=1`, or a DDoS-Guard marker, log in again once. Send a realistic
  browser User-Agent.
- **DDoS-Guard detection**: a 302/307 to a URL containing `check=1`, `__ddg` cookies, or
  ddos-guard HTML markers means the request is blocked. Do NOT try to solve the challenge.
  Report "Blocked by DDoS-Guard on <host>" and try the next mirror.
- **Search**: `GET /search?q=<urlencoded>&ext=<fmt>&lang=<lang>&page=<n>`, with proper URL
  encoding. Parse results by finding `href="/md5/<32hex>"` anchors, and extract title,
  author, publisher/year, language, format and size where present. Parsing must tolerate
  missing fields. Decode HTML entities. Support pagination (Next page).
- **Fast download**: `GET /dyn/api/fast_download.json?md5=<md5>&key=<secret>` returns JSON
  with `download_url`, and possibly `error` and `account_fast_download_info` (the remaining
  quota).
  - The `domain_index` and `path_index` query params return alternate partner URLs.
  - When a host fails, retry with the next `domain_index` (0 to N), until an error says
    none are left or you reach 6.
  - Show the remaining daily quota if the API returns it.
- No slow-download support in v0.1 (countdown pages are out of scope).

### LibGen (fallback, a per-book "Try LibGen" button)
- The user can edit the mirror allowlist. Default: `https://libgen.li`, `https://libgen.gl`,
  `https://libgen.la`, `https://libgen.vg`, `https://libgen.bz`.
- Resolve by md5: `GET /ads.php?md5=<md5>`, take the first `get.php?md5=...&key=...` link,
  and download it.

## Downloads (`bookfetch/download.lua`)
- **Stream** the response body to `<final>.part` with an ltn12 file sink. Never buffer
  the whole file in memory.
- **Resume**: if a `.part` file exists, send `Range: bytes=<size>-`. Accept 206; if the
  server answers 200, restart from zero.
- **Follow redirects manually** (max 8), so every hop's host can be checked and reported.
- **Remember failing hosts** for the session, and persist them in settings for 24 h. A
  connect timeout, refusal or TLS failure marks the host bad and records the reason; skip
  bad hosts next time. Errors must name the host and the reason, for example "Could not
  connect to xyz.org (timed out, possibly blocked by firewall)".
- **Validate** before renaming:
  - The content must not be HTML (check the first bytes and the content-type).
  - Magic bytes must match the format: epub/cbz/docx = `PK\3\4`; pdf = `%PDF`;
    mobi/azw/azw3 = `BOOKMOBI` at offset 60; djvu = `AT&TFORM`; fb2 = XML; txt is allowed.
  - **The MD5 of the file must equal the Anna's Archive md5.** First check on the device
    whether `require("ffi/sha2")` or an md5 module exists; if neither does, implement a
    streaming MD5 in Lua. On a mismatch, rename the `.part` file to `.bad` and report it.
- **Atomic rename** from `.part` to the final name. **Avoid collisions**: name files
  `Title - Author.ext`, then ` (2)`, ` (3)` and so on.
- **Filenames**: allow only characters safe on vfat (strip `\/:*?"<>|` and control chars),
  collapse whitespace, trim dots and spaces, and truncate to ≤ 120 bytes **on UTF-8
  boundaries**.
- **Size sanity**: refuse files over 500 MB. Check free space before starting (`lfs`, or
  statvfs through ffi if available; otherwise skip the check).
- Default download folder: `/mnt/onboard/Books`, created if missing. It's a setting with a
  folder picker. After a successful download, refresh the FileManager if it's visible and
  offer "Open now".
- Timeouts: connect 15 s, idle-read 60 s. No overall time cap, but Cancel must work.

## UI (`bookfetch/ui.lua`), all in English
- A main menu entry under Tools, **Book Fetch** (menu key `bookfetch`), and a Dispatcher
  action (`bookfetch_search`) so it can be bound to a gesture.
- Search dialog: query, a format filter (any/epub/pdf/mobi/azw3) and a language filter
  (any/en/...).
- Results list (a KOReader `Menu`): "Title — Author (2019, epub, 1.2 MB)". Tapping a result
  opens a detail dialog with the metadata and buttons **Download**, **Try LibGen** and
  Cancel.
- Progress dialog: bytes/total, speed and current host. Cancel deletes nothing (the
  `.part` file stays for resuming), but there is also a "Discard partial" option.
- Settings submenu: secret key (masked input), mirror list (edited as text, one per line),
  LibGen mirrors, download folder, preferred format, "Clear bad-host list", About.
- Covers: out of scope for v0.1, to keep the UI fast on e-ink.

## Code quality
- Files: `main.lua`, `_meta.lua`, and `bookfetch/{config,http,aa,libgen,parse,download,
  md5,names,ui}.lua`.
- The pure-logic modules (`parse`, `names`, `md5`, URL encoding, the magic-byte check) must
  not require KOReader UI modules, so they can be unit-tested headless.
- `spec/` holds plain-Lua tests run by `luajit spec/run.lua` (no busted dependency). Cover:
  - the parser, against realistic fixture HTML that you create in `spec/fixtures/`;
  - names: unicode truncation, collisions, illegal characters;
  - md5, with known test vectors;
  - magic bytes;
  - URL encoding;
  - key redaction.
- Use `logger.dbg` for diagnostics, with the key redacted. No `print`.
- README.md, in English, covering:
  - what it does, how to install it, and its settings;
  - how fast downloads and the daily quota work;
  - firewall notes: partner domains rotate, and GeoIP rules can block them;
  - privacy: what leaves the device;
  - that it is meant for public-domain, openly licensed, or owner-entitled material.
- LICENSE: MIT.
  - If you adapt any code from KindleFetch (MIT, © 2026 william-spongberg), keep its
    copyright notice in the adapted file and credit it in the README.
  - Do NOT copy code from the AGPL repos (ZlibraryKO, fischer-hub, IT-Yohan) or from the
    unlicensed one (bitesized). Ideas only.

## Out of scope (v0.1)
Slow downloads and countdowns, solving DDoS-Guard (including FlareSolverr), covers,
self-update, kepub conversion, Z-Library.
