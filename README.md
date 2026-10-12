# Book Fetch for KOReader

Book Fetch 0.1.0 searches Anna's Archive and downloads books directly to a Kobo. Its development target is the Kobo Libra Colour with KOReader v2026.07.1. Use it for public-domain, openly licensed, or owner-entitled material.

**Status: experimental.** Automated tests cover local logic, mocked transports, and selected KOReader APIs; they do not establish that current mirrors, membership login, or physical-device UI behavior work. See [Tests](#tests) and the [release checklist](docs/RELEASING.md) before distributing a build. Other devices and KOReader versions are not established compatibility targets.

Search and download work runs in a cancellable KOReader subprocess. Downloads stream to disk, resume when the server supports ranges, and become visible as books only after signature and MD5 verification. The plugin makes no network requests at startup.

## Install

1. Install KOReader first. Use a trusted source checkout or a release archive with a **bookfetch.koplugin** directory; rename a GitHub source ZIP's extracted directory if it has a branch or version suffix.
2. Copy **bookfetch.koplugin** into KOReader's `plugins` directory. On a typical Kobo installation that is `/mnt/onboard/.adds/koreader/plugins/bookfetch.koplugin`. Its top level must contain `main.lua`, `_meta.lua`, and `bookfetch/`, without an extra nested directory.
3. Restart KOReader when convenient.
4. Open **Tools → Book Fetch → Settings** and enter your Anna's Archive membership secret key.
5. Open **Tools → Book Fetch → Search**. The **Book Fetch** dispatcher action can also be assigned to a gesture.

Do not copy `.git`, temporary test files, settings, credentials, or downloaded books. The runtime files are `main.lua`, `_meta.lua`, and `bookfetch/`; retain the supplied license when redistributing. KOReader supplies LuaJIT and the runtime libraries, so no separate package installation is required on the Kobo.

Before upgrading, keep a private backup of the old plugin directory and `settings/bookfetch.lua`. Replace the plugin directory while KOReader is stopped, retaining your settings separately. To uninstall, stop KOReader and remove `plugins/bookfetch.koplugin`; downloaded books and the separate settings file remain. Delete `settings/bookfetch.lua` separately if you also want to remove the saved membership key.

## Search and download

Enter a title, author, or ISBN. The format filter accepts blank/any, epub, pdf, mobi, or azw3. The language filter accepts blank/any or a code such as `en`, `fr`, or `de`. Results show available metadata; **Next page** and **Previous page** navigate server pages.

Tap a book for details, then **Download** for Anna's Archive fast downloads or **Try LibGen** for the fallback. The progress dialog shows the phase, host, received bytes, total when known, and average transfer speed. **Cancel** terminates the worker and keeps a partial file. **Discard partial** terminates it and removes that operation's partial file and ownership sidecar. After successful verification the file manager refreshes and you can choose **Open now**.

Fast downloads require an Anna's Archive membership with available daily downloads. Book Fetch exchanges the secret key for an in-memory login session, then requests the fast-download API. It displays quota fields returned by the API after a successful download. Partner failures can require additional API calls and may consume additional quota; the plugin tries domain indices 0 through 6 and stops on a terminal account/quota/domain error. Temporary API errors continue to the next index. Disk, size-limit, integrity, and policy failures stop without requesting another partner URL. Quota rules and API fields are controlled by Anna's Archive, so check your account for authoritative details.

LibGen does not require your Anna's Archive key. The plugin fetches `ads.php` for the selected MD5, resolves an allowlisted `get.php` link, and checks every verified HTTPS redirect against the allowlist before connecting. Listed hosts and their subdomains are allowed. Metadata and the expected MD5 remain those of the selected book. If that exact file is unavailable, it reports an error.

DDoS-Guard challenges and access denials are reported. A blocked authenticated request moves directly to the next configured mirror without another login POST. A DDoS-Guard cookie by itself does not block a successful search response. There is no challenge solver or slow-download countdown support.

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

Supported signatures: epub/cbz/docx (ZIP), pdf, mobi/azw/azw3, djvu, fb2 (XML), and plain text. When a result has no format, Book Fetch identifies it from the downloaded signature and Content-Type before choosing its extension; unrecognized content is quarantined. Unsupported declared formats are reported. ZIP-based signatures do not inspect archive contents. Covers, conversion, self-update, slow downloads, and Z-Library are out of scope.

## Firewall and privacy

Fast-download partner domains rotate and may live in different countries. DNS, GeoIP rules, or firewall policy can block a partner even when the search mirror works. Failures identify the host and reason. Book Fetch tries alternatives, then remembers hosts with connection/TLS failures for 24 hours. A truncated body does not blacklist the host, so its partial can still resume. Clear the bad-host list after correcting a firewall rule; enabling broader access is your decision.

Your configured mirrors receive your IP address, browser-style User-Agent, search terms, filters, page numbers, and selected book MD5s. Anna's Archive receives your secret key over verified HTTPS for login/API requests and may return an account session cookie. Download partners receive the selected URL, IP address, and range request; account cookies are removed on cross-origin redirects. LibGen receives the selected MD5 and its own link token. Book Fetch has no telemetry, covers, automatic discovery, or startup network traffic.

## Tests

Run the pure logic suite from this repository with LuaJIT (Lua alone is insufficient because the MD5 implementation uses LuaJIT's `bit` module):

```sh
luajit spec/run.lua
```

For the integration and syntax suites, use an existing KOReader runtime built for the machine running the tests. It must include `luajit`, `setupkoenv.lua`, `frontend/`, `common/`, `libs/`, and the CA bundle. An ARM Kobo runtime cannot be executed directly on an x86 workstation. Set these absolute paths for your own checkout and runtime:

```sh
BOOKFETCH_ROOT='/absolute/path/to/bookfetch.koplugin'
KOREADER_ROOT='/absolute/path/to/koreader'
cd "$KOREADER_ROOT"
./luajit "$BOOKFETCH_ROOT/spec/probe.lua"
./luajit "$BOOKFETCH_ROOT/spec/run.lua"
./luajit "$BOOKFETCH_ROOT/spec/run_ko.lua"
./luajit "$BOOKFETCH_ROOT/spec/syntax.lua" "$BOOKFETCH_ROOT"
```

`spec/run_ko.lua` uses synthetic HTML, mocked transports, disposable temporary files, and stubbed UI callbacks. It makes no external requests and does not start a second KOReader UI. Run it in an isolated test environment with the source and runtime read-only, no network or credentials, and a writable temporary directory. Do not run it against a live reading session as a substitute for an isolated test setup.

The summary separates **passed**, **failed**, and **skipped** checks. Some native UI/Trapper checks need KOReader global initialization that `setupkoenv` does not perform. A standalone runtime may therefore skip them; each skip prints the missing module and reason. A skip is not compatibility evidence. To require every check to execute, use:

```sh
BOOKFETCH_REQUIRE_RUNTIME=1 ./luajit "$BOOKFETCH_ROOT/spec/run_ko.lua"
```

This mode turns skipped checks into failures and exits unsuccessfully until the required runtime is initialized. It does not initialize KOReader for you. Even a run without skips uses mocks for network transport, widgets, scheduling, and subprocess callbacks; it is not a physical acceptance test.

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
