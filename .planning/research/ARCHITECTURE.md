# Architecture Patterns

**Domain:** Bash installer script revision with CI/CD cross-compilation pipeline
**Researched:** 2026-03-01

## Recommended Architecture

The system has three distinct components that operate across two repositories and two execution contexts (CI and user machine). The architecture is a linear pipeline: source code flows through CI into release assets, which are consumed at runtime by the installer script.

```
[0xc0re/trashcan repo]
  |
  |-- tools/                     <-- C source files (vendored)
  |     |-- shm_launcher.c
  |     |-- xinput_remap.c
  |     |-- xinput1_3.def
  |
  |-- configs/                   <-- Raw config files (not base64)
  |     |-- controller_neptune.vdf
  |
  |-- .github/workflows/
  |     |-- build.yml            <-- CI workflow (cross-compile + release)
  |
  |-- script.sh                  <-- Installer script (restructured)

[GitHub Releases]
  |-- v1.0.0/
        |-- shm_launcher.exe     <-- Built from tools/shm_launcher.c
        |-- xinput1_3.dll        <-- Built from tools/xinput_remap.c + .def
        |-- checksums.sha256     <-- SHA-256 of both binaries
```

### Component Boundaries

| Component | Responsibility | Communicates With | Location |
|-----------|---------------|-------------------|----------|
| **C source files** (`tools/`) | Auditable source for Windows helper binaries | CI workflow reads them at build time | `0xc0re/trashcan` repo |
| **CI workflow** (`.github/workflows/build.yml`) | Cross-compiles source to Windows binaries, creates GitHub Release with assets | Reads `tools/`, writes to GitHub Releases API | GitHub Actions runner (ubuntu-latest) |
| **GitHub Release assets** | Versioned distribution point for compiled binaries | CI uploads, script.sh downloads | GitHub Releases on `0xc0re/trashcan` |
| **Neptune VDF config** (`configs/`) | Steam Deck controller layout template | script.sh reads it directly from repo (or embeds inline) | `0xc0re/trashcan` repo |
| **script.sh** | End-user installer: downloads binaries, sets up Wine, installs game | Downloads from GitHub Releases; reads VDF from local file or repo | User's machine at runtime |

### Data Flow

**Build-time flow (CI -- triggered by git tag push):**

```
git tag v1.0.0 && git push --tags
        |
        v
GitHub Actions trigger: on push tags 'v*'
        |
        v
ubuntu-latest runner
        |
        +-- apt-get install gcc-mingw-w64-x86-64
        |
        +-- x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows \
        |       -o shm_launcher.exe tools/shm_launcher.c
        |
        +-- x86_64-w64-mingw32-gcc -O2 -Wall -shared \
        |       -o xinput1_3.dll tools/xinput_remap.c tools/xinput1_3.def
        |
        +-- sha256sum shm_launcher.exe xinput1_3.dll > checksums.sha256
        |
        +-- softprops/action-gh-release@v2
                creates release for tag, uploads .exe, .dll, .sha256
```

**Runtime flow (user runs script.sh):**

```
User: ./script.sh --controller
        |
        v
Step 1-5: System deps, Wine prefix, game download (unchanged)
        |
        v
Step 6 (revised): Download helper binaries
        |
        +-- curl -fSL https://github.com/0xc0re/trashcan/releases/download/v1.0.0/shm_launcher.exe
        +-- curl -fSL https://github.com/0xc0re/trashcan/releases/download/v1.0.0/xinput1_3.dll
        |
        +-- sha256sum --check (against hardcoded checksums in script)
        |
        +-- Deploy to TOOLS_DIR / Wine prefix
        |
        v
Steps 7-12: Assets, launcher, desktop shortcut, Steam, patches, auth (unchanged)
```

## Component 1: CI Workflow (`.github/workflows/build.yml`)

### Design

Use a single-job workflow triggered by version tags. The ubuntu-latest runner does NOT include mingw-w64 pre-installed (verified against the GitHub Actions Ubuntu 24.04 runner image manifest), so the workflow must install it via apt.

**Confidence:** HIGH -- verified ubuntu-latest runner contents via official runner-images README

### Workflow Structure

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
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install MinGW cross-compiler
        run: |
          sudo apt-get update
          sudo apt-get install -y gcc-mingw-w64-x86-64

      - name: Build shm_launcher.exe
        run: |
          x86_64-w64-mingw32-gcc -O2 -Wall -municode \
            -Wl,--subsystem,windows \
            -o shm_launcher.exe tools/shm_launcher.c

      - name: Build xinput1_3.dll
        run: |
          x86_64-w64-mingw32-gcc -O2 -Wall -shared \
            -o xinput1_3.dll tools/xinput_remap.c tools/xinput1_3.def

      - name: Generate checksums
        run: sha256sum shm_launcher.exe xinput1_3.dll > checksums.sha256

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            shm_launcher.exe
            xinput1_3.dll
            checksums.sha256
```

**Confidence:** HIGH for softprops/action-gh-release@v2 (latest v2.5.0, actively maintained, verified via GitHub repo). HIGH for the mingw compile flags (copied directly from the existing script's documented reproducible build instructions).

### Key Design Decisions

1. **Single job, not matrix:** There is only one target (x86_64 Windows). No need for a build matrix.
2. **`permissions: contents: write`:** Required to create releases and upload assets. Without it, the GITHUB_TOKEN gets a 403.
3. **Tag-triggered only:** Binaries should only be built on explicit version tags, not on every push. This keeps releases intentional and auditable.
4. **Checksum file in release:** The checksums.sha256 file travels with the binaries. The script can optionally download and verify it, or continue using hardcoded checksums (see Script Architecture below for the tradeoff).

## Component 2: Release Asset Management

### Versioning Strategy

Use semantic version tags (`v1.0.0`) on the trashcan repo. The tag represents the version of the helper binaries, not the game version (which has its own versioning from the update server).

**Release URL pattern:**
```
https://github.com/0xc0re/trashcan/releases/download/{tag}/shm_launcher.exe
https://github.com/0xc0re/trashcan/releases/download/{tag}/xinput1_3.dll
```

**Script references a specific tag:** The script should hardcode the release tag (e.g., `TOOLS_RELEASE="v1.0.0"`). This ensures:
- Reproducibility: every script version downloads exactly the same binaries
- No surprise breakage: a new tag does not silently change what users download
- Auditability: the tag in the script maps to a specific commit and build

**Do NOT use the `latest` release URL.** The `latest` endpoint resolves dynamically, which breaks reproducibility. If binaries need updating, bump the tag in the script explicitly.

### Checksum Strategy

**Recommendation: Keep hardcoded checksums in script.sh.** The existing script already has `SHM_LAUNCHER_SHA256` and `XINPUT_DLL_SHA256` constants. This is the right pattern because:
- The checksums serve as a trust anchor. Downloading a checksum file from the same source as the binary provides no additional security -- if the binary is compromised, the checksum file would be too.
- Hardcoded checksums in the script mean the script itself is the verification source, and the script is what the user has already chosen to trust by running it.
- When binaries are rebuilt (new tag), update both the tag reference and the checksum constants in the script. This is a deliberate, reviewable change.

## Component 3: Script Architecture (script.sh restructure)

### Current State Analysis

The existing script is 5,069 lines with this structure:

| Section | Lines | Content |
|---------|-------|---------|
| Header/constants | 1-313 | Shebang, usage docs, readonly vars, ANSI colors |
| Output helpers | 314-380 | step_msg, info_msg, ok_msg, warn_msg, error_exit, print_help |
| Utility functions | 381-470 | command_exists, is_pkg_installed, get_wine_env_additions |
| Core functions | 471-2599 | is_game_up_to_date, install_sys_deps, ensure_python_deps, ensure_winetricks_fresh, install_winetricks_multi, fetch_version_info, parse_version_field, verify_sha256, run_uninstall, parallel_download, run_update, is_steam_deck, apply_game_patches, find_wine |
| main() | 2600-5067 | Arg parsing, Steps 1-12, inline Python scripts |
| Signal handler + entry | 5068-5069 | _term(), main "$@" |

**Key problem:** `main()` is ~2,470 lines. It contains:
- Argument parsing (~100 lines)
- 12 numbered steps with heavy inline logic
- ~393 lines of C source as comments
- ~400+ lines of base64 data (SHM_B64_EOF, XDLL_B64_EOF, NEPTUNE_B64_EOF)
- Two substantial inline Python scripts (~150+ lines each)
- Step 6 alone is ~550 lines (comments + source + base64 + build instructions)

### Recommended Restructure

Follow the Google Shell Style Guide pattern: constants at top, all functions grouped, main() as thin orchestrator at bottom.

**Target structure for script.sh:**

```
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SECTION 1: Guards (root check)
# ============================================================

# ============================================================
# SECTION 2: User-configurable variables
# ============================================================

# ============================================================
# SECTION 3: Constants (readonly)
# ============================================================
# All readonly vars, ANSI codes, URLs, paths, checksums
# NEW: TOOLS_RELEASE="v1.0.0"
# NEW: TOOLS_BASE_URL="https://github.com/0xc0re/trashcan/releases/download/${TOOLS_RELEASE}"

# ============================================================
# SECTION 4: Output helpers
# ============================================================
# step_msg, info_msg, ok_msg, warn_msg, error_exit

# ============================================================
# SECTION 5: Utility functions
# ============================================================
# command_exists, is_pkg_installed, verify_sha256, print_help

# ============================================================
# SECTION 6: System setup functions
# ============================================================
# install_sys_deps, ensure_python_deps, ensure_winetricks_fresh,
# install_winetricks_multi

# ============================================================
# SECTION 7: Wine functions
# ============================================================
# find_wine, get_wine_env_additions, create_wine_prefix (extracted from main)

# ============================================================
# SECTION 8: Game management functions
# ============================================================
# fetch_version_info, parse_version_field, is_game_up_to_date,
# parallel_download, download_game (extracted from main),
# run_update

# ============================================================
# SECTION 9: Binary management functions (NEW)
# ============================================================
# download_helper_binaries -- replaces base64 extraction
# install_shm_launcher
# install_xinput_dll

# ============================================================
# SECTION 10: Patch and config functions
# ============================================================
# is_steam_deck, apply_game_patches
# deploy_neptune_vdf (reads from configs/ dir or inline)

# ============================================================
# SECTION 11: Desktop integration functions
# ============================================================
# create_launcher_script (extracted from main Step 8)
# create_desktop_shortcut (extracted from main Step 9)
# configure_steam_integration (extracted from main Step 10)
# download_steam_assets (extracted from main Step 7)

# ============================================================
# SECTION 12: Auth functions
# ============================================================
# verify_account (wraps the inline Python)

# ============================================================
# SECTION 13: Uninstall
# ============================================================
# run_uninstall

# ============================================================
# SECTION 14: main()
# ============================================================
# Thin orchestrator: parse args, call functions in order

# ============================================================
# SECTION 15: Signal handler + entry point
# ============================================================
# _term()
# main "$@"
```

### Extraction Targets (from main)

These blocks should be extracted from main() into named functions:

| Current Location | Lines (approx) | New Function Name | Rationale |
|-----------------|----------------|-------------------|-----------|
| main Step 3 (Wine prefix) | ~150 | `create_wine_prefix` | Self-contained Wine setup logic |
| main Step 4 (winetricks) | ~110 | `configure_wine_runtime` | Winetricks + DXVK config |
| main Step 5 (game download) | ~100 | `download_game` | Game zip download and extraction |
| main Step 6 (base64 decode) | ~550 | `download_helper_binaries` | **Replace entirely** with curl download + verify |
| main Step 7 (assets) | ~90 | `download_steam_assets` | Steam art download |
| main Step 8 (launcher) | ~400 | `create_launcher_script` | Launcher generation |
| main Step 9 (desktop) | ~50 | `create_desktop_shortcut` | .desktop file creation |
| main Step 10 (Steam) | ~300 | `configure_steam_integration` | Steam shortcut + grid art |
| main Step 12 (auth) | ~100 | `verify_account` | Python auth wrapper |

After extraction, `main()` should be approximately 150-200 lines: argument parsing + sequential function calls.

### Pattern: New Binary Download Function

The new `download_helper_binaries` function replaces the ~550-line Step 6 block (C source comments + base64 blobs + build instructions). It becomes approximately 40-50 lines:

```bash
download_helper_binaries() {
  local tools_dir="$1"
  local controller_mode="$2"

  mkdir -p "${tools_dir}"

  local shm_path="${tools_dir}/shm_launcher.exe"
  local shm_url="${TOOLS_BASE_URL}/shm_launcher.exe"

  step_msg "Step 6 -- Installing helper binaries..."

  if [[ ! -f "${shm_path}" ]] || ! verify_sha256 "${shm_path}" "${SHM_LAUNCHER_SHA256}"; then
    info_msg "Downloading shm_launcher.exe..."
    curl -fSL --max-time 60 -o "${shm_path}" "${shm_url}" \
      || error_exit "Failed to download shm_launcher.exe from ${shm_url}"
    verify_sha256 "${shm_path}" "${SHM_LAUNCHER_SHA256}" \
      || error_exit "SHA-256 mismatch for shm_launcher.exe -- binary may be corrupted or tampered with"
  else
    ok_msg "shm_launcher.exe already present and verified."
  fi

  if [[ "${controller_mode}" == "true" ]]; then
    local xdll_path="${tools_dir}/xinput1_3.dll"
    local xdll_url="${TOOLS_BASE_URL}/xinput1_3.dll"

    if [[ ! -f "${xdll_path}" ]] || ! verify_sha256 "${xdll_path}" "${XINPUT_DLL_SHA256}"; then
      info_msg "Downloading xinput1_3.dll..."
      curl -fSL --max-time 60 -o "${xdll_path}" "${xdll_url}" \
        || error_exit "Failed to download xinput1_3.dll from ${xdll_url}"
      verify_sha256 "${xdll_path}" "${XINPUT_DLL_SHA256}" \
        || error_exit "SHA-256 mismatch for xinput1_3.dll -- binary may be corrupted or tampered with"
    else
      ok_msg "xinput1_3.dll already present and verified."
    fi
  fi
}
```

### Pattern: Neptune VDF Handling

The Neptune VDF is a config file (~122 lines of base64, decodes to a text VDF). Two viable approaches:

**Recommended: Inline the raw VDF text using a heredoc.** The VDF is a config file, not a binary. Store it as a readable heredoc in the `deploy_neptune_vdf` function rather than base64. This eliminates the base64 decode step and makes the config directly auditable in the script.

Alternative: Read from `configs/controller_neptune.vdf` in the repo. But this requires the user to have the full repo cloned, which they typically do not -- they download script.sh standalone. So inline heredoc is better for a single-file script.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Using GitHub "latest" Release URL
**What:** Constructing download URLs with `/releases/latest/download/` instead of a pinned tag.
**Why bad:** A new release silently changes what every user downloads. If a build is broken, all new installs break with no way to rollback except creating another release. The checksums in the script will no longer match, causing cryptic verification failures.
**Instead:** Pin the release tag in the script (`TOOLS_RELEASE="v1.0.0"`) and update it explicitly when binaries change.

### Anti-Pattern 2: Downloading Checksums from Same Source as Binaries
**What:** Fetching `checksums.sha256` from the same GitHub Release and verifying against that.
**Why bad:** If an attacker compromises the release, they replace both the binary and the checksum file. Self-referential verification provides zero security benefit.
**Instead:** Hardcode checksums in script.sh. The script is the trust root. The checksums.sha256 file in the release is for convenience/transparency, not for script verification.

### Anti-Pattern 3: Monolithic main() with Inline Logic
**What:** Keeping Steps 1-12 as inline blocks in main() rather than extracting to functions.
**Why bad:** 2,470-line functions are unreadable, untestable, and brittle. Local variable scope bleeds across steps. Finding a specific step requires scrolling through thousands of lines.
**Instead:** Extract each step into a named function. main() becomes a sequence of function calls. Each function has clear inputs (parameters) and outputs (side effects on filesystem).

### Anti-Pattern 4: Embedding Build Instructions in the Script
**What:** Keeping the ~80 lines of "REPRODUCIBLE BUILDS" instructions and the ~393 lines of C source code as comments in script.sh.
**Why bad:** After moving to CI builds, the source lives in `tools/` and the build process is in `.github/workflows/build.yml`. Duplicating this in script comments creates two sources of truth that will inevitably drift.
**Instead:** Replace with a brief comment pointing to the repo:
```bash
# Helper binaries are built from source in CI. Source code and build
# instructions: https://github.com/0xc0re/trashcan/tree/main/tools
# CI workflow: https://github.com/0xc0re/trashcan/actions
```

## Build Order and Dependencies

The components have a strict dependency chain that dictates implementation order:

```
Phase 1: Vendor source files into tools/
    |     (shm_launcher.c, xinput_remap.c, xinput1_3.def)
    |     + Commit Neptune VDF as raw file in configs/
    |
    v
Phase 2: Create CI workflow (.github/workflows/build.yml)
    |     Depends on: source files existing in tools/
    |     Output: working build that produces .exe and .dll
    |
    v
Phase 3: Tag + release (validate CI produces correct binaries)
    |     Depends on: working CI workflow
    |     Output: GitHub Release with verified assets
    |     Verification: SHA-256 of CI-built binaries matches
    |                   existing hardcoded checksums in script
    |
    v
Phase 4: Restructure script.sh (extract functions from main)
    |     Can start in parallel with Phases 1-3 on a branch
    |     Does NOT change behavior -- pure refactor
    |
    v
Phase 5: Replace base64 extraction with download logic
    |     Depends on: Phase 3 (release assets exist to download)
    |     Depends on: Phase 4 (clean function structure to add to)
    |     Changes: Step 6 in main -> download_helper_binaries()
    |     Removes: SHM_B64_EOF, XDLL_B64_EOF blocks
    |     Removes: Embedded C source comments
    |     Removes: Reproducible build instructions (replaced with link)
    |
    v
Phase 6: Replace Neptune VDF base64 with inline heredoc
    |     Depends on: Phase 4 (clean structure)
    |     Changes: NEPTUNE_B64_EOF -> raw text heredoc
    |     Removes: ~122 lines of base64
    |
    v
Phase 7: Final verification
          All modes tested (--auto, --gamescope, --controller,
          --steam-deck, --update, --uninstall)
          Binary checksums verified
          Script size significantly reduced
```

**Key insight:** Phase 4 (restructure) can proceed in parallel with Phases 1-3 (CI setup) because the restructure is a pure refactor that does not depend on how binaries are delivered. Phases 5-6 require both tracks to be complete.

## Scalability Considerations

This project is not a web service, so traditional scalability metrics do not apply. Instead, consider maintenance scalability:

| Concern | Current (1 maintainer) | If 2-3 contributors | If community fork |
|---------|----------------------|---------------------|-------------------|
| Binary updates | Update base64 in script, update checksums | Merge conflicts on base64 blobs guaranteed | Fork diverges from upstream blobs immediately |
| Binary updates (after revision) | Tag new version, CI builds, update tag + checksums in script | Clean diff, reviewable PR | Fork can point to their own releases |
| Script changes | Edit 5000-line file, hope nothing breaks | Hard to review changes in monolithic main() | Impossible to cherry-pick individual features |
| Script changes (after revision) | Edit focused function, test in isolation | Clear ownership per function, smaller diffs | Can cherry-pick specific functions |

## Sources

- GitHub Actions runner images (Ubuntu 24.04 pre-installed software): https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md [HIGH confidence -- official repo]
- softprops/action-gh-release v2: https://github.com/softprops/action-gh-release [HIGH confidence -- verified latest v2.5.0]
- Google Shell Style Guide: https://google.github.io/styleguide/shellguide.html [HIGH confidence -- official]
- Existing script.sh analysis: direct inspection of `/home/cstory/src/sleepy/script.sh` [HIGH confidence -- primary source]
- MinGW cross-compilation on GitHub Actions: https://github.com/marketplace/actions/install-mingw, https://github.com/ggml-org/whisper.cpp/issues/168 [MEDIUM confidence -- community examples]
- GitHub Release asset upload patterns: https://trstringer.com/github-actions-create-release-upload-artifacts/ [MEDIUM confidence -- blog, but pattern verified against official docs]
- SHA-256 verification patterns: https://thanoskoutr.com/posts/download-release-github/ [MEDIUM confidence -- community guide, verified against existing script patterns]
