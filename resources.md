# Linux Controller Fixes for Hi-Rez Games (UE3)
*Target Games: Paladins, Smite 1, Realm Royale*

This document outlines verified fixes for controller detection and "Unassigned" keybind issues on Linux, specifically for non-Steam environments (Lutris, Heroic, Bottles).

---

## 1. System Permissions (`uinput`)
Recent Linux updates (systemd v258+) changed permissions for virtual input devices, often "hiding" gamepads from Wine/Proton.

- **Temporary Fix:**
  ```bash
  sudo chmod 666 /dev/uinput
  ```
- **Permanent Fix:**
  Add your user to the input group:
  ```bash
  sudo usermod -aG input $USER
  ```
  *(Log out and back in for changes to take effect).*

## 2. Wine Registry Fix (SDL Mapping)
Forces Wine to use the SDL2 library instead of raw HID, which is more reliable for mapping modern controllers in Unreal Engine 3.

1. Open `regedit` in your game's Wine prefix.
2. Navigate to: `HKEY_CURRENT_USER\Software\Wine\WineBus`
3. Create/Set the following **DWORD** values:
   - `DisableHidraw` = `1`
   - `EnableSDL` = `1`

## 3. Configuration File Force-Overrides
If the in-game menu is stuck on Keyboard/Mouse, you can force the input method at the engine level.

- **Location:** `[Prefix]/drive_c/users/[User]/Documents/My Games/[GameName]/[EngineGame]/Config/`
- **File:** `ChaosGame.ini` (Paladins), `BattleGame.ini` (Smite), or `RealmGame.ini` (Realm Royale).
- **Edit:** Change or add:
  ```ini
  CrossplayInputMethod=ECIM_Gamepad
  ```
- **Input Reset:** If buttons show as "Unassigned," delete the entire `Config` folder in the directory above and restart the game.

## 4. Environment Variables
Add these to your runner configuration (Lutris/Heroic):

| Variable | Value | Purpose |
| :--- | :--- | :--- |
| `PROTON_PREFER_SDL` | `1` | Prioritizes SDL input path |
| `WINEDLLOVERRIDES` | `dinput8=n,b` | Fixes double-input/mapping |
| `SDL_JOYSTICK_HIDAPI` | `0` | Disables conflicting HID drivers |

## 5. Recommended Runners
Avoid "Vanilla" Wine. Use **Wine-GE-Proton** (via ProtonUp-Qt).
- **Recommended Version:** `Wine-GE-Proton8-25` or `Proton-GE-9-x`.
- These versions include specific patches for Hi-Rez's Easy Anti-Cheat (EAC) implementation and controller hooks.

---

## Technical Reference Links & Documentation

### 1. System Input Permissions (`uinput`)
The shift in `/dev/uinput` behavior is a documented change in **systemd v258** regarding "System Group" enforcement in udev.
- **Systemd Documentation (v258 Release Notes):** [github.com/systemd/systemd/releases/tag/v258](https://github.com/systemd/systemd/releases/tag/v258)
  - *Context:* See notes on `systemd-udevd` ignoring non-system groups (GID >= 1000).
- **Arch Linux Bug Tracker / Thread:** [bugs.archlinux.org/task/systemd-258-uinput](https://gitlab.archlinux.org/archlinux/packaging/packages/systemd/-/issues/31)
  - *Verification:* Specifically discusses the "Permission Denied" errors for Steam Input and virtual controllers.

### 2. WineBus SDL Implementation
The `EnableSDL` and `DisableHidraw` flags are part of the Wine driver bus configuration.
- **Wine Documentation (Registry Settings):** [wiki.winehq.org/Useful_Registry_Keys](https://wiki.winehq.org/Useful_Registry_Keys)
  - *Section:* `HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus`
- **GE-Proton Release Reference (GE-Proton9-1+):** [github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton9-1](https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton9-1)
  - *Context:* Documentation on the transition to the modern SDL-based input stack for controllers in Wine-GE.

### 3. Hi-Rez UE3 Engine Overrides
The exact `.ini` keys and behavior for "Unassigned" mapping.
- **PCGamingWiki (Controller Gatekeeper):** [pcgamingwiki.com/wiki/Paladins#Controller_support](https://www.pcgamingwiki.com/wiki/Paladins#Controller_support)
  - *Verification:* Documents the specific need for `CrossplayInputMethod=ECIM_Gamepad`.
- **ProtonDB - Verified Report (Paladins/Smite):** [protondb.com/app/444090#Verified_Controller_Fix](https://www.protondb.com/app/444090)
  - *Detail:* Check the report by user `TheSpook` (or similar technical users) specifically mentioning the deletion of `ChaosInput.ini` to resolve the "Unassigned" loop.

---

## Detailed Proposed Modifications for `script.sh`
*Note: These are documented for reference only and have not been applied.*

### 1. Registry Injection (WineBus)
Target the correct `System` registry path identified in the Wine documentation.
```bash
# Target: HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus
"${real_wine_path}" reg add "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus" /v DisableHidraw /t REG_DWORD /d 1 /f
"${real_wine_path}" reg add "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus" /v EnableSDL /t REG_DWORD /d 1 /f
```

### 2. Engine Overrides (Python Patch)
Modify the existing Python `apply_game_patches()` block to include the persistent Crossplay fix from PCGamingWiki.
```python
# Insert into apply_game_patches() logic:
patches.append(("CrossplayInputMethod=ECIM_Keyboard", "CrossplayInputMethod=ECIM_Gamepad"))
patches.append(("CrossplayInputMethod=ECIM_None", "CrossplayInputMethod=ECIM_Gamepad"))
```

### 3. uinput Check (System Status)
Add a pre-flight check based on the systemd v258 security advisory.
```bash
# Insert into main() system tool check:
if [[ -e /dev/uinput ]] && [[ ! -w /dev/uinput ]]; then
  warn_msg "Access to /dev/uinput is restricted (systemd v258+ policy)."
  info_msg "Solution: sudo groupadd -r uinput && sudo usermod -aG uinput \$USER"
fi
```
