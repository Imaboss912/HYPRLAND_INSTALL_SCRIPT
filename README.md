# Hyprland Install Script
A post-install setup script for Arch Linux, targeted at AMD hardware (Ryzen 5900X + Radeon 7900 XT).
Installs and configures a full Hyprland desktop with CachyOS performance tweaks, a complete app stack, and drops in all of my personal configs automatically.

---

## What the script does

- Adds CachyOS repositories and installs the `linux-cachyos` kernel with `scx-scheds` scheduler support (LAVD, tuned for Zen 3)
- Installs the full RADV/Mesa graphics stack optimised for RDNA3, including VA-API hardware video decode
- Sets up PipeWire (full stack: ALSA, PulseAudio, JACK) with correct user-level systemd services
- Installs Hyprland and the full desktop ecosystem: Waybar, Wofi, swww, swaync, hyprlock, hypridle, hyprsunset, hyprpolkit, cliphist
- Installs productivity apps: LibreOffice, Okular, Krita, Anki, Bitwarden
- Installs dev/monitoring tools: btop, fastfetch, Kitty, and more
- Installs AUR packages: hyprshot, qt6ct-kde, LM Studio, kew, Stremio, Maple Mono font
- Configures zram (ram/2, lz4) for improved responsiveness under heavy loads
- Detects and enables `amd_pstate=active` (EPP) for Zen 3 power management
- Enables the `scx` systemd service for userspace scheduler management
- Configures the `ly` display manager with correct Wayland session settings
- Writes a full `hyprland.conf` with personal keybinds, monitor layout, design settings, and all exec-once daemons
- Writes configs for Kitty, Waybar, Wofi, and fastfetch
- Optional gaming stack prompt: Steam, Lutris, Wine, and ROCm HIP SDK for LM Studio GPU acceleration on RDNA3

---

## Requirements

- A fresh Arch Linux base install (see Stage 1 below)
- A user account with sudo access
- Internet connection

---

## Stage 1 — Install the base system

Boot from an Arch ISO and use the built-in guided installer:

```bash
archinstall
```

Key choices when stepping through the menus:

| Option | What to pick |
|---|---|
| Language / locale | Your region |
| Mirrors | Your country |
| Drive | Your NVMe/SSD — `ext4` or `btrfs`, wipe the disk |
| Bootloader | `systemd-boot` or `grub` (script handles both) |
| Swap | **Skip** — the script configures zram |
| Profile | **Minimal** — no desktop, the script handles everything |
| Audio | **Skip** — the script installs PipeWire |
| Kernel | `linux` for now — the script replaces it with `linux-cachyos` |
| Network | `NetworkManager` |
| Root password | Set one |
| User account | Create your user and **tick sudo access** |

When the installer finishes, reboot and remove the USB.

---

## Stage 2 — Run the script

Log in as your user, then:

```bash
# If on WiFi, connect first
nmtui

# Download and run the script
curl -O https://raw.githubusercontent.com/Imaboss912/HYPRLAND_INSTALL_SCRIPT/main/arch_install.sh
chmod +x arch_install.sh
sudo bash arch_install.sh
```

The script will prompt you for:
- Your mirror country (for reflector optimisation)
- Whether to install the gaming stack (Steam / Lutris / Wine)
- Whether to install ROCm / HIP for LM Studio GPU acceleration (~2 GB)
- Whether to reboot when finished

Everything else is fully automated.

---

## After reboot

Log in via `ly` and Hyprland will start automatically. A few things to do on first login:

- **Set a wallpaper:** `swww img /path/to/wallpaper`
- **Qt theming:** run `qt6ct` and configure your theme — if KDE apps like Okular look off, make sure `qt6ct-kde` is selected
- **Test Vulkan:** `vkcube`
- **Test VA-API:** `vainfo`
- **Verify amd_pstate:** `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver` (should read `amd-pstate-epp`)
- **Multi-GPU ROCm:** if you have more than one GPU, add `env = HIP_VISIBLE_DEVICES,0` to `hyprland.conf`

---

## Keybinds (quick reference)

| Bind | Action |
|---|---|
| `SUPER + Enter` | Terminal (Kitty) |
| `SUPER + D` | App launcher (Wofi) |
| `SUPER + E` | File manager (PCManFM-Qt) |
| `SUPER + Q` | Kill focused window |
| `SUPER + F` | Fullscreen |
| `SUPER + SHIFT + Space` | Toggle floating |
| `SUPER + SHIFT + S` | Screenshot (region → ~/Pictures/Screenshots) |
| `SUPER + V` | Clipboard history (cliphist) |
| `SUPER + 1–9` | Switch workspace |
| `SUPER + SHIFT + 1–9` | Move window to workspace |
| `SUPER + ALT + P` | Play / Pause (kew) |
| `SUPER + ALT + Left/Right` | Previous / Next track (kew) |
| `SUPER + ALT + Up/Down` | Volume +/- 5% |
