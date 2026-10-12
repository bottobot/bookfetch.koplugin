# Preparing a Book Fetch release

Book Fetch 0.1.0 is an early implementation. Source publication and an installable release need separate checks: passing the local suites establishes only their exercised behavior. Keep any repository visibility change, Git push, tag creation, or release publication as an explicit maintainer action.

## Before tagging

- Review the exact commit to distribute, including its history, for credentials, account data, local settings, downloaded books, and personal machine details. A clean secret scan is useful evidence, not proof that every sensitive value has been detected.
- Retain `LICENSE` and the provenance statement in `README.md`. If implementation code or assets are added from another project, record the source revision and applicable notices before including them. The current attribution is a project statement of independent implementation; it is not an independent provenance or legal verification.
- Run the pure, integration, and syntax commands in the README in an isolated runtime. Record the source commit, runtime version, operating system, command, exit status, and separate pass/fail/skip counts. Investigate failures. Record skipped native checks as unvalidated; use `BOOKFETCH_REQUIRE_RUNTIME=1` when complete runtime execution is a release requirement.
- Review changes against the documented behavior: verified HTTPS, origin restrictions, credential redaction, quota-aware retry stopping, partial-file ownership, size limits, signature/MD5 checks, and collision-safe final names.
- Keep the release version consistent in `_meta.lua`, the README, and the About text in `bookfetch/ui.lua`. Describe compatibility as tested only where a dated test record supports it.

## Integration acceptance

The tests do not establish current external-service behavior. Before calling a build ready for ordinary users, record the following checks in a disposable emulator or an explicitly authorized device session, using a small public-domain or openly licensed fixture:

1. Install the packaged directory, verify the Tools menu and dispatcher action, and confirm that startup makes no network requests.
2. Verify search, paging, empty results, and a useful error for an unavailable or blocked mirror. Confirm that secrets do not appear in UI errors, filenames, or logs.
3. Verify a complete download, signature and MD5 results, file-manager refresh, and opening the resulting book. Record the exact fixture identity without distributing restricted content.
4. Check cancel, resume, discard, a name collision, insufficient storage, and an interrupted transfer without replacing an existing book. Confirm that reopening KOReader preserves the expected settings and partial files.
5. Verify actual TLS acceptance/rejection using a controlled test service and dummy credentials, including a wrong hostname and untrusted certificate. Mocked certificate objects alone do not prove a real TLS handshake.
6. Verify native dialog layout, update rate, cancellation responsiveness, and cleanup on the supported physical device. Emulator checks do not establish e-ink behavior.

Account authentication and fast downloads may consume membership quota. Run such checks only with account-owner authorization; never place the membership key or cookies in a test record. A LibGen fallback check is separate from Anna's Archive authentication and does not establish the latter. If any required external or physical check is unavailable, state the gap and label the release experimental rather than claiming acceptance.

## Package from the reviewed tag

After reviewing and tagging the intended commit, create an archive from that tag with an explicit file list. For example, use `v0.1.0` only if that tag identifies the reviewed release:

```sh
git archive --format=zip --prefix=bookfetch.koplugin/ \
  --output='../bookfetch-v0.1.0.zip' v0.1.0 \
  LICENSE README.md SPEC.md docs _meta.lua main.lua bookfetch
```

This command reads tracked files from the tag. It does not include uncommitted changes or create a tag or GitHub release. Update the version and output path for subsequent releases. Do not package an entire local working directory: it may contain settings, credentials, books, logs, or temporary artifacts.

List the archive contents and check its root before installing it into a disposable test runtime:

```sh
unzip -l ../bookfetch-v0.1.0.zip
sha256sum ../bookfetch-v0.1.0.zip
```

The archive must have exactly one top-level `bookfetch.koplugin/` directory containing `main.lua`, `_meta.lua`, `bookfetch/`, the license, and documentation. It must not contain `.git`, settings, credentials, downloaded books, partial downloads, or logs. Record the checksum alongside the source tag and test results. Test the extracted archive, not only the working checkout.

Publish release notes describing the tested device/runtime, changes, open limitations, installation instructions, and checksum. Do not include credentials, private account responses, or personal paths in screenshots or logs. Repository publicity does not establish a successful tagged release, and creating a ZIP does not establish installation acceptance.
