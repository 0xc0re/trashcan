# Project Research Summary

**Project:** Cluckers Central Script Revision -- CI Binary Builds & Runtime Download
**Domain:** Bash installer script revision with CI/CD cross-compilation pipeline
**Researched:** 2026-03-01
**Confidence:** HIGH

## Executive Summary

This project revises a 5,069-line (~924KB) bash installer script that currently embeds two Windows helper binaries as base64 blobs, a controller config VDF as base64, and ~393 lines of C source code as comments. The revision moves binary compilation to GitHub Actions CI (cross-compiling with mingw-w64), publishes artifacts as GitHub Release assets, and replaces base64 extraction with runtime `curl` downloads verified by hardcoded SHA-256 checksums. The script also undergoes structural refactoring to extract its monolithic 2,470-line `main()` into named functions. All existing user-facing behavior is preserved.

The recommended approach is well-established and high-confidence across all research areas. The stack is simple: a GitHub Actions workflow on a pinned `ubuntu-24.04` runner using `gcc-mingw-w64-x86-64` (GCC 13.2.0) to cross-compile two small C files, with `softprops/action-gh-release@v2` publishing assets to tagged releases. At runtime, the script uses `curl` (already a dependency) with direct tagged-release URLs (no API calls, no rate limits) and `sha256sum` verification (already present). No new runtime dependencies are introduced.

The primary risk is a one-time checksum migration: CI-built binaries will almost certainly have different SHA-256 hashes than the currently embedded base64 blobs due to PE timestamp non-determinism and potential minor compiler version differences. This is a known, solvable problem (pin compiler version, set `SOURCE_DATE_EPOCH=0`, accept new checksums). The secondary risk is the restructuring introducing subtle control flow changes in a language with no type system and treacherous scoping rules. This is mitigated by separating the restructure (pure refactor, no behavior change) from the download logic change (new behavior), and testing all flag combinations.

## Key Findings

### Recommended Stack

The entire stack is battle-tested and requires zero novel technology. Every component is either already used in the script or is a standard GitHub Actions pattern.

**Core technologies:**
- `ubuntu-24.04` (pinned runner): Matches the script's documented build environment; prevents silent breakage when `ubuntu-latest` rolls forward
- `gcc-mingw-w64-x86-64` via apt (GCC 13.2.0): Exact compiler version documented in the script's reproducible build instructions; byte-compatible output
- `softprops/action-gh-release@v2`: The de facto standard for GitHub release creation; replaces archived `actions/upload-release-asset`
- `actions/checkout@v4`: Stable, patched; v6 offers no benefit for this use case
- `curl` with `-fSL --retry 3`: Already a script dependency; direct tagged-release URLs avoid API rate limits
- `sha256sum`: Already a script dependency; existing `verify_sha256()` function reused as-is

**Critical version pinning:** Runner MUST be `ubuntu-24.04` (not `ubuntu-latest`). The compiler version (GCC 13.2.0) should be logged in CI and validated.

### Expected Features

**Must have (table stakes):**
- Download binaries from GitHub Releases via direct tagged URL (no API, no jq)
- SHA-256 verification of downloaded binaries using existing `verify_sha256()`
- Idempotent skip-if-valid: do not re-download if binary exists and checksum matches
- Clear error messages on download failure with manual download URL fallback
- GitHub Actions CI workflow for cross-compilation on tag push
- Release assets attached to semantic version tags (`v1.0.0`)
- Vendored C source in `tools/` directory
- All base64 heredoc blocks removed (SHM_B64_EOF, XDLL_B64_EOF, NEPTUNE_B64_EOF)
- Embedded C source comments removed (~393 lines)
- Functions extracted from `main()` so it reads as an orchestration table of contents

**Should have (differentiators):**
- Retry with backoff on download failure (3 attempts, 5-second delay)
- Logical function grouping with section headers (15 sections)
- ShellCheck in CI
- Neptune VDF as inline raw heredoc (replacing base64 decode)
- SHA-256 of built binaries printed in CI log for easy constant updates
- Offline-friendly error with actionable manual download instructions

**Defer (v2+):**
- Reproducible build verification in CI (build twice, compare)
- `--tools-path` override flag for pre-staged binaries
- Makefile in `tools/` for local builds

### Architecture Approach

The system is a linear pipeline across two execution contexts: CI builds from source on tag push, publishes to GitHub Releases, and the script downloads at runtime with checksum verification. The architecture has five components: vendored C source (`tools/`), CI workflow (`.github/workflows/build.yml`), GitHub Release assets (the distribution point), optional raw config files (`configs/`), and the restructured `script.sh`. The script restructure targets 15 logical sections with `main()` reduced from ~2,470 lines to ~150-200 lines of orchestration calls.

**Major components:**
1. **CI Workflow** (`.github/workflows/build.yml`) -- Cross-compiles C source to Windows PE binaries on tag push, uploads to GitHub Releases
2. **GitHub Release Assets** -- Versioned binary distribution via deterministic URLs; script pins a specific tag
3. **script.sh (restructured)** -- 15 logical sections; new `download_helper_binaries()` function replaces ~550-line Step 6; all `main()` steps extracted to named functions

### Critical Pitfalls

1. **Checksum mismatch between CI-built and embedded binaries** -- CI will produce different hashes than current base64 blobs. Pin `ubuntu-24.04`, set `SOURCE_DATE_EPOCH=0`, accept new checksums as a one-time migration, and update constants in the script after first CI build.
2. **curl downloads HTML error page instead of binary** -- Always use `curl -fSL` (the `-f` flag is essential). Without it, curl saves a 404/rate-limit HTML page and exits 0. The existing script uses `-f` consistently; preserve this.
3. **Breaking skip-if-verified optimization** -- The current script skips extraction if the binary exists and checksum matches. This MUST be preserved in the download path, or every script run requires internet access.
4. **Restructuring silently changes control flow** -- Bash variable scoping is treacherous (`local` vars leak to callees, subshells lose state). Separate "move code" from "change behavior" into different phases. Test all flag combinations.
5. **Forgetting to remove all base64 blocks** -- Verify with `grep -c 'B64_EOF' script.sh` returning 0, and script size dropping from ~924KB to ~100-150KB.

## Implications for Roadmap

Based on research, the project has a strict dependency chain that dictates phase ordering. The CI pipeline must exist before download logic can be written, and the restructure should be separated from behavior changes.

### Phase 1: Vendor Source and Repository Setup
**Rationale:** Everything else depends on having source files in the repo and the first release published. This is the foundation.
**Delivers:** `tools/` directory with C source files, `configs/` directory with Neptune VDF, `.github/workflows/build.yml` that compiles and publishes on tag push, first tagged release (`v1.0.0`) with verified assets.
**Addresses:** Table stakes -- CI workflow, release assets, vendored source
**Avoids:** Pitfall 1 (checksum mismatch -- pin compiler, set SOURCE_DATE_EPOCH=0, validate output), Pitfall 6 (compiler flag mismatch -- copy exact flags from script), Pitfall 10 (runner drift -- pin ubuntu-24.04)

### Phase 2: Script Download Logic
**Rationale:** With release assets available, the script can be updated to download binaries instead of extracting base64. This is the core behavior change and must be done before structural cleanup to avoid conflating behavior changes with refactoring.
**Delivers:** New `download_helper_binaries()` function using `curl` + `sha256sum`, updated checksum constants, removal of all three base64 heredoc blocks, removal of embedded C source comments and reproducible build instructions (replaced with repo links). Neptune VDF converted from base64 to inline raw heredoc.
**Uses:** `curl -fSL --retry 3 --retry-delay 5`, direct tagged-release URLs, existing `verify_sha256()` function
**Avoids:** Pitfall 2 (HTML error page -- use `-f` flag), Pitfall 3 (skip-if-verified -- preserve existing check pattern), Pitfall 5 (version mismatch -- hardcode tag constant), Pitfall 9 (offline users -- actionable error message), Pitfall 11 (leftover base64 -- grep verification), Pitfall 12 (parallel_download misuse -- use simple curl for tiny files)

### Phase 3: Script Restructure
**Rationale:** With behavior changes complete and tested, restructure the script into clean functions. Separating this from Phase 2 ensures that any regression is attributable to the refactor, not the download logic.
**Delivers:** 15 logical sections with function groupings; `main()` reduced to ~150-200 lines of orchestration; every `step_msg "Step N"` block extracted to a named function; consistent documentation headers.
**Avoids:** Pitfall 4 (silent control flow changes -- shellcheck, bash -x trace comparison, all-flags test matrix), Pitfall 13 (dangling references -- grep for removed markers)

### Phase 4: CI Quality and Verification
**Rationale:** With everything functional, add quality gates: ShellCheck in CI, reproducible build verification, comprehensive testing.
**Delivers:** ShellCheck CI step, final verification across all flag combinations (--auto, --gamescope, --controller, --steam-deck, --update, --uninstall), script size verification (<150KB), documentation updates.
**Addresses:** Differentiators -- ShellCheck, CI checksums in logs

### Phase Ordering Rationale

- **Phase 1 before Phase 2:** Cannot write download logic without release assets to download from. The CI pipeline must produce verified binaries with known checksums first.
- **Phase 2 before Phase 3:** Behavior changes (download vs. base64) must be isolated from structural changes (refactoring). This makes regressions attributable and rollback simple.
- **Phase 3 after Phase 2:** The restructure is a pure refactor with no behavior change. It benefits from the base64 blocks already being removed (less code to move around, cleaner diffs).
- **Phase 4 last:** Quality gates and verification are meaningful only after the core changes are in place. ShellCheck is most valuable when run against the final structure.
- **Phases 1-2 could be done as a single phase** if the team is comfortable. The dependency is strict (release must exist before download code), but the work can happen in one PR with CI setup merged first.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1:** May need research on `SOURCE_DATE_EPOCH` behavior with mingw-w64 specifically and PE timestamp zeroing. The general patterns are documented, but the exact mingw-w64 linker flags for deterministic output may need experimentation.
- **Phase 2:** Likely needs research if the Neptune VDF base64 block contains binary content that cannot be stored as a plain-text heredoc. (Research suggests it IS plain text, but should be verified by decoding.)

Phases with standard patterns (skip research-phase):
- **Phase 3:** Well-documented bash restructuring patterns. Google Shell Style Guide provides the blueprint. No novel decisions.
- **Phase 4:** Standard CI quality tooling. ShellCheck integration is extensively documented.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Every technology is already in use or is a de facto standard. Sources are official docs and verified package repositories. No novel stack choices. |
| Features | HIGH | Feature list derives directly from PROJECT.md requirements plus well-established bash scripting patterns. Verified against Google Shell Style Guide and existing script analysis. |
| Architecture | HIGH | Linear pipeline architecture with clear component boundaries. Patterns verified against GitHub Actions docs, softprops action, and existing script structure. |
| Pitfalls | HIGH | Pitfalls are concrete and domain-specific, not generic. PE timestamp non-determinism, curl error page behavior, and bash scoping issues are well-documented failure modes with known mitigations. |

**Overall confidence:** HIGH

### Gaps to Address

- **Exact checksum outcome:** Until the first CI build runs, the exact SHA-256 values of CI-produced binaries are unknown. The checksums in the script WILL change. This is expected and documented, but requires a manual update step after Phase 1.
- **Neptune VDF content verification:** Should be decoded from the existing base64 block and confirmed to be plain text before committing as a raw file or heredoc. If it contains binary content, the approach changes.
- **PE timestamp determinism:** Setting `SOURCE_DATE_EPOCH=0` should work for the COFF timestamp, but the specific mingw-w64 linker's behavior should be verified in the first CI run. If non-deterministic output persists, the `-Wl,--no-insert-timestamp` flag or post-processing may be needed.
- **Test coverage:** No automated test framework exists for the script. Phase 3 (restructure) relies on manual testing of all flag combinations. Consider whether ShellSpec or BATS could provide a safety net, but this is explicitly deferred as a v2 concern.

## Sources

### Primary (HIGH confidence)
- [GitHub Actions Ubuntu 24.04 Runner Image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md) -- runner contents, GCC versions
- [softprops/action-gh-release@v2](https://github.com/softprops/action-gh-release) -- release creation action (v2.5.0, Dec 2024)
- [actions/checkout@v4](https://github.com/actions/checkout/releases) -- v4.3.1 (Nov 2024)
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) -- function organization, main pattern, naming
- [GitHub Docs: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) -- URL patterns
- [curl retry documentation](https://everything.curl.dev/usingcurl/downloads/retry.html) -- retry flags
- [GitHub REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) -- 60 req/hr unauthenticated
- Existing script analysis: `script.sh` (5069 lines, 924KB) -- primary source for all patterns

### Secondary (MEDIUM confidence)
- [Deterministic Builds with C/C++ (Conan Blog)](https://blog.conan.io/2019/09/02/Deterministic-builds-with-C-C++.html) -- PE timestamp non-determinism, SOURCE_DATE_EPOCH
- [Tor Project: Deterministic Builds](https://blog.torproject.org/deterministic-builds-part-two-technical-details/) -- PE header patching
- [MinGW cross-compilation on GitHub Actions](https://github.com/marketplace/actions/install-mingw) -- community examples
- [Download from GitHub releases guide](https://thanoskoutr.com/posts/download-release-github/) -- curl download and checksum patterns
- [Greg's Wiki BashGuide/Practices](https://mywiki.wooledge.org/BashGuide/Practices) -- bash best practices

---
*Research completed: 2026-03-01*
*Ready for roadmap: yes*
