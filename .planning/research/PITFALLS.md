# Domain Pitfalls

**Domain:** Bash script revision -- replacing embedded binaries with runtime downloads, CI cross-compilation, and large script restructuring
**Project:** Cluckers Central Script Revision
**Researched:** 2026-03-01

## Critical Pitfalls

Mistakes that cause rewrites, broken user installs, or silent data corruption.

### Pitfall 1: Checksum Mismatch Between CI-Built and Historically-Embedded Binaries

**What goes wrong:** The new CI-built binaries produce different SHA-256 checksums than the currently embedded base64 blobs, even when compiled from identical source code with the same flags. The existing script hardcodes `SHM_LAUNCHER_SHA256` and `XINPUT_DLL_SHA256` as readonly constants. If the CI binaries don't match byte-for-byte, existing users who already have the old binaries installed will be forced to re-download, and worse, any version of the script that hasn't been updated with the new checksums will `error_exit` on verification.

**Why it happens:** Windows PE binaries embed timestamps in the COFF header (`TimeDateStamp` field). MinGW GCC also embeds `__DATE__`/`__TIME__` macros if used by any included header. Different GCC versions (even minor patches like 13.2.0 vs 13.3.0) can produce different codegen. The current script documents "x86_64-w64-mingw32-gcc (GCC) 13-win32 (13.2.0)" specifically, but the Ubuntu runner image in GitHub Actions may ship a different minor version. Additionally, linking order, library versions of mingw-w64 runtime, and even the CRT startup code can differ between distro packages.

**Consequences:** Users get `SHA-256 mismatch` errors and cannot install. The entire reproducible-build promise breaks. If you update the checksums to match CI output, anyone running the old script version with the new binaries from GitHub Releases will also fail.

**Prevention:**
1. Pin the exact compiler version in CI. Use a specific Ubuntu runner version (e.g., `ubuntu-24.04`) and verify the exact GCC version in the workflow before compiling. Add `x86_64-w64-mingw32-gcc --version` as a CI step and fail if it doesn't match expectations.
2. Set `SOURCE_DATE_EPOCH=0` in the CI environment to eliminate timestamp-based non-determinism in PE headers.
3. Use `-Wl,--no-insert-timestamp` (if supported by the linker version) or post-process the binary to zero out the PE timestamp field.
4. Accept that the CI binaries will have NEW checksums. Update the hardcoded SHA-256 constants in script.sh to match the CI output. This is a one-time migration, not an ongoing problem -- once CI is the source of truth, checksums come from CI.
5. Add a CI step that computes and outputs the SHA-256 of each built artifact, making it trivial to update script.sh.

**Detection:** CI workflow succeeds but the script rejects the downloaded binary with "SHA-256 mismatch." Test this in the first CI run by downloading the built artifact and running `verify_sha256` against it.

**Phase relevance:** Must be addressed in Phase 1 (CI workflow creation) and Phase 2 (script download logic). The checksum constants cannot be updated until CI produces its first stable build.

---

### Pitfall 2: curl Downloads an HTML Error Page Instead of the Binary

**What goes wrong:** The script downloads a GitHub error page, redirect page, or rate-limit response (a small HTML document) instead of the actual binary. Since the file is non-empty, basic existence checks pass. The SHA-256 check catches it, but the error message ("SHA-256 mismatch") is confusing to users who don't understand what happened.

**Why it happens:** Multiple causes:
- Missing `-L` flag: GitHub release asset URLs issue 302 redirects to S3/CDN. Without `-L`, curl saves the redirect HTML body.
- GitHub API rate limiting: Unauthenticated API requests are limited to 60/hour per IP. If the download URL is fetched via the API (e.g., `api.github.com/repos/.../releases/latest`), shared IPs (university networks, corporate NATs, CI runners) can exhaust this quickly. Direct download URLs (`github.com/OWNER/REPO/releases/download/TAG/FILE`) do NOT count against the API rate limit -- they use CDN bandwidth.
- GitHub outages or asset not yet published: If the release is created but assets haven't finished uploading, the URL 404s.

**Consequences:** User sees a cryptic checksum error. They delete the file and retry, hitting the same issue. Frustration leads to abandonment.

**Prevention:**
1. Use the direct download URL pattern: `https://github.com/0xc0re/trashcan/releases/download/v1.0.0/shm_launcher.exe` -- this does NOT use the API and has no rate limit.
2. Always use `curl -fSL` (or the existing `CURL_FLAGS="-sL"` plus `-f`). The `-f` flag makes curl return a non-zero exit code on HTTP errors (4xx/5xx) instead of saving the error page. This is the single most important flag.
3. Check the HTTP status code or file size before checksum verification. A 10KB file when expecting a 50KB+ binary is a clear signal.
4. Provide a human-readable error: "Download failed (HTTP 404). The release asset may not exist at this URL. Check https://github.com/0xc0re/trashcan/releases for available versions."

**Detection:** `curl` exits 0 even on 404 unless `-f` is used. Check exit code AND file size.

**Phase relevance:** Phase 2 (script download logic). Must be correct before any user sees the new download path.

---

### Pitfall 3: Breaking the Existing Binary Skip-If-Verified Optimization

**What goes wrong:** The current script has an important optimization at line ~3861: if `shm_launcher.exe` already exists at the destination AND its SHA-256 matches, it skips extraction entirely ("already installed and verified -- skipping"). When switching to runtime downloads, this optimization must be preserved exactly. If it's removed or broken, every script run re-downloads the binaries, adding latency and network dependency to every launch.

**Why it happens:** During refactoring, it's easy to simplify the binary installation step to "always download." The skip logic depends on comparing the SHA-256 of the file on disk against the expected constant. If the expected constant changes (because CI produces different binaries) but the user already has a working copy, the script will re-download unnecessarily.

**Consequences:** Every script invocation requires internet access and adds download latency. Users on slow connections or behind restrictive firewalls experience degraded UX. The script goes from "works offline after first install" to "requires internet every time."

**Prevention:**
1. Preserve the exact check pattern: if file exists AND sha256 matches, skip download.
2. When updating checksums for CI-built binaries, document that this is a one-time re-download for existing users.
3. Consider a version file alongside the binary (e.g., `shm_launcher.version`) that stores the release tag. Check version first (cheap), then checksum only if versions differ.

**Detection:** Run the script twice in succession. The second run should show "already installed and verified -- skipping" for both binaries.

**Phase relevance:** Phase 2 (script download logic). Critical for user experience.

---

### Pitfall 4: Large Script Restructuring Silently Changes Control Flow

**What goes wrong:** Reordering, renaming, or restructuring functions in a 5000-line bash script introduces subtle behavioral changes that aren't caught by cursory testing. Variable scoping in bash is particularly treacherous: `local` variables shadow globals, unquoted variables split on whitespace, and `set -e` (errexit) interacts poorly with function calls in conditionals.

**Why it happens:** Bash has no type system, no compiler warnings for logic errors, and function-scoping rules that differ from every other language:
- A `local` variable in function A is visible to function B if B is called from A. Moving B to be called from a different parent changes what variables it sees.
- Variables set inside subshells `$(...)` are lost when the subshell exits. Refactoring inline code into a function called in `$(...)` changes variable visibility.
- The `readonly` keyword makes variables truly global. Moving code above or below a `readonly` declaration changes behavior.
- Heredocs with unquoted delimiters (e.g., `<< EOF` vs `<< 'EOF'`) expand variables. Changing quoting during cleanup breaks embedded content.

**Consequences:** Script appears to work in the happy path but fails in edge cases: `--update` mode, `--uninstall`, `--steam-deck`, `--controller`, or combinations thereof. Bugs may not surface until a user with a specific configuration encounters them.

**Prevention:**
1. Do NOT restructure and change download logic in the same commit/phase. Separate "move code around" from "change behavior."
2. Create a test matrix covering all flag combinations: `--auto`, `--gamescope`, `--controller`, `--steam-deck`, `--gamescope-with-controller`, `--update`, `--uninstall`, `--wayland-cursor-fix`, and combinations.
3. Use `shellcheck` on the script before and after restructuring. It catches many variable-scoping and quoting issues.
4. Diff the script's runtime behavior, not just its source. Run both versions with `bash -x` and compare the trace output for the same inputs.
5. Keep the restructuring phase conservative: rename/reorder functions but don't change their internal logic.

**Detection:** `shellcheck` warnings increase after refactoring. Manual testing of each flag combination reveals failures. `bash -x` trace differs between old and new versions.

**Phase relevance:** Phase 3 (script restructuring). This should be the LAST phase, after download logic is proven correct.


## Moderate Pitfalls

### Pitfall 5: GitHub Release Versioning Strategy Mismatch

**What goes wrong:** The script needs to download binaries from a specific release tag, but the versioning strategy for the trashcan repo hasn't been decided. If the script hardcodes `v1.0.0` and the release tag is `v1.0`, or if a "latest" release strategy is used but the API call hits rate limits, downloads break.

**Prevention:**
1. Decide the versioning scheme upfront: use semantic versioning (e.g., `v1.0.0`) for the trashcan repo releases.
2. Hardcode the release tag in the script (not a "latest" API lookup). When binaries change, bump the tag in the script. This avoids API rate limits entirely and makes the script version-pinned to known-good binaries.
3. The download URL pattern should be: `https://github.com/0xc0re/trashcan/releases/download/${TOOLS_RELEASE_TAG}/shm_launcher.exe`
4. Add a `TOOLS_RELEASE_TAG` constant at the top of the script alongside the SHA-256 constants.

**Detection:** Script fails to download because the release tag doesn't exist.

**Phase relevance:** Phase 1 (CI workflow -- must create the release with a known tag) and Phase 2 (script must reference that tag).

---

### Pitfall 6: MinGW Cross-Compilation Flags Differ From Documented Build

**What goes wrong:** The CI workflow uses slightly different compiler flags than the ones documented in the script's REPRODUCIBLE BUILDS section, producing binaries that work but have different characteristics (e.g., missing `-municode` for shm_launcher.exe causes it to use `main()` instead of `wmain()`, breaking Unicode path support).

**Prevention:**
1. Extract the exact compile commands from the current script (lines ~3430-3440):
   - `x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows -o shm_launcher.exe shm_launcher.c`
   - `x86_64-w64-mingw32-gcc -O2 -Wall -shared -o xinput1_3.dll xinput_remap.c xinput1_3.def`
2. Use these EXACT commands in the CI workflow. Copy-paste, don't paraphrase.
3. Add a CI test that verifies the binaries are functional: run them under Wine in CI (optional but ideal), or at minimum verify they are valid PE binaries with `file` command.

**Detection:** `file shm_launcher.exe` should show "PE32+ executable (GUI) x86-64" (note: GUI, not console, because of `-Wl,--subsystem,windows`). If it shows "console" the subsystem flag was missed.

**Phase relevance:** Phase 1 (CI workflow creation).

---

### Pitfall 7: Neptune VDF Treated as Binary When It's Plain Text

**What goes wrong:** The Neptune controller layout VDF is currently embedded as base64 alongside the actual binaries. During the revision, it gets lumped into the "download from GitHub Releases" strategy. But VDF is a plain-text Valve configuration file -- it should be committed as a raw file in the repo, not published as a release asset.

**Prevention:**
1. The PROJECT.md already identifies this correctly: "Commit Neptune controller VDF as a raw file in the repo (not embedded base64)."
2. Decode the base64 block and commit the resulting `.vdf` file to the repo (e.g., `controller_neptune.vdf` at repo root or in a `config/` directory).
3. The script should reference this file via a raw GitHub URL (`https://raw.githubusercontent.com/0xc0re/trashcan/main/controller_neptune.vdf`) OR bundle it inline in the script as a heredoc (it's just text). A raw GitHub URL is cleaner.
4. Keep SHA-256 verification for the VDF file -- even text files can be tampered with.

**Detection:** If the VDF is pushed to GitHub Releases instead of the repo, it works but creates unnecessary coupling between release versions and a config file that changes independently.

**Phase relevance:** Phase 1 (repo setup -- commit the VDF file) and Phase 2 (script references it correctly).

---

### Pitfall 8: Removing Embedded Source Comments Breaks Auditability Promise

**What goes wrong:** The current script embeds ~393 lines of C source code as comments so users can audit what the binaries do. Removing these comments (as planned) without providing an equivalent audit path breaks the trust model that the script's documentation promises.

**Prevention:**
1. Replace embedded source comments with a clear pointer to the vendored source in the repo: "Source code: https://github.com/0xc0re/trashcan/tree/main/tools/"
2. Replace the "REPRODUCIBLE BUILDS" section with a shorter version: "Build from source: clone this repo and run `make` in the `tools/` directory. The CI workflow at `.github/workflows/build.yml` shows the exact commands."
3. Add a `Makefile` or build script in `tools/` that encapsulates the compile commands, so users don't have to read CI YAML to reproduce builds.
4. Keep the SHA-256 constants in the script -- these are the cryptographic proof that downloaded binaries match the source.

**Detection:** Users who previously verified builds using the embedded source will look for equivalent instructions.

**Phase relevance:** Phase 2 (script changes) and Phase 3 (script restructuring -- updating documentation comments).

---

### Pitfall 9: Offline/Air-Gapped Users Lose the Ability to Install

**What goes wrong:** The current script works without internet for the binary installation step (binaries are embedded). Switching to runtime downloads means the script REQUIRES internet for first install. Users behind corporate firewalls, on aircraft, or in regions with unreliable connectivity cannot install.

**Prevention:**
1. The PROJECT.md already flags this: "Offline graceful: if curl fails to download binaries, script should give a clear error with fallback instructions."
2. Implement retry with exponential backoff: `curl --retry 3 --retry-delay 2 --retry-max-time 30`.
3. On download failure, print actionable instructions: "Download failed. You can manually download the binaries from https://github.com/0xc0re/trashcan/releases/download/v1.0.0/ and place them in ~/.local/share/cluckers-central/tools/"
4. Consider supporting a `TOOLS_DIR` override or a `--tools-path` flag so users can pre-stage binaries.
5. Do NOT attempt to re-embed binaries as a fallback. That defeats the entire purpose of the revision.

**Detection:** Disconnect from the network and run the script. The error message should be clear and actionable.

**Phase relevance:** Phase 2 (script download logic).

---

### Pitfall 10: GitHub Actions Runner Image Changes Break CI

**What goes wrong:** GitHub periodically updates runner images. The `ubuntu-latest` tag can shift from Ubuntu 22.04 to 24.04 (or beyond), changing the available MinGW version. A workflow that worked last month suddenly produces binaries with different checksums or fails entirely because a package was renamed or removed.

**Prevention:**
1. Pin the runner image: use `runs-on: ubuntu-24.04` not `runs-on: ubuntu-latest`.
2. Pin the `gcc-mingw-w64-x86-64` package version if apt supports it, or at minimum log the installed version.
3. Add a hash of the compiled binary to the CI output. If it changes unexpectedly, the CI should flag it.
4. Consider using a Docker container in CI with a fully pinned toolchain for maximum reproducibility.

**Detection:** CI logs show a different GCC version than expected. Binary checksums change without source code changes.

**Phase relevance:** Phase 1 (CI workflow creation).


## Minor Pitfalls

### Pitfall 11: Forgetting to Remove ALL Base64 Blocks

**What goes wrong:** After adding download logic, one of the three base64 blocks (`SHM_B64_EOF`, `XDLL_B64_EOF`, `NEPTUNE_B64_EOF`) is accidentally left in the script, making the script larger than necessary and creating confusion about which path (embedded vs downloaded) is actually used.

**Prevention:**
1. After removing base64 blocks, verify: `grep -c 'B64_EOF' script.sh` should return 0.
2. Check file size: the script should drop from ~924KB to roughly 100-150KB after removing base64 and embedded source comments.
3. The heredoc markers to remove are: `SHM_B64_EOF`, `XDLL_B64_EOF`, `NEPTUNE_B64_EOF`.

**Detection:** `wc -c script.sh` still shows >500KB after revision.

**Phase relevance:** Phase 2 (script changes).

---

### Pitfall 12: Parallel Download Function Interferes with Binary Downloads

**What goes wrong:** The script already has a sophisticated `parallel_download()` function (line ~1510) for downloading the game zip. If the new binary download logic accidentally uses this function for small files (the helper binaries are likely <100KB each), the range-request splitting and chunking logic adds unnecessary complexity and may fail for servers that don't support range requests for small files.

**Prevention:**
1. Use a simple `curl -fSL -o "$dest" "$url"` for the helper binaries. They are tiny and don't benefit from parallel downloading.
2. Reserve `parallel_download()` for the game zip, which is multi-GB.
3. Create a small helper function like `download_tool()` that wraps the curl call with retry logic and error handling specific to GitHub release assets.

**Detection:** Binary download attempts show "parallel download" or "N threads" messages for a sub-100KB file.

**Phase relevance:** Phase 2 (script download logic).

---

### Pitfall 13: sed/grep Extraction Commands in Comments Become Invalid

**What goes wrong:** The current script contains `sed` one-liners (lines ~3413-3425) that users can run to extract the embedded C source code from the script. After removing the embedded source, these commands will silently produce empty output or errors.

**Prevention:**
1. Remove the `sed` extraction commands along with the embedded source.
2. Replace with: "View source at https://github.com/0xc0re/trashcan/tree/main/tools/"
3. Search for all cross-references to "SOURCE CODE" and "REPRODUCIBLE BUILDS" in comments and update them.

**Detection:** `grep -n 'sed -n' script.sh` shows extraction commands that reference content that no longer exists.

**Phase relevance:** Phase 2 (script changes) and Phase 3 (comment cleanup during restructuring).


## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| CI Workflow (Phase 1) | Compiler version mismatch producing different binaries | Pin `ubuntu-24.04` runner, log `x86_64-w64-mingw32-gcc --version`, set `SOURCE_DATE_EPOCH=0` |
| CI Workflow (Phase 1) | Missing compile flags (`-municode`, `-Wl,--subsystem,windows`) | Copy exact commands from script's REPRODUCIBLE BUILDS section |
| CI Workflow (Phase 1) | Release asset upload fails silently | Verify assets exist with `gh release view` after upload step |
| Download Logic (Phase 2) | curl saves HTML error page instead of binary | Use `curl -fSL`, check exit code, check file size before SHA-256 |
| Download Logic (Phase 2) | GitHub API rate limiting on shared IPs | Use direct download URLs, never the API, for binary downloads |
| Download Logic (Phase 2) | Missing skip-if-verified optimization | Preserve `if file exists AND sha256 matches, skip` pattern |
| Download Logic (Phase 2) | Checksum constants not updated for CI binaries | Update SHA-256 constants after first successful CI build |
| VDF + Repo Setup (Phase 1) | VDF file treated as binary release asset | Commit as raw text file in repo, download via raw.githubusercontent.com |
| Script Restructuring (Phase 3) | Variable scoping changes when functions move | Run shellcheck, test all flag combinations, use `bash -x` trace comparison |
| Script Restructuring (Phase 3) | Embedded content removal leaves dangling references | grep for `B64_EOF`, `SOURCE CODE`, `REPRODUCIBLE BUILDS`, `sed -n` |
| Script Restructuring (Phase 3) | Behavioral regression in non-default modes | Test matrix: every flag and combination from `--help` output |

## Sources

- [Deterministic Builds with C/C++ - Conan Blog](https://blog.conan.io/2019/09/02/Deterministic-builds-with-C-C++.html) -- PE timestamp non-determinism, SOURCE_DATE_EPOCH
- [Tor Project: Deterministic Builds Technical Details](https://blog.torproject.org/deterministic-builds-part-two-technical-details/) -- PE header timestamp patching for reproducibility
- [GitHub Rate Limits for REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) -- 60 req/hr unauthenticated limit
- [GitHub Changelog: Updated rate limits for unauthenticated requests](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/) -- recent rate limit changes
- [Download Latest Release from GitHub and Verify Checksums](https://thanoskoutr.com/posts/download-release-github/) -- curl download patterns
- [curl retry documentation](https://everything.curl.dev/usingcurl/downloads/retry.html) -- retry and backoff options
- [GCC/MinGW 32-bit compilers on windows-latest](https://github.com/actions/virtual-environments/issues/2549) -- runner image MinGW issues
- [Windows MinGW binary runtime issues](https://github.com/actions/runner-images/issues/6412) -- runner image breaking changes
- [ShellSpec BDD Testing Framework](https://shellspec.info/) -- bash script testing
- Current script analysis: `/home/cstory/src/sleepy/script.sh` (5069 lines, 924KB)
