# Feature Landscape

**Domain:** Bash script revision -- runtime asset downloading, CI-built binary distribution, large script restructuring
**Researched:** 2026-03-01
**Confidence:** HIGH (patterns well-established in shell scripting ecosystem; verified against Google Shell Style Guide, idempotent scripting literature, and GitHub release distribution patterns)

## Table Stakes

Features users expect. Missing = script feels broken or untrustworthy.

### Runtime Binary Download

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Download from GitHub Releases via curl** | Standard pattern for distributing CI-built binaries; curl is universally available on Linux | Low | Use direct URL pattern: `https://github.com/OWNER/REPO/releases/download/TAG/FILE`. Avoids GitHub API rate limits and jq dependency. The script already uses curl extensively. |
| **SHA-256 verification of downloaded binaries** | Confirms integrity and authenticity of downloaded files; already present for base64-extracted binaries | Low | Preserve existing `SHM_LAUNCHER_SHA256` and `XINPUT_DLL_SHA256` constants. Use `sha256sum` which is available on all Linux systems. Pattern: `echo "HASH FILE" \| sha256sum -c --status` |
| **Idempotent skip-if-valid** | Avoids re-downloading on every run; existing script already checks sha256 before extraction | Low | Check if binary exists AND checksum matches before downloading. This is the existing pattern -- just change the source from base64 decode to curl fetch. |
| **Clear error message on download failure** | Users need to know what went wrong and what to do about it | Low | Print the URL that failed, suggest checking internet connection, and provide manual download instructions as fallback |
| **HTTPS-only downloads** | Security baseline; GitHub releases are already HTTPS | Low | Already the case -- just enforce it in the URL constants |

### Script Structure

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Functions for all logical blocks** | Every step in `main()` should be a named function. The current `main()` is ~2400 lines with inline heredocs and step logic. Functions make the script scannable and testable. | Med | Google Shell Style Guide: "Put all functions together in the file just below constants. Don't hide executable code between functions." |
| **Function documentation headers** | Each function needs a comment block describing purpose, arguments, return values, and globals used/modified | Low | Google Shell Style Guide standard. The script already does this for some functions (e.g., `parallel_download`, `run_update`). Extend to all. |
| **`set -euo pipefail` retained** | Already present; standard for safe bash. Exit on error, undefined variable, or pipe failure | Low | Already in place at line 108. Keep it. |
| **`main "$@"` as last line** | Already present; Google Shell Style Guide pattern. Ensures entire script is parsed before execution begins | Low | Already in place at line 5069. Keep it. |
| **Consistent naming convention** | Functions use `snake_case` consistently | Low | Already mostly consistent. The existing functions (`step_msg`, `info_msg`, `error_exit`, `parallel_download`, etc.) all follow snake_case. |

### Binary Distribution (CI)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **GitHub Actions workflow for cross-compilation** | Builds shm_launcher.exe and xinput1_3.dll from vendored C source using mingw | Med | Use `x86_64-w64-mingw32-gcc` as already documented in the script. The exact compile commands are embedded in the script comments. |
| **Release assets attached to tagged releases** | Standard GitHub pattern for binary distribution. curl-friendly URLs with stable versioning | Low | Use `gh release create` or GitHub Actions `softprops/action-gh-release` to attach binaries to releases |
| **Vendored C source in repo** | Self-contained builds without cross-repo dependency. Source auditability without embedded comments | Low | Move shm_launcher.c, xinput_remap.c, xinput1_3.def into `tools/` directory |

## Differentiators

Features that improve maintainability and user experience beyond the minimum. Not expected, but valued.

### Download Resilience

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Retry with backoff on download failure** | Transient network errors (DNS hiccup, CDN timeout) are common; a single retry often succeeds | Low | Simple pattern: try once, sleep 2, try again, sleep 5, try a third time. Three attempts max. The existing `parallel_download` function does not retry. |
| **Offline-friendly error with manual download URL** | When curl fails entirely, print the exact URL so the user can download on another machine and place the file manually | Low | Pattern: `error_exit "Download failed. You can manually download from: URL and place it at: PATH"` |
| **Download progress indication for binaries** | The helper binaries are small (~100KB each) so a progress bar is overkill, but a spinner or "downloading..." message avoids silent pauses | Low | Already have `info_msg` calls. Just add one before the curl call. curl's `--progress-bar` is available but unnecessary for small files. |
| **Version tag in download URL** | Pin the download to a specific release tag rather than `latest`, so the script is reproducible. The SHA-256 already pins the content, but the URL should be explicit. | Low | Use `https://github.com/0xc0re/trashcan/releases/download/v1.0.0/shm_launcher.exe` pattern with a `TOOLS_VERSION` constant in the script |

### Script Organization

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Logical function grouping with section headers** | The existing `# ===` section dividers work well. Extend the pattern so every function group has a clear banner comment. Groups: messaging, system checks, wine management, download/install, game patches, steam integration, auth, main flow. | Low | Already partially done. Formalize into consistent sections. |
| **Extract inline Python into dedicated functions** | The script has 3 inline Python heredocs (Steam VDF, auth, BLAKE3 verify). Wrapping each in a bash function with a clear name improves readability even though the Python stays inline. | Med | Pattern: `steam_add_shortcut()` wrapping the Python heredoc. The Python itself stays as a heredoc -- no external files (single-file constraint). |
| **Extract launcher heredoc into its own function** | The launcher script heredoc (~400 lines starting at line ~4115) is the largest single block in `main()`. Moving it to `create_launcher_script()` function makes main() scannable. | Med | The heredoc stays in the function body, but the function has a name and docstring. |
| **Reduce main() to orchestration only** | After extracting steps into functions, `main()` should read like a table of contents: parse args, then call step functions in order | High | This is the core restructuring goal. Main goes from ~2400 lines to ~100 lines of function calls. Every `step_msg "Step N"` block becomes a function. |
| **Neptune VDF as raw file in repo** | Not a binary build artifact -- just a controller config. Storing as a raw file is more readable than base64 and can be diffed in PRs | Low | Commit the VDF file directly. Script reads it with `cat` instead of `base64 -d << 'NEPTUNE_B64_EOF'` |

### CI Quality

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **ShellCheck in CI** | Catches subtle bugs (unquoted variables, useless cats, POSIX portability issues). Industry standard for bash quality. | Low | Add `shellcheck script.sh` step to the GitHub Actions workflow. The script already uses some `# shellcheck disable=` pragmas. |
| **SHA-256 of built binaries printed in CI log** | Allows maintainers to update the script's checksum constants by reading the CI output | Low | Add `sha256sum shm_launcher.exe xinput1_3.dll` after the build step |
| **Reproducible build verification in CI** | Build twice and confirm identical output. Proves the build is deterministic. | Med | mingw builds with the same flags should be deterministic. Add a second build step and compare checksums. |

## Anti-Features

Features to explicitly NOT build. These are tempting but wrong for this project.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Split script.sh into multiple files** | PROJECT.md explicitly constrains to single file. Users `curl` a single script. Multiple files require a tarball or installer-of-installer. | Keep single file. Use functions and section headers for organization. |
| **Dynamic version detection from GitHub API** | Adds `jq` dependency or fragile grep parsing. GitHub API has rate limits (60/hr unauthenticated). The script pins SHA-256 checksums, so the binary version is already implicitly pinned. | Use a hardcoded `TOOLS_VERSION` constant and direct download URL. Update the constant when releasing new tool versions. |
| **Auto-update of helper binaries** | The script's SHA-256 verification means a new binary version requires updating the script anyway. Auto-update without checksum update = security hole. | Pin version + checksum in script constants. Update both together in a PR. |
| **Fallback to base64-embedded binaries** | Defeats the purpose of the revision. Keeping base64 as fallback means maintaining two code paths and the script stays bloated. | Remove all base64 blocks. If download fails, give clear error with manual download URL. |
| **External dependency manager (dpend, etc.)** | Adds complexity for a script that only needs curl (already required) to fetch 2 small files | Use curl directly. The script already has curl as a dependency for game downloads. |
| **Downloading binaries to /tmp** | Temp files are cleaned on reboot. Users who reboot mid-install would re-download. The existing pattern of downloading to `TOOLS_DIR` is correct. | Download directly to `TOOLS_DIR` (or a temp file in the same directory, then mv). Already the pattern. |
| **GPG signature verification** | Overkill for this use case. SHA-256 checksums hardcoded in the script, downloaded over HTTPS from GitHub, are sufficient. GPG adds key management complexity. | SHA-256 checksums in the script + HTTPS download. |
| **Rewrite in Python/Go** | The script works. Users expect a bash script. The Wine/Proton ecosystem tooling is shell-native. A rewrite changes the deployment model. | Restructure the bash, don't replace it. Use inline Python only where bash cannot do the job (VDF parsing, BLAKE3, auth). |
| **Add `--offline` flag** | Unnecessary complexity. If the binaries are already downloaded and verified, the script naturally works offline. If they aren't, there's nothing to fall back to. | The idempotent skip-if-valid check handles this naturally. |

## Feature Dependencies

```
Vendor C source into tools/ --> CI workflow can compile them
CI workflow produces binaries --> Binaries available as release assets
Release assets exist         --> Script can download them via curl
SHA-256 constants updated    --> Script can verify downloaded binaries
Base64 blocks removed        --> Script is smaller (~1000+ lines removed)
Embedded C comments removed  --> Script is cleaner (~393 lines removed)

Functions extracted from main() --> main() becomes orchestration
Inline heredocs wrapped in functions --> Each step is independently readable
Section headers formalized    --> Script has clear navigation structure

Neptune VDF committed as file --> base64 decode block removed (~122 lines)
```

Dependency chain for the binary distribution feature:

```
1. Vendor source (tools/)
2. CI workflow (GitHub Actions)
3. First release (gh release create)
4. Update script download URL + SHA-256 constants
5. Remove base64 blocks and embedded source comments
6. Restructure remaining code into functions
```

Steps 1-3 are prerequisites that must happen before step 4-5.
Step 6 can happen in parallel with steps 4-5 but is easier to review as a separate change.

## MVP Recommendation

Prioritize:

1. **Vendor C source + CI workflow + first release** -- This is the foundation. Nothing else can happen without binaries being available to download. (Table stakes: CI binary distribution)
2. **Script downloads binaries from GitHub Releases with SHA-256 verification** -- Replace the base64 extraction with curl download. Preserve idempotent skip-if-valid check. (Table stakes: runtime download)
3. **Remove all base64 heredoc blocks and embedded source comments** -- The payoff: ~1500 lines removed from the script. (Table stakes: cleanup)
4. **Neptune VDF as raw file** -- Quick win: commit the file, replace base64 decode with cat. ~122 lines removed. (Table stakes: cleanup)
5. **Extract main() steps into named functions** -- Core restructuring. Each `step_msg "Step N"` block becomes a function. main() becomes a table of contents. (Differentiator: organization)

Defer:

- **ShellCheck in CI**: Valuable but not blocking. Can be added anytime.
- **Retry with backoff**: The helper binaries are tiny (~100KB). Retry is nice-to-have.
- **Reproducible build verification**: Useful for trust but not blocking the revision.
- **Reduce main() to ~100 lines**: This is the aspirational end state. Getting each step into a function is the critical move; further refactoring of argument parsing and flow control can follow.

## Sources

- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) -- Function organization, main pattern, naming conventions (HIGH confidence)
- [How to write idempotent Bash scripts](https://arslan.io/2019/07/03/how-to-write-idempotent-bash-scripts/) -- Skip-if-exists patterns (MEDIUM confidence, verified against multiple sources)
- [One-liner to download latest GitHub release](https://gist.github.com/steinwaywhw/a4cd19cda655b8249d908261a62687f8) -- GitHub release download patterns (MEDIUM confidence)
- [Bash trap for temp file cleanup](https://www.linuxjournal.com/content/use-bash-trap-statement-cleanup-temporary-files) -- Cleanup patterns (HIGH confidence, well-established)
- [Greg's Wiki BashGuide/Practices](https://mywiki.wooledge.org/BashGuide/Practices) -- General bash best practices (HIGH confidence, canonical reference)
- [Bash Scripting Best Practices 2026](https://oneuptime.com/blog/post/2026-02-13-bash-best-practices/view) -- Current best practices (MEDIUM confidence)
- [GitHub SHA-256 checksum verification gist](https://gist.github.com/onnimonni/b49779ebc96216771a6be3de46449fa1) -- Checksum verification pattern (MEDIUM confidence)
- Existing script analysis: `/home/cstory/src/sleepy/script.sh` (5069 lines, 24 functions, 12-step main flow) -- Direct code inspection (HIGH confidence)
