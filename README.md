# Corsair K70 RGB MK.2 Onboard Hardware Profile Burner

A standalone, zero-dependency macOS CLI tool that reverse-engineers the Corsair iCUE legacy protocol to permanently program standalone hardware profiles into the onboard SPI NOR Flash / EEPROM of the **Corsair K70 RGB MK.2 Mechanical Gaming Keyboard** (`VID: 0x1B1C`, `PID: 0x1B49`, Firmware 3.24+).

---

## ⚡ Key Highlights
- **100% Standalone Hardware Mode**: Profiles are flashed directly onto the keyboard's physical SPI NOR Flash chip.
- **Zero Background Footprint**: Requires **0 background processes, 0 daemons, 0 LaunchAgents, and 0 MB RAM**.
- **Permanent Retention**: Settings persist across reboots, shutdowns, and when plugged into different machines (macOS, Windows, Linux).
- **No Root / Sudo Required**: Uses the standard vendor lighting interface (`0xFFC2:0x0004`) under user-space permissions.

---

## 🎨 Profile Specifications

| Slot | Profile Name | Color | Hex Code | RGB Values | Description |
| :---: | :--- | :--- | :---: | :---: | :--- |
| **Slot 1** | **Profile 1** *(Active)* | **Pure Carmine Red** | `#FF0000` | `255, 0, 0` | Pure red static lighting |
| **Slot 2** | **Profile 2** | **Night Vision Green** | `#46FF00` | `70, 255, 0` | High-contrast tactical green |
| **Slot 3** | **Profile 3** | **Glacier Ice Cyan** | `#9ADCE7` | `154, 220, 231` | Soft glacier ice blue |

---

## 🕹️ Top Cluster & WinLock Button Controls
- **Windows Lock Key Action**: Disabled at the hardware level (`PROFILE.DAT` byte 1 = `0x00` and vendor command `0x07, 0x48, 0x00, 0x00`). Pressing the WinLock key will never disrupt or lock modifier keys on macOS.
- **Top Cluster RGB Synchronization**: WinLock (Locked & Unlocked states), Profile, and Brightness LEDs are dynamically synchronized 1:1 with each slot's profile color in `PROFILE.I` (bytes 253–264).
- **Physical Switching**: Switch between profiles anytime by pressing the physical **Profile Button** located on the top-left corner of the keyboard.

---

## 🔬 Reverse-Engineered Protocol & Storage Architecture
The Corsair K70 RGB MK.2 runs on an NXP LPC ARM Cortex microcontroller interfacing with an SPI NOR Flash storage system. Each profile slot is maintained as a directory containing 7 structured files:

1. `PROFILE.DAT` (4 bytes): Profile metadata and hardware WinLock disable flag.
2. `PROFILE.I` (268 bytes): 128-bit GUID, 16-bit Hardware ID, Profile Name (UTF-16LE), and top-row button RGB color mapping.
3. `PROFILE.MAP` (4 bytes): File allocation table identifier.
4. `lght_00.d` (37 bytes): Static lighting effect descriptor.
5. `lght_00.k` (160 bytes): Physical key LED matrix lookup table (156 addressable keys).
6. `lght_00.r` (1024 bytes): RGB color data array (`[R, G, B, Alpha]` per key).
7. `lghtcnt.cnt` (4 bytes): Active lighting effect count.

### Protocol Timing & Settle Details
- **SPI Flash Sector Erase & Write**: Requires a quiet period of **5.0 seconds** after `commitProfileChanges` (`0x07, 0x17, 0x0E, 0x00`) to prevent SPI bus collision.
- **Hardware Status Codes**:
  - `0x00`: Success / Idle
  - `0x01`: Operation in progress
  - `0x03`: File already opened (handled via automated `closeFile` + retry)
  - `0x0C`: `SyncInProgress` (handled via automated wait loop)
  - `0x0D`: `SyncNotStarted` / `FlashBusy` (handled via automated wait loop)

---

## 🚀 How to Run

### Option 1: Run Directly via Swift Interpreter
```bash
./K70HardwareProfileBurner.swift
```

### Option 2: Compile to an Optimized Native Binary
```bash
swiftc -O K70HardwareProfileBurner.swift -o k70_burner
./k70_burner
```

If the keyboard's USB endpoint is currently busy or stalled, the program's built-in event loop will prompt you to briefly unplug the main keyboard cable (marked with the ⌨️ keyboard icon) and reconnect it; writing will begin automatically upon detection.
