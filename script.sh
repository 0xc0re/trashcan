#!/usr/bin/env bash
# ==============================================================================
#  Cluckers Central — Linux Setup Script
#
#  Installs Wine, Windows libraries, and the game. Handles authentication
#  directly via the Project Crown gateway API (the server that manages your
#  account and game content — no Windows launcher needed).
#  Optionally configures Steam integration and Gamescope.
#
#  USAGE
#    chmod +x script.sh          # make executable (first time only)
#    ./script.sh                 # interactive install (keyboard/mouse)
#    ./script.sh --auto          # skip all prompts, use defaults
#    ./script.sh --verbose       # show full Wine debug output
#    ./script.sh --gamescope              # opt-in: enable Gamescope compositor (-g)
#                                                 # Gamescope is a specialized window manager
#                                                 # that provides better performance and
#                                                 # features like upscaling and HDR.
#    ./script.sh --gamescope-with-controller  # opt-in: Gamescope + controller support (-gc)
#                                                 # Combines --gamescope and --controller in one
#                                                 # flag. Ideal for couch/TV setups where you
#                                                 # want the Gamescope compositor AND a gamepad.
#                                                 # Also triggered when both -g and -c are passed.
#    ./script.sh --steam-deck             # opt-in: apply game patches (Deck)    (-d)
#    ./script.sh --controller             # opt-in: enable controller support   (-c)
#    ./script.sh --wayland-cursor-fix     # opt-in: disable winex11 to fix cursor warping under Proton on Wayland-only desktops (e.g., COSMIC)
#    ./script.sh --update                 # check for game update       (-u)
#    ./script.sh --uninstall              # remove everything
#    ./script.sh --help                   # show this help message      (-h)
#
#  SHORT FLAGS
#    -a  auto    -v  verbose    -g  gamescope    -gc  gamescope-with-controller
#    -d  steam-deck    -c  controller    -u  update    -h  help
#    Passing both -g and -c together is the same as -gc (auto-detected).
#    --uninstall  (full word only, no short alias — removes everything)
#
#  UPDATE  (--update / -u)
#    Checks the update server for a newer game version. Update detection
#    compares the local GameVersion.dat BLAKE3 hash (a unique file identifier)
#    against the server's value. If they differ, the new game zip is downloaded
#    with resume support, verified, and extracted in place. All setup steps
#    (Wine compatibility layer, launcher, etc.) are skipped.
#
#    Combine with -d to also re-apply Deck patches afterward:
#      ./script.sh --update --steam-deck
#
#  VERSION PINNING  (--update only)
#    Pass GAME_VERSION=x.x.x.x to target a specific build instead of latest:
#      GAME_VERSION=0.36.2100.0 ./script.sh --update
#
#    Version pinning allows users to lock the game to a specific version for
#    stability and reproducibility (useful when a newer version breaks mods or
#    known functionality).
#
#    The chosen version is written to ~/.cluckers/game/.pinned_version so
#    subsequent plain `./script.sh --update` runs use the same version
#    automatically — no need to set GAME_VERSION each time.
#
#    To return to auto-update (always latest), delete the pin file:
#      rm ~/.cluckers/game/.pinned_version
#
#  STEAM DECK & CONTROLLER USERS
#    Pass --steam-deck / -d or --controller / -c to apply game patches after
#    the game is downloaded. These flags ensure controllers work reliably:
#      • DefaultInput.ini / RealmInput.ini — removes phantom mouse-axis
#        counters to prevent the gamepad switching to keyboard/mouse mode
#        under Wine.
#
#    The --steam-deck / -d flag additionally applies Deck-specific tweaks:
#      • RealmSystemSettings.ini — forced fullscreen at 1280×800
#      • controller_neptune_config.vdf — deploys the custom Steam Deck button
#        layout to your Steam controller config directory (preserves any
#        existing one). VDF is Valve's text-based configuration format.
#      • Gamescope is not used (SteamOS manages its own compositor)
#
#    The --gamescope-with-controller / -gc flag is for desktop Linux users who
#    want BOTH the Gamescope compositor AND controller input support. It is
#    equivalent to passing --gamescope --controller (or -g -c) together and
#    bakes both modes into the generated launcher script. Ideal for couch/TV
#    setups on desktop Linux. Steam Deck users should use --steam-deck instead.
#
#  PIN A SPECIFIC GAME VERSION
#    GAME_VERSION=0.36.9999.0 ./script.sh
#
#  REPRODUCIBLE BINARIES
#    Two small Windows helper binaries are downloaded from GitHub Releases
#    and SHA-256 verified at runtime:
#
#    shm_launcher.exe  — creates a named Windows shared memory region
#                        containing the content bootstrap blob that the game
#                        reads on startup.
#
#    xinput1_3.dll     — remaps controller input so all buttons work correctly
#                        under Wine/Proton.
#
#    Both are built from auditable C source in CI (GitHub Actions) using
#    mingw-w64. Source code, build workflow, and releases:
#      https://github.com/0xc0re/trashcan
#
# ==============================================================================

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  printf "\n\033[0;31m[ERROR]\033[0m Please do not run this script as root or with sudo.\n" >&2
  printf "        System dependencies will automatically request sudo if needed.\n\n" >&2
  exit 1
fi

# ==============================================================================
#  User-configurable variables
#  Edit this section to customise the install without touching anything else.
# ==============================================================================

# Game version to install. Leave as "auto" to always get the latest release.
# To pin a specific version, set it here or override on the command line:
#   GAME_VERSION=0.36.2100.0 ./script.sh
GAME_VERSION="${GAME_VERSION:-auto}"

# Gamescope compositor arguments baked into the launcher at setup time.
#
# Gamescope is a Valve compositor that keeps the mouse cursor locked inside the
# game window natively on Wayland (GNOME, KDE, COSMIC). If
# you want to use it, pass --gamescope / -g when running this script.
#
# Common tweaks:
#   -W <width> -H <height>   — output resolution (default: 1920×1080)
#   -r <hz>                  — output refresh rate cap (default: 240)
#   --adaptive-sync          — enable FreeSync/G-Sync (remove if unsupported)
#   --fullscreen             — true fullscreen (borderless is broken — does not
#                              fill the screen even with a correct resolution set)
#   --hdr-enabled            — enable HDR passthrough (requires HDR display)
#
# Steam Deck users: these args are NOT used when --steam-deck / -d is passed
# because SteamOS manages its own Gamescope session automatically.
# --force-grab-cursor is included because it fixes the mouse bugging out
# (stuck in a corner or invisible) on many Desktop Environments and Distros.
# These args are also used when --gamescope-with-controller / -G is passed,
# which enables Gamescope plus full controller support in a single flag.
GAMESCOPE_ARGS="gamescope --force-grab-cursor -W 1920 -H 1080 -r 240 --adaptive-sync --fullscreen"

# ==============================================================================
#  Constants  (readonly — cannot be changed at runtime)
# ==============================================================================

# Directory containing this script, used for resolving relative paths to
# bundled files such as config/controller_neptune.vdf.
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Root directory for all Cluckers-related data.
readonly CLUCKERS_ROOT="${HOME}/.cluckers"

# Wine prefix: a self-contained fake Windows environment created just for this
# game. Think of it as a tiny, isolated Windows installation that lives inside
# your home folder. It does not affect the rest of your Linux system at all.
# To uninstall the game completely, delete this directory (the --uninstall flag
# does this for you).
# We use the 'pfx' name to match Proton's internal directory structure, which
# improves compatibility with some Proton tools.
readonly WINEPREFIX="${CLUCKERS_ROOT}/pfx"

# Directory where extra Python packages used by this script are installed.
# Packages go here instead of system-wide to avoid needing sudo or affecting
# other Python programs on your system.
readonly CLUCKERS_PYLIBS="${CLUCKERS_ROOT}/pylibs"
export PYTHONPATH="${CLUCKERS_PYLIBS}:${PYTHONPATH:-}"

# XDG Base Directory Specification fallbacks.
# Source: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
_BIN_HOME="${HOME}/.local/bin"

# The launcher script written to ~/.local/bin/ during setup. This is the small
# shell script that sets up Wine and starts the game. You can run it directly
# from a terminal or via the .desktop shortcut in your application menu.
readonly LAUNCHER_SCRIPT="${_BIN_HOME}/cluckers-central.sh"

# The .desktop file makes the game appear as an icon in your application menu
# (GNOME, KDE, etc.) so you can launch it just like a native Linux app.
readonly DESKTOP_FILE="${_DATA_HOME}/applications/cluckers-central.desktop"
readonly ICON_DIR="${_DATA_HOME}/icons"
# Desktop icon: PNG converted from the ICO embedded in the game EXE.
# The ICO is extracted via unzip and its largest frame converted to PNG
# using Pillow. PNG is used because most Linux DEs do not render ICO
# files reliably via absolute path in Icon=. The Steam shortcuts.vdf
# "icon" field uses STEAM_ICO_PATH (the CDN ICO) instead.
readonly ICON_PATH="${ICON_DIR}/cluckers-central.png"  # game icon (PNG for .desktop Icon= field)
readonly ICON_POSTER_PATH="${ICON_DIR}/cluckers-central.jpg"  # portrait poster (600×900), Steam grid only

readonly APP_NAME="Cluckers Central"

# Update-server endpoint that returns version.json with the latest build info.
# The JSON schema is defined in the companion Go server source:
# https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
readonly UPDATER_URL="https://updater.realmhub.io/builds/version.json"

# Directory where game files are downloaded and extracted.
GAME_DIR="${CLUCKERS_ROOT}/game"

# Path to the game executable, relative to GAME_DIR.
# "ShippingPC-RealmGameNoEditor.exe" is the standard name for a shipped (retail)
# Unreal Engine 3 game binary. "NoEditor" simply means the UE3 level-editor
# tools are stripped out — this is normal for all shipped UE3 titles.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/deckconfig.go
GAME_EXE_REL="Realm-Royale/Binaries/Win64/ShippingPC-RealmGameNoEditor.exe"

# Official Steam store AppID for Realm Royale Reforged. Used when creating and
# removing Steam non-Steam-game shortcuts so the correct shortcut is found.
# Verify: https://store.steampowered.com/app/813820/Realm_Royale_Reforged/
readonly REALM_ROYALE_APPID="813820"
readonly STEAM_ASSET_BASE="https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/${REALM_ROYALE_APPID}"

# High-quality art assets fetched from the Steam CDN.
# All URLs and sizes verified directly from the community assets source.
#
# community assets label  → filename                    Steam grid/ slot / use
# ───────────────────────────────────────────────────────────────────────────
# library_capsule      2x → library_600x900_2x.jpg      portrait poster  (suffix: p)
#                                                         600×900; also used as desktop icon
# library_hero         2x → library_hero_2x.jpg          hero background  (suffix: _hero)
#                                                         3840×1240 (2x HiDPI)
# logo                 2x → logo_2x.png                  logo banner      (suffix: _logo)
#                                                         1280×720 with background; NOT transparent
# main_capsule            → capsule_616x353.jpg           wide cover       (suffix: empty)
#                                                         616×353
# header                  → header.jpg                    store header     (suffix: _header)
#                                                         460×215
# community_icon (ico)    → c59e5de...ico                Steam shortcut icon (32×32 ICO)
#                                                         Used as shortcuts.vdf "icon" field —
#                                                         ICO format is natively read by Steam
#                                                         and Linux desktop environments.
# community_icon (jpg)    → 068664cf...jpg               32×32 JPG — too small, not used
#
# logo_position from community assets (written verbatim to localconfig.vdf):
#   pinned_position: BottomLeft
#   width_pct:  36.44186046511628
#   height_pct: 100
readonly STEAM_LOGO_URL="${STEAM_ASSET_BASE}/logo_2x.png?t=1739811771"
readonly STEAM_GRID_URL="${STEAM_ASSET_BASE}/library_600x900_2x.jpg?t=1739811771"
readonly STEAM_HERO_URL="${STEAM_ASSET_BASE}/library_hero_2x.jpg?t=1739811771"
readonly STEAM_WIDE_URL="${STEAM_ASSET_BASE}/capsule_616x353.jpg?t=1739811771"
readonly STEAM_HEADER_URL="${STEAM_ASSET_BASE}/header.jpg?t=1739811771"
# Game icon: the 32×32 ICO from Steam's community assets — the authoritative
# icon Steam itself uses for this game. ICO is natively handled by Steam and
# Linux desktops (XDG icon theme). Used as the shortcuts.vdf "icon" field.
# Hash from community assets: c59e5deabf96d228085fe122772251dfa526b9e2.ico
readonly STEAM_ICO_URL="https://shared.fastly.steamstatic.com/community_assets/images/apps/813820/c59e5deabf96d228085fe122772251dfa526b9e2.ico"
# community_icon jpg: 32×32 thumbnail — too small to use, not downloaded.

readonly STEAM_ASSETS_DIR="${CLUCKERS_ROOT}/assets"
# Asset paths — filenames match their purpose for clarity.
# Sizes verified against community assets source:
#   library_capsule  → library_600x900_2x.jpg  (portrait poster, 600×900; desktop icon)
#   library_hero     → library_hero_2x.jpg      (hero background, 3840×1240)
#   logo             → logo_2x.png              (logo banner 1280×720 with background; grid _logo slot)
#   main_capsule     → capsule_616x353.jpg       (wide cover, 616×353)
#   community_icon   → c59e5de...ico            (32×32 ICO; Steam shortcut icon field)
readonly STEAM_LOGO_PATH="${STEAM_ASSETS_DIR}/logo.png"
readonly STEAM_GRID_PATH="${STEAM_ASSETS_DIR}/grid.jpg"
readonly STEAM_HERO_PATH="${STEAM_ASSETS_DIR}/hero.jpg"
readonly STEAM_WIDE_PATH="${STEAM_ASSETS_DIR}/wide.jpg"
readonly STEAM_HEADER_PATH="${STEAM_ASSETS_DIR}/header.jpg"
readonly STEAM_ICO_PATH="${STEAM_ASSETS_DIR}/icon.ico"

# Directory where the two helper .exe / .dll binaries are stored after setup.
readonly TOOLS_DIR="${HOME}/.local/share/cluckers-central/tools"

# SHA-256 checksums for the two Windows helper binaries downloaded from GitHub
# Releases. SHA-256 is a fingerprint algorithm: if even one byte of a file
# changes, the fingerprint changes completely. We compare the fingerprint after
# downloading to guarantee you are running exactly the code we compiled — not a
# modified or corrupted version.
readonly SHM_LAUNCHER_SHA256="de1490b362ccd84dc0e7196e61abd883f22f1dfd24d2337edfee3fddb104c0b2"
readonly XINPUT_DLL_SHA256="2f7aa905ba178b4f08f026b0092a4ce8e04af44cf6a750ae31bbcaec946611f6"

# SHA-256 fingerprint of the Steam Deck controller layout template
# (config/controller_neptune.vdf). Verified after copying to confirm integrity.
readonly CONTROLLER_LAYOUT_SHA256="779194a12bf6a353e8931b17298d930f60e83126aa1a357dc6597d81dfd61709"

# GitHub Release download URLs for CI-built helper binaries.
# CI-built binaries are downloaded and SHA-256 verified at runtime.
readonly RELEASE_TAG="v0.1.0"
readonly RELEASE_BASE="https://github.com/0xc0re/trashcan/releases/download/${RELEASE_TAG}"
readonly SHM_LAUNCHER_URL="${RELEASE_BASE}/shm_launcher.exe"
readonly XINPUT_DLL_URL="${RELEASE_BASE}/xinput1_3.dll"

export WINEPREFIX

# WINEARCH tells Wine what type of fake Windows environment to create.
# "win64" means a 64-bit Windows prefix. This is required because Realm Royale
# only ships a 64-bit game executable — there is no 32-bit version of the game.
# A "win32" prefix would be unable to run it at all.
# A win64 prefix also keeps 32-bit helper DLLs in a separate folder (syswow64)
# alongside the 64-bit ones in system32, which is needed by the Visual C++
# runtime packages that ship DLLs for both architectures.
# Source: https://wiki.winehq.org/Wine_User%27s_Guide#WINEARCH
export WINEARCH="win64"

# ANSI colour codes.
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ==============================================================================
#  Output helpers
# ==============================================================================

# Prints a bold section-header banner to stdout.
#
# Arguments:
#   $1 - Step description string to display.
#
# Returns:
#   Always 0.
step_msg() {
  printf "\n%b\n%b[STEP]%b %b%b%s%b\n" \
    "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" \
    "${BLUE}" "${NC}" "${BOLD}" "${GREEN}" "$1" "${NC}"
}

# Prints an informational message to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
info_msg() { printf "  %b[INFO]%b  %s\n" "${CYAN}" "${NC}" "$1"; }

# Prints a success message to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
ok_msg() { printf "  %b[ OK ]%b  %s\n" "${GREEN}" "${NC}" "$1"; }

# Prints a non-fatal warning to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
warn_msg() { printf "  %b[WARN]%b  %s\n" "${YELLOW}" "${NC}" "$1"; }

# Prints an error message to stderr and exits with status 1.
#
# Arguments:
#   $1 - Error message string.
#
# Returns:
#   Does not return; exits the process.
error_exit() {
  printf "\n%b[ERROR]%b %s\n\n" "${RED}" "${NC}" "$1" >&2
  exit 1
}

# Prints the script usage documentation extracted from the header comment block.
#
# The header comment spans lines 2-100 of this file. Leading "# " prefixes are
# stripped so the output is plain text, suitable for display in a terminal.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
print_help() {
  sed -n '2,104p' "$0" | sed 's/^# \?//'
}

# Returns 0 if the named command exists on PATH, 1 otherwise.
#
# Arguments:
#   $1 - Command name to look up.
#
# Returns:
#   0 if found, 1 if not found.
command_exists() { command -v "$1" > /dev/null 2>&1; }

# Returns 0 if the named package is installed according to the package manager.
#
# Arguments:
#   $1 - Package manager name.
#   $2 - Package name.
#
# Returns:
#   0 if installed, 1 if not.
is_pkg_installed() {
  local mgr="$1"
  local pkg="$2"
  case "${mgr}" in
    apt)    dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed" ;;
    pacman) pacman -Qq "${pkg}" >/dev/null 2>&1 ;;
    dnf)    rpm -q "${pkg}" >/dev/null 2>&1 ;;
    zypper) zypper se --installed-only "${pkg}" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# ==============================================================================
#  System dependency helpers
# ==============================================================================

# Returns the PATH, LD_LIBRARY_PATH, and WINELOADER required for a Wine binary.
#
# Arguments:
#   $1 - wine_path: Absolute path to the wine or wine64 binary.
#
# Returns:
#   Prints "BIN_DIR|LD_LIB_ADD|LOADER_PATH" to stdout.
get_wine_env_additions() {
  local wine_path="$1"
  [[ -z "${wine_path}" ]] && return 1
  
  if [[ "${wine_path}" != /* ]]; then
    wine_path=$(command -v "${wine_path}" 2>/dev/null || echo "${wine_path}")
  fi
  
  local bin_dir root_dir
  bin_dir=$(readlink -f "$(dirname "${wine_path}")" 2>/dev/null || dirname "${wine_path}")
  root_dir=$(readlink -f "$(dirname "${bin_dir}")" 2>/dev/null || dirname "${bin_dir}")
  
  # If it doesn't look like a standard /bin layout, we can't reliably guess libs.
  if [[ "$(basename "${bin_dir}")" != "bin" ]]; then
    printf '%s||%s' "${bin_dir}" "${wine_path}"
    return 0
  fi
  
  local libs=""
  local ld

  # Search for standard and architecture-specific lib folders.
  local lib_dirs=(
    "lib64" "lib" 
    "lib64/wine" "lib/wine"
    "lib64/wine/x86_64-unix" "lib/wine/i386-unix"
    "lib64/wine/x86_64-windows" "lib/wine/i386-windows"
    "lib/x86_64-linux-gnu" "lib/i386-linux-gnu"
    "lib/x86_64-linux-gnu/wine" "lib/i386-linux-gnu/wine"
  )
  for ld in "${lib_dirs[@]}"; do
    if [[ -d "${root_dir}/${ld}" ]]; then
      libs="${libs}${libs:+:}${root_dir}/${ld}"
    fi
  done
  
  # Proton 'files' layout check
  local is_proton_layout="false"
  if [[ "${bin_dir}" == */files/bin ]]; then
     is_proton_layout="true"
     local parent_root
     parent_root=$(readlink -f "$(dirname "${root_dir}")" 2>/dev/null || dirname "${root_dir}")
     for ld in "${lib_dirs[@]}"; do
       if [[ -d "${parent_root}/${ld}" ]]; then
         libs="${libs}${libs:+:}${parent_root}/${ld}"
       fi
     done
  fi
  
  # Standard system fallbacks — only add if not in a Proton layout to avoid
  # mixing system libs with Proton's bundled runtime.
  if [[ "${is_proton_layout}" == "false" ]]; then
    libs="${libs}${libs:+:}/usr/lib64:/usr/lib:/lib64:/lib:/usr/lib/x86_64-linux-gnu"
  fi
  
  printf "%s|%s|%s" "${bin_dir}" "${libs}" "${wine_path}"
}

# Returns 0 if the local game matches the version info on the server.
# Replicates the version check in:
# https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
#
# BLAKE3 is a cryptographic hash function (a unique file fingerprint).
#
# Arguments:
#   $1 - dat_path_rel: Relative path to GameVersion.dat.
#   $2 - dat_blake3: Expected BLAKE3 hash from the server.
#
# Returns:
#   0 if up to date, 1 otherwise.
is_game_up_to_date() {
  local dat_path_rel="$1"
  local dat_blake3="$2"

  local local_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
  if [[ ! -f "${local_game_exe}" ]]; then
    return 1
  fi

  if [[ -z "${dat_path_rel}" || -z "${dat_blake3}" ]]; then
    ok_msg "Game files found (version info missing; deep integrity check skipped)."
    return 0
  fi

  local local_dat="${GAME_DIR}/${dat_path_rel}"
  if [[ ! -f "${local_dat}" ]]; then
    ok_msg "Game files found but version data is missing — assuming update needed."
    return 1
  fi

  info_msg "Checking local GameVersion.dat (${local_dat})..."
  local local_dat_hash
  local_dat_hash=$(python3 - "${local_dat}" << 'DATBLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    h = b3()
    with open(sys.argv[1], "rb") as f:
        h.update(f.read())
    print(h.hexdigest())
except ImportError:
    print("skip")
DATBLAKE3EOF
  ) || local_dat_hash="skip"

  if [[ "${local_dat_hash}" == "skip" ]]; then
    ok_msg "Game files found, but deep integrity verification was skipped (blake3 missing)."
    return 0
  fi

  if [[ "${local_dat_hash}" == "${dat_blake3}" ]]; then
    ok_msg "Game version verified successfully (BLAKE3 match)."
    return 0
  fi

  warn_msg "Game version mismatch or update available."
  info_msg "Run the script with --update to get the latest version."
  return 1
}

# Installs missing system packages using the distro's package manager.
#
# Checks for the tools this script depends on and installs only those that are
# absent. Supported package managers: apt, pacman, dnf, zypper.
# On apt systems, also ensures wine32:i386, wine64, libwine:i386, and
# fonts-wine are installed, since Wine's 64-bit prefix still needs the 32-bit
# runtime libraries for syswow64 (mixed 32/64-bit DLL support).
#
# Arguments:
#   $1  Package manager name: "apt" | "pacman" | "dnf" | "zypper".
#   $@  Additional package names to check/install beyond the default set.
#
# Returns:
#   0 on success; non-zero if the package manager command fails.
install_sys_deps() {
  local -r pkg_mgr="$1"
  shift
  local to_install=()
  local tool

  local -a tools=(wine winetricks curl wget python3 unzip sha256sum cabextract)

  info_msg "Checking for: ${tools[*]}..."
  for tool in "${tools[@]}" "$@"; do
    if ! command_exists "${tool}"; then
      # If binary doesn't exist, check if the package is missing.
      # Some distros name packages differently than binaries.
      local pkg_name="${tool}"
      [[ "${pkg_mgr}" == "apt" && "${tool}" == "wine" ]] && pkg_name="wine64"
      
      if ! is_pkg_installed "${pkg_mgr}" "${pkg_name}"; then
        to_install+=("${pkg_name}")
      fi
    fi
  done

  # Explicitly check for pip / pip3.
  if ! command_exists pip && ! command_exists pip3; then
    local pip_pkg="python3-pip"
    [[ "${pkg_mgr}" == "pacman" ]] && pip_pkg="python-pip"
    [[ "${pkg_mgr}" == "dnf" ]] && pip_pkg="python3-pip"
    [[ "${pkg_mgr}" == "zypper" ]] && pip_pkg="python3-pip"
    if ! is_pkg_installed "${pkg_mgr}" "${pip_pkg}"; then
      to_install+=("${pip_pkg}")
    fi
  fi

  # Some distros provide wine/winetricks commands via package names that differ
  # from binary names. Ensure apt users still receive the full runtime stack.
  if [[ "${pkg_mgr}" == "apt" ]]; then
    local apt_deps=(wine32:i386 wine64 libwine:i386 fonts-wine)
    for ad in "${apt_deps[@]}"; do
      if ! is_pkg_installed "apt" "${ad}"; then
        # Avoid duplicates
        [[ " ${to_install[*]} " == *" ${ad} "* ]] || to_install+=("${ad}")
      fi
    done
  fi

  # Check for wine-mono/gecko on Arch-based systems.
  if [[ "${pkg_mgr}" == "pacman" ]]; then
    for ap in wine-mono wine-gecko; do
      if ! is_pkg_installed "pacman" "${ap}"; then
        to_install+=("${ap}")
      fi
    done
  fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    # Even if system packages are present, we should still ensure pip modules.
    # We call ensure_python_deps below to handle this.
    ok_msg "All required system tools are already installed."
  else
    info_msg "Missing tools: ${to_install[*]}. Installing..."
    
    # Simple progress bar for the installation process.
    local i
    local total=${#to_install[@]}
    printf "  %b[PROG]%b  Installing system dependencies: [" "${BLUE}" "${NC}"
    for ((i=0; i<40; i++)); do printf "-"; done
    printf "] 0%%\r"

    case "${pkg_mgr}" in
      apt)
        sudo dpkg --add-architecture i386
        # Only update if the cache is older than 1 hour (3600 seconds) to save time.
        local last_update
        last_update=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if (( now - last_update > 3600 )); then
          sudo apt-get update -qq
        fi
        # Use fancy progress bar if supported.
        sudo apt-get install -y -qq -o Dpkg::Progress-Fancy="1" "${to_install[@]}" >/dev/null 2>&1
        ;;
      pacman)
        sudo pacman -Sy --noconfirm -q "${to_install[@]}" >/dev/null 2>&1
        ;;
      dnf)
        sudo dnf install -y -q "${to_install[@]}" >/dev/null 2>&1
        ;;
      zypper)
        sudo zypper install -y "${to_install[@]}" >/dev/null 2>&1
        ;;
    esac

    # Complete the progress bar.
    printf "  %b[ OK ]%b  Installing system dependencies: [" "${GREEN}" "${NC}"
    for ((i=0; i<40; i++)); do printf "#"; done
    printf "] 100%%\n"
    ok_msg "All system tools installed."
  fi

  # Step 1c — Ensure Python modules (Pillow, blake3, vdf).
  ensure_python_deps "${pkg_mgr}"
}

# Ensures essential Python modules are installed via pip.
# Pillow is required for icon extraction, blake3 for update verification,
# and vdf for Steam integration. We use 'python3 -m pip install --target'
# to keep these isolated in our local pylibs directory.
#
# Arguments:
#   $1  Package manager name (optional, for install instructions).
#
# Returns:
#   0 on success; 1 on failure to install missing modules.
ensure_python_deps() {
  local -r pkg_mgr="${1:-}"
  step_msg "Step 1c — Verifying Python dependencies (Pillow, blake3, vdf)..."
  
  if ! command_exists python3; then
    warn_msg "python3 not found — skipping Python dependency check."
    return 0
  fi

  # Prefer 'python3 -m pip' as it is the most reliable way to invoke pip.
  local pip_cmd="python3 -m pip"
  
  # Check if the pip module is actually available to python3.
  if ! python3 -m pip --version >/dev/null 2>&1; then
    info_msg "pip module not found. Attempting to bootstrap via ensurepip..."
    python3 -m ensurepip --user >/dev/null 2>&1 || true
    
    # If ensurepip failed, check for 'pip3' or 'pip' binaries.
    if ! python3 -m pip --version >/dev/null 2>&1; then
      if command_exists pip3; then
        pip_cmd="pip3"
      elif command_exists pip; then
        pip_cmd="pip"
      else
        warn_msg "pip not found. Python modules might be missing."
        case "${pkg_mgr}" in
          apt)    info_msg "To install: sudo apt update && sudo apt install python3-pip" ;;
          pacman) info_msg "To install: sudo pacman -S python-pip" ;;
          dnf)    info_msg "To install: sudo dnf install python3-pip" ;;
          zypper) info_msg "To install: sudo zypper install python3-pip" ;;
          *)      info_msg "Please install the 'pip' package for your Python 3 distribution." ;;
        esac
        return 0
      fi
    fi
  fi

  local -a py_deps=(Pillow blake3 vdf)
  local missing_deps=()

  mkdir -p "${CLUCKERS_PYLIBS}"

  # Add our private pylibs to PYTHONPATH for the check.
  export PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}"

  for dep in "${py_deps[@]}"; do
    if ! python3 -c "import ${dep}" >/dev/null 2>&1; then
      missing_deps+=("${dep}")
    fi
  done

  if [[ ${#missing_deps[@]} -eq 0 ]]; then
    ok_msg "All required Python modules are already present."
    return 0
  fi

  info_msg "Installing missing Python modules: ${missing_deps[*]}..."
  # Use --target to install into our private pylibs directory.
  # This avoids PEP 668 issues and doesn't require sudo.
  if ! ${pip_cmd} install --upgrade --target "${CLUCKERS_PYLIBS}" "${missing_deps[@]}" >/dev/null 2>&1; then
    warn_msg "Failed to install Python modules via pip. Icon extraction or update verification may fail."
    return 1
  fi

  ok_msg "Python modules installed successfully."
}


# Ensures winetricks is recent enough to install the packages the game needs.
#
# winetricks is a helper script that installs Windows libraries (DLLs) into a
# Wine prefix. Like any software, it can become outdated. An old copy may try
# to download a library from a URL that no longer exists, or install a version
# too old to work. This function checks the installed version and updates it
# from the official GitHub source if it is below the minimum required version.
#
# If the update download fails (no internet, GitHub unreachable), the existing
# copy is kept and a warning is printed. The script continues — it never stops
# just because it could not update winetricks.
#
# Official winetricks source:
#   https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
#
# Arguments:
#   None.
#
# Returns:
#   Always 0 (degrades gracefully on failure).
ensure_winetricks_fresh() {
  local wt_path
  wt_path=$(command -v winetricks 2>/dev/null || true)
  if [[ -z "${wt_path}" ]]; then
    warn_msg "winetricks not found on PATH — skipping freshness check."
    return 0
  fi

  # winetricks --version prints a date string like "20230212" or "20240101".
  local wt_ver
  wt_ver=$(winetricks --version 2>/dev/null | head -n1 | grep -oE '[0-9]{8}' | head -n1 || echo "0")

  # Minimum required version: 20240105 (first release with vcrun2019 + dxvk 2.3).
  local min_ver="20240105"

  if [[ "${wt_ver}" -ge "${min_ver}" ]] 2>/dev/null; then
    ok_msg "winetricks ${wt_ver} is up-to-date (≥ ${min_ver})."
    WINETRICKS_BIN="${wt_path}"
    return 0
  fi

  warn_msg "winetricks version '${wt_ver}' is older than ${min_ver} — fetching latest from GitHub."
  warn_msg "(An old winetricks can install wrong/broken DLL versions.)"

  local wt_url="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
  local wt_tmp
  wt_tmp=$(mktemp /tmp/winetricks.XXXXXX)

  if curl ${CURL_SILENT}fSL --max-time 30 "${wt_url}" -o "${wt_tmp}" 2>/dev/null; then
    # Sanity-check: the downloaded file must look like a shell script.
    local first_line
    first_line=$(head -c 64 "${wt_tmp}" 2>/dev/null || true)
    if [[ "${first_line}" != "#!"* ]]; then
      rm -f "${wt_tmp}"
      warn_msg "Downloaded winetricks is not a valid shell script — keeping installed copy."
      WINETRICKS_BIN="${wt_path}"
      return 0
    fi

    chmod +x "${wt_tmp}"
    local new_ver
    new_ver=$(bash "${wt_tmp}" --version 2>/dev/null \
      | head -n1 | grep -oE '[0-9]{8}' | head -n1 || echo "0")
    if [[ "${new_ver}" -ge "${wt_ver}" ]] 2>/dev/null; then
      local install_dir
      if [[ -w "${wt_path}" ]]; then
        install_dir="$(dirname "${wt_path}")"
      else
        install_dir="${HOME}/.local/bin"
        mkdir -p "${install_dir}"
      fi
      if cp "${wt_tmp}" "${install_dir}/winetricks"; then
        rm -f "${wt_tmp}"
        ok_msg "winetricks updated to ${new_ver} at ${install_dir}/winetricks."
        WINETRICKS_BIN="${install_dir}/winetricks"
      else
        rm -f "${wt_tmp}"
        warn_msg "Could not write updated winetricks to ${install_dir} — keeping installed copy."
        WINETRICKS_BIN="${wt_path}"
      fi
    else
      rm -f "${wt_tmp}"
      warn_msg "Downloaded winetricks version (${new_ver}) is not newer — keeping installed copy."
      WINETRICKS_BIN="${wt_path}"
    fi
  else
    rm -f "${wt_tmp}"
    warn_msg "Could not download latest winetricks (no internet or GitHub unreachable)."
    WINETRICKS_BIN="${wt_path}"
  fi
}

# Installs one or more winetricks packages, skipping any already present.
#
# winetricks "verbs" are short package names (like "vcrun2019" or "dxvk") that
# winetricks translates into real Windows library installers. This function
# checks whether each verb is already installed before running winetricks, so
# re-running the setup script does not waste time re-downloading packages that
# are already present in your Wine prefix.
#
# Two checks are used before deciding to install a package:
#
#   1. winetricks.log — winetricks records every successfully installed verb in
#      "${WINEPREFIX}/winetricks.log", one name per line. We search this file
#      with "grep -w" (whole-word match) using the same logic that winetricks
#      itself uses in its winetricks_is_installed() function.
#      Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
#              winetricks_is_installed() ~line 4277
#              winetricks_stats_log_command() ~line 19630
#
#   2. DLL file presence — each package installs a specific Windows DLL file
#      into the Wine prefix. If that DLL already exists, the package is already
#      installed — even if winetricks did not install it (Proton, for example,
#      pre-installs many of these). The DLL names come from each verb's
#      "installed_file1" entry in the winetricks source code.
#      Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
#              w_metadata blocks for vcrun2010, vcrun2012, vcrun2019, dxvk,
#              d3dx11_43; W_SYSTEM64_DLLS assignment ~line 4673
#
# Arguments:
#   $1  Human-readable label shown in progress messages (e.g. "C++ runtimes").
#   $2  Path to the Wine binary to use for this operation.
#   $3  Path to the wineserver binary paired with $2.
#   $4  "true" if running in non-interactive (auto) mode, "false" otherwise.
#   $@  winetricks verb names to install (e.g. "vcrun2010" "vcrun2019").
#
# Returns:
#   0 on success; continues with a warning if individual verbs fail.
install_winetricks_multi() {
  local -r desc="$1"; shift
  local -r maint_wine="$1"; shift
  local -r maint_server="$1"; shift
  local -r is_auto="$1"; shift
  local -a to_install=()
  local pkg

  # Inside your Wine prefix, Windows DLL files are stored in two folders that
  # mirror the layout of a real 64-bit Windows installation:
  #
  #   drive_c/windows/system32   — 64-bit DLLs (called W_SYSTEM64_DLLS in winetricks)
  #   drive_c/windows/syswow64   — 32-bit DLLs (called W_SYSTEM32_DLLS in winetricks)
  #
  # Even though "system32" sounds like it should hold 32-bit files, on 64-bit
  # Windows (and Wine win64 prefixes) it actually holds the 64-bit libraries.
  # This is a historical naming quirk that Microsoft kept for compatibility.
  # The Visual C++ runtime packages install DLLs into both folders, while DXVK
  # only installs 64-bit DLLs into system32.

  # Checks whether the key DLL for a given winetricks verb already exists in
  # the Wine prefix. Returns 0 (success/true) if found, 1 (failure/false) if
  # not found or if the verb is not recognised.
  #
  # This is used as a fast pre-check so we skip re-installing packages that
  # Proton already put into the prefix before winetricks was ever run (Proton
  # bundles many of the same DLLs that winetricks would install separately).
  #
  # DLL names are taken from the installed_file1 field in each verb's w_metadata
  # block in the winetricks source:
  # https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #
  # Arguments:
  #   $1  winetricks verb name (e.g. "vcrun2010", "dxvk").
  #
  # Returns:
  #   0 if the package's key DLL is present; 1 if absent or verb is unknown.
  _verb_dll_present() {
    local v="$1"
    local search_path="${WINEPREFIX}/drive_c/windows"
    case "${v}" in
      vcrun2010)
        find "${search_path}" -maxdepth 2 -iname "msvcr100.dll" 2>/dev/null | grep -q .
        ;;
      vcrun2012)
        find "${search_path}" -maxdepth 2 -iname "msvcr110.dll" 2>/dev/null | grep -q .
        ;;
      vcrun2019)
        # vcruntime140.dll is the canonical installed_file1 for vcrun2019.
        find "${search_path}" -maxdepth 2 -iname "vcruntime140.dll" 2>/dev/null | grep -q .
        ;;
      dxvk)
        # Both d3d11.dll and dxgi.dll must be present.
        find "${search_path}/system32" -maxdepth 1 -iname "d3d11.dll" 2>/dev/null | grep -q . && \
        find "${search_path}/system32" -maxdepth 1 -iname "dxgi.dll" 2>/dev/null | grep -q .
        ;;
      d3dx11_43)
        find "${search_path}" -maxdepth 2 -iname "d3dx11_43.dll" 2>/dev/null | grep -q .
        ;;
      *)
        return 1
        ;;
    esac
  }

  # winetricks writes one successfully installed verb per line to this log file.
  # It is the most reliable source of truth for what winetricks has installed.
  local wt_log="${WINEPREFIX}/winetricks.log"
  for pkg in "$@"; do
    # First, check the winetricks log (most reliable, same logic winetricks uses).
    # We check case-insensitively and match the whole line to be sure.
    # Winetricks typically logs as "load_verb", so we check for both.
    if grep -iqE "^(load_)?${pkg}$" "${wt_log}" 2>/dev/null; then
      ok_msg "${pkg} already installed (winetricks.log) — skipping."
    elif _verb_dll_present "${pkg}"; then
      ok_msg "${pkg} already installed (DLL present in prefix) — skipping."
    else
      to_install+=("${pkg}")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    ok_msg "All ${desc} are already installed."
    return 0
  fi

  info_msg "Installing ${desc}: ${to_install[*]}..."
  info_msg "(This may take several minutes. Please wait...)"

  # Ensure no orphaned wineservers are running before winetricks.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true

  local wt_flags=""
  if [[ "${is_auto}" == "true" && "${VERBOSE_MODE:-false}" != "true" ]]; then
    wt_flags="-q"
  fi

  # Run all missing packages in a single winetricks call for speed. Multiple
  # packages in one call avoids repeatedly starting and stopping Wine.
  #
  # The environment variables below are critical for a fast, clean install:
  #
  # WINEPREFIX=  — tells winetricks to install into our game's Wine prefix
  #   (~/.cluckers/pfx) instead of the default ~/.wine. Without this,
  #   winetricks would install packages into the wrong place entirely.
  #
  # DISPLAY=""   — prevents Wine from opening graphical installer windows.
  #   The Visual C++ installers normally show a progress dialog that causes
  #   Wine to spawn a full display server process inside a background thread.
  #   That process grows by ~7 MB/s with no visible activity in the terminal,
  #   making the install appear to hang. Setting DISPLAY="" prevents this.
  #
  # WINEDLLOVERRIDES="mscoree,mshtml=" — stops Wine from auto-installing Mono
  #   (.NET runtime) and Gecko (Internet Explorer engine) when the prefix is
  #   first touched. Wine tries to download these automatically, but we don't
  #   need them for this game and they add several minutes of download time.
  # Use env to pass variables to winetricks without re-assigning them in the
  # current shell. Inline VAR=value syntax (VAR=x cmd) is rejected by bash
  # when VAR is declared readonly, even though it would only be a temporary
  # assignment for the child process. env sidesteps this restriction entirely.
  #
  # LD_LIBRARY_PATH and PATH are set using get_wine_env_additions() so
  # winetricks can find Wine's internal DLLs (like kernel32.dll) and binaries.
  # These are skipped if using the Proton wrapper (is_proton_maint), as Proton
  # handles its own environment variables.
  #
  # shellcheck disable=SC2086
  local env_adds bin_add lib_add loader_add temp
  if [[ "${is_proton_maint:-false}" == "false" ]]; then
    env_adds=$(get_wine_env_additions "${maint_wine}")
    bin_add="${env_adds%%|*}"; temp="${env_adds#*|}"; 
    lib_add="${temp%%|*}"; loader_add="${env_adds##*|}"
  else
    # In Proton maintenance mode, maint_wine/maint_server are wrappers.
    # bin_add is the wrapper directory. we leave lib_add empty as Proton
    # handles its own libs, and we set loader_add to the ACTUAL wine binary
    # so winetricks doesn't try to use a script as WINELOADER.
    bin_add=$(dirname "${maint_wine}"); 
    lib_add=""; 
    loader_add="${real_wine_path}"
  fi

  # Start winetricks in the background so we can show a progress indicator.
  local wt_out
  wt_out=$(mktemp /tmp/wt_out.XXXXXX)
  
  # Snapshot the current log so we can count NEW installations.
  local log_before
  log_before=$(mktemp /tmp/wt_log_before.XXXXXX)
  mkdir -p "${WINEPREFIX}"
  touch "${WINEPREFIX}/winetricks.log"
  cp "${WINEPREFIX}/winetricks.log" "${log_before}"
  local lines_before
  lines_before=$(wc -l < "${log_before}" 2>/dev/null || echo 0)

  (
    env WINEPREFIX="${WINEPREFIX}" WINE="${maint_wine}" WINESERVER="${maint_server}" \
       PATH="${bin_add}:${PATH}" \
       ${lib_add:+LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"} \
       WINELOADER="${loader_add}" \
       DISPLAY="" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG="-all" \
       "${WINETRICKS_BIN:-winetricks}" ${wt_flags} "${to_install[@]}" > "${wt_out}" 2>&1
  ) &
  local wt_pid=$!
  
  local i=0
  local chars="/-\|"
  local current_verb=""
  local completed=0
  local total=${#to_install[@]}

  while kill -0 "${wt_pid}" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    
    # Calculate progress based on how many new verbs appeared in the log.
    local current_lines
    current_lines=$(wc -l < "${WINEPREFIX}/winetricks.log" 2>/dev/null || echo 0)
    completed=$(( current_lines - lines_before ))
    # Clamp completed to total.
    if (( completed > total )); then completed=${total}; fi
    if (( completed < 0 )); then completed=0; fi
    
    # Guard against division by zero if total is somehow 0.
    local percent=0
    local filled=0
    local empty=30
    if [[ ${total} -gt 0 ]]; then
      percent=$(( completed * 100 / total ))
      filled=$(( completed * 30 / total ))
      empty=$(( 30 - filled ))
    fi

    local bar_str empty_str
    bar_str=$(printf "%${filled}s" "" | tr ' ' '#')
    empty_str=$(printf "%${empty}s" "" | tr ' ' '-')
    
    # Try to find what's currently executing from the output.
    # We use || true to prevent the script from exiting when grep finds no matches
    # (which returns exit code 1), as set -e and pipefail are active.
    current_verb=$(grep "Executing" "${wt_out}" 2>/dev/null | tail -n1 | sed 's/.*load_//; s/ .*//' | cut -c1-15 || true)
    [[ -z "${current_verb}" ]] && current_verb="initialising"

    printf "\r  %b[PROG]%b  [%s%s] %d%% (%d/%d) %-15s [%c]" \
      "${BLUE}" "${NC}" "${bar_str}" "${empty_str}" "${percent}" \
      "${completed}" "${total}" "${current_verb}" "${chars:$i:1}"
    
    sleep 0.5
  done
  set +e
  wait "${wt_pid}"
  local wt_status=$?
  set -e
  printf "\r"
  # Clear the progress line.
  printf "                                                                                \r"

  rm -f "${log_before}"

  if [[ "${wt_status}" -eq 0 ]]; then
    ok_msg "${desc} installed successfully."
  else
    warn_msg "Some components in '${desc}' failed to install — continuing anyway."
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
      cat "${wt_out}"
    fi
  fi
  rm -f "${wt_out}"

  # Wait for wineserver to finish all pending work, then stop it.
  #
  # wineserver is a background process Wine uses to manage its internal state
  # (similar to a Windows kernel process). After winetricks finishes, wineserver
  # keeps running until told to stop. Without "-w" (wait), wineserver lingers in
  # the background consuming ~7 MB/s of memory (visible in htop/btop as a Wine
  # process with high priority). "-w" waits for it to finish gracefully; "-k"
  # then sends a kill signal to any that did not exit on their own.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -w 2>/dev/null || true
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true
}

# ==============================================================================
#  Version resolution
# ==============================================================================

# Fetches game version metadata from the update server.
#
# Sends a request to UPDATER_URL and stores the JSON response in the global
# variable VERSION_INFO_JSON. Other functions call parse_version_field() to
# read specific fields (download URL, checksum, version string, etc.) from it.
#
# Arguments:
#   None.
#
# Returns:
#   0 on success; 1 if the server is unreachable or the response is malformed.
fetch_version_info() {
  info_msg "Querying update server for the latest game version..."

  VERSION_INFO_JSON=$(curl ${CURL_SILENT}f --max-time 15 "${UPDATER_URL}" 2>/dev/null || true)

  if [[ -z "${VERSION_INFO_JSON}" ]]; then
    return 1
  fi

  local check
  if ! check=$(python3 - "${VERSION_INFO_JSON}" << 'EOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    v = d.get("latest_version", "")
    if v:
        print(v)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
EOF
  ); then
    return 1
  fi

  if [[ ! "${check}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
}

# Extracts a single string field from VERSION_INFO_JSON.
#
# Arguments:
#   $1 - JSON key name (e.g. "zip_url").
#
# Returns:
#   Prints the field value to stdout. Prints an empty string if not found.
parse_version_field() {
  local -r field="$1"
  python3 - "${VERSION_INFO_JSON}" << EOF
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("${field}", ""))
except Exception:
    print("")
EOF
}

# ==============================================================================
#  Checksum verification
# ==============================================================================

# Verifies a file's SHA-256 checksum and exits the script on mismatch.
#
# A mismatch means the file is corrupt or has been tampered with. The script
# exits rather than continuing with a bad binary to prevent subtle breakage.
# Skips silently when the expected value is the all-zeros placeholder, which
# signals "checksum not yet known" during development.
#
# Arguments:
#   $1  Path to the file to verify.
#   $2  Expected SHA-256 hex string (64 lowercase hex characters).
#
# Returns:
#   0 if the checksum matches or is the all-zeros placeholder.
#   Does not return on mismatch; exits the process.
verify_sha256() {
  local -r file_path="$1"
  local -r expected="$2"

  if [[ "${expected}" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    # All-zeros is the placeholder — skip rather than fail so the script
    # remains usable when the installer URL changes and the SHA is not yet known.
    warn_msg "Checksum placeholder — skipping SHA-256 verification."
    return 0
  fi

  info_msg "Verifying SHA-256..."
  local actual
  actual=$(sha256sum "${file_path}" | awk '{print $1}')
  if [[ "${actual}" != "${expected}" ]]; then
    error_exit "SHA-256 mismatch for ${file_path}.
  Expected: ${expected}
  Got:      ${actual}
  The file may be corrupt or tampered. Delete it and re-run."
  fi
  ok_msg "Checksum verified."
}

# Downloads a binary from GitHub Releases, verifies its SHA-256 checksum, and
# installs it to the specified destination. Skips the download entirely if the
# file is already present and verified (cache-friendly for repeat runs).
# On failure, prints a clear error with the manual download URL so the user
# can fetch the file themselves.
#
# Arguments:
#   $1  URL to download from.
#   $2  Destination path for the installed file.
#   $3  Expected SHA-256 hex string.
download_binary() {
  local -r url="$1"
  local -r dest="$2"
  local -r expected_sha="$3"
  local -r name="$(basename "$dest")"

  # Skip if already present and verified (DL-04)
  if [[ -f "${dest}" ]] \
      && [[ "$(sha256sum "${dest}" | awk '{print $1}')" == "${expected_sha}" ]]; then
    ok_msg "${name} already installed and verified -- skipping."
    return 0
  fi

  info_msg "Downloading ${name} from GitHub Releases..."
  local partial="${dest}.partial"

  # -f: fail on HTTP errors (DL-06), -C -: resume interrupted downloads (DL-07)
  if ! curl ${CURL_FLAGS}f -C - -o "${partial}" "${url}"; then
    rm -f "${partial}"
    error_exit "Failed to download ${name}.

  You can download it manually:
    ${url}

  Then place it at:
    ${dest}

  The expected SHA-256 checksum is:
    ${expected_sha}"
  fi

  # Verify checksum before installing (DL-03)
  verify_sha256 "${partial}" "${expected_sha}"
  mv "${partial}" "${dest}"
  ok_msg "${name} installed."
}

# ==============================================================================
#  Uninstall
# ==============================================================================

# Removes everything this script created and cleans up Steam configuration.
#
# Deletes the Wine prefix, game files, launcher script, .desktop shortcut,
# icon, tools, and the Steam non-Steam-game shortcut entry. The Steam shortcut
# ID computation mirrors the Go implementation so the correct entry is removed.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
#
# Source (shortcut ID algorithm):
#   https://github.com/0xc0re/cluckers/blob/master/internal/cli/steam_linux.go
run_uninstall() {
  step_msg "Uninstalling Cluckers Central..."

  local cluckers_home="${HOME}/.cluckers"

  if [[ -d "${cluckers_home}" ]]; then
    info_msg "Removing Cluckers profile at ${cluckers_home}..."
    rm -rf "${cluckers_home}"
    ok_msg "Cluckers profile removed."
  fi

  local -a to_remove=(
    "${LAUNCHER_SCRIPT}"
    "${DESKTOP_FILE}"
    "${ICON_PATH}"
    "${ICON_DIR}/cluckers-central.ico"
    "${ICON_POSTER_PATH}"
    "${TOOLS_DIR}/shm_launcher.exe"
    "${TOOLS_DIR}/xinput1_3.dll"
    "${ICON_DIR}/hicolor/32x32/apps/cluckers-central.png"
    "${ICON_DIR}/hicolor/256x256/apps/cluckers-central.png"
  )
  local -a labels=(
    "Launcher script"
    "Desktop shortcut"
    "Icon (PNG)"
    "Icon (ICO)"
    "Icon (portrait poster)"
    "shm_launcher.exe"
    "xinput1_3.dll"
    "Hicolor theme icon (32x32)"
    "Hicolor theme icon (256x256)"
  )

  local i
  for i in "${!to_remove[@]}"; do
    if [[ -f "${to_remove[i]}" ]]; then
      rm -f "${to_remove[i]}"
      ok_msg "${labels[i]} removed."
    fi
  done

  # Step 1b — Uninstall Python modules (Pillow, blake3, vdf) via pip.
  if command_exists python3 && python3 -m pip --version >/dev/null 2>&1; then
    info_msg "Uninstalling Python dependencies via pip..."
    # --break-system-packages is needed on some modern distros (PEP 668) 
    # to allow pip to uninstall packages it installed in ~/.local.
    python3 -m pip uninstall -y Pillow blake3 vdf >/dev/null 2>&1 || \
    python3 -m pip uninstall -y --break-system-packages Pillow blake3 vdf >/dev/null 2>&1 || \
      warn_msg "Could not uninstall Python modules via pip (already removed?)."
    ok_msg "Python dependencies removed."
  fi

  info_msg "Looking for Steam installation to clean up shortcuts..."
  local steam_root=""
  local candidate

  # Validate a Steam directory by checking for canonical Steam marker files.
  # This matches the isSteamDir() logic in cluckers/internal/wine/steamdir.go.
  # Checking only for a userdata/ subdirectory is insufficient because some
  # Steam layouts (Flatpak) have userdata elsewhere relative to the root.
  _is_steam_dir() {
    [[ -f "${1}/steam.sh" ]] \
      || [[ -f "${1}/ubuntu12_32/steamclient.so" ]]
  }

  for candidate in \
    "${HOME}/.local/share/Steam" \
    "${HOME}/.steam/steam" \
    "${HOME}/.steam/root" \
    "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
    "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "${HOME}/snap/steam/common/.local/share/Steam"; do
    # Resolve symlinks so we don't visit the same directory twice.
    local _resolved
    _resolved=$(readlink -f "${candidate}" 2>/dev/null) || continue
    if _is_steam_dir "${_resolved}"; then
      steam_root="${_resolved}"
      break
    fi
  done

  if [[ -z "${steam_root}" ]] || ! command_exists python3; then
    warn_msg "Steam not found or Python unavailable — skipping Steam cleanup."
    printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
    return 0
  fi

  local steam_user=""
  local userdata_dir="${steam_root}/userdata"
  if [[ -d "${userdata_dir}" ]]; then
    # Pick the most-recently-modified userdata subdirectory as the active
    # Steam account. stat -c %Y is more portable than find -printf '%T@'
    # (which is a GNU-only extension unavailable on some systems).
    steam_user=$(
      find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | while IFS= read -r _d; do
            printf '%s %s\n' "$(stat -c '%Y' "${_d}" 2>/dev/null || echo 0)" \
                             "$(basename "${_d}")"
          done \
        | sort -rn \
        | awk 'NR==1 {print $2}'
    )
  fi

  if [[ -z "${steam_user}" ]]; then
    warn_msg "No Steam user found — skipping Steam cleanup."
    printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
    return 0
  fi

  info_msg "Cleaning Steam config for user ${steam_user}..."

  STEAM_ROOT="${steam_root}" \
  USER_CONFIG_DIR="${steam_root}/userdata/${steam_user}/config" \
  LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
  REALM_APPID="${REALM_ROYALE_APPID}" \
  APP_NAME_ENV="${APP_NAME}" \
  python3 - << 'PYEOF'
"""Removes Cluckers Central entries from Steam configuration files."""

import binascii
import os

import vdf  # pip install vdf

STEAM_ROOT      = os.environ["STEAM_ROOT"]
USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER        = os.environ["LAUNCHER_ENV"]
REALM_APPID     = os.environ["REALM_APPID"]
APP_NAME        = os.environ["APP_NAME_ENV"]

_OK   = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam non-Steam shortcut ID for the given exe + name pair.

    Steam computes the shortcut ID from the raw (unquoted) exe path concatenated
    with the app name. The Exe field in shortcuts.vdf is stored quoted, but the
    ID itself is derived from the unquoted path.

    Args:
        exe:  Absolute path to the launcher script or executable (unquoted).
        name: Display name used when the shortcut was added.

    Returns:
        Unsigned 32-bit shortcut ID.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id    = compute_shortcut_id(LAUNCHER, APP_NAME)
shortcut_appid = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)
# Both ID formats written by the installer need to be cleaned up.
long_id    = (unsigned_id << 32) | 0x02000000
grid_appids = [str(unsigned_id), str(long_id)]

# -- shortcuts.vdf ----------------------------------------------------------
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
        sc = shortcuts.get("shortcuts", {})
        keys_to_delete = [
            k for k, v in sc.items()
            if isinstance(v, dict)
            and int(v.get("appid", v.get("AppId", 0))) == shortcut_appid
        ]
        for k in keys_to_delete:
            del sc[k]
        with open(shortcuts_path, "wb") as fh:
            vdf.binary_dump(shortcuts, fh)
        print(f"{_OK} Removed shortcut from Steam.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean shortcuts.vdf: {exc}")

# -- localconfig.vdf --------------------------------------------------------
localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(localconfig_path, encoding="utf-8", errors="replace") as fh:
            lc = vdf.load(fh)
        apps = (
            lc.get("UserLocalConfigStore", {})
              .get("Software", {})
              .get("Valve", {})
              .get("Steam", {})
              .get("apps", {})
        )
        changed = False
        if REALM_APPID in apps and "LaunchOptions" in apps[REALM_APPID]:
            del apps[REALM_APPID]["LaunchOptions"]
            print(f"{_OK} Removed Realm Royale launch options.")
            changed = True
        
        if str(shortcut_appid) in apps:
            del apps[str(shortcut_appid)]
            print(f"{_OK} Removed Cluckers Central localconfig settings (signed).")
            changed = True
        
        unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
        if str(unsigned_id) in apps:
            del apps[str(unsigned_id)]
            print(f"{_OK} Removed Cluckers Central localconfig settings (unsigned).")
            changed = True

        if changed:
            with open(localconfig_path, "w", encoding="utf-8") as fh:
                vdf.dump(lc, fh, pretty=True)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean localconfig.vdf: {exc}")

# -- config.vdf -------------------------------------------------------------
config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(config_path, encoding="utf-8", errors="replace") as fh:
            cfg = vdf.load(fh)
        mapping = (
            cfg.get("InstallConfigStore", {})
               .get("Software", {})
               .get("Valve", {})
               .get("Steam", {})
               .get("CompatToolMapping", {})
        )
        for key in (str(shortcut_appid), REALM_APPID):
            mapping.pop(key, None)
        with open(config_path, "w", encoding="utf-8") as fh:
            vdf.dump(cfg, fh, pretty=True)
        print(f"{_OK} Removed Proton compatibility settings.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean config.vdf: {exc}")

# -- grid/ artwork ----------------------------------------------------------
# Remove all artwork files written by the installer.
# Steam uses two ID formats: modern (long_id) and legacy (unsigned_id).
# We clean both to ensure no orphaned files remain after uninstall.
grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
removed = 0
# All suffix+extension combinations written by the installer.
art_names = [
    "p.jpg", "p.png",          # Vertical poster
    ".jpg",  ".png",            # Horizontal grid / wide cover
    "_hero.jpg", "_hero.png",   # Hero background
    "_logo.png", "_logo.jpg",   # Logo banner
    "_header.jpg", "_header.png",  # Small header
]
for grid_id in grid_appids:
    for name in art_names:
        art = os.path.join(grid_dir, f"{grid_id}{name}")
        if os.path.exists(art):
            os.remove(art)
            removed += 1
if removed:
    print(f"{_OK} Removed custom Steam artwork ({removed} file(s)).")
PYEOF

  printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
}


# ==============================================================================
#  Main install
# ==============================================================================

# Downloads a file using parallel HTTP range requests for maximum speed.
#
# Splits the file into N chunks (one per CPU thread, capped at 8) and downloads
# each chunk concurrently with curl using HTTP Range headers. Recombines the
# chunks into the final file with cat. Falls back to a single-threaded curl
# download with resume support (-C -) if the server does not advertise
# "Accept-Ranges: bytes", which is required for range requests to work.
#
# Arguments:
#   $1  Direct HTTP/HTTPS download URL.
#   $2  Destination file path to write the completed download.
#
# Returns:
#   0 on success; 1 on download failure.
#
# Source (parallel download logic):
#   https://github.com/0xc0re/cluckers/blob/master/internal/game/download.go
parallel_download() {
  local url="$1"
  local dest="$2"
  # Detect available CPU threads dynamically. Cap at 8 to avoid hammering the
  # server; floor at 1 for single-core machines or containers without nproc.
  local threads
  threads=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  # Clamp: minimum 1, maximum 8
  [[ "${threads}" -lt 1 ]] && threads=1
  [[ "${threads}" -gt 8 ]] && threads=8

  # Helper: clean up all chunk and temp files for this download.
  # Called on failure so stale chunks don't corrupt a future resume.
  _cleanup_parts() {
    local i
    for ((i=0; i<threads; i++)); do
      rm -f "${dest}.part${i}" "${dest}.part${i}.tmp"
    done
  }

  # Probe the server: get Content-Length and confirm range-request support.
  # We need both to do a correct parallel split.
  local headers
  headers=$(curl ${CURL_SILENT}IL "$url" 2>/dev/null)
  local size
  size=$(printf '%s' "$headers" \
    | grep -i '^content-length:' | tail -n1 | awk '{print $2}' | tr -d '\r' || true)
  local accept_ranges
  accept_ranges=$(printf '%s' "$headers" \
    | grep -i '^accept-ranges:' | tail -n1 | tr -d '\r' | awk '{print $2}' || true)

  # If the server doesn't support range requests, or we couldn't get the file
  # size, fall back to a single-threaded download with resume support.
  # (-C - tells curl to resume from where a previous partial download stopped.)
  if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ || "${accept_ranges,,}" != "bytes" ]]; then
    info_msg "Server does not support parallel downloads — using single-threaded download."
    local resume_flag=""
    if [[ -f "${dest}.partial" ]]; then
      local partial_size
      partial_size=$(stat -c%s "${dest}.partial" 2>/dev/null || echo 0)
      info_msg "Resuming partial download from ${partial_size} bytes..."
      resume_flag="-C -"
    fi
    # resume_flag is intentionally unquoted: when empty it must not expand
    # to an empty-string argument that would confuse curl's option parser.
    # shellcheck disable=SC2086
    curl ${CURL_FLAGS} --progress-bar ${resume_flag} -o "${dest}.partial" "$url" || return 1
    mv "${dest}.partial" "$dest"
    return 0
  fi

  info_msg "Downloading with ${threads} parallel threads (${size} bytes total)..."

  local chunk_size=$(( size / threads ))
  local pids=()
  local i

  for ((i=0; i<threads; i++)); do
    local start=$(( i * chunk_size ))
    local end=$(( (i == threads - 1) ? size - 1 : (i + 1) * chunk_size - 1 ))
    local part_file="${dest}.part${i}"
    local part_size=0

    if [[ -f "$part_file" ]]; then
      part_size=$(stat -c%s "$part_file" 2>/dev/null || echo 0)
    fi

    local expected_size=$(( end - start + 1 ))

    if [[ $part_size -ge $expected_size ]]; then
      # Chunk already complete — nothing to do.
      if [[ $part_size -gt $expected_size ]]; then
        # Chunk is corrupted (too large) — reset it.
        warn_msg "Chunk ${i} is oversized — resetting."
        rm -f "$part_file"
        part_size=0
      else
        continue
      fi
    fi

    # Remove any stale .tmp file left by a previously interrupted run before
    # starting the curl subprocess, so we don't append to garbage data.
    rm -f "${part_file}.tmp"

    local new_start=$(( start + part_size ))
    # Download the remaining bytes for this chunk into a .tmp file, then
    # append to the .part file. This two-step write ensures the .part file
    # only grows with fully received data, making resume safe.
    (
      curl ${CURL_FLAGS}f -r "${new_start}-${end}" -o "${part_file}.tmp" "$url" && \
      cat "${part_file}.tmp" >> "$part_file" && \
      rm -f "${part_file}.tmp"
    ) &
    pids+=($!)
  done

  if [[ ${#pids[@]} -gt 0 ]]; then
    # Show a live progress bar while chunks download in the background.
    while true; do
      local current_size=0
      for ((i=0; i<threads; i++)); do
        local ps=0 tmps=0
        [[ -f "${dest}.part${i}" ]] \
          && ps=$(stat -c%s "${dest}.part${i}" 2>/dev/null || echo 0)
        [[ -f "${dest}.part${i}.tmp" ]] \
          && tmps=$(stat -c%s "${dest}.part${i}.tmp" 2>/dev/null || echo 0)
        current_size=$(( current_size + ps + tmps ))
      done

      local percent=0
      [[ "${size}" -gt 0 ]] && percent=$(( current_size * 100 / size ))
      local bar_length=40
      local filled=$(( percent * bar_length / 100 ))
      local empty=$(( bar_length - filled ))
      local bar_str empty_str
      bar_str=$(printf "%${filled}s"  | tr ' ' '#')
      empty_str=$(printf "%${empty}s" | tr ' ' '-')
      printf "\r  [INFO]  [%s%s] %d%% (%d / %d MB)   " \
        "${bar_str}" "${empty_str}" "${percent}" \
        "$((current_size / 1048576))" "$((size / 1048576))"

      local all_done=true
      local pid
      for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && { all_done=false; break; }
      done
      $all_done && break
      sleep 1
    done

    # Collect exit codes only after the progress loop exits, so we get the
    # true final status of every subprocess before reporting success or failure.
    local failed=false
    local pid_w
    for pid_w in "${pids[@]}"; do
      wait "$pid_w" || failed=true
    done
    printf "\n"

    if $failed; then
      warn_msg "One or more download chunks failed — cleaning up partial files."
      _cleanup_parts
      return 1
    fi
  fi

  # All chunks complete — concatenate in order into the final destination file.
  rm -f "$dest"
  for ((i=0; i<threads; i++)); do
    cat "${dest}.part${i}" >> "$dest"
    rm -f "${dest}.part${i}"
  done

  return 0
}

# Checks for a newer game version and downloads it if available.
# Skips all setup steps — only updates the game files in GAME_DIR.
# Optionally applies game patches (Steam Deck or Controller) afterward.
# Uses global variables: GAME_DIR, UPDATER_URL, GAME_VERSION.
#
# Update detection: fetches version.json from the update server, reads the
# local GameVersion.dat, computes its BLAKE3 hash, and compares it against
# the server's value. A mismatch means an update is needed.
# BLAKE3 is a cryptographic fingerprinting algorithm (a fast hash function that
# produces a unique file identifier). If even one byte changes, the entire hash
# changes. We use it to verify the downloaded file wasn't corrupted or tampered with.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
#
# Version pinning:
#   Set GAME_VERSION=x.x.x.x before calling to target a specific build.
#   The pin is written to ${GAME_DIR}/.pinned_version so subsequent plain
#   `./script.sh --update` runs remember the chosen version without
#   needing GAME_VERSION set again. Clear the file to return to auto-update.
#   Version pinning allows users to lock the game to a specific version for
#   stability and reproducibility (useful when a newer version breaks mods or
#   known functionality).
#
# Arguments:
#   $1 - steam_deck_flag: "true" | "false"
#   $2 - controller_flag: "true" | "false"
#
# Returns:
#   0 on success; exits with error via error_exit() on failure.
run_update() {
  local -r steam_deck_flag="$1"
  local -r controller_flag="$2"

  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║          Cluckers Central — Game Update              ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n\n" "${GREEN}" "${NC}"

  step_msg "Checking for game update..."

  # Fetch version metadata from the update server.
  # VERSION_INFO_JSON is a local to avoid polluting the caller's scope.
  local VERSION_INFO_JSON=""
  if ! fetch_version_info; then
    error_exit "Could not reach update server. Check your internet connection."
  fi

  local server_version
  local zip_url
  local zip_blake3
  local dat_path_rel
  local dat_blake3
  server_version=$(parse_version_field "latest_version")
  zip_url=$(parse_version_field "zip_url")
  zip_blake3=$(parse_version_field "zip_blake3")
  # gameversion_dat_path is relative to GAME_DIR — e.g.
  # "Realm-Royale/Binaries/GameVersion.dat" (no Win64/ component).
  dat_path_rel=$(parse_version_field "gameversion_dat_path")
  dat_blake3=$(parse_version_field "gameversion_dat_blake3")

  info_msg "Latest version on server: ${server_version}"

  # ---- Version pinning -------------------------------------------------------
  # Version pinning allows users to lock the game to a specific version for
  # stability and reproducibility (useful when a newer version breaks mods or
  # known functionality). Priority order (highest first):
  #   1. GAME_VERSION env var set by the user for this run.
  #   2. .pinned_version file written by a previous pinned --update run.
  #   3. "auto" — use latest from server.
  local pin_file="${GAME_DIR}/.pinned_version"
  local target_version="${GAME_VERSION}"

  if [[ "${target_version}" == "auto" ]] && [[ -f "${pin_file}" ]]; then
    target_version=$(tr -d '[:space:]' < "${pin_file}" 2>/dev/null || echo "auto")
    # Validate the pin file value is a safe dotted-numeric version string.
    # This prevents a tampered/corrupted pin file from injecting arbitrary
    # characters into the download URL constructed below.
    if [[ "${target_version}" != "auto" ]]; then
      if [[ "${target_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        info_msg "Using pinned version from ${pin_file}: ${target_version}"
      else
        warn_msg "Pin file contains invalid version '${target_version}' — ignoring, using latest."
        target_version="auto"
      fi
    fi
  fi

  if [[ "${target_version}" == "auto" ]]; then
    target_version="${server_version}"
    info_msg "Targeting latest version: ${target_version}"
  else
    info_msg "Targeting pinned version: ${target_version}"
    # Build the zip URL for the pinned version (BLAKE3 not available for old
    # builds, so we skip hash verification and rely on SHA-256 of the zip).
    # target_version is already validated as ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$
    # so it is safe to interpolate directly into the URL.
    zip_url="https://updater.realmhub.io/builds/game-${target_version}.zip"
    zip_blake3=""
    dat_blake3=""
    # Write pin file so future plain --update runs use the same version.
    mkdir -p "${GAME_DIR}"
    printf '%s\n' "${target_version}" > "${pin_file}"
    ok_msg "Version pinned to ${target_version} (saved to ${pin_file})."
    info_msg "To return to auto-update, delete ${pin_file} or run:"
    info_msg "  rm ${pin_file}"
  fi

  # ---- Update detection ------------------------------------------------------
  # Read the local GameVersion.dat, compute its BLAKE3 hash, and compare to
  # the server's value. Falls back to "needs update" if absent or unreadable.
  if is_game_up_to_date "${dat_path_rel}" "${dat_blake3}"; then
    ok_msg "Game is already up to date (${target_version})."
    ok_msg "Game version verified successfully."
    return 0
  fi

  # Validate the zip URL before use — reject anything that isn't a plain
  # https:// URL pointing to the expected update host. This prevents a
  # compromised version.json from redirecting downloads to an attacker's server.
  if [[ ! "${zip_url}" =~ ^https://updater\.realmhub\.io/ ]]; then
    error_exit "Update server returned an unexpected download URL: '${zip_url}'
  Only https://updater.realmhub.io/ URLs are accepted. Aborting for safety."
  fi

  info_msg "Update required. Downloading ${target_version}..."
  info_msg "URL: ${zip_url}"

  # ---- Download with resume --------------------------------------------------
  local zip_path="${GAME_DIR}/game.zip"
  mkdir -p "${GAME_DIR}"

  info_msg "Downloading (~5.3 GB — this may take a while)..."
  info_msg "If interrupted, re-run with --update / -u to resume."

  parallel_download "${zip_url}" "${zip_path}" \
    || error_exit "Download failed. Check your internet connection."

  ok_msg "Download complete."

  # ---- BLAKE3 hash verification (file integrity check) ----------------------
  if [[ -n "${zip_blake3}" ]]; then
    info_msg "Verifying BLAKE3 integrity of game zip..."
    # Verify downloaded zip integrity using BLAKE3 hash comparison against server's value.
    local actual_blake3
    actual_blake3=$(python3 - "${zip_path}" << 'ZIPBLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    h = b3()
    with open(sys.argv[1], "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    print(h.hexdigest())
except ImportError:
    print("skip")
ZIPBLAKE3EOF
    ) || actual_blake3="skip"

    if [[ "${actual_blake3}" == "skip" ]]; then
      warn_msg "blake3 module not installed — skipping zip BLAKE3 verification."
      warn_msg "Install with: pip install blake3"
    elif [[ "${actual_blake3}" != "${zip_blake3}" ]]; then
      rm -f "${zip_path}"
      error_exit "BLAKE3 mismatch — zip may be corrupt. Re-run --update to retry.
  Expected: ${zip_blake3}
  Got:      ${actual_blake3}"
    else
      ok_msg "BLAKE3 integrity verified."
    fi
  fi

  # ---- Prepare for extraction ------------------------------------------------
  # If any existing game files are read-only, extraction will fail with
  # "Permission denied" when the tool tries to overwrite them. This matches
  # the fix applied in Cluckers fix-35 (commit cd25d215): before extracting,
  # find all read-only regular files in GAME_DIR and make them user-writable.
  # This is safe because we are about to overwrite them with newer versions.
  if [[ -d "${GAME_DIR}" ]]; then
    info_msg "Ensuring game files are writable before extraction..."
    find "${GAME_DIR}" -type f ! -writable -exec chmod u+w {} + 2>/dev/null || true
  fi

  # ---- Extract in place -------------------------------------------------------
  info_msg "Extracting update (this may take several minutes)..."
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "${zip_path}" -C "${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  elif command -v 7z >/dev/null 2>&1; then
    7z x -y "${zip_path}" -o"${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  else
    UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip -o "${zip_path}" -d "${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  fi
  rm -f "${zip_path}"
  ok_msg "Game updated to ${target_version}."

  # Apply game patches (Deck or controller) if any flags were set.
  # Without this, --update --steam-deck would download the update but skip
  # re-applying input patches, leaving the game unconfigured for the Deck.
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    apply_game_patches "${GAME_DIR}" "${steam_deck_flag}" "${controller_flag}"
  fi
}

# Returns 0 if running on a Steam Deck, 1 otherwise.
# Checks DMI board vendor, /etc/os-release, and the default Deck home directory.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/gui/deck_linux.go
#
# Arguments:
#   None.
#
# Returns:
#   0 if Steam Deck, 1 otherwise.
is_steam_deck() {
  # Primary: DMI board vendor set to "Valve" by SteamOS.
  if [[ -r /sys/devices/virtual/dmi/id/board_vendor ]]; then
    local vendor
    vendor=$(tr -d '[:space:]' < /sys/devices/virtual/dmi/id/board_vendor)
    if [[ "${vendor}" == "Valve" ]]; then
      return 0
    fi
  fi
  # Secondary: /etc/os-release identifies SteamOS.
  if [[ -r /etc/os-release ]] && grep -q "ID=steamos" /etc/os-release; then
    return 0
  fi
  # Tertiary: /home/deck exists AND /etc/os-release contains SteamOS marker.
  # The bare /home/deck check is intentionally combined with an os-release
  # check to avoid false-positives on any machine that happens to have a
  # 'deck' user account (e.g. a developer's workstation).
  if [[ -d /home/deck ]] && [[ -r /etc/os-release ]] \
     && grep -qi "steamos\|valve" /etc/os-release 2>/dev/null; then
    return 0
  fi
  return 1
}

# Applies game patches (display, input, layout) for Steam Deck or generic controllers.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/deckconfig.go
#
# Patches applied:
#   RealmSystemSettings.ini — forces fullscreen at 1280x800 (Deck only).
#   DefaultInput.ini / RealmInput.ini — removes phantom mouse-axis counters
#     (Count bXAxis / Count bYAxis) to prevent the controller from switching
#     to keyboard/mouse mode under Wine. Wine is a compatibility layer that
#     allows Windows games to run on Linux by translating Windows API calls.
#     Under Wine, controller input needs special patches to work correctly.
#   controller_neptune_config.vdf — Steam Deck button layout (best-effort, Deck only).
#     controller_neptune_config.vdf is a Steam Deck controller configuration file
#     (VDF is Valve's text-based configuration format for Steam) that defines
#     custom button mappings for this game.
#
# Arguments:
#   $1 - game_dir: absolute path to the game data directory (GAME_DIR).
#   $2 - steam_deck_flag: "true" | "false"
#   $3 - controller_flag: "true" | "false"
#
# Returns:
#   0 on success; 1 if required config directories not found.
apply_game_patches() {
  local game_dir="$1"
  local -r steam_deck_flag="$2"
  local -r controller_flag="$3"
  local config_dir="${game_dir}/Realm-Royale/RealmGame/Config"
  local engine_config_dir="${game_dir}/Realm-Royale/Engine/Config"

  # Ensure the game's config directories exist before attempting to patch.
  if [[ ! -d "${config_dir}" || ! -d "${engine_config_dir}" ]]; then
    warn_msg "Game configuration directories not found in ${game_dir}"
    warn_msg "  (Run setup again after downloading the game.)"
    return 1
  fi

  local ini

  # List all applicable patches based on preferences
  info_msg "Evaluating applicable patches:"
  [[ "${steam_deck_flag}" == "true" ]] \
    && info_msg "  • [Steam Deck] Force 1280x800 resolution and fullscreen"
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    info_msg "  • [Controller] Force engine-level input to Gamepad"
    info_msg "  • [Controller] Neutralize phantom mouse-axis counters (fixes KB/M switching)"
  fi
  [[ "${steam_deck_flag}" == "true" ]] \
    && info_msg "  • [Steam Deck] Deploy custom button layout template"

  # Remember preference if requested.
  if [[ "${controller_flag}" == "true" ]]; then
    mkdir -p "${game_dir}"
    touch "${game_dir}/.controller_enabled"
  fi


  # -- Display: force fullscreen 1280x800 (Steam Deck only) ------------------
  if [[ "${steam_deck_flag}" == "true" ]]; then
    info_msg "Patch: Forcing 1280x800 fullscreen (Steam Deck)..."
    ini="${config_dir}/RealmSystemSettings.ini"
    if [[ -f "${ini}" ]]; then
      chmod u+w "${ini}"
      python3 - "${ini}" << 'DECK_DISPLAY_EOF'
import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    ("Fullscreen=false",        "Fullscreen=True"),
    ("FullscreenWindowed=false","FullscreenWindowed=True"),
    ("ResX=1920",               "ResX=1280"),
    ("ResY=1080",               "ResY=800"),
]
for old, new in patches:
    txt = txt.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
print("  Patched RealmSystemSettings.ini (1280x800 fullscreen)")
DECK_DISPLAY_EOF
    else
      warn_msg "RealmSystemSettings.ini not found — display patch skipped."
      warn_msg "  (Run setup again after downloading the game.)"
    fi
  fi

  # -- Input: remove phantom mouse-axis counters (Deck or Controller mode) ---
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    # CrossplayInputMethod=Gamepad forces the UE3 engine to treat all input as
    # gamepad, resolving "Unassigned" button labels and preventing the engine
    # from switching back to keyboard/mouse mode during map transitions.
    # Source: https://www.pcgamingwiki.com/wiki/Paladins#Controller_support
    #         (CrossplayInputMethod ini key documented under Controller support)
    info_msg "Patch: Forcing engine-level input to Gamepad (Controller mode)..."
    ini="${config_dir}/RealmGame.ini"
    if [[ -f "${ini}" ]]; then
      chmod u+w "${ini}"
      python3 - "${ini}" << 'ENGINE_OVERRIDE_EOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    ("CrossplayInputMethod=ECIM_Keyboard", "CrossplayInputMethod=ECIM_Gamepad"),
    ("CrossplayInputMethod=ECIM_None", "CrossplayInputMethod=ECIM_Gamepad")
]
changed = False
for old, new in patches:
    if old in txt:
        txt = txt.replace(old, new)
        changed = True

# If neither is found, we might need to add it, but replacing existing is safer
if "CrossplayInputMethod=ECIM_Gamepad" not in txt:
    # Just in case it's missing entirely in [TgGame.TgGameProfile]
    if "[TgGame.TgGameProfile]" in txt:
        txt = txt.replace("[TgGame.TgGameProfile]", "[TgGame.TgGameProfile]\nCrossplayInputMethod=ECIM_Gamepad")
        changed = True

if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    print("  Patched RealmGame.ini (CrossplayInputMethod)")
ENGINE_OVERRIDE_EOF
    fi

    info_msg "Patch: Neutralizing phantom mouse-axis counters (Controller mode)..."
    # "Count bXAxis" / "Count bYAxis" in mouse bindings cause UE3 to switch from
    # gamepad to KB/M mode whenever phantom mouse events arrive under Wine.
    # Removes phantom mouse-axis counters that cause the game to switch from
    # gamepad to KB/M mode under Wine.
    for ini in \
      "${engine_config_dir}/BaseInput.ini" \
      "${config_dir}/DefaultInput.ini" \
      "${config_dir}/RealmInput.ini"; do
      if [[ ! -f "${ini}" ]]; then
        continue
      fi
      chmod u+w "${ini}"
      python3 - "${ini}" << 'DECK_INPUT_EOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    (
        'Bindings=(Name="MouseX",Command="Count bXAxis | Axis aMouseX")',
        'Bindings=(Name="MouseX",Command="Axis aMouseX")',
    ),
    (
        'Bindings=(Name="MouseY",Command="Count bYAxis | Axis aMouseY")',
        'Bindings=(Name="MouseY",Command="Axis aMouseY")',
    ),
]

changed = False
for old, new in patches:
    if old in txt:
        txt = txt.replace(old, new)
        txt = txt.replace("+" + old, "+" + new)
        changed = True

# For DefaultInput.ini, add UE3 -Bindings= removal directives so coalescing
# does not re-add the Count commands from BaseInput.ini.
import os
if os.path.basename(path) == "DefaultInput.ini":
    for old, new in patches:
        remove = "-" + old
        if remove not in txt:
            add_line = "+" + new
            idx = txt.find(add_line)
            if idx > 0:
                txt = txt[:idx] + remove + "\n" + txt[idx:]
                changed = True
    # Ensure bUsingGamepad=True and AllowJoystickInput=True in input sections.
for section in ["[Engine.PlayerInput]", "[TgGame.TgPlayerInput]"]:
    if section not in txt:
        txt += f"\n{section}\nbUsingGamepad=True\nAllowJoystickInput=True\n"
        changed = True
    else:
        # If section exists, ensure keys are set
        lines = txt.splitlines()
        new_lines = []
        in_sect = False
        has_gamepad = False
        has_joystick = False
        for line in lines:
            if line.strip().lower() == section.lower():
                in_sect = True
            elif in_sect and line.strip().startswith("["):
                if not has_gamepad: new_lines.append("bUsingGamepad=True")
                if not has_joystick: new_lines.append("AllowJoystickInput=True")
                in_sect = False

            if in_sect:
                if line.strip().lower().startswith("businggamepad="):
                    line = "bUsingGamepad=True"
                    has_gamepad = True
                    changed = True
                if line.strip().lower().startswith("allowjoystickinput="):
                    line = "AllowJoystickInput=True"
                    has_joystick = True
                    changed = True
            new_lines.append(line)

        if in_sect: # Section was at end of file
            if not has_gamepad: new_lines.append("bUsingGamepad=True")
            if not has_joystick: new_lines.append("AllowJoystickInput=True")
            changed = True
        txt = "\n".join(new_lines)

if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    print("  Patched " + os.path.basename(path))
else:
    print("  " + os.path.basename(path) + " already patched — skipping.")
DECK_INPUT_EOF
    done
  fi

  # Make all INI files writable so the game can save user controller preferences.
  chmod u+w "${config_dir}"/*.ini 2>/dev/null || true

  # -- Controller layout: deploy controller_neptune_config.vdf (Deck only) ----
  if [[ "${steam_deck_flag}" == "true" ]]; then
    info_msg "Patch: Deploying Steam Deck controller layout template..."
    # Best-effort: deploy to every Steam userdata account directory found.
    # Preserves any existing user-customised layout (never overwrites).
    # Deploys the Steam Deck button layout template to Steam's controller config.
    local vdf_src="${SCRIPT_DIR}/config/controller_neptune.vdf"
    if [[ ! -f "${vdf_src}" ]]; then
      warn_msg "Controller layout file not found: ${vdf_src}"
      warn_msg "Skipping Steam Deck controller layout deploy."
      return 0
    fi
    local vdf_tmp
    vdf_tmp=$(mktemp /tmp/cluckers_neptune_XXXXXX --suffix=.vdf) \
      || { warn_msg "mktemp failed — skipping controller layout deploy."; return 0; }
    cp "${vdf_src}" "${vdf_tmp}"
  verify_sha256 "${vdf_tmp}" "${CONTROLLER_LAYOUT_SHA256}"

  python3 - "${vdf_tmp}" << 'DECK_LAYOUT_EOF'
import sys, os, struct

vdf_src = sys.argv[1]
home = os.path.expanduser("~")
userdata = os.path.join(home, ".local", "share", "Steam", "userdata")

if not os.path.isdir(userdata):
    print("  Steam userdata not found — controller layout skipped.")
    sys.exit(0)

with open(vdf_src, "rb") as f:
    layout_data = f.read()

deployed = 0
for uid in os.listdir(userdata):
    shortcuts_path = os.path.join(userdata, uid, "config", "shortcuts.vdf")
    if not os.path.isfile(shortcuts_path):
        continue
    with open(shortcuts_path, "rb") as f:
        data = f.read()
    # Find the Cluckers shortcut's appid in the binary VDF.
    exe_field = b"\x01exe\x00"
    appid_field = b"\x02appid\x00"
    offset = 0
    app_id = None
    while True:
        idx = data.find(exe_field, offset)
        if idx < 0:
            break
        str_start = idx + len(exe_field)
        str_end = data.find(b"\x00", str_start)
        if str_end < 0:
            break
        exe_path = data[str_start:str_end].decode("utf-8", errors="replace").lower()
        if "cluckers" in exe_path:
            region = data[:idx]
            aid_idx = region.rfind(appid_field)
            if aid_idx >= 0:
                val_start = aid_idx + len(appid_field)
                if val_start + 4 <= len(data):
                    app_id = struct.unpack_from("<I", data, val_start)[0]
            break
        offset = str_end + 1
    if app_id is None:
        continue
    deploy_dir = os.path.join(
        userdata, uid, "config", "controller_configs", "apps", str(app_id)
    )
    deploy_path = os.path.join(deploy_dir, "controller_neptune_config.vdf")
    if os.path.exists(deploy_path):
        print(f"  Controller layout already exists for uid {uid} — skipping.")
        continue
    os.makedirs(deploy_dir, exist_ok=True)
    with open(deploy_path, "wb") as f:
        f.write(layout_data)
    print(f"  OK: Deployed controller layout for uid {uid} (appid {app_id}).")
    deployed += 1

if deployed == 0:
    if app_id is None:
        print("  WARN: Cluckers shortcut not found in Steam — add it as a non-Steam game first.")
    else:
        print("  INFO: All found Steam accounts already have the controller layout template.")
DECK_LAYOUT_EOF

    rm -f "${vdf_tmp}"
  fi

  ok_msg "Game patches applied."
}
# find_proton_template <proton_root> <out_var>
# Searches for Proton's default_pfx directory under the given root.
# Sets <out_var> to the path if found, or "" if not found.
#
# Proton stores its prefix template in different locations depending on the
# build (Steam, GE, AUR package, etc.). This function checks all known
# candidates and returns the first match.
#
# Arguments:
#   $1  Path to the Proton installation root.
#   $2  Name of the variable to receive the template path.
#
# Returns:
#   0 if a template was found, 1 otherwise.
find_proton_template() {
  local root="$1"
  local -n _out_template=$2
  _out_template=""
  local _cand
  for _cand in \
    "${root}/dist/share/default_pfx" \
    "${root}/files/share/default_pfx" \
    "${root}/files/default_pfx" \
    "${root}/share/default_pfx" \
    "${root}/default_pfx"; do
    if [[ -d "${_cand}" ]]; then
      _out_template="${_cand}"
      return 0
    fi
  done
  return 1
}
# Finds the best available Wine or Proton-GE binary on this system.
#
# Proton-GE is a community-built version of Proton (Valve's Windows-game
# compatibility layer) with additional patches and newer components than the
# version shipped with Steam. It typically provides better game compatibility
# and performance than the standard system Wine package.
#
# This function searches common install locations for Proton-GE (Steam,
# Lutris, and Bottles runner directories), picks the highest-version copy
# found, and verifies it can actually run before selecting it. Falls back
# to system Wine if no Proton-GE installation is found.
#
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/wine/detect.go
#
# Arguments:
#   $1  Name of the variable to receive the wine binary path.
#   $2  Name of the variable to receive a "true"/"false" is-Proton flag.
#   $3  Name of the variable to receive the tool name (e.g. "Proton-GE-9-5").
#   $4  Name of the variable to receive the wineserver binary path.
#   $5  Name of the variable to receive the proton script path.
#   $6  Name of the variable to receive a "true"/"false" is-SLR flag.
#
# Returns:
#   Always 0. Output is written to the named variables via nameref.
find_wine() {
  local -n _out_path=$1
  local -n _out_is_proton=$2
  local -n _out_tool_name=$3
  local -n _out_server=$4
  local -n _out_proton_script=$5
  local -n _out_is_slr=$6

  _out_path=""
  _out_is_proton="false"
  _out_tool_name="proton"
  _out_proton_script=""
  _out_is_slr="false"

  local search_dirs=(
    "/usr/share/steam/compatibilitytools.d"
    "/opt/proton-cachyos"
    "/opt/proton-cachyos-slr"
    "${HOME}/.steam/root/compatibilitytools.d"
    "${HOME}/.steam/steam/compatibilitytools.d"
    "${HOME}/.local/share/Steam/compatibilitytools.d"
    "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
    "${HOME}/snap/steam/common/.steam/steam/compatibilitytools.d"
    "${HOME}/.var/app/net.davidotek.pupgui2/data/Steam/compatibilitytools.d"
    "${HOME}/.local/share/Steam/steamapps/common/Proton - GE/compatibilitytools.d"
    "${HOME}/.local/share/lutris/runners/wine"
    "${HOME}/.local/share/bottles/runners"
  )

  if [[ -L "${HOME}/.steam/root" ]]; then
    search_dirs+=("$(readlink -f "${HOME}/.steam/root")/compatibilitytools.d")
  fi
  if [[ -L "${HOME}/.steam/steam" ]]; then
    search_dirs+=("$(readlink -f "${HOME}/.steam/steam")/compatibilitytools.d")
  fi

  local newest_proton=""
  local newest_version="00000-00000"
  local newest_script=""
  local newest_is_slr="false"

  local d p base major minor
  for d in "${search_dirs[@]}"; do
    if [[ ! -d "${d}" ]]; then continue; fi

    # 1. Check for common Proton and custom Wine prefixes
    # Use a broad glob to find GE-Proton, proton-cachyos, lutris-ge, etc.
    for p in "${d}"/GE-Proton* "${d}"/proton-cachyos* \
              "${d}"/proton-ge-custom "${d}"/lutris-* "${d}"/wine-ge-* "${d}"/Proton*; do
      local check_exe=""
      if [[ -f "${p}/files/bin/wine64" ]]; then
        check_exe="${p}/files/bin/wine64"
      elif [[ -f "${p}/bin/wine64" ]]; then
        check_exe="${p}/bin/wine64"
      fi

      if [[ -n "${check_exe}" ]] && [[ -x "${check_exe}" ]]; then
        base=$(basename "${p}")

        # Detect the companion 'proton' script. Official Valve Proton and many
        # community builds include this script to handle container initialization
        # (Steam Linux Runtime) and prefix setup.
        local proton_script=""
        local tool_root="${p}"
        if [[ -f "${tool_root}/proton" ]]; then
            proton_script="${tool_root}/proton"
        fi
        
        # Test if the Wine binary can actually run a simple command.
        # SLR builds fail outside Steam Runtime unless wrapped correctly.
        local env_adds bin_add lib_add loader_add
        env_adds=$(get_wine_env_additions "${check_exe}")
        bin_add="${env_adds%%|*}"; temp_adds="${env_adds#*|}"; 
        lib_add="${temp_adds%%|*}"; loader_add="${env_adds##*|}"
        
        local check_pfx
        check_pfx=$(mktemp -d /tmp/cluckers_pfx_check_XXXXXX)
        local can_run="false"
        local current_is_slr="false"

        # If a 'proton' script is present, mark this build as needing the wrapper.
        # This covers all Proton builds — whether they use the Steam Linux Runtime
        # container (SLR/Pressure Vessel) or run standalone. All are treated the
        # same: we use the 'proton run' script instead of calling wine directly.
        # GE-Proton, Proton-GE, proton-cachyos, and upstream Proton all qualify.
        if [[ -f "${proton_script}" ]]; then
          current_is_slr="true"
        fi

        local check_out="/dev/null"
        [[ "${VERBOSE_MODE:-false}" == "true" ]] && check_out="/dev/stderr"

        if env WINEPREFIX="${check_pfx}" \
           PATH="${bin_add}:${PATH}" \
           LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
           WINELOADER="${loader_add}" \
           WINEDLLOVERRIDES="mscoree,mshtml=" \
           DISPLAY="" \
           "${check_exe}" cmd.exe /c exit >"${check_out}" 2>&1; then
          can_run="true"
        elif [[ "${current_is_slr}" == "true" ]]; then
          # The Wine binary failed to run standalone, but a 'proton' script
          # exists. This is normal for container-based Proton builds (those
          # that rely on Steam Linux Runtime / Pressure Vessel). We still mark
          # them as usable because the 'proton run' wrapper handles everything.
          can_run="true"
        fi
        rm -rf "${check_pfx}" 2>/dev/null || true

        if [[ "${can_run}" == "true" ]]; then
          # Try to extract version from folder name or 'version' file.
          # Matches GE-ProtonX-Y, Proton-GE-X-Y, proton-cachyos, Proton 9.0, etc.
          local v_str=""
          if [[ "${base}" =~ ([0-9]+)\.([0-9]+) ]]; then
            # Matches "Proton 9.0", "Proton 8.0"
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            v_str=$(printf "%05d-%05d" "${major}" "${minor}")
          elif [[ "${base}" =~ ([0-9]+)-([0-9]+) ]]; then
            # Matches "GE-Proton9-20", "proton-cachyos-10-1"
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            v_str=$(printf "%05d-%05d" "${major}" "${minor}")
          elif [[ -f "${p}/version" ]]; then
            # Read version from Steam's 'version' file (e.g. "1712345678 proton-9.0-2")
            local v_file_content
            v_file_content=$(head -n1 "${p}/version" 2>/dev/null || true)
            if [[ "${v_file_content}" =~ ([0-9]+)\.([0-9]+) ]]; then
              major="${BASH_REMATCH[1]}"
              minor="${BASH_REMATCH[2]}"
              v_str=$(printf "%05d-%05d" "${major}" "${minor}")
            fi
          fi

          if [[ -n "${v_str}" ]]; then
            if [[ "${v_str}" > "${newest_version}" || -z "${newest_proton}" ]]; then
              newest_version="${v_str}"
              newest_proton="${check_exe}"
              newest_script="${proton_script}"
              newest_is_slr="${current_is_slr}"
            fi
          elif [[ -z "${newest_proton}" ]]; then
            # Fallback for builds without clear versioning.
            newest_proton="${check_exe}"
            newest_script="${proton_script}"
            newest_is_slr="${current_is_slr}"
          fi
        fi
      fi
    done
  done

  if [[ -n "${newest_proton}" ]] && [[ -x "${newest_proton}" ]]; then
    _out_path="${newest_proton}"
    _out_is_proton="true"
    _out_proton_script="${newest_script}"
    _out_is_slr="${newest_is_slr}"

    # Extract tool name for info message.
    local tool_dir
    tool_dir=$(dirname "$(dirname "${newest_proton}")")
    [[ "$(basename "${tool_dir}")" == "bin" || "$(basename "${tool_dir}")" == "files" ]] && tool_dir=$(dirname "${tool_dir}")
    _out_tool_name=$(basename "${tool_dir}")

    # Set the wineserver path associated with this Wine binary
    _out_server="$(dirname "${newest_proton}")/wineserver"
    [[ ! -x "${_out_server}" ]] && _out_server="wineserver"

    info_msg "Detected Proton build: ${_out_tool_name} (uses proton script: ${_out_is_slr})"
    [[ -n "${_out_proton_script}" ]] && info_msg "Proton script: ${_out_proton_script}"
    return 0
  fi

  # Check for system Wine and side-by-side installs
  local wine_candidates=(
    "wine64"
    "wine"
    "/opt/wine-cachyos/bin/wine64"
    "/opt/wine-cachyos/bin/wine"
    "/opt/wine-staging/bin/wine64"
    "/opt/wine-staging/bin/wine"
    "/usr/lib/wine/wine64"
    "/usr/lib/wine/wine"
  )

  local candidate path
  for candidate in "${wine_candidates[@]}"; do
    if [[ "${candidate}" == /* ]]; then
      path="${candidate}"
    else
      path=$(command -v "${candidate}" 2>/dev/null || true)
    fi

    if [[ -n "${path}" ]] && [[ -x "${path}" ]]; then
      # Verification test for system wine
      local env_adds bin_add lib_add loader_add
      env_adds=$(get_wine_env_additions "${path}")
      bin_add="${env_adds%%|*}"; temp_adds="${env_adds#*|}"; 
      lib_add="${temp_adds%%|*}"; loader_add="${env_adds##*|}"
      
      local check_pfx
      check_pfx=$(mktemp -d /tmp/cluckers_pfx_check_XXXXXX)
      if env WINEPREFIX="${check_pfx}" \
         PATH="${bin_add}:${PATH}" \
         LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
         WINELOADER="${loader_add}" \
         WINEDLLOVERRIDES="mscoree,mshtml=" \
         DISPLAY="" \
         "${path}" cmd.exe /c exit >/dev/null 2>&1; then
        rm -rf "${check_pfx}"
        _out_path="${path}"
        _out_tool_name="wine"
        _out_proton_script=""
        _out_is_slr="false"

        # Set the wineserver path associated with this Wine binary
        _out_server="$(dirname "${path}")/wineserver"
        [[ ! -x "${_out_server}" ]] && _out_server="wineserver"
        return 0
      else
        rm -rf "${check_pfx}"
      fi
    fi
  done

  return 1
}

# Parses command-line flags and runs all install steps in order.
#
# Arguments:
#   "$@" - Flags passed to the script.
#
# Returns:
#   0 on success; exits with error via error_exit() on failure.
main() {
  local verbose="false"
  local auto_mode="false"
  local use_gamescope="false"
  local steam_deck="false"
  local controller_mode="false"
  local wayland_cursor_fix="false"
  local resolved_version="${GAME_VERSION}"
  local VERSION_INFO_JSON=""
  local do_update="false"
  local WINETRICKS_BIN="winetricks"
  local GATEWAY_URL="${GATEWAY_URL:-https://gateway-dev.project-crown.com}"
  local CREDS_FILE="${CLUCKERS_ROOT}/credentials.enc"

  # Detect if the game EXE is in the current directory.
  # If found, we use the current directory as GAME_DIR and set relative path
  # to the EXE. This allows running the script from a manual game install.
  if [[ -f "ShippingPC-RealmGameNoEditor.exe" ]]; then
    GAME_DIR="$(pwd)"
    GAME_EXE_REL="ShippingPC-RealmGameNoEditor.exe"
    ok_msg "Found game EXE in current directory: ${GAME_EXE_REL}"
    ok_msg "Using current directory as GAME_DIR: ${GAME_DIR}"
  fi

  # Load saved preferences.
  local controller_pref_file="${GAME_DIR}/.controller_enabled"
  if [[ -f "${controller_pref_file}" ]]; then
    controller_mode="true"
  fi

  # Detected once early — available for Step 4 (DXVK decision) and
  # Step 8 (launcher creation). find_wine sets the variables passed as arguments.
  local _is_proton="false"
  local real_wine_path=""
  local real_wineserver="wineserver"
  local _proton_tool_name="proton"
  local real_proton_script=""
  local _is_slr="false"

  local arg
  for arg in "$@"; do
    case "${arg}" in
      --uninstall)
        printf "\n%b[WARN]%b This will permanently remove Cluckers Central, the Wine prefix,\n" \
          "${YELLOW}" "${NC}"
        printf "        all game files in ~/.cluckers, and Steam shortcuts.\n"
        printf "        This action cannot be undone.\n\n"
        printf "  Type 'yes' to confirm: "
        local _confirm=""
        read -r _confirm
        if [[ "${_confirm}" != "yes" ]]; then
          printf "  Uninstall cancelled.\n\n"
          exit 0
        fi
        run_uninstall; exit 0
        ;;
      --update|-u)       do_update="true" ;;
      --verbose|-v)      verbose="true" ;;
      --auto|-a)         auto_mode="true" ;;
      --gamescope|-g)    use_gamescope="true" ;;
      --no-gamescope)    use_gamescope="false" ;;
      # --gamescope-with-controller / -gc enables the Gamescope compositor AND
      # controller input support together in a single flag. Passing both -g and
      # -c separately has the same effect (detected after the argument loop).
      # This is the recommended mode for couch/TV setups on desktop Linux where
      # you want a cursor-locked fullscreen compositor and a working gamepad.
      # Steam Deck users: use --steam-deck / -d instead. SteamOS manages its
      # own Gamescope session and controller support automatically.
      --gamescope-with-controller|-gc)
        use_gamescope="true"
        controller_mode="true"
        ;;
      --steam-deck|-d)   steam_deck="true"; use_gamescope="false"; controller_mode="true" ;;
      --controller|-c)   controller_mode="true" ;;
      --wayland-cursor-fix) wayland_cursor_fix="true" ;;
      --no-controller)
        controller_mode="false"
        [[ -f "${controller_pref_file}" ]] && rm -f "${controller_pref_file}"
        ;;
      --help|-h)         print_help; exit 0 ;;
      *) warn_msg "Unknown flag ignored: '${arg}' (try --help for usage)" ;;
    esac
  done

  # If the user passed both --gamescope / -g and --controller / -c separately,
  # treat that as equivalent to --gamescope-with-controller / -gc. This means
  # you never have to remember the combined flag — -g -c just works.
  # We only apply this on non-Deck systems; Steam Deck manages its own compositor.
  if [[ "${use_gamescope}" == "true" ]] && [[ "${controller_mode}" == "true" ]] \
     && [[ "${steam_deck}" == "false" ]]; then
    : # Already in gamescope-with-controller mode — nothing extra needed.
  fi

  # Save preference if enabled.
  if [[ "${controller_mode}" == "true" ]]; then
    mkdir -p "${GAME_DIR}"
    touch "${controller_pref_file}"
  fi



  # Show the banner immediately so the user knows the script has started.
  # This must come before find_wine (which probes Wine binaries and can take
  # a few seconds), so there is no silent gap after pressing Enter.
  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║        Cluckers Central — Linux Setup Script         ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n\n" "${GREEN}" "${NC}"

  if [[ "${verbose}" == "true" ]]; then
    export WINEDEBUG=""
    export VERBOSE_MODE="true"
    set -x
    export CURL_FLAGS="-L"
    export CURL_SILENT=""
  else
    export WINEDEBUG="-all"
    export VERBOSE_MODE="false"
    export CURL_FLAGS="-sL"
    export CURL_SILENT="-s"
  fi

  # --------------------------------------------------------------------------
  # Gamescope Configuration
  # --------------------------------------------------------------------------
  if [[ "${use_gamescope}" == "true" ]]; then
    printf "Gamescope is enabled. We use '--force-grab-cursor' because it fixes\n"
    printf "the mouse bugging out (stuck/invisible) on many Linux setups.\n"
    if [[ "${controller_mode}" == "true" ]] && [[ "${steam_deck}" == "false" ]]; then
      printf "Controller support is also enabled (--gamescope-with-controller mode).\n"
      printf "SDL hints and the XInput remap DLL will be deployed for full gamepad support.\n"
    fi
    printf "\n"
    printf "Current flags: %s\n" "${GAMESCOPE_ARGS}"
    printf "Press ENTER to keep these, or type new flags: "
    local _new_gs_args=""
    read -r _new_gs_args
    if [[ -n "${_new_gs_args}" ]]; then
      GAMESCOPE_ARGS="${_new_gs_args}"
      ok_msg "Gamescope flags updated to: ${GAMESCOPE_ARGS}"
    fi
    printf "\n"
  fi

  # Auto-detect Steam Deck. If running on Deck hardware but -d was not passed,
  # warn the user so they know Deck-specific patches are available.
  if [[ "${steam_deck}" == "false" ]] && is_steam_deck; then
    warn_msg "Steam Deck detected (board_vendor=Valve)."
    warn_msg "Re-run with --steam-deck / -d to apply Deck-specific patches:"
    warn_msg "  • Fullscreen 1280x800  • Controller input fix  • Button layout"
    warn_msg "Example: ./script.sh -d"
    warn_msg "(Continuing without Deck patches...)"
    printf "\n"
  fi

  local skip_heavy_steps="false"
  if [[ "${do_update}" == "true" ]]; then
    run_update "${steam_deck}" "${controller_mode}"
    skip_heavy_steps="true"
  fi

  info_msg "Initialising — detecting Wine installation..."
  info_msg "(This may take a few seconds on first run while Wine is located.)"

  # Detect Wine/Proton once upfront — result is used in Step 3 (prefix),
  # Step 4 (DXVK), and Step 8 (launcher). find_wine sets the variables
  # passed as arguments.
  find_wine real_wine_path _is_proton _proton_tool_name real_wineserver real_proton_script _is_slr || true

  # Migrate old 'prefix' directory to 'pfx' if it exists.
  if [[ -d "${CLUCKERS_ROOT}/prefix" ]] && [[ ! -d "${WINEPREFIX}" ]]; then
    info_msg "Migrating Wine prefix from 'prefix' to 'pfx'..."
    mv "${CLUCKERS_ROOT}/prefix" "${WINEPREFIX}"
    ok_msg "Prefix migrated."
  fi

  # Proton tracks the compatdata schema version in ${CLUCKERS_ROOT}/version.
  # If an old system-Wine prefix already exists but this file does not,
  # Proton can fail during its initial prefix conversion (FileExistsError).
  # To avoid that hard failure, we preserve the legacy prefix as a backup and
  # let Proton build a clean pfx on first run.
  if [[ -n "${real_proton_script}" ]] && [[ -x "${real_proton_script}" ]] && \
     [[ -d "${WINEPREFIX}" ]] && [[ ! -f "${CLUCKERS_ROOT}/version" ]]; then
    info_msg "Proton version file missing — backing up existing prefix to avoid FileExistsError."
    info_msg "The prefix will be regenerated from the Proton template on next launch."
    mv "${WINEPREFIX}" "${WINEPREFIX}.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  # Maintenance Wine: used for winetricks and wineboot (prefix setup).
  # Container-based Proton builds (those that use the Steam Linux Runtime /
  # Pressure Vessel) cannot run wine directly without the container. For those,
  # we create thin wrapper scripts that call 'proton run' instead. This covers
  # GE-Proton, upstream Proton, and any other build with a 'proton' script.
  # Standalone Wine builds (system Wine, custom non-proton GE builds) are used
  # directly without any wrapper.
  local maint_wine="wine"
  local maint_server="wineserver"
  local is_proton_maint="false"

  # Use the detected Proton script if available (works for SLR and non-SLR).
  if [[ -n "${real_proton_script}" ]] && [[ -x "${real_proton_script}" ]]; then
    # For maintenance tasks (wineboot, winetricks) we MUST NOT call 'proton run'.
    # The 'proton' script launches the Steam Linux Runtime (pressure-vessel)
    # container, which requires Steam to be running and causes Steam to open
    # unexpectedly during install. This is wrong for setup tasks.
    #
    # Instead we call the Wine binary directly, with the Proton build's own
    # library paths prepended to LD_LIBRARY_PATH. This is the same approach
    # used by Heroic Games Launcher, Lutris, and Bottles for Proton maintenance.
    # The libraries in files/lib64 and files/lib provide the same DLLs/overrides
    # that the container would supply, so wineboot and winetricks work correctly.
    local proton_root
    proton_root="$(dirname "${real_proton_script}")"
    local proton_lib64="${proton_root}/files/lib64"
    local proton_lib="${proton_root}/files/lib"

    # Build the wrapper's LD_LIBRARY_PATH, prepending Proton's bundled libs so
    # that dlopen() picks up Proton's custom DXVK/VKD3D/FAudio/etc. over system
    # versions. This replicates what pressure-vessel does without the container.
    local proton_ld_path="${proton_lib64}:${proton_lib}"

    local wrapper_dir="${CLUCKERS_ROOT}/tools"
    mkdir -p "${wrapper_dir}"
    maint_wine="${wrapper_dir}/wine"

    cat << EOF > "${maint_wine}"
#!/usr/bin/env bash
# Maintenance Wine wrapper: calls Proton's wine64 binary directly, bypassing
# the Steam Linux Runtime container. This avoids launching Steam during setup.
export WINEPREFIX="\${WINEPREFIX}"
export LD_LIBRARY_PATH="${proton_ld_path}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WINEFSYNC=1
export WINEESYNC=1
exec "${real_wine_path}" "\$@"
EOF
    cp "${maint_wine}" "${wrapper_dir}/wine64"
    chmod +x "${maint_wine}" "${wrapper_dir}/wine64"

    # Wineserver wrapper: same direct-binary approach.
    maint_server="${wrapper_dir}/wineserver"
    cat << EOF > "${maint_server}"
#!/usr/bin/env bash
# Maintenance wineserver wrapper: direct binary, no SLR container.
export WINEPREFIX="\${WINEPREFIX}"
export LD_LIBRARY_PATH="${proton_ld_path}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WINEFSYNC=1
export WINEESYNC=1
exec "${real_wineserver}" "\$@"
EOF
    chmod +x "${maint_server}"

    is_proton_maint="true"
    info_msg "Using Proton Wine directly for maintenance (no SLR container): ${real_wine_path}"
    local maint_ver
    maint_ver=$("${real_wine_path}" --version 2>/dev/null || echo "unknown")
    info_msg "Maintenance Wine version: ${maint_ver}"
  elif [[ -n "${real_wine_path}" ]]; then
    # Use the detected Wine binary directly. All Proton builds that have a
    # 'proton' script are already handled above; this branch covers standalone
    # Wine builds (system Wine, custom GE builds without a proton script, etc.).
    maint_wine="${real_wine_path}"
    maint_server="${real_wineserver}"
    info_msg "Using Wine binary: ${real_wine_path}"
  else
    # Fallback to system Wine.
    if command_exists wine; then
      maint_wine=$(command -v wine)
      maint_server=$(command -v wineserver || echo "wineserver")
      info_msg "Falling back to system Wine for maintenance: ${maint_wine}"
    fi
  fi

  # --------------------------------------------------------------------------
  # Step 1 — System tools
  #
  # Detects your Linux distribution's package manager (apt for Ubuntu/Debian,
  # pacman for Arch, dnf for Fedora, zypper for openSUSE) and installs any
  # missing tools.
  #
  # Note: This step requires 'sudo' (administrator) privileges to install
  # system-wide tools like Wine.
  # --------------------------------------------------------------------------
  step_msg "Step 1 — Verifying system tools..."

  if [[ -e /dev/uinput ]] && [[ ! -w /dev/uinput ]]; then
    warn_msg "Access to /dev/uinput is restricted (systemd v258+ policy)."
    info_msg "Solution: sudo groupadd -r uinput && sudo usermod -aG uinput \$USER"
    info_msg "More info: https://gitlab.archlinux.org/archlinux/packaging/packages/systemd/-/issues/31"
  fi

  local pkg_mgr=""
  if   command_exists apt;    then pkg_mgr="apt"
  elif command_exists pacman; then pkg_mgr="pacman"
  elif command_exists dnf;    then pkg_mgr="dnf"
  elif command_exists zypper; then pkg_mgr="zypper"
  else
    error_exit "No supported package manager found (apt / pacman / dnf / zypper)."
  fi

  local -a extra_tools=()
  [[ "${use_gamescope}" == "true" ]] && extra_tools+=("gamescope")
  install_sys_deps "${pkg_mgr}" "${extra_tools[@]}"

  # Ensure winetricks is recent enough to know about vcrun2019 and dxvk 2.x.
  # Distro packages are often many months behind; we fetch the latest from the
  # official Winetricks GitHub repo so verb downloads use correct, live URLs.
  step_msg "Step 1b — Ensuring winetricks is up-to-date..."
  ensure_winetricks_fresh

  # ~/.local/bin is not in PATH by default on all distros. Add it now so the
  # launcher script we create in Step 12 can be found immediately.
  if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
    info_msg "Added ~/.local/bin to PATH for this session."
    info_msg "(Add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to ~/.bashrc to make it permanent.)"
  fi

  # Skip heavy steps (Steps 2-6) if we just performed an update.
  if [[ "${skip_heavy_steps}" == "false" ]]; then
    # --------------------------------------------------------------------------
    # Step 2 — Resolve game version
  #
  #   latest_version          — e.g. "0.36.2100.0"
  #   zip_url                 — direct URL to the game zip (~5.3 GB)
  #   zip_blake3              — BLAKE3 hash of the zip for integrity checking
  #   zip_size                — expected size in bytes
  #   gameversion_dat_path    — relative path to GameVersion.dat inside the zip
  #   gameversion_dat_blake3  — BLAKE3 hash of GameVersion.dat (used for update
  #                             detection — if this matches local, no download
  #                             is needed)
  #
  # Set GAME_VERSION=x.x.x.x on the command line to skip the server check and
  # use a specific build instead.
  # --------------------------------------------------------------------------
  step_msg "Step 2 — Resolving game version..."

  local zip_url=""
  local zip_blake3=""
  local dat_path_rel=""
  local dat_blake3=""

  if fetch_version_info; then
    local server_version
    server_version=$(parse_version_field "latest_version")
    zip_url=$(parse_version_field "zip_url")
    zip_blake3=$(parse_version_field "zip_blake3")
    dat_path_rel=$(parse_version_field "gameversion_dat_path")
    dat_blake3=$(parse_version_field "gameversion_dat_blake3")
    ok_msg "Server reports latest version: ${server_version}"

    if [[ "${resolved_version}" == "auto" ]]; then
      resolved_version="${server_version}"
      ok_msg "Using latest version: ${resolved_version}"
    else
      ok_msg "Using pinned version: ${resolved_version}"
      zip_url="https://updater.realmhub.io/builds/game-${resolved_version}.zip"
      zip_blake3=""
      dat_path_rel=""
      dat_blake3=""
    fi
  else
    warn_msg "Could not reach update server."
    if [[ "${resolved_version}" == "auto" ]]; then
      resolved_version="0.36.2100.0"
      warn_msg "Falling back to hardcoded version: ${resolved_version}"
    fi
    # resolved_version is either the hardcoded fallback above or was set from
    # GAME_VERSION env var, which was already validated as ^[0-9.]+$ by the
    # arg-parsing logic. Safe to interpolate directly into the URL.
    zip_url="https://updater.realmhub.io/builds/game-${resolved_version}.zip"
  fi

  # Validate resolved_version is a safe dotted-numeric string before it
  # is interpolated into any URL (covers both the server and offline paths).
  if [[ ! "${resolved_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error_exit "Resolved game version '${resolved_version}' is not a valid version string.
  Expected format: X.Y.Z.W (e.g. 0.36.2100.0). Aborting for safety."
  fi

  ok_msg "Game version: ${resolved_version}"

  # Validate the zip URL before use — reject anything not pointing to the
  # expected update host. Prevents a compromised version.json from redirecting
  # downloads to an attacker-controlled server.
  if [[ -n "${zip_url}" && ! "${zip_url}" =~ ^https://updater\.realmhub\.io/ ]]; then
    error_exit "Update server returned an unexpected download URL: '${zip_url}'
  Only https://updater.realmhub.io/ URLs are accepted. Aborting for safety."
  fi

  ok_msg "Download URL: ${zip_url}"

  is_game_up_to_date "${dat_path_rel}" "${dat_blake3}" || true

  # --------------------------------------------------------------------------
  # Step 3 — Create Wine prefix
  #
  # The Wine prefix is a self-contained fake-Windows installation. Think of it
  # as a virtual hard drive that only this game uses. It lives at
  # ~/.cluckers/prefix and is completely separate from any other Wine apps.
  #
  # 'wine wineboot' initialises the prefix (creates the fake registry, Program
  # Files, Windows directories, etc.). This takes about 30 seconds the first
  # time and is instant if the prefix already exists.
  # --------------------------------------------------------------------------
  step_msg "Step 3 — Initialising Wine prefix..."

  # If we are using Proton, ensure there are no conflicting real files
  # where Proton expects to place symlinks. Proton's prefix upgrade creates
  # symlinks from its bundled files into the Wine prefix; if a prior Wine or
  # older Proton left real files (or stale symlinks from cp -r) at those
  # paths, os.symlink() in Proton's Python script raises FileExistsError. We use Proton's own default_pfx
  # template to identify which paths should be symlinks — this is robust
  # across all Proton versions without maintaining a hardcoded file list.
  # Only clean up when Proton's creation_sync_guard is absent — that's when
  # copy_pfx() will run and need a clean slate. Once copy_pfx() succeeds it
  # writes creation_sync_guard, and subsequent runs use update_builtin_libs()
  # which handles existing files correctly on its own.
  if [[ "${_is_proton}" == "true" ]] && [[ -d "${WINEPREFIX}/drive_c" ]] \
     && [[ ! -f "${WINEPREFIX}/creation_sync_guard" ]]; then
    local proton_root_for_cleanup
    proton_root_for_cleanup="$(dirname "$(dirname "$(dirname "${real_wine_path}")")")"
    local cleanup_template=""
    find_proton_template "${proton_root_for_cleanup}" cleanup_template
    if [[ -n "${cleanup_template}" ]]; then
      info_msg "Checking prefix for symlink conflicts against Proton template..."
      local _conflict_count=0
      # Find every symlink in default_pfx, check if the corresponding path
      # in WINEPREFIX already exists (file OR symlink). Proton's os.symlink()
      # fails on any existing entry, not just regular files.
      while IFS= read -r -d '' _tmpl_link; do
        local _rel_path="${_tmpl_link#"${cleanup_template}"/}"
        local _pfx_path="${WINEPREFIX}/${_rel_path}"
        if [[ -e "${_pfx_path}" ]] || [[ -L "${_pfx_path}" ]]; then
          rm -f "${_pfx_path}"
          (( _conflict_count++ )) || true
        fi
      done < <(find "${cleanup_template}" -type l -print0 2>/dev/null)
      if (( _conflict_count > 0 )); then
        ok_msg "Removed ${_conflict_count} conflicting file(s) that Proton needs to replace with symlinks."
      fi
    else
      # Fallback: no template found. Remove the most common offenders.
      # This covers the case where default_pfx is missing (unusual).
      info_msg "No Proton template found — removing known symlink conflict files..."
      find "${WINEPREFIX}/drive_c" -type f \( \
        -path "*/Internet Explorer/iexplore.exe" -o \
        -path "*/system32/notepad.exe" -o \
        -path "*/system32/winhlp32.exe" -o \
        -path "*/system32/cmd.exe" -o \
        -path "*/system32/control.exe" -o \
        -path "*/system32/regedit.exe" \
      \) -not -type l -delete 2>/dev/null || true
    fi
  fi

  if [[ -d "${WINEPREFIX}/drive_c" ]]; then
    ok_msg "Wine prefix already exists at ${WINEPREFIX}."
  else
    info_msg "Creating Wine prefix at ${WINEPREFIX} (this takes ~30 seconds)..."
    mkdir -p "${WINEPREFIX}"

    # If we are using Proton, it's safer and faster to copy its bundled default_pfx
    # instead of running wineboot --init (which can hang with some Proton builds).
    local proton_template=""
    if [[ "${_is_proton}" == "true" ]]; then
      # find_wine resolves real_wine_path to something like .../Proton/files/bin/wine
      local proton_root
      proton_root="$(dirname "$(dirname "$(dirname "${real_wine_path}")")")"
      find_proton_template "${proton_root}" proton_template
    fi

    if [[ -n "${proton_template}" ]]; then
      info_msg "Copying Proton prefix template from ${proton_template}..."
      cp -r "${proton_template}"/* "${WINEPREFIX}/"
    else

      # Suppress Wine GUI dialogs during prefix initialisation:
      #   DISPLAY=""                        — no X window for mono/gecko installers
      #   WINEDLLOVERRIDES=mscoree,mshtml=  — skip .NET and IE installers
      # env is used instead of inline VAR=value syntax because WINEPREFIX is
      # declared readonly and bash rejects inline re-assignment of readonly vars.
      local env_adds bin_add lib_add loader_add
      env_adds=$(get_wine_env_additions "${maint_wine}")
      bin_add="${env_adds%%|*}"; temp="${env_adds#*|}"; 
      lib_add="${temp%%|*}"; loader_add="${env_adds##*|}"
      env WINEPREFIX="${WINEPREFIX}" DISPLAY="" \
        PATH="${bin_add}:${PATH}" \
        LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        WINELOADER="${loader_add}" \
        WINEDLLOVERRIDES="mscoree,mshtml=" \
        WINE="${maint_wine}" WINESERVER="${maint_server}" \
        "${maint_wine}" wineboot --init || true
      # Stabilize the prefix — wait for all Wine children to exit cleanly.
      env WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
        PATH="${bin_add}:${PATH}" \
        LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        WINELOADER="${loader_add}" \
        "${maint_server}" -w || true
    fi
    ok_msg "Wine prefix created."
  fi

  # Install xinput1_3.dll into the Wine prefix system32 so Wine loads our
  # custom XInput remapper instead of the built-in stub when the game requests
  # XInput. This must happen AFTER wineboot has fully initialised the prefix.
  #
  # In a Proton prefix, drive_c/windows/system32 is a symlink to the real
  # Windows DLL directory inside the prefix. Copying into a symlink with plain
  # `cp` follows it and may fail with "not writing through dangling symlink" if
  # the link target does not yet exist. We resolve the real path with
  # `readlink -f` and copy directly into the resolved directory to avoid this.
  #
  # Wine resolves DLLs from the prefix system32 before its own built-in stubs,
  # so placing the remapper here ensures it intercepts all XInput calls.
  # Source: https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/xinput1_3/xinput_main.c
  if [[ "${controller_mode}" == "true" ]]; then
    local _xdll_src="${TOOLS_DIR}/xinput1_3.dll"
    local _wine_sys32_link="${WINEPREFIX}/drive_c/windows/system32"
    local _wine_sys32
    _wine_sys32=$(readlink -f "${_wine_sys32_link}" 2>/dev/null || echo "${_wine_sys32_link}")
    if [[ -f "${_xdll_src}" ]] && [[ -d "${_wine_sys32}" ]]; then
      cp -f "${_xdll_src}" "${_wine_sys32}/xinput1_3.dll" \
        && ok_msg "xinput1_3.dll placed in Wine system32 (${_wine_sys32})." \
        || warn_msg "Could not copy xinput1_3.dll into Wine system32 — controller remapping may not work."
    elif [[ -f "${_xdll_src}" ]]; then
      warn_msg "Wine system32 not yet initialised — xinput1_3.dll will be copied on next run."
    fi
  fi

  if [[ "${controller_mode}" == "true" ]]; then
    # Check that the user has read access to /dev/input/event* nodes.
    # Without this, Wine's SDL layer cannot enumerate the controller and it
    # will appear invisible to the game regardless of other settings.
    # The standard fix is to be a member of the 'input' group.
    # Source: https://wiki.archlinux.org/title/Gamepad#Setting_up_a_gamepad
    local _event_found="false"
    local _event_readable="false"
    local _ev
    for _ev in /dev/input/event*; do
      [[ -e "${_ev}" ]] || continue
      _event_found="true"
      [[ -r "${_ev}" ]] && { _event_readable="true"; break; }
    done
    if [[ "${_event_found}" == "false" ]]; then
      warn_msg "No /dev/input/event* nodes found — controller may not be connected."
    elif [[ "${_event_readable}" == "false" ]]; then
      warn_msg "You may not have read access to /dev/input/event* devices."
      warn_msg "Fix: sudo usermod -aG input \$USER  (then log out and back in)"
      warn_msg "Source: https://wiki.archlinux.org/title/Gamepad#Setting_up_a_gamepad"
    fi

    # Suggest SDL_GameControllerDB if not already installed.
    # This community database provides correct button mappings for thousands
    # of controllers, fixing mis-mapped triggers, bumpers, and face buttons
    # under Wine's SDL layer. Highly recommended for any non-Xbox controller.
    # Source: https://github.com/gabomdq/SDL_GameControllerDB
    local _sdl_db_found="false"
    for _db_path in \
      "${HOME}/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "${HOME}/.config/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "/usr/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "/usr/local/share/SDL_GameControllerDB/gamecontrollerdb.txt"; do
      if [[ -f "${_db_path}" ]]; then
        _sdl_db_found="true"
        ok_msg "SDL GameControllerDB found at ${_db_path} — will be loaded by launcher."
        break
      fi
    done
    if [[ "${_sdl_db_found}" == "false" ]]; then
      info_msg "Tip: Install SDL_GameControllerDB for correct controller button mappings:"
      info_msg "  mkdir -p ~/.local/share/SDL_GameControllerDB"
      info_msg "  curl -L https://raw.githubusercontent.com/gabomdq/SDL_GameControllerDB/master/gamecontrollerdb.txt \\"
      info_msg "       -o ~/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt"
      info_msg "Source: https://github.com/gabomdq/SDL_GameControllerDB"
    fi

    info_msg "Applying WineBus SDL mapping for controllers..."
    # Configure Wine's controller input backend to use SDL2 instead of hidraw.
    #
    # Wine can talk to controllers in two ways: through "hidraw" (a Linux kernel
    # interface that reads raw USB data) or through SDL2 (a cross-platform game
    # library with built-in controller support). When both are active at the same
    # time, the controller appears twice to the game — once from hidraw and once
    # from SDL2. Unreal Engine 3 adds both sets of axis events together, resulting
    # in phantom camera spin where the camera rotates by itself even without
    # touching the stick.
    #
    # DisableHidraw=1 — tells Wine's winebus.sys driver to stop reading the
    #   controller through the hidraw kernel interface, eliminating the duplicate.
    # EnableSDL=1 — tells Wine to use the SDL2 library as the sole controller
    #   input source, which correctly maps axes, buttons, and triggers.
    #
    # These are registry keys read by Wine's controller driver (winebus.sys).
    # Source: https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/winebus.sys/main.c
    #         (options.disable_hidraw ~line 518, options.disable_sdl ~line 541)
    local winebus_key
    winebus_key="HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus"
    env DISPLAY="" WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
      "${maint_wine}" reg add "${winebus_key}" \
      /v DisableHidraw /t REG_DWORD /d 1 /f 2>/dev/null || true
    env DISPLAY="" WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
      "${maint_wine}" reg add "${winebus_key}" \
      /v EnableSDL /t REG_DWORD /d 1 /f 2>/dev/null || true
    # Wait for wineserver to finish processing registry writes before continuing.
    env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -w 2>/dev/null || true
    env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true
  fi

  # --------------------------------------------------------------------------
  # Step 4 — Windows runtime libraries
  #
  # The game is a Windows program running inside Wine on Linux. Wine provides
  # a compatibility layer that translates Windows system calls to Linux, but it
  # does not include the C++ standard library DLLs or the DirectX graphics
  # libraries that the game was compiled against. Those must be installed
  # separately into the Wine prefix — that is what this step does.
  #
  # Think of it like this: if you took a Windows game and tried to run it on a
  # fresh Windows install without the Visual C++ Redistributable packages, it
  # would fail to start with a "DLL not found" error. The same is true here.
  #
  # Each package is checked before downloading. If it is already installed
  # (from a previous run, or by Proton), the download is skipped entirely.
  #
  # vcrun2010  Visual C++ 2010 runtime (msvcp100.dll, msvcr100.dll).
  #            The core Unreal Engine 3 code was compiled with Microsoft Visual
  #            Studio 2010 and requires these DLLs at startup. Missing them
  #            causes the game to crash immediately with a "DLL not found" error.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2010 installed_file1=mfc100.dll
  #
  # vcrun2012  Visual C++ 2012 runtime (msvcp110.dll, msvcr110.dll).
  #            The game's networking and audio subsystems were compiled with a
  #            newer toolchain than the engine core and require these DLLs.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2012 installed_file1=mfc110.dll
  #
  # vcrun2019  Visual C++ 2015-2019 runtime (msvcp140.dll, vcruntime140.dll,
  #            vcruntime140_1.dll). The game launcher and EAC anti-cheat system
  #            require these DLLs. We install vcrun2019 rather than vcrun2022
  #            because vcrun2022 bundles extra localised MFC resource DLLs
  #            (mfc140chs.dll, mfc140deu.dll, etc.) that the game does not need,
  #            adding unnecessary download size. Both versions provide the same
  #            core runtime DLLs that matter.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2019 installed_file1=vcruntime140.dll
  #
  # dxvk       Vulkan-based Direct3D implementation for Wine. Replaces Wine's
  #            built-in Direct3D 11 with a high-performance Vulkan translation
  #            layer. This dramatically improves frame rate and reduces CPU usage
  #            compared to Wine's own Direct3D implementation. Requires a
  #            Vulkan-capable GPU: NVIDIA (driver ≥ 470), AMD (Mesa ≥ 21.x),
  #            or Intel (ANV Vulkan driver).
  #            Source: https://github.com/doitsujin/dxvk
  #
  # d3dx11_43  A DirectX 11 helper DLL (d3dx11_43.dll) used by the game's
  #            shader compilation system at startup. Without it, the game may
  #            fail to load shaders and render incorrectly or not at all.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata d3dx11_43 installed_file1=d3dx11_43.dll
  # --------------------------------------------------------------------------
  step_msg "Step 4 — Configuring Windows runtime environment..."

  # Kill any orphaned wineserver from previous steps before running winetricks.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true

  install_winetricks_multi \
    "Windows runtime environment" \
    "${maint_wine}" \
    "${maint_server}" \
    "${auto_mode}" \
    "vcrun2010" "vcrun2012" "vcrun2019" "dxvk" "d3dx11_43"

  # --------------------------------------------------------------------------
  # Step 5 — Synchronizing game content
  #
  # Downloads the game zip (~5.3 GB) from the update server with resume
  # support (if a previous download was interrupted it continues from where
  # it stopped). After download the BLAKE3 hash is verified against the
  # value from version.json to confirm the download is intact.
  # --------------------------------------------------------------------------
  step_msg "Step 5 — Synchronizing game content..."

  mkdir -p "${GAME_DIR}"

  # Verify that the game directory is writable before attempting a multi-GB
  # download. A read-only or permission-denied directory causes a confusing
  # failure deep into the download rather than a clear error up front.
  # Common causes: the directory was created as root, or lives on a read-only
  # mount (e.g. an NTFS drive mounted without write permissions).
  if [[ ! -w "${GAME_DIR}" ]]; then
    error_exit "Game directory is not writable: ${GAME_DIR}
  Fix with: chmod u+w \"${GAME_DIR}\"
  Or check that the filesystem is mounted with write permissions."
  fi

  # Also verify that the parent filesystem is not mounted read-only.
  if ! touch "${GAME_DIR}/.write_test" 2>/dev/null; then
    error_exit "Cannot write to game directory: ${GAME_DIR}
  The filesystem may be mounted read-only. Check: mount | grep \$(df -P \"${GAME_DIR}\" | tail -1 | awk '{print \$1}')"
  fi
  rm -f "${GAME_DIR}/.write_test"

  local local_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
  if [[ -f "${local_game_exe}" ]]; then
    ok_msg "Game files already present at ${GAME_DIR} — skipping synchronization."
  else
    info_msg "Downloading game zip from ${zip_url}"
    info_msg "(This is ~5.3 GB — it may take a while on slower connections.)"
    info_msg "If interrupted, re-run the script to resume from where it stopped."

    local zip_path="${GAME_DIR}/game.zip"

    parallel_download "${zip_url}" "${zip_path}" \
      || error_exit "Game download failed. Check your internet connection."

    ok_msg "Download complete."

    # Verify BLAKE3 hash using Python (bash has no native BLAKE3 support).
    if [[ -n "${zip_blake3}" ]]; then
      info_msg "Verifying BLAKE3 integrity of game zip..."
      local actual_blake3
      actual_blake3=$(python3 - "${zip_path}" << 'BLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    fn = sys.argv[1]
    h = b3()
    with open(fn, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    print(h.hexdigest())
except ImportError:
    # blake3 module not available — skip verification
    print("skip")
BLAKE3EOF
      ) || actual_blake3="skip"

      if [[ "${actual_blake3}" == "skip" ]]; then
        warn_msg "blake3 Python module not installed — skipping BLAKE3 verification."
        warn_msg "Install with: pip install blake3"
      elif [[ "${actual_blake3}" != "${zip_blake3}" ]]; then
        rm -f "${zip_path}"
        error_exit "BLAKE3 mismatch — game zip may be corrupt.
  Expected: ${zip_blake3}
  Got:      ${actual_blake3}
  Re-run the script to re-download."
      else
        ok_msg "BLAKE3 integrity verified."
      fi
    fi

    # Extract the zip.
    info_msg "Extracting game files (this may take several minutes)..."
    if command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "${zip_path}" -C "${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    elif command -v 7z >/dev/null 2>&1; then
      7z x -y "${zip_path}" -o"${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    else
      UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip -o "${zip_path}" -d "${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    fi
    rm -f "${zip_path}"
    ok_msg "Game files extracted to ${GAME_DIR}"
  fi

  # --------------------------------------------------------------------------
  # Step 6 — Install helper binaries (shm_launcher.exe + xinput1_3.dll)
  #
  # Two small Windows helper binaries are required for full game functionality:
  #
  # shm_launcher.exe
  #   Creates a named Windows shared memory (IPC) region and copies the content
  #   bootstrap blob into it before launching the game executable. The game
  #   reads this region at startup via OpenFileMapping(). Without it the game
  #   starts but may not receive the bootstrap payload needed for EAC.
  #   Compile: x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows \
  #              -o shm_launcher.exe shm_launcher.c
  #   Note: -municode is required because the entry point is wmain() not main().
  #
  # xinput1_3.dll
  #   A drop-in replacement for the system XInput DLL that remaps controller
  #   input so all buttons (triggers, bumpers, face buttons) work correctly
  #   under Wine/Proton. Installed into the Wine prefix system32 folder so
  #   Wine loads it instead of the built-in stub.
  #   Compile: x86_64-w64-mingw32-gcc -O2 -Wall -shared \
  #              -o xinput1_3.dll xinput_remap.c xinput1_3.def
  #
  # ============================================================================
  #  REPRODUCIBLE BINARIES
  # ============================================================================
  #
  #    Two small Windows helper binaries are downloaded from GitHub Releases:
  #
  #    shm_launcher.exe  -- creates a named Windows shared memory region
  #                         containing the content bootstrap blob that the game
  #                         reads on startup.
  #
  #    xinput1_3.dll     -- remaps controller input so all buttons work correctly
  #                         under Wine/Proton.
  #
  #    Both are built from auditable C source in CI (GitHub Actions) using
  #    mingw-w64. SHA-256 checksums are verified after download.
  #
  #    Source code, build workflow, and releases:
  #      https://github.com/0xc0re/trashcan
  #
  # ============================================================================
  step_msg "Step 6 — Installing helper binaries..."

  mkdir -p "${TOOLS_DIR}"

  # -- shm_launcher.exe ------------------------------------------------------
  local shm_dst="${TOOLS_DIR}/shm_launcher.exe"
  download_binary "${SHM_LAUNCHER_URL}" "${shm_dst}" "${SHM_LAUNCHER_SHA256}"

  # -- xinput1_3.dll ---------------------------------------------------------
  if [[ "${controller_mode}" == "true" ]]; then
    local xdll_dst="${TOOLS_DIR}/xinput1_3.dll"
    download_binary "${XINPUT_DLL_URL}" "${xdll_dst}" "${XINPUT_DLL_SHA256}"

    # NOTE: xinput1_3.dll is placed into the Wine prefix system32 in Step 3,
    # after wineboot has run and the prefix is fully initialised. Proton creates
    # system32 as a symlink during prefix initialisation; copying into it before
    # wineboot runs follows a dangling symlink and fails with:
    #   cp: not writing through dangling symlink '…/system32/xinput1_3.dll'
    # Step 3 calls install_xinput_dll() after wineboot completes.
  fi

    # --------------------------------------------------------------------------
  # Step 7 — Synchronizing game assets
  #
  # Fetches high-quality icons, grid art, and hero images from Steam's CDN.
  # These are used for both the desktop shortcut and the Steam non-Steam game
  # entry for a professional look.
  # --------------------------------------------------------------------------
  step_msg "Step 7 — Synchronizing game assets..."

  mkdir -p "${ICON_DIR}"
  mkdir -p "${STEAM_ASSETS_DIR}"

  if command_exists curl; then
    info_msg "Synchronizing assets from Steam CDN..."

    # Download each asset individually so a single failure doesn't abort the rest.
    # '|| true' ensures the script continues even if the CDN is temporarily down.
    curl ${CURL_FLAGS}f -o "${STEAM_LOGO_PATH}"   "${STEAM_LOGO_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_GRID_PATH}"   "${STEAM_GRID_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_HERO_PATH}"   "${STEAM_HERO_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_WIDE_PATH}"   "${STEAM_WIDE_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_HEADER_PATH}" "${STEAM_HEADER_URL}" || true

    # Download the game's ICO from Steam's community assets (32×32, authoritative
    # icon Steam itself uses). The ICO is kept for the Steam shortcuts.vdf "icon"
    # Install the game icon into the XDG hicolor icon theme so desktop
    # environments (GNOME, KDE, XFCE) find it reliably by name. Icons must
    # live in a theme subdirectory — the DE resolves Icon=cluckers-central
    # (no path, no extension) through the theme cache at runtime.
    #
    # Icon source: 1.ico extracted from the game EXE via unzip.
    # The Realm Royale shipping EXE is packaged in a format that unzip can
    # read directly. The icon is stored at the path .rsrc/ICON/1.ico inside
    # the archive and contains multiple frames (32×32, 256×256, etc.),
    # giving a crisp native icon at every size slot without any upscaling.
    #
    # We install:
    #   hicolor/32x32/apps/cluckers-central.png  — taskbar / panel icon.
    #   hicolor/256x256/apps/cluckers-central.png — HiDPI application grid.
    #   ICON_PATH (flat PNG)                      — absolute-path fallback
    #     for desktop environments that resolve Icon= by path before theme.
    #
    # The Steam CDN ICO (STEAM_ICO_PATH) is still downloaded because Steam's
    # shortcuts.vdf requires a path to an ICO file in its "icon" field.
    # Download the Steam CDN ICO for shortcuts.vdf (not used as desktop icon).
    curl ${CURL_FLAGS}f -o "${STEAM_ICO_PATH}" "${STEAM_ICO_URL}" || true

    # Extract the game icon from the EXE and install it as the desktop icon.
    # The Realm Royale EXE stores its icon at .rsrc/ICON/1.ico in a format
    # that unzip can read directly. The ICO contains multiple frames
    # (32×32, 256×256, etc.). We convert the largest frame to PNG using
    # Pillow because most Linux DEs do not render ICO reliably via Icon=.
    # The PNG is installed to ICON_PATH and also into the hicolor theme so
    # the DE finds it by name (Icon=cluckers-central in the .desktop file).
    local _game_exe="${GAME_DIR}/${GAME_EXE_REL}"
    local _exe_ico="${STEAM_ASSETS_DIR}/icon_exe.ico"
    mkdir -p "${ICON_DIR}/hicolor/256x256/apps"
    if [[ ! -f "${_game_exe}" ]]; then
      warn_msg "Game EXE not found — desktop icon cannot be installed yet."
      warn_msg "Re-run setup after downloading the game to install the icon."
    elif ! command_exists unzip; then
      warn_msg "unzip not found — desktop icon cannot be installed."
      warn_msg "Install unzip: sudo apt install unzip  (or your distro's equivalent)"
    else
      # Extract the icon from the game EXE using a Python PE resource parser.
      # The EXE is a standard Windows PE binary — not a zip archive — so
      # tools like unzip or 7z cannot read its resources. We parse the PE
      # .rsrc section directly using Python's struct module (stdlib only),
      # extract RT_GROUP_ICON (type 14) and RT_ICON (type 3) frames, assemble
      # a valid ICO file in memory, and save the largest frame as PNG.
      PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}" \
      python3 - "${_game_exe}" "${ICON_PATH}" \
                 "${ICON_DIR}/hicolor/256x256/apps/cluckers-central.png" << 'ICOEXT_EOF'
import struct, sys, shutil, io
from PIL import Image

def extract_pe_group_icon(path, group_id=1):
    """Parse a Windows PE binary and extract an icon group as ICO bytes."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:2] != b'MZ':
        raise ValueError("Not a PE file")
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe_off:pe_off+4] != b'PE\x00\x00':
        raise ValueError("Bad PE signature")
    num_sects = struct.unpack_from('<H', data, pe_off + 6)[0]
    opt_sz    = struct.unpack_from('<H', data, pe_off + 20)[0]
    magic     = struct.unpack_from('<H', data, pe_off + 24)[0]
    dd_base   = pe_off + 24 + (112 if magic == 0x20B else 96)
    rsrc_rva  = struct.unpack_from('<I', data, dd_base + 16)[0]
    rsrc_vaddr = rsrc_foff = 0
    sect_base = pe_off + 24 + opt_sz
    for i in range(num_sects):
        s   = sect_base + i * 40
        va  = struct.unpack_from('<I', data, s + 12)[0]
        rsz = struct.unpack_from('<I', data, s + 16)[0]
        rof = struct.unpack_from('<I', data, s + 20)[0]
        if va <= rsrc_rva < va + rsz:
            rsrc_vaddr, rsrc_foff = va, rof
            break
    if rsrc_foff == 0:
        raise ValueError("No .rsrc section")
    def rva2off(rva): return rsrc_foff + (rva - rsrc_vaddr)
    def read_dir(off):
        named = struct.unpack_from('<H', data, off + 12)[0]
        ident = struct.unpack_from('<H', data, off + 14)[0]
        return [(struct.unpack_from('<I', data, off+16+i*8)[0] & 0x7FFFFFFF,
                 struct.unpack_from('<I', data, off+16+i*8+4)[0] & 0x7FFFFFFF,
                 bool(struct.unpack_from('<I', data, off+16+i*8+4)[0] & 0x80000000))
                for i in range(named + ident)]
    def get_res(type_id, res_id):
        root_dir = read_dir(rsrc_foff)
        td = next((rsrc_foff+o for i,o,s in root_dir if i==type_id and s), None)
        if td is None: return None
        type_dir = read_dir(td)
        # If requested res_id not found, pick the first available ID
        if not any(i == res_id for i,o,s in type_dir):
            if not type_dir: return None
            res_id = type_dir[0][0]
        id_dir = next((rsrc_foff+o for i,o,s in type_dir if i==res_id and s), None)
        if id_dir is None: return None
        langs = read_dir(id_dir)
        if not langs: return None
        _, doff, is_sub = langs[0]
        if is_sub: return None
        eoff = rsrc_foff + doff
        rva  = struct.unpack_from('<I', data, eoff)[0]
        size = struct.unpack_from('<I', data, eoff+4)[0]
        return data[rva2off(rva):rva2off(rva)+size]
    grp = get_res(14, group_id)
    if not grp: raise ValueError("No icon groups found in .rsrc")
    count = struct.unpack_from('<H', grp, 4)[0]
    frames = []
    for i in range(count):
        e = 6 + i*14
        w,h,col = struct.unpack_from('<BBB', grp, e)
        planes,bpp = struct.unpack_from('<HH', grp, e+4)
        icon_id = struct.unpack_from('<H', grp, e+12)[0]
        dib = get_res(3, icon_id)
        if dib: frames.append((w,h,col,planes,bpp,dib))
    if not frames: raise ValueError("No icon frames extracted")
    n = len(frames); data_off = 6 + 16*n
    hdr = struct.pack('<HHH', 0, 1, n)
    dirs = b''; imgs = b''
    for w,h,col,planes,bpp,dib in frames:
        dirs += struct.pack('<BBBBHHII', w,h,col,0,planes,bpp,len(dib),data_off+len(imgs))
        imgs += dib
    return hdr + dirs + imgs

try:
    exe   = sys.argv[1]
    flat  = sys.argv[2]
    hi    = sys.argv[3]
    ico   = extract_pe_group_icon(exe, 1)
    img   = Image.open(io.BytesIO(ico))
    # img.ico.sizes() might not exist in all PIL versions, fallback to img.size
    if hasattr(img, 'ico') and hasattr(img.ico, 'sizes') and img.ico.sizes():
        sizes = sorted(img.ico.sizes(), key=lambda s: s[0]*s[1], reverse=True)
    else:
        sizes = [img.size]
    
    if hasattr(img, 'ico') and hasattr(img.ico, 'getimage'):
        frame = img.ico.getimage(sizes[0]).convert('RGBA')
    else:
        frame = img.convert('RGBA')
        
    frame.save(flat, 'PNG')
    shutil.copy2(flat, hi)
    print(f"[icon] {frame.width}x{frame.height} PNG from PE .rsrc installed.")
    sys.exit(0)
except Exception as e:
    print(f"[icon] PE icon extraction failed: {e}", file=sys.stderr)
    sys.exit(1)
ICOEXT_EOF
      if [[ $? -eq 0 ]]; then
        ok_msg "Game icon installed at ${ICON_PATH}."
      else
        warn_msg "Could not extract icon from game EXE — desktop icon will be missing."
        warn_msg "Ensure python3 and Pillow (pip install pillow) are available."
      fi
    fi

    # Refresh the icon theme cache so the new icon appears immediately.
    if command_exists gtk-update-icon-cache; then
      gtk-update-icon-cache -f -t "${ICON_DIR}/hicolor" 2>/dev/null || true
    fi

    # Copy the portrait poster to ICON_POSTER_PATH for Steam grid artwork only.
    if [[ -f "${STEAM_GRID_PATH}" ]]; then
      cp "${STEAM_GRID_PATH}" "${ICON_POSTER_PATH}"
      ok_msg "High-quality Steam assets downloaded."
    else
      warn_msg "Grid poster unavailable — portrait poster slot will be empty."
    fi

  fi

  # --------------------------------------------------------------------------
  # Step 8 — Create launcher script
  #
  # Writes ~/.local/bin/cluckers-central.sh — a small shell script that:
  #   1. Writes the .env file so the launcher uses the local proxy.
  #   2. Starts the gateway proxy in the background and stops it on exit.
  #   3. Launches Cluckers Central under Wine, optionally wrapped in Gamescope.
  #
  # Two heredoc styles are used:
  #   Double-quoted (EOF)   — values expanded NOW at setup time (paths, flags).
  #   Single-quoted ('EOF') — code written literally, variables expand at
  #                           LAUNCH TIME when the generated script runs.
  #
  # Environment variables set in the launcher:
  #   WINE_NTSYNC=1 — enables NT sync primitives (requires a modern kernel).
  #   WINEFSYNC=1   — enables futex-based sync (standard GE-Proton fallback).
  # --------------------------------------------------------------------------
  step_msg "Step 8 — Creating launcher script..."

  # Wine/Proton was detected upfront in main() before Step 3.
  # real_wine_path, _is_proton, and _proton_tool_name are already set.
  [[ -z "${real_wine_path}" ]] && \
    error_exit "No Proton found. Install a Proton build via Steam or ProtonUp-Qt."
  ok_msg "Wine binary (Proton): ${real_wine_path}"
  ok_msg "Proton compat tool name: ${_proton_tool_name}"
  # Sync primitives: ntsync (modern) or fsync (standard Proton fallback).
  if [[ "${_is_proton}" == "true" ]]; then
    if [[ -c /dev/ntsync ]]; then
      ok_msg "WINE_NTSYNC=1 will be set in the launcher (compatible kernel found)."
    else
      ok_msg "WINEFSYNC=1 will be set in the launcher."
    fi
  fi

  if [[ "${use_gamescope}" == "true" ]]; then
    if [[ "${controller_mode}" == "true" ]] && [[ "${steam_deck}" == "false" ]]; then
      ok_msg "Gamescope + controller support will be used in the launcher (--gamescope-with-controller)."
    else
      ok_msg "Gamescope compositor will be used in the launcher."
    fi
  fi

  # Pre-compute launcher strings to avoid subshell expansion issues inside the heredoc.
  local _launcher_wine_env=""
  if [[ -z "${real_proton_script}" ]]; then
    local _env_adds="$(get_wine_env_additions "${real_wine_path}")"
    local _bin_add="${_env_adds%%|*}"
    local _temp="${_env_adds#*|}"
    local _lib_add="${_temp%%|*}"
    local _loader_add="${_env_adds##*|}"
    _launcher_wine_env="export PATH=\"${_bin_add}:\${PATH}\"
export LD_LIBRARY_PATH=\"${_lib_add}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}\"
export WINELOADER=\"${_loader_add}\""
  fi

  local _launcher_overrides="dxgi=n"
  if [[ "${controller_mode}" == "true" || "${steam_deck}" == "true" ]]; then
    _launcher_overrides="dxgi=n;xinput1_3=n"
  fi
  if [[ "${wayland_cursor_fix}" == "true" ]]; then
    _launcher_overrides="${_launcher_overrides};winex11.drv="
  fi

  local _launcher_sdl_logic=""
  if [[ "${controller_mode}" == "true" || "${steam_deck}" == "true" ]]; then
    _launcher_sdl_logic="export SDL_JOYSTICK_HIDAPI=0
export SDL_JOYSTICK_HIDAPI_PS4=0
export SDL_JOYSTICK_HIDAPI_PS5=0
export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1

_sdl_db=\"\"
for _db_path in \\
  \"\${HOME}/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"\${HOME}/.config/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"/usr/share/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"/usr/local/share/SDL_GameControllerDB/gamecontrollerdb.txt\"; do
  if [[ -f \"\${_db_path}\" ]]; then _sdl_db=\"\${_db_path}\"; break; fi
done
[[ -n \"\${_sdl_db}\" ]] && export SDL_GAMECONTROLLERCONFIG_FILE=\"\${_sdl_db}\""
  fi

  local _launcher_sync_logic=""
  if [[ "${_is_proton}" == "true" ]]; then
    if [[ -c /dev/ntsync ]]; then
      _launcher_sync_logic="export WINE_NTSYNC=1"
    else
      _launcher_sync_logic="export WINEFSYNC=1"
    fi
  fi

  mkdir -p "$(dirname "${LAUNCHER_SCRIPT}")"

  local real_wineserver
  real_wineserver="$(dirname "${real_wine_path}")/wineserver"
  [[ ! -x "${real_wineserver}" ]] && real_wineserver="wineserver"

  local _steam_root="${HOME}/.steam/root"
  local _cand
  for _cand in "${HOME}/.local/share/Steam" "${HOME}/.steam/steam" "${HOME}/.steam/root" "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" "${HOME}/snap/steam/common/.local/share/Steam"; do
    if [[ -d "${_cand}" ]]; then _steam_root="${_cand}"; break; fi
  done

  # Part 1: setup-time values baked in as plain strings.
  # We use a sed pipe to strip the 2-space indentation so the shebang is valid.
  sed 's/^  //' > "${LAUNCHER_SCRIPT}" << EOF
  #!/usr/bin/env bash
  # Cluckers Central launcher — generated by script.sh on $(date)
  # Re-run script.sh to regenerate after updating Wine or the game.

  # Exit on error, undefined variable, or pipe failure.
  set -euo pipefail

  # Legacy Steam environment variables required by ProtonFixes and some
  # networking components to correctly identify the game and user.
  export SteamAppId="813820"
  export SteamGameId="813820"
  export STEAM_COMPAT_APP_ID="813820"
  export GAMEID="813820"
  export UMU_ID="813820"
  export SteamUser="${USER}"
  export SteamAppUser="${USER}"
  export SteamClientLaunch="1"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="${_steam_root}"
  export STEAM_COMPAT_DATA_PATH="${CLUCKERS_ROOT}"

  # Set PATH and LD_LIBRARY_PATH to include Wine's internal libraries and
  # binaries. Prepend them to any existing paths.
  ${_launcher_wine_env}

  export CLUCKERS_ROOT="${CLUCKERS_ROOT}"
  export WINEPREFIX="${WINEPREFIX}"
  export WINEARCH="win64"

  # Setup-time variables baked in as plain strings.
  USE_GAMESCOPE="${use_gamescope}"
  GS_ARGS="${GAMESCOPE_ARGS}"
  GAME_DIR="${GAME_DIR}"
  GAME_EXE_REL="${GAME_EXE_REL}"
  TOOLS_DIR="${TOOLS_DIR}"
  GATEWAY_URL="${GATEWAY_URL:-https://gateway-dev.project-crown.com}"
  HOST_X="${HOST_X:-157.90.131.105}"
  CREDS_FILE="${CLUCKERS_ROOT}/credentials.enc"

  # Suppress noisy Wine debug output. Set to "" to see full Wine diagnostics.
  export WINEDEBUG="-all"

  # Force native overrides for performance and crash prevention.
  export WINEDLLOVERRIDES="${_launcher_overrides}"

  # SDL and controller configuration.
  ${_launcher_sdl_logic}

  # Wine binary and optional Proton script resolved by find_wine() at setup time.
  WINE="${real_wine_path}"
  WINESERVER="${real_wineserver}"
  PROTON_SCRIPT="${real_proton_script}"

  # Sync primitives (ntsync/fsync).
  ${_launcher_sync_logic}

  # Ensure we run from the game directory for consistency.
  cd "${GAME_DIR}"

  # Gamescope PID (if used).
  _GS_PID=""    # PID of gamescope process group leader (gamescope path)
  _WINE_PID=""  # PID of wine process group leader (non-gamescope path)
EOF

  # Part 2: launch-time auth + game launch logic.
  # We also strip the indentation for the appended literal block.
  sed 's/^  //' >> "${LAUNCHER_SCRIPT}" << 'LAUNCHEOF'
# ---------------------------------------------------------------------------
# Authentication — direct calls to the Project Crown gateway API.
# Handles login, OIDC token, and content bootstrap without a Windows launcher.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/auth/login.go
# ---------------------------------------------------------------------------
_auth_result=$(python3 - "${CREDS_FILE}" "${GATEWAY_URL}" << 'AUTHEOF'
import base64, json, os, sys, urllib.request, urllib.error

creds_file = sys.argv[1]
gateway    = sys.argv[2].rstrip("/")

def _post(endpoint, payload):
    # URL format: /json/<command>
    url  = f"{gateway}/json/{endpoint}"
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        url, data=data,
        headers={
            "Content-Type": "application/json",
            # User-Agent must match the Windows launcher to avoid server rejection.
            # Set the expected User-Agent so the gateway accepts the request.
            "User-Agent": "CluckersCentral/1.1.68",
            "Accept": "*/*",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def _flex_bool(val):
    if isinstance(val, bool):   return val
    if isinstance(val, (int, float)): return val != 0
    if isinstance(val, str):    return val.lower() in ("true", "1", "yes")
    return False

# Load or prompt for credentials.
username = password = ""
if os.path.exists(creds_file):
    try:
        with open(creds_file) as f:
            line = f.read().strip()
        username, password = line.split(":", 1)
    except Exception:
        pass

if not username or not password:
    # stdin is consumed by the heredoc pipe, so read from /dev/tty directly.
    # Open separate fds for reading and writing to avoid seekability issues.
    import termios, tty as ttymod
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        tty_r = os.fdopen(os.dup(tty_fd), "r", buffering=1, closefd=True)
        tty_w = os.fdopen(tty_fd,          "w", buffering=1, closefd=True)
    except OSError as e:
        print(f"ERROR: Cannot open /dev/tty: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        tty_w.write("[cluckers] Enter your Project Crown credentials.\n")
        tty_w.write("Username: ")
        tty_w.flush()
        username = tty_r.readline().rstrip("\n")
        tty_w.write("Password: ")
        tty_w.flush()
        old = termios.tcgetattr(tty_r)
        try:
            ttymod.setraw(tty_r)
            password = ""
            while True:
                ch = tty_r.read(1)
                if ch in ("\n", "\r"):
                    break
                if ch == "\x7f":  # backspace
                    password = password[:-1]
                else:
                    password += ch
        finally:
            termios.tcsetattr(tty_r, termios.TCSADRAIN, old)
            tty_w.write("\n")
            tty_w.flush()
    finally:
        tty_r.close()
        tty_w.close()
    os.makedirs(os.path.dirname(creds_file), exist_ok=True)
    def secure_opener(path, flags):
        return os.open(path, flags, 0o600)
    with open(creds_file, "w", opener=secure_opener) as f:
        f.write(f"{username}:{password}")

# Login — exchange credentials for an access token.
try:
    print("[auth] Logging in...", file=sys.stderr)
    login = _post("LAUNCHER_LOGIN_OR_LINK",
                  {"user_name": username, "password": password})
except urllib.error.URLError as e:
    print(f"ERROR: Cannot reach gateway ({e})", file=sys.stderr)
    sys.exit(1)

if not _flex_bool(login.get("SUCCESS")):
    msg = login.get("TEXT_VALUE") or "unknown error"
    print(f"ERROR: Login failed: {msg}", file=sys.stderr)
    try:
        os.remove(creds_file)
    except OSError:
        pass
    sys.exit(1)

access_token = login.get("ACCESS_TOKEN", "")
if not access_token:
    print("ERROR: No access token in login response", file=sys.stderr)
    sys.exit(1)

# OIDC token — required by EAC for anti-cheat authentication.
try:
    print("[auth] Requesting OIDC token...", file=sys.stderr)
    oidc_resp = _post("LAUNCHER_EAC_OIDC_TOKEN",
                      {"user_name": username, "access_token": access_token})
    oidc_token = (oidc_resp.get("PORTAL_INFO_1")
                  or oidc_resp.get("STRING_VALUE")
                  or oidc_resp.get("TEXT_VALUE", ""))
except Exception as e:
    print(f"[auth] OIDC token failed: {e}", file=sys.stderr)
    oidc_token = ""

# Content bootstrap — 136-byte blob the game reads from shared memory at startup.
bootstrap_b64 = ""
try:
    print("[auth] Requesting content bootstrap...", file=sys.stderr)
    boot_resp = _post("LAUNCHER_CONTENT_BOOTSTRAP",
                      {"user_name": username, "access_token": access_token})
    raw = (boot_resp.get("PORTAL_INFO_1") or boot_resp.get("STRING_VALUE", ""))
    if raw:
        # Fix base64 padding if needed.
        missing_padding = len(raw) % 4
        if missing_padding:
            raw += "=" * (4 - missing_padding)

        decoded = base64.b64decode(raw)
        if len(decoded) != 136:
            print(f"[auth] WARNING: Unexpected bootstrap size: {len(decoded)} bytes (expected 136)", file=sys.stderr)

        if len(decoded) > 0:
            bootstrap_b64 = base64.b64encode(decoded).decode()
            print(f"[auth] Bootstrap received ({len(decoded)} bytes)", file=sys.stderr)
except Exception as e:
    print(f"[auth] Bootstrap failed: {e}", file=sys.stderr)
    pass

print(username)
print(access_token)
print(oidc_token)
print(bootstrap_b64)
AUTHEOF
)

if [[ $? -ne 0 ]]; then
  printf '\n[ERROR] Authentication failed. Check your credentials.\n' >&2
  exit 1
fi

_auth_username=$(printf '%s' "${_auth_result}" | sed -n '1p')
_auth_token=$(printf '%s'    "${_auth_result}" | sed -n '2p')
_auth_oidc=$(printf '%s'     "${_auth_result}" | sed -n '3p')
_auth_bootstrap=$(printf '%s' "${_auth_result}" | sed -n '4p')


# Temp files for OIDC token and bootstrap blob.
_oidc_tmp=$(mktemp /tmp/cluckers_oidc_XXXXXX)
_bootstrap_tmp=$(mktemp /tmp/cluckers_bootstrap_XXXXXX)

# Write OIDC token; game reads it via -eac_oidc_token_file.
printf '%s' "${_auth_oidc}" > "${_oidc_tmp}"

# Decode and write bootstrap blob (base64 → 136-byte binary file).
# shm_launcher.exe reads this file and maps it into shared memory.
if [[ -n "${_auth_bootstrap}" ]]; then
  printf '%s' "${_auth_bootstrap}" | base64 -d > "${_bootstrap_tmp}"
fi

# Convert Linux paths to Windows paths for Wine (Z: maps to /).
_oidc_wine=$(printf '%s' "${_oidc_tmp}" | sed 's|/|\\|g; s|^|Z:|')
_bootstrap_wine=$(printf '%s' "${_bootstrap_tmp}" | sed 's|/|\\|g; s|^|Z:|')
_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
_game_exe_wine=$(printf '%s' "${_game_exe}" | sed 's|/|\\|g; s|^|Z:|')

# Convert shm_launcher.exe path to Wine format. Proton's run() inserts
# "start.exe /unix" for executables with Unix paths (starting with "/"),
# which launches GUI-subsystem apps detached and returns immediately.
# Using a Wine Z: path makes Proton call wine64 directly, so it properly
# waits for shm_launcher.exe (and the game) to exit.
_shm_launcher_wine=$(printf '%s' "${TOOLS_DIR}/shm_launcher.exe" | sed 's|/|\\|g; s|^|Z:|')

# Shared-memory name — unique per session PID.
_shm_name="Local\\realm_content_bootstrap_$$"

# Game launch arguments — passed directly to the game executable.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/process.go
_game_args=(
  "-user=${_auth_username}"
  "-token=${_auth_token}"
  "-eac_oidc_token_file=${_oidc_wine}"
  "-hostx=${HOST_X}"
  "-Language=INT"
  "-dx11"
  "-content_bootstrap_size=136"
  "-seekfreeloadingpcconsole"
  "-nohomedir"
)

# Append bootstrap shared memory argument if a bootstrap blob is present.
if [[ -s "${_bootstrap_tmp}" ]]; then
  _game_args+=("-content_bootstrap_shm=${_shm_name}")
fi

# ---- Proton pre-flight -----------------------------------------------------
# When Proton upgrades a prefix, it replaces certain files with symlinks back
# to its own bundled copies. If a previous Wine/Proton version left real files
# at those paths, Proton's os.symlink() raises FileExistsError. We resolve
# this by scanning Proton's default_pfx template for symlinks and removing any
# corresponding real files from our prefix before Proton runs.
# Only clean up when Proton's creation_sync_guard is absent — that's when
# copy_pfx() will run and need a clean slate. Once copy_pfx() succeeds it
# writes creation_sync_guard, and subsequent runs use update_builtin_libs()
# which handles existing files correctly on its own.
if [[ -n "${PROTON_SCRIPT}" ]] && [[ ! -f "${WINEPREFIX}/creation_sync_guard" ]]; then
  _proton_root="$(dirname "${PROTON_SCRIPT}")"
  _pfx_template=""
  for _cand in \
    "${_proton_root}/dist/share/default_pfx" \
    "${_proton_root}/files/share/default_pfx" \
    "${_proton_root}/files/default_pfx" \
    "${_proton_root}/share/default_pfx" \
    "${_proton_root}/default_pfx"; do
    if [[ -d "${_cand}" ]]; then _pfx_template="${_cand}"; break; fi
  done
  if [[ -n "${_pfx_template}" ]] && [[ -d "${WINEPREFIX}/drive_c" ]]; then
    _cleaned=0
    while IFS= read -r -d '' _tl; do
      _rel="${_tl#"${_pfx_template}"/}"
      _target="${WINEPREFIX}/${_rel}"
      if [[ -e "${_target}" ]] || [[ -L "${_target}" ]]; then
        rm -f "${_target}"
        (( _cleaned++ )) || true
      fi
    done < <(find "${_pfx_template}" -type l -print0 2>/dev/null)
    (( _cleaned > 0 )) && printf '[INFO] Removed %d symlink conflict(s) before Proton launch.\n' "${_cleaned}" >&2
  fi
fi

# ---- Launch ---------------------------------------------------------------

# Prepare final command.
# If a Proton script is available, we use 'proton run' to launch the game.
# This ensures the game runs within the Steam Linux Runtime (pressure-vessel)
# container, which provides modern networking and crypto libraries (like GnuTLS)
# required by the Unreal Engine 3 ServerTravel match transition. Without it,
# the game may hang on the loading screen when entering a match.
if [[ -n "${PROTON_SCRIPT}" ]]; then
  # Prepare the launch command. We use 'env -u' to strip environment variables 
  # that conflict with Proton's internal management without unsetting them
  # globally, so they remain available for the cleanup section at the end.
  _launch_cmd=(env -u WINEPREFIX -u WINE -u LD_LIBRARY_PATH -u WINEFSYNC -u WINEESYNC "python3" "${PROTON_SCRIPT}" "waitforexitandrun")
else
  _launch_cmd=("${WINE}")
fi
if [[ -s "${_bootstrap_tmp}" ]]; then
  _game_args=("${_shm_launcher_wine}" "${_bootstrap_wine}" "${_shm_name}" "${_game_exe_wine}" "${_game_args[@]}")
else
  _game_args=("${_game_exe}" "${_game_args[@]}")
fi

if [[ "${USE_GAMESCOPE}" == "true" ]]; then
  # shellcheck disable=SC2086
  env DBUS_SESSION_BUS_ADDRESS=/dev/null ${GS_ARGS} -- "${_launch_cmd[@]}" "${_game_args[@]}" &
  _PID=$!
else
  "${_launch_cmd[@]}" "${_game_args[@]}" &
  _PID=$!
fi

# Pass termination signals to the child process so it can shut down gracefully.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
_term() {
  trap '' INT TERM HUP
  if [[ -n "${_PID:-}" ]]; then
    kill -TERM "${_PID}" 2>/dev/null || true
    wait "${_PID}" 2>/dev/null || true
  fi
}
trap _term INT TERM HUP

# Wait for the game (or gamescope) to exit normally.
if [[ -n "${_PID:-}" ]]; then
  wait "${_PID}" 2>/dev/null || true
fi

# ---- Cleanup --------------------------------------------------------------
trap '' EXIT INT TERM HUP

# Graceful wineserver shutdown — terminates winedevice.exe, services.exe, 
# plugplay.exe and all Wine helpers for our specific prefix.
WINEPREFIX="${WINEPREFIX:-}" "${WINESERVER:-}" -k 2>/dev/null || true
# Wait for wineserver to fully stop so Steam doesn't see it as "Running".
WINEPREFIX="${WINEPREFIX:-}" "${WINESERVER:-}" -w 2>/dev/null || true

# Kill gamescope components explicitly by name as a fallback.
# These UI components can sometimes survive if gamescope crashed.
pkill -9 -x "gamescope-wl"    2>/dev/null || true
pkill -9 -f "gamescopereaper" 2>/dev/null || true

# Remove temp files created during this launcher session.
[[ -n "${_bootstrap_tmp:-}" ]] && rm -f "${_bootstrap_tmp}"
[[ -n "${_oidc_tmp:-}" ]] && rm -f "${_oidc_tmp}"

exit 0

LAUNCHEOF

  chmod +x "${LAUNCHER_SCRIPT}"
  ok_msg "Launcher script created at: ${LAUNCHER_SCRIPT}"

  # --------------------------------------------------------------------------
  # Step 9 — Create .desktop shortcut
  #
  # The .desktop file tells your application menu (GNOME, KDE, etc.) about
  # the game: its name, icon, and how to launch it. After install you will
  # find "Cluckers Central" in your app grid / start menu.
  # --------------------------------------------------------------------------
  step_msg "Step 9 — Creating desktop shortcut..."

  # Remove any existing Cluckers Central desktop entries that may have been
  # created by a previous install or by the Windows launcher running under Wine.
  local _shortcut_dirs=(
    "${HOME}/.local/share/applications"
    "${HOME}/.local/share/applications/wine"
    "${HOME}/Desktop"
    "/usr/share/applications"
  )
  local _sdir
  for _sdir in "${_shortcut_dirs[@]}"; do
    [[ -d "${_sdir}" ]] || continue
    while IFS= read -r _old; do
      [[ -f "${_old}" ]] || continue
      info_msg "Removing existing shortcut: ${_old}"
      rm -f "${_old}"
    done < <(find "${_sdir}" -maxdepth 2 \
      \( -name "*[Cc]luckers*" -o -name "*[Rr]ealm*[Rr]oyale*" \) \
      2>/dev/null)
  done

  mkdir -p "$(dirname "${DESKTOP_FILE}")"
  cat > "${DESKTOP_FILE}" << EOF
[Desktop Entry]
Name=${APP_NAME}
Comment=Play Cluckers Central (Realm Royale) on Linux
Exec=${LAUNCHER_SCRIPT}
Path=${HOME}/.local/bin
Icon=cluckers-central
Terminal=false
Type=Application
Categories=Game;
StartupNotify=true
StartupWMClass=ShippingPC-RealmGameNoEditor.exe
EOF

  chmod +x "${DESKTOP_FILE}"

  # Refresh the desktop database so the launcher appears in menus immediately.
  if command_exists update-desktop-database; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi
  ok_msg "Desktop shortcut created at: ${DESKTOP_FILE}"

  # --------------------------------------------------------------------------
  step_msg "Step 10 — Configuring Steam integration (optional)..."

  local steam_root=""
  local skip_steam="false"

  # If Steam is currently running, its shortcuts.vdf is held open and will be
  # overwritten when Steam exits — wiping any changes we write now. We warn the
  # user and give them a chance to close Steam before we proceed. We never
  # launch or kill Steam ourselves; that's the user's decision.
  # Detect Steam running under any of: native, Flatpak, or Snap packaging.
  # pgrep -x "steam" only matches the native binary name. Flatpak Steam runs
  # as "steam" inside a container but its host-visible process may differ.
  # We also check for the Flatpak host process name.
  if pgrep -x "steam" > /dev/null 2>&1 \
     || pgrep -f "com.valvesoftware.Steam" > /dev/null 2>&1; then
    warn_msg "Steam is currently running."
    warn_msg "Steam holds shortcuts.vdf open and will overwrite it when it closes."
    warn_msg "For the shortcut to survive, close Steam first:"
    warn_msg "  Steam menu → Exit  (or right-click the tray icon → Exit Steam)"
    warn_msg "You can also re-run this script after closing Steam."
    if [[ "${auto_mode}" == "false" ]]; then
      printf "\n  [PROMPT] Press ENTER when Steam is closed (or type 'skip' to skip): "
      local choice=""
      read -r choice
      if [[ "${choice,,}" == "skip" ]]; then
        info_msg "Skipping Steam integration (user requested)."
        skip_steam="true"
      fi
    else
      # In auto mode, write the shortcut now. Steam will overwrite it when it
      # exits, but the files will be correct — the user can restart Steam and
      # the shortcut will appear on the next launch.
      info_msg "Auto mode: writing Steam shortcut now. Restart Steam afterwards to see it."
    fi
  fi

  if [[ "${skip_steam}" == "false" ]]; then
    local candidate
    # Search all known Steam installation locations, in priority order:
    # native first, then Flatpak, then Snap. Multiple may coexist on the same
    # system; we take the first one that passes the Steam validity check.
    #
    # We validate using canonical Steam marker files (steam.sh or
    # ubuntu12_32/steamclient.so), matching cluckers/internal/wine/steamdir.go.
    # Checking only for userdata/ is unreliable — Flatpak Steam at data/Steam
    # may have userdata/ nested differently depending on the version.
    for candidate in \
      "${HOME}/.local/share/Steam" \
      "${HOME}/.steam/steam" \
      "${HOME}/.steam/root" \
      "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
      "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
      "${HOME}/snap/steam/common/.local/share/Steam"; do
      local _r
      _r=$(readlink -f "${candidate}" 2>/dev/null) || continue
      if [[ -f "${_r}/steam.sh" ]] || [[ -f "${_r}/ubuntu12_32/steamclient.so" ]]; then
        steam_root="${_r}"
        break
      fi
    done

    if [[ -z "${steam_root}" ]]; then
      warn_msg "Steam installation not found — skipping Steam integration."
      warn_msg "To add manually: add ${LAUNCHER_SCRIPT} as a non-Steam game in Steam."
    elif ! command_exists python3; then
      warn_msg "Python 3 not available — skipping Steam integration."
    else
      local steam_userdata="${steam_root}/userdata"
      local steam_user=""
      if [[ -d "${steam_userdata}" ]]; then
        # Pick the most-recently-modified userdata subdirectory as the active
        # Steam account. stat -c %Y is more portable than find -printf '%T@'
        # (which is a GNU extension not available on all systems).
        steam_user=$(
          find "${steam_userdata}" -maxdepth 1 -mindepth 1 -type d \
            2>/dev/null \
          | while IFS= read -r _d; do
              printf '%s %s\n' "$(stat -c '%Y' "${_d}" 2>/dev/null || echo 0)" \
                               "$(basename "${_d}")"
            done \
          | sort -rn \
          | awk 'NR==1 {print $2}'
        )
      fi

      if [[ -z "${steam_user}" ]]; then
        warn_msg "No Steam user account found — skipping Steam integration."
      else
        info_msg "Configuring Steam for user ${steam_user}..."

        USER_CONFIG_DIR="${steam_userdata}/${steam_user}/config" \
        LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
        ICON_PATH_ENV="${ICON_PATH}" \
        APP_NAME_ENV="${APP_NAME}" \
        STEAM_GRID_PATH_ENV="${STEAM_GRID_PATH}" \
        STEAM_HERO_PATH_ENV="${STEAM_HERO_PATH}" \
        STEAM_LOGO_PATH_ENV="${STEAM_LOGO_PATH}" \
        STEAM_WIDE_PATH_ENV="${STEAM_WIDE_PATH}" \
        STEAM_HEADER_PATH_ENV="${STEAM_HEADER_PATH}" \
        STEAM_ICO_PATH_ENV="${STEAM_ICO_PATH}" \
        python3 - << 'PYEOF'
"""Adds Cluckers Central to Steam as a non-Steam shortcut."""

import binascii
import os
import shutil
import time

import vdf  # pip install vdf

USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER        = os.environ["LAUNCHER_ENV"]
ICON_PATH       = os.environ["ICON_PATH_ENV"]
APP_NAME        = os.environ["APP_NAME_ENV"]
STEAM_GRID      = os.environ.get("STEAM_GRID_PATH_ENV", "")
STEAM_HERO      = os.environ.get("STEAM_HERO_PATH_ENV", "")
STEAM_LOGO      = os.environ.get("STEAM_LOGO_PATH_ENV", "")
STEAM_WIDE      = os.environ.get("STEAM_WIDE_PATH_ENV", "")
STEAM_HEADER    = os.environ.get("STEAM_HEADER_PATH_ENV", "")
STEAM_ICO       = os.environ.get("STEAM_ICO_PATH_ENV", "")

_OK   = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam non-Steam shortcut ID for the given exe + name pair.

    Steam computes the shortcut ID from the raw (unquoted) exe path concatenated
    with the app name. The Exe field in shortcuts.vdf is stored quoted, but the
    ID itself is derived from the unquoted path. Verified against the original
    working version of this script and the Steam source behaviour.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id    = compute_shortcut_id(LAUNCHER, APP_NAME)
# For the shortcuts.vdf file, Steam expects a signed 32-bit integer.
shortcut_appid = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)

os.makedirs(USER_CONFIG_DIR, exist_ok=True)

# -- shortcuts.vdf: add non-Steam game entry --------------------------------
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
try:
    if os.path.exists(shortcuts_path):
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
    else:
        shortcuts = {"shortcuts": {}}

    sc = shortcuts.setdefault("shortcuts", {})

    # Remove any existing entry for this launcher to avoid duplicates.
    keys_to_delete = [
        k for k, v in sc.items()
        if isinstance(v, dict)
        and LAUNCHER in v.get("Exe", v.get("exe", ""))
    ]
    for k in keys_to_delete:
        del sc[k]

    # Steam requires Exe and StartDir to be quoted strings in shortcuts.vdf.
    # Without quotes Steam may fail to launch the non-Steam shortcut.
    # Source: Valve's internal format, reproduced by steam-rom-manager.
    quoted_exe = f'"{LAUNCHER}"'
    start_dir  = f'"{os.path.dirname(LAUNCHER)}"'
    # Use the Steam community ICO as the Steam shortcut icon (shortcuts.vdf
    # "icon" field). Fall back to ICON_PATH if the ICO was not downloaded.
    # The desktop .desktop file uses Icon=cluckers-central (theme name lookup),
    # not an absolute path, so ICON_PATH is only used here as a fallback.
    icon_path = STEAM_ICO if STEAM_ICO and os.path.exists(STEAM_ICO) else ICON_PATH
    # LaunchOptions: leave empty — the launcher script handles
    # all launch arguments internally.
    launch_opts = ""

    next_key = str(len(sc))
    sc[next_key] = {
        "appid":              shortcut_appid,
        "AppName":            APP_NAME,
        "Exe":                quoted_exe,
        "StartDir":           start_dir,
        "icon":               icon_path,
        "ShortcutPath":       "",
        "LaunchOptions":      launch_opts,
        "IsHidden":           0,
        "AllowDesktopConfig": 1,
        "AllowOverlay":       1,
        "openvr":             0,
        "Devkit":             0,
        "DevkitGameID":       "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime":       int(time.time()),
        "FlatpakAppID":       "",
        "tags":               {},
    }

    with open(shortcuts_path, "wb") as fh:
        vdf.binary_dump(shortcuts, fh)

    # -- Steam Library Artwork: grid/hero/logo ------------------------------
    # Steam stores non-Steam game artwork in userdata/<uid>/config/grid/.
    # Files are named <appid><suffix>.<ext> where appid is derived from the
    # shortcut's CRC32. Two ID formats are in use depending on Steam version:
    #
    #   long_id  = (unsigned_crc << 32) | 0x02000000
    #     Modern Steam (post-2019) uses this 64-bit ID for grid/ filenames.
    #     This is what tools like Heroic, Lutris, and steam-rom-manager write.
    #
    #   unsigned_crc  = crc32(exe+name) | 0x80000000
    #     Older Steam versions used this 32-bit ID directly.
    #
    # We write both formats so the artwork appears regardless of Steam version.
    #
    # Suffix conventions (verified against Steam client source and community):
    #   p        — Vertical grid / portrait poster  (600×900)
    #   (none)   — Horizontal grid / wide cover     (616×353)
    #   _hero    — Library hero / banner background (3840×1240 for 2x)
    #   _logo    — Logo banner                      (1280×720 with background)
    #   _header  — Small header / capsule           (460×215)
    #
    # Sources:
    #   https://www.steamgriddb.com/blog/backgrounds-and-logos
    #   https://github.com/nicowillis/steam-rom-manager
    #   https://github.com/lutris/lutris/blob/master/lutris/services/steam.py
    # grid/ lives inside config/, not one level up — USER_CONFIG_DIR is
    # already userdata/<uid>/config so grid/ is a direct subdirectory.
    grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
    os.makedirs(grid_dir, exist_ok=True)

    # Artwork suffix mapping — verified from steam-rom-manager source and img-sauce.
    # Steam stores non-Steam game artwork under two ID formats (both written so
    # the correct image appears regardless of Steam client version):
    #
    #   unsigned_id  = crc32(exe+name) | 0x80000000   — legacy 32-bit prefix
    #   long_id      = (unsigned_id << 32) | 0x02000000 — modern 64-bit prefix
    #                  (used by Steam post-2019 / Big Picture / Steam Deck)
    #
    # community assets label → grid/ suffix → source file
    # library_capsule     2x → p            → library_600x900_2x.jpg  (600×900 portrait)
    # main_capsule           → (empty)      → capsule_616x353.jpg     (616×353 wide cover)
    # library_hero        2x → _hero        → library_hero_2x.jpg     (3840×1240 banner)
    # logo                2x → _logo        → logo_2x.png             (1280×720 logo banner)
    # header                 → _header      → header.jpg              (460×215 header)
    art_map = {
        STEAM_GRID:   "p",       # portrait poster  (600×900)
        STEAM_WIDE:   "",        # wide cover       (616×353)
        STEAM_HERO:   "_hero",   # hero background  (3840×1240)
        STEAM_LOGO:   "_logo",   # logo banner      (1280×720)
        STEAM_HEADER: "_header", # header tile      (460×215)
    }

    # Write artwork for both ID formats so the images appear in all Steam versions.
    long_id = (unsigned_id << 32) | 0x02000000
    for grid_id in (str(unsigned_id), str(long_id)):
        for src, suffix in art_map.items():
            if not src or not os.path.exists(src):
                continue
            ext = os.path.splitext(src)[1]
            dest = os.path.join(grid_dir, f"{grid_id}{suffix}{ext}")
            try:
                shutil.copy2(src, dest)
            except Exception:
                pass

    # -- localconfig.vdf: set logo position ---------------------------------
    localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
    if os.path.exists(localconfig_path):
        try:
            with open(localconfig_path, encoding="utf-8", errors="replace") as fh:
                lc = vdf.load(fh)
            
            apps = lc.setdefault("UserLocalConfigStore", {}).setdefault("Software", {}).setdefault("Valve", {}).setdefault("Steam", {}).setdefault("apps", {})
            # localconfig.vdf uses the UNSIGNED 32-bit CRC ID as the key.
            app = apps.setdefault(str(unsigned_id), {})
            app["logo_position"] = {
                "pinned_position": "BottomLeft",
                "width_pct": "36.44186046511628",
                "height_pct": "100"
            }
            
            with open(localconfig_path, "w", encoding="utf-8") as fh:
                vdf.dump(lc, fh, pretty=True)
        except Exception as exc:
            print(f"{_WARN} Could not update logo position in localconfig.vdf: {exc}")

    print(f"{_OK} Added Cluckers Central to Steam library (including artwork).")
except Exception as exc:  # pylint: disable=broad-except
    print(f"{_WARN} Could not update shortcuts.vdf: {exc}")

PYEOF
    fi
  fi
fi

# --------------------------------------------------------------------------
# Install complete
# --------------------------------------------------------------------------
  printf "\n"
  # --------------------------------------------------------------------------
  # Step 11 — Game patches (Steam Deck or controller)
  #
  # Applies patches to game config files for Steam Deck or generic controller
  # support:
  #
  #   1. RealmSystemSettings.ini — force fullscreen at 1280×800 (Steam Deck only).
  #
  #   2. DefaultInput.ini / RealmInput.ini / BaseInput.ini — remove the
  #      "Count bXAxis" and "Count bYAxis" mouse-axis counters. These counters
  #      cause the engine to switch from gamepad mode to keyboard/mouse mode
  #      under Wine whenever the mouse moves.
  #
  #   3. controller_neptune_config.vdf — deploy the custom Steam Deck button
  #      layout template (Steam Deck only).
  #
  # Safe to run multiple times — all patches are idempotent.
  # --------------------------------------------------------------------------
  step_msg "Step 11 — Applying game patches..."

  if [[ "${steam_deck}" == "true" ]] && ! is_steam_deck; then
    warn_msg "Steam Deck hardware not detected (board_vendor != Valve)."
    warn_msg "Applying patches anyway as --steam-deck / -d was passed."
  fi

  apply_game_patches "${GAME_DIR}" "${steam_deck}" "${controller_mode}"

  # --------------------------------------------------------------------------
  # Step 12 — Verifying account
  #
  # Ensures the user can log in before finishing. This step is skipped in
  # auto mode if credentials already exist.
  # --------------------------------------------------------------------------
  if [[ "${auto_mode}" == "false" ]] || [[ ! -f "${CREDS_FILE}" ]]; then
    step_msg "Step 12 — Verifying account..."
    
    while true; do
      if [[ -f "${CREDS_FILE}" ]]; then
        info_msg "Credentials found. Verifying existing account..."
      else
        info_msg "No credentials found. Please log in."
      fi

      # Run verification via Python (same logic as launcher).
      _auth_status=$(PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}" \
      python3 - "${CREDS_FILE}" "${GATEWAY_URL}" << 'AUTHEOF'
import base64, json, os, sys, urllib.request, urllib.error, termios, tty as ttymod

creds_file = sys.argv[1]
gateway    = sys.argv[2].rstrip("/")

def _post(endpoint, payload):
    url  = f"{gateway}/json/{endpoint}"
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "User-Agent": "CluckersCentral/1.1.68", "Accept": "*/*"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def _flex_bool(val):
    if isinstance(val, bool): return val
    if isinstance(val, (int, float)): return val != 0
    if isinstance(val, str): return val.lower() in ("true", "1", "yes")
    return False

username = password = ""
if os.path.exists(creds_file):
    try:
        with open(creds_file) as f:
            line = f.read().strip()
        username, password = line.split(":", 1)
    except Exception: pass

if not username or not password:
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        tty_r = os.fdopen(os.dup(tty_fd), "r", buffering=1, closefd=True)
        tty_w = os.fdopen(tty_fd,          "w", buffering=1, closefd=True)
    except OSError:
        print("FAIL:Cannot open /dev/tty for input")
        sys.exit(1)
    try:
        tty_w.write("\nEnter your Project Crown credentials.\nUsername: ")
        tty_w.flush()
        username = tty_r.readline().rstrip("\n")
        tty_w.write("Password: ")
        tty_w.flush()
        old = termios.tcgetattr(tty_r)
        try:
            ttymod.setraw(tty_r)
            password = ""
            while True:
                ch = tty_r.read(1)
                if ch in ("\n", "\r"): break
                if ch == "\x7f": password = password[:-1]
                else: password += ch
        finally:
            termios.tcsetattr(tty_r, termios.TCSADRAIN, old)
            tty_w.write("\n")
            tty_w.flush()
    finally:
        tty_r.close()
        tty_w.close()

try:
    login = _post("LAUNCHER_LOGIN_OR_LINK", {"user_name": username, "password": password})
    if _flex_bool(login.get("SUCCESS")):
        os.makedirs(os.path.dirname(creds_file), exist_ok=True)
        def secure_opener(path, flags): return os.open(path, flags, 0o600)
        with open(creds_file, "w", opener=secure_opener) as f:
            f.write(f"{username}:{password}")
        print(f"OK:{username}")
    else:
        msg = login.get("TEXT_VALUE") or "invalid credentials"
        print(f"FAIL:{msg}")
        if os.path.exists(creds_file): os.remove(creds_file)
except Exception as e:
    print(f"FAIL:Connection error ({e})")
AUTHEOF
)
      if [[ "${_auth_status}" == OK:* ]]; then
        ok_msg "Account verified: ${_auth_status#OK:}"
        break
      else
        error_msg="${_auth_status#FAIL:}"
        warn_msg "Verification failed: ${error_msg:-unknown error}"
        if [[ "${auto_mode}" == "true" ]]; then
          warn_msg "Skipping account verification in auto mode."
          break
        fi
        printf "  Try again? (Y/n): "
        read -r _retry
        if [[ "${_retry}" =~ ^[Nn] ]]; then break; fi
      fi
    done
  fi

  fi # end skip_heavy_steps

  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║              Installation complete!                  ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n" "${GREEN}" "${NC}"
  printf "\n"
  printf "  To start the game:\n"
  printf "    %b%s%b\n" "${BOLD}" "${LAUNCHER_SCRIPT}" "${NC}"
  printf "\n"
  printf "  Or launch from your application menu / Steam library.\n"
  printf "\n"
  printf "  If login fails, delete credentials and re-run:\n"
  printf "    rm ~/.cluckers/credentials.enc\n"
  printf "  If the game crashes, check the Wine log:\n"
  printf "    cat /tmp/cluckers_wine.log\n"
  printf "\n"
  printf "  To uninstall:\n"
  printf "    %b./script.sh --uninstall%b\n" "${BOLD}" "${NC}"
  printf "\n"
}

main "$@"
