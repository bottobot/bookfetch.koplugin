# Book Fetch for KOReader

Book Fetch 0.1.0 searches Anna's Archive and downloads books directly to a Kobo. It targets the Kobo Libra Colour with KOReader v2026.07.1. Use it for public-domain, openly licensed, or owner-entitled material.

Search and download work runs in a cancellable KOReader subprocess. Downloads stream to disk, resume when the server supports ranges, and become visible as books only after signature and MD5 verification. The plugin makes no network requests at startup.

## Install

1. Copy this directory, named **bookfetch.koplugin**, into KOReader's `plugins` directory. On a typical Kobo installation that is `/mnt/onboard/.adds/koreader/plugins/bookfetch.koplugin`.
2. Restart KOReader when convenient.
3. Open **Tools → Book Fetch → Settings** and enter your Anna's Archive membership secret key.
4. Open **Tools → Book Fetch → Search**. The **Book Fetch** dispatcher action can also be assigned to a gesture.

Do not copy `.git`, temporary test files, or downloaded books. This implementation task does not install into, modify, or restart the existing KOReader installation.

## Search and download

Enter a title, author, or ISBN. The format filter accepts blank/any, epub, pdf, mobi, or azw3. The language filter accepts blank/any or a code such as `en`, `fr`, or `de`. Results show available metadata; **Next page** and **Previous page** navigate server pages.

Tap a book for details, then **Download** for Anna's Archive fast downloads or **Try LibGen** for the fallback. The progress dialog shows the phase, host, received bytes, total when known, and average transfer speed. **Cancel** terminates the worker and keeps a partial file. **Discard partial** terminates it and removes that operation's partial file and ownership sidecar. After successful verification the file manager refreshes and you can choose **Open now**.

Fast downloads require an Anna's Archive membership with available daily downloads. Book Fetch exchanges the secret key for an in-memory login session, then requests the fast-download API. It displays quota fields returned by the API after a successful download. Partner failures can require additional API calls and may consume additional quota; the plugin tries domain indices 0 through 6 and stops on an API error. Quota rules and API fields are controlled by Anna's Archive, so check your account for authoritative details.

LibGen does not require your Anna's Archive key. The plugin fetches `ads.php` for the selected MD5, resolves an allowlisted `get.php` link, and follows verified HTTPS download redirects. Metadata and the expected MD5 remain those of the selected book. If that exact file is unavailable, it reports an error.

DDoS-Guard challenges and access denials are reported. An expired/blocked authenticated request triggers at most one login retry for that mirror, then the next configured mirror is tried. There is no challenge solver or slow-download countdown support.

## Settings

- **Secret key:** masked input, stored only in KOReader's `settings/bookfetch.lua` using LuaSettings. Changing it clears in-memory sessions.
- **Anna's Archive mirrors:** HTTPS base URLs, one per line, tried in order. Default: `https://annas-archive.pk`.
- **LibGen mirrors:** HTTPS base URL allowlist. Defaults: `libgen.li`, `libgen.gl`, `libgen.la`, `libgen.vg`, and `libgen.bz`.
- **Download folder:** choose a directory with the KOReader folder picker; long-press to select. The default `/mnt/onboard/Books` is created on the first download.
- **Preferred format:** initial search filter.
- **Clear bad-host list:** retry hosts previously skipped for connection/TLS failures. Entries expire after 24 hours.

Mirror domains can change. Edit the lists explicitly; the plugin never discovers mirrors or checks for updates automatically. Mirror lists require HTTPS. TLS verifies the certificate chain against KOReader's installation `data/ca-bundle.crt` and checks the certificate hostname. A missing CA bundle is an error. There is no insecure fallback.

Kobo onboard storage uses vfat: Unix file permissions cannot protect the settings file there. Protect physical access to the device and keep settings/backups private. Cookie jars remain in memory, including worker return data; they are not written to progress files or settings. The secret is redacted from diagnostic errors and URL query parameters.

## File safety and resume

Files use `Title - Author.ext`, with ` (2)`, ` (3)`, etc. for collisions. Names remove vfat-invalid/control characters, collapse whitespace, and fit within 120 bytes including the extension and collision suffix, on UTF-8 boundaries.

A download has `<filename>.part` and `<filename>.part.md5`. The sidecar associates the partial with the expected MD5; keep both to resume. A different book with the same title cannot append to that partial. A `206` must have a valid range beginning at the current size. A `200` restarts the file. Redirects and HTTP error pages do not overwrite partial data. A completed partial can be checked after a matching `416` response.

The limit is **500,000,000 bytes**. Free space is checked through KOReader's statvfs wrapper when available, including when the server provides the total size; older builds without that wrapper skip the check and still report write errors. The plugin checks the file signature and rejects HTML, then computes a streaming MD5 over the entire file. It checks for KOReader's `ffi/sha2.md5` streaming API first and uses the included RFC 1321 implementation when unavailable. Signature/hash failures are preserved as `.bad` (with a suffix if necessary). They never become books. A verified partial is atomically renamed in the same directory. MD5 identifies the catalog file; it is not a malware or authenticity guarantee.

Supported signatures: epub/cbz/docx (ZIP), pdf, mobi/azw/azw3, djvu, fb2 (XML), and plain text. Missing or unsupported result formats are reported instead of guessed. ZIP-based signatures do not inspect archive contents. Covers, conversion, self-update, slow downloads, and Z-Library are out of scope.

## Firewall and privacy

Fast-download partner domains rotate and may live in different countries. DNS, GeoIP rules, or firewall policy can block a partner even when the search mirror works. Failures identify the host and reason. Book Fetch tries alternatives, then remembers failed network hosts for 24 hours. Clear the bad-host list after correcting a firewall rule; enabling broader access is your decision.

Your configured mirrors receive your IP address, browser-style User-Agent, search terms, filters, page numbers, and selected book MD5s. Anna's Archive receives your secret key over verified HTTPS for login/API requests and may return an account session cookie. Download partners receive the selected URL, IP address, and range request; account cookies are removed on cross-origin redirects. LibGen receives the selected MD5 and its own link token. Book Fetch has no telemetry, covers, automatic discovery, or startup network traffic.

## Device-only tests

The plain-Lua suite uses synthetic HTML fixtures and mocked transports, with no external requests. Download tests use a disposable temporary directory. UI tests stub widgets and the scheduler, so they do not start a second KOReader UI. Run on the Kobo's LuaJIT, with the existing KOReader directory as the working directory for library/CA lookup. `setupkoenv` only configures module/library paths.

From the workstation, copy only the test payload into `/tmp/bookfetch-test` on the Kobo:

```sh
ssh kobo 'mkdir -p /tmp/bookfetch-test'
scp -r main.lua _meta.lua bookfetch spec kobo:/tmp/bookfetch-test/
ssh kobo 'cd /mnt/onboard/.adds/koreader && ./luajit /tmp/bookfetch-test/spec/probe.lua'
ssh kobo 'cd /mnt/onboard/.adds/koreader && ./luajit /tmp/bookfetch-test/spec/run.lua'
ssh kobo 'cd /mnt/onboard/.adds/koreader && ./luajit /tmp/bookfetch-test/spec/syntax.lua /tmp/bookfetch-test'
```

Some workstation OpenSSH configurations have an unreadable system include. If that occurs, use `ssh -F /home/robert/.ssh/config kobo` and the corresponding `scp -F` option, retaining the owner's host and identity settings.

The tests cover names/UTF-8/collisions, RFC 1321 MD5 vectors, realistic parsing, signatures, URL encoding/redaction, TLS hostname rules, redirect/cookie isolation, bad-host expiry, adapters, streamed resume/restart, limits, corrupt-file preservation, and subprocess/online gating. They do not prove live mirror availability, account login/quota, actual TLS handshakes, physical cancellation, or e-ink rendering. Those require an explicit authorized smoke test on the device.

The supplied `SPEC.md` documents prohibited APIs as text. To audit executable Lua files without matching that prose, run:

```sh
rg -n 'os\.execute|io\.popen|dismissablePopen' --glob '*.lua' .
```

Successful output is empty. Runtime modules also contain no command-line networking or archive extraction.

## Architecture and references

All runtime modules use `bookfetch.*`. `sources/aa.lua` and `sources/libgen.lua` expose the adapters through a small `new(http, settings)` / `resolve(book, alternate)` interface; Anna's Archive also implements `search`. The named `aa.lua` and `libgen.lua` modules contain their implementations. Parsing, filenames, MD5, and HTTP utilities have no KOReader UI dependency.

This code was independently implemented. [KindleFetch](https://github.com/william-spongberg/KindleFetch.koplugin) (MIT, © 2026 william-spongberg) was read for settings, menu, progress, and filename patterns; no implementation code was copied or adapted. The unlicensed Anna's Archive reference was consulted for protocol ideas only, and no AGPL scraper implementation was copied.

Integration APIs were checked against upstream [KOReader Trapper](https://github.com/koreader/koreader/blob/master/frontend/ui/trapper.lua), [socketutil](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua), [LuaSocket HTTP](https://github.com/lunarmodules/luasocket/blob/master/src/http.lua), and [LuaSec HTTPS](https://github.com/lunarmodules/luasec/blob/master/src/https.lua). The device's installed release remains the authoritative integration target.

MIT License, © 2026 bottobot. See [LICENSE](LICENSE).
