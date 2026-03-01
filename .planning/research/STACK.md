# Technology Stack

**Project:** Cluckers Central Script Revision -- CI Binary Builds & Runtime Download
**Researched:** 2026-03-01
**Scope:** Cross-compiling Windows binaries from C in GitHub Actions, publishing as release assets, downloading at runtime in bash with checksum verification

## Recommended Stack

### CI/CD -- GitHub Actions Workflow

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| `runs-on: ubuntu-24.04` | Ubuntu 24.04 LTS | CI runner OS | Pin to `ubuntu-24.04`, not `ubuntu-latest`. The script's reproducible build docs specify Ubuntu 24.04 LTS, and pinning avoids silent breakage when `ubuntu-latest` rolls forward. `ubuntu-latest` already points to 24.04 as of Jan 2025, but explicit pinning is defensive. | HIGH |
| `actions/checkout` | `@v4` | Checkout repository | v4 is the safe, battle-tested choice. v6 exists (Nov 2024, Node.js 24) but changes credential persistence behavior with no clear benefit for this use case. v4 continues to receive backport patches (v4.3.1, Nov 2024). Use v4 to avoid unnecessary migration risk. | HIGH |
| `softprops/action-gh-release` | `@v2` | Create release + upload assets | The standard for GitHub release creation. GitHub's own `actions/upload-release-asset` was archived March 2021 and explicitly recommends softprops as the replacement. Latest: v2.5.0 (Dec 2024). Handles release creation and asset upload in one step. | HIGH |
| `gcc-mingw-w64-x86-64` | 13.2.0 (via apt) | Cross-compiler | Ubuntu 24.04's apt ships GCC 13.2.0 for mingw-w64. This matches exactly what the existing script documents as its compiler (`x86_64-w64-mingw32-gcc (GCC) 13-win32 (13.2.0)`), ensuring byte-identical reproducible builds. Install via `sudo apt-get install -y gcc-mingw-w64-x86-64`. | HIGH |

### CI/CD -- Workflow Trigger

| Pattern | Value | Why | Confidence |
|---------|-------|-----|------------|
| Trigger event | `on: push: tags: ['v*']` | Tag-push trigger is the standard CI/CD pattern for releases. Pushing `v1.0.0` triggers the build-and-release pipeline. No manual intervention needed after tagging. | HIGH |
| Tag format | Semantic: `v1.0.0` | Matches existing cluckers repo convention (v1.2.0 releases exist). Simple, universally understood. | HIGH |

### Runtime -- Bash Download

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| `curl` | (system) | Download binaries | Already a hard dependency of the script (`tools=(...curl...)`). No new dependencies. Use the script's existing `CURL_FLAGS` and `CURL_SILENT` variables for consistency. | HIGH |
| `sha256sum` | (system) | Checksum verification | Already a hard dependency of the script. The existing `verify_sha256()` function is well-written and handles the all-zeros placeholder for development. Reuse it as-is. | HIGH |

### Runtime -- Download URLs

| Pattern | Value | Why | Confidence |
|---------|-------|-----|------------|
| Stable tagged URL | `https://github.com/0xc0re/trashcan/releases/download/v{VERSION}/{filename}` | Deterministic, no API call needed, no jq dependency, curl-friendly with `-L` for redirect following. GitHub guarantees this URL pattern for release assets. | HIGH |
| Latest URL (do NOT use) | `https://github.com/0xc0re/trashcan/releases/latest/download/{filename}` | See "Alternatives Considered" below for why this is rejected. | HIGH |

## Detailed Specifications

### GitHub Actions Workflow Structure

```yaml
name: Build Helper Binaries

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Install mingw-w64 cross-compiler
        run: |
          sudo apt-get update
          sudo apt-get install -y gcc-mingw-w64-x86-64

      - name: Compile shm_launcher.exe
        run: |
          x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows \
            -o shm_launcher.exe tools/shm_launcher.c

      - name: Compile xinput1_3.dll
        run: |
          x86_64-w64-mingw32-gcc -O2 -Wall -shared \
            -o xinput1_3.dll tools/xinput_remap.c tools/xinput1_3.def

      - name: Generate SHA-256 checksums
        run: sha256sum shm_launcher.exe xinput1_3.dll > SHA256SUMS.txt

      - name: Upload release assets
        uses: softprops/action-gh-release@v2
        with:
          files: |
            shm_launcher.exe
            xinput1_3.dll
            SHA256SUMS.txt
```

### Compiler Flags (Preserved from Existing Script)

These flags are not negotiable -- they produce byte-identical output to the current embedded binaries:

| Binary | Flags | Rationale |
|--------|-------|-----------|
| `shm_launcher.exe` | `-O2 -Wall -municode -Wl,--subsystem,windows` | `-municode` required because entry point is `wmain()` (wide-char Unicode). `-Wl,--subsystem,windows` suppresses console window. `-O2` for optimization. `-Wall` for warnings. |
| `xinput1_3.dll` | `-O2 -Wall -shared` | `-shared` produces a DLL. Linked with `xinput1_3.def` for export definitions. |

### curl Flags for Runtime Binary Download

```bash
# Download with retry, timeout, and redirect following.
# Uses the script's existing CURL_FLAGS variable (-sL or -L depending on verbose mode).
curl ${CURL_FLAGS} \
  --fail \
  --retry 3 \
  --retry-delay 5 \
  --retry-max-time 60 \
  --max-time 30 \
  --connect-timeout 10 \
  -o "${dest_tmp}" \
  "${download_url}"
```

| Flag | Purpose | Why |
|------|---------|-----|
| `${CURL_FLAGS}` | `-sL` (normal) or `-L` (verbose) | Already defined in script. `-L` follows GitHub's redirect from releases URL to CDN. `-s` silences progress in non-verbose mode. |
| `--fail` / `-f` | Return error on HTTP 4xx/5xx | Without this, curl writes the HTML error page to the output file. The script already uses `-f` consistently. |
| `--retry 3` | Retry transient failures up to 3 times | Handles flaky connections. 3 is conservative -- these are small files (< 1MB). |
| `--retry-delay 5` | 5-second fixed delay between retries | Avoids hammering GitHub CDN. Fixed delay is simpler than exponential backoff for a 3-retry scenario. |
| `--retry-max-time 60` | Cap total retry time at 60 seconds | Prevents infinite retry loops. 60s is generous for < 1MB files. |
| `--max-time 30` | Individual transfer timeout | 30 seconds per attempt. More than enough for < 1MB binaries even on slow connections. |
| `--connect-timeout 10` | Connection establishment timeout | Fail fast if GitHub is unreachable rather than hanging for minutes. |
| `-o "${dest_tmp}"` | Write to temp file | Download to temp, verify checksum, then `mv` to final path. Same pattern the script already uses for base64 extraction. |

### SHA-256 Verification Pattern

Reuse the existing `verify_sha256()` function unchanged:

```bash
verify_sha256() {
  local -r file_path="$1"
  local -r expected="$2"

  # Skip verification when expected is the all-zeros placeholder
  # (signals "checksum not yet known" during development).
  if [[ "${expected}" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    return 0
  fi

  info_msg "Verifying SHA-256..."
  local actual
  actual=$(sha256sum "${file_path}" | awk '{print $1}')
  if [[ "${actual}" != "${expected}" ]]; then
    error_exit "SHA-256 mismatch for ${file_path}.
  Expected: ${expected}
  Got:      ${actual}"
  fi
}
```

The checksums are hardcoded as `readonly` constants at the top of the script. When CI produces new binaries from a new tag, the workflow also produces `SHA256SUMS.txt` as a release asset for human reference, but the script itself uses hardcoded constants for verification (same pattern as today).

### Download Function Pattern

```bash
# Constants at top of script (replacing base64 blocks):
readonly TOOLS_VERSION="v1.0.0"
readonly TOOLS_BASE_URL="https://github.com/0xc0re/trashcan/releases/download/${TOOLS_VERSION}"
readonly SHM_LAUNCHER_SHA256="923ff334fd0b0aa6be27d57bf11809d604abb7f6342c881328423f73efcb69fa"
readonly XINPUT_DLL_SHA256="30c2cf5d35fb7489779ac6fa714c6f874868d58ec2e5f6623d9dd5a24ae503a9"

download_tool() {
  local -r filename="$1"
  local -r dest="$2"
  local -r expected_sha256="$3"
  local -r url="${TOOLS_BASE_URL}/${filename}"

  local dest_tmp
  dest_tmp=$(mktemp --suffix=".${filename##*.}")

  info_msg "Downloading ${filename} from GitHub releases..."
  if ! curl ${CURL_FLAGS} \
      --fail \
      --retry 3 \
      --retry-delay 5 \
      --retry-max-time 60 \
      --max-time 30 \
      --connect-timeout 10 \
      -o "${dest_tmp}" \
      "${url}"; then
    rm -f "${dest_tmp}"
    error_exit "Failed to download ${filename}.
  URL: ${url}
  Check your internet connection, or download manually from:
  https://github.com/0xc0re/trashcan/releases/tag/${TOOLS_VERSION}"
  fi

  verify_sha256 "${dest_tmp}" "${expected_sha256}"
  mv "${dest_tmp}" "${dest}"
  ok_msg "${filename} installed."
}
```

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Release action | `softprops/action-gh-release@v2` | `actions/upload-release-asset@v1` | Archived March 2021, unmaintained, officially recommends softprops as replacement. |
| Release action | `softprops/action-gh-release@v2` | `gh release create` in a `run:` step | Works but reinvents what softprops already handles (idempotent release creation, multi-file upload, draft support). The action is declarative and more readable. |
| Checkout action | `actions/checkout@v4` | `actions/checkout@v6` | v6 (Nov 2024) changes credential persistence behavior. No benefit for this simple workflow. v4 continues receiving patches. Avoid unnecessary migration risk for a workflow that just checks out code and compiles. |
| Runner OS | `ubuntu-24.04` (pinned) | `ubuntu-latest` | `ubuntu-latest` already maps to 24.04, but pinning prevents silent breakage when GitHub rolls forward to 26.04. The script documents "Ubuntu 24.04 LTS" as its reference environment -- pin it. |
| Download URL | Tagged URL (`/releases/download/v1.0.0/`) | Latest URL (`/releases/latest/download/`) | Using `/latest/` means the script could silently download binaries that don't match its hardcoded checksums after a new release. Tagged URLs ensure the script always gets the exact version its checksums expect. The `TOOLS_VERSION` constant makes version bumps explicit. |
| Download URL | Tagged URL | GitHub API + jq | Adds jq as a new runtime dependency. The script currently requires `curl` and `sha256sum` but not `jq`. Tagged URLs avoid this entirely -- they're deterministic, no API parsing needed. |
| Checksum storage | Hardcoded `readonly` constants | Download SHA256SUMS.txt at runtime | Downloading checksums from the same server you're downloading binaries from provides zero additional security -- an attacker who can tamper with binaries can tamper with the checksum file. Hardcoded constants in the script are the correct pattern (same as today). |
| Cross-compiler | `gcc-mingw-w64-x86-64` via apt | LLVM/Clang cross-compile | The existing binaries were compiled with GCC mingw. Switching compilers would change binary output, breaking reproducible build verification. GCC mingw is the standard for Wine/Proton ecosystem tooling. |
| Cross-compiler | Install via apt in workflow | Pre-built Docker image with mingw | Over-engineering for two tiny C files. `apt-get install` takes < 10 seconds and is transparent. A Docker image adds maintenance burden and opacity. |
| Checksum tool | `sha256sum` (coreutils) | `openssl dgst -sha256` | `sha256sum` is already a hard dependency of the script. It's simpler, produces cleaner output, and is available on every Linux distro via coreutils. No reason to change. |

## What NOT to Use

| Technology | Why Not |
|------------|---------|
| `actions/upload-release-asset` | Archived, unmaintained since 2021. |
| `actions/create-release` | Also archived. softprops replaces both. |
| `ubuntu-latest` (unpinned) | Will silently change underneath you. Pin to `ubuntu-24.04`. |
| `/releases/latest/download/` URLs | Script has hardcoded checksums. A new release would cause checksum mismatch. Version must be explicit. |
| `jq` for parsing GitHub API | Unnecessary dependency. Tagged URLs are deterministic. |
| `wget` instead of `curl` | `curl` is already required. Don't split download logic across two tools. |
| Docker/container-based CI | Two C files. `apt-get install` is simpler and more transparent. |
| CMake / Meson / Make | The compile commands are two one-liners. A build system adds complexity with zero benefit. |
| `--retry-all-errors` | Too aggressive. Retries on 404 (wrong URL) or 403 (rate-limited) would waste time. Default retry behavior handles transient 5xx and timeouts, which is correct. |
| `actions/checkout@v6` | Unnecessary migration risk. v4 is stable and patched. |
| Separate checksum download | Security theater -- checksums from the same origin as binaries add no trust. Hardcode them. |

## Version Update Workflow

When updating the helper binaries:

1. Update C source in `tools/`
2. Push a new tag: `git tag v1.1.0 && git push origin v1.1.0`
3. CI builds, checksums, and publishes to GitHub Releases automatically
4. Read the new checksums from the release's `SHA256SUMS.txt` (or from the CI log)
5. Update `SHM_LAUNCHER_SHA256`, `XINPUT_DLL_SHA256`, and `TOOLS_VERSION` in `script.sh`
6. Commit the script update

This is a deliberate two-step process. The script's checksums are never auto-updated -- a human must verify and commit the new values. This is a feature, not a limitation: it prevents supply-chain attacks where a compromised CI pipeline publishes tampered binaries.

## Sources

- [Ubuntu 24.04 Runner Image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md) -- GCC versions, runner contents (HIGH confidence)
- [ubuntu-latest now maps to 24.04](https://github.com/actions/runner-images/issues/10636) -- transition completed Jan 2025 (HIGH confidence)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release) -- v2.5.0, Dec 2024 (HIGH confidence)
- [softprops/action-gh-release releases](https://github.com/softprops/action-gh-release/releases) -- version history (HIGH confidence)
- [actions/upload-release-asset](https://github.com/actions/upload-release-asset) -- archived March 2021, recommends softprops (HIGH confidence)
- [actions/checkout releases](https://github.com/actions/checkout/releases) -- v4.3.1 (Nov 2024), v6.0.2 (Jan 2025) (HIGH confidence)
- [gcc-mingw-w64-x86-64 on Ubuntu Noble](https://launchpad.net/ubuntu/noble/+package/mingw-w64) -- mingw-w64 11.0.1, GCC 13.2.0 (HIGH confidence)
- [GitHub Docs: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) -- `/releases/latest/download/` URL pattern (HIGH confidence)
- [curl retry documentation](https://everything.curl.dev/usingcurl/downloads/retry.html) -- `--retry`, `--retry-delay`, `--retry-max-time` flags (HIGH confidence)
- [Existing script.sh](file:///home/cstory/src/sleepy/script.sh) -- current verify_sha256(), CURL_FLAGS, download patterns (HIGH confidence, primary source)
