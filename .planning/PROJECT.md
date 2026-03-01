# Cluckers Central Script Revision

## What This Is

A revision of the Cluckers Central Linux setup script (`script.sh`) — a ~5,000-line bash installer that sets up Wine, authenticates, downloads, and launches a Windows game on Linux. The revision removes embedded binaries, builds them from auditable source in CI, and restructures the script for clarity.

## Core Value

The script works identically for end users, but all binaries are built from source in CI — no opaque embedded blobs — and the codebase is significantly simpler to maintain.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Vendor C source files (shm_launcher.c, xinput_remap.c, xinput1_3.def) into a `tools/` directory in the trashcan repo
- [ ] GitHub Actions workflow that cross-compiles shm_launcher.exe and xinput1_3.dll from vendored source using mingw
- [ ] Publish shm_launcher.exe and xinput1_3.dll as release assets on 0xc0re/trashcan
- [ ] Commit Neptune controller VDF as a raw file in the repo (not embedded base64)
- [ ] Script downloads shm_launcher.exe and xinput1_3.dll from GitHub releases at runtime via curl
- [ ] SHA-256 verification of downloaded binaries (preserve existing checksums)
- [ ] Remove all base64 heredoc blocks (SHM_B64_EOF, XDLL_B64_EOF, NEPTUNE_B64_EOF)
- [ ] Remove embedded C source code comments (~393 lines of shm_launcher.c, xinput_remap.c, xinput1_3.def)
- [ ] Remove reproducible build instructions that reference embedded content (link to repo instead)
- [ ] Restructure script.sh into cleaner, well-organized functions
- [ ] All existing features preserved (Gamescope, controller, Steam Deck, update, uninstall, etc.)

### Out of Scope

- Feature removal — all current features stay
- Splitting into multiple script files — stays as a single script.sh
- Renaming script.sh
- Changes to game logic, authentication, or update mechanics

## Context

- The script is the sole file in the `0xc0re/trashcan` repo (924KB, 5069 lines)
- Two Windows helper binaries are currently embedded as base64:
  - `shm_launcher.exe` — creates named Windows shared memory for game bootstrap
  - `xinput1_3.dll` — remaps controller input for Wine/Proton
- A Steam Deck controller layout (Neptune VDF) is also embedded as base64 (~122 lines)
- ~393 lines of C source code are embedded as comments for auditability
- The `0xc0re/cluckers` repo has the upstream source for shm_launcher.c at `tools/shm_launcher.c`
- The cluckers repo has releases (v1.2.0) with AppImage/tar.gz but not standalone helper binaries
- The script already verifies binaries with SHA-256 checksums after extraction

## Constraints

- **Single file**: script.sh remains a single bash script — no splitting
- **Feature parity**: every mode (--auto, --gamescope, --controller, --steam-deck, --update, --uninstall) must work identically
- **Build transparency**: CI builds from source, users can audit the build pipeline
- **Offline graceful**: if curl fails to download binaries, script should give a clear error with fallback instructions
- **Cross-compile**: CI uses x86_64-w64-mingw32-gcc (same toolchain documented in current script)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Vendor C source into trashcan repo | Self-contained builds, no cross-repo dependency | — Pending |
| GitHub Releases for binary distribution | Standard pattern, curl-friendly URLs, versioned | — Pending |
| Neptune VDF as raw file in repo | Not a binary build artifact — just a config file | — Pending |
| Keep script.sh filename | Matches existing repo convention | — Pending |
| Restructure functions (not split files) | Cleaner code without changing deployment model | — Pending |

---
*Last updated: 2026-03-01 after initialization*
