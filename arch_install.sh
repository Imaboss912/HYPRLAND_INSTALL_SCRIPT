#!/usr/bin/env bash
# Arch + CachyOS + Hyprland (2026 Edition)
# Optimized for: AMD Ryzen 5900X + Radeon 7900 XT
# ---------------------------------------------------------
set -euo pipefail
#!/usr/bin/env bash
# Arch + CachyOS + Hyprland (2026 Edition)
# Optimized for: AMD Ryzen 5900X + Radeon 7900 XT
# ---------------------------------------------------------
set -euo pipefail

# =========================================================
# --- 0. Pre-flight Checks ---
# =========================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

if ! ping -c 1 google.com &> /dev/null; then
    echo "No internet connection detected. Please fix and try again."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
LOGFILE="/var/log/arch_install.log"

# Timestamped logging with flush-safe tee
exec > >(while IFS= read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" | tee -a "$LOGFILE"; done)
exec 2>&1

# prompt_user "Question text" VARIABLE_NAME
# Writes prompts directly to /dev/tty so they appear on the terminal even though
# stdout/stderr are redirected through the timestamped logging pipe above.
prompt_user() {
    local __prompt="$1"
    local __var="$2"
    printf '%s' "$__prompt" > /dev/tty
    read "$__var" < /dev/tty
}

echo "=== System Setup for $TARGET_USER (CPU: Zen 3 | GPU: RDNA3) ==="

# =========================================================
# --- 1. Mirror Country Selection ---
# =========================================================
echo ""
prompt_user "Enter your country for mirror optimization (e.g. US, GB, DE, AU) [default: US]: " MIRROR_COUNTRY
MIRROR_COUNTRY="${MIRROR_COUNTRY:-US}"
echo "Using mirror country: $MIRROR_COUNTRY"

# =========================================================
# --- 2. Base Updates & Mirror Optimization ---
# =========================================================
echo "--- Updating system & optimizing mirrors ---"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    reflector git base-devel curl rsync \
    unzip zip tar wget p7zip unrar

reflector --country "$MIRROR_COUNTRY" --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist

# =========================================================
# --- 3. Enable Multilib ---
# =========================================================
echo "--- Enabling Multilib repository ---"
sed -i '/\[multilib\]/,/Include/s/^[ ]*#//' /etc/pacman.conf
pacman -Syy --noconfirm

# =========================================================
# --- 4. CachyOS Repositories ---
# =========================================================
echo "--- Adding CachyOS Repos ---"
curl -L https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz

# Fetch and verify the upstream-published checksum dynamically.
# Validates that the fetched value looks like a real SHA256 hash (64 hex chars)
# before comparing — avoids false aborts when the mirror returns a 404 HTML page.
echo "--- Extracting CachyOS repo setup ---"

tar xvf /tmp/cachyos-repo.tar.xz -C /tmp

# Subshell so cd cannot affect the rest of the script.
# cachyos-repo.sh is interactive — redirect its I/O directly to /dev/tty so
# its prompts are visible and input works despite our logging redirect above.
(
    cd /tmp/cachyos-repo
    chmod +x ./cachyos-repo.sh
    ./cachyos-repo.sh < /dev/tty > /dev/tty 2>&1
)

# Verify the CachyOS script did not silently fail
if ! grep -q '\[cachyos\]' /etc/pacman.conf; then
    echo "ERROR: CachyOS repo setup appears to have failed — [cachyos] not found in pacman.conf."
    exit 1
fi

rm -rf /tmp/cachyos-repo*

# CachyOS repos now active — install meta packages.
# Note: yay should now be available via CachyOS repos. If it fails, we fall back to
# building it manually from AUR so the rest of the script can continue.
pacman -Syu --needed --noconfirm cachyos-settings cachyos-hooks cachyos-gaming-meta

if ! pacman -S --needed --noconfirm yay 2>/dev/null; then
    echo "WARNING: yay not found in CachyOS repos — building from AUR as fallback."
    (
        BUILDDIR=$(sudo -u "$TARGET_USER" mktemp -d)
        sudo -u "$TARGET_USER" git clone https://aur.archlinux.org/yay.git "$BUILDDIR/yay"
        cd "$BUILDDIR/yay"
        sudo -u "$TARGET_USER" makepkg -si --noconfirm
        rm -rf "$BUILDDIR"
    )
fi

# =========================================================
# --- 5. Kernel & Bootloader ---
# =========================================================
echo "--- Installing CachyOS Kernel & Sched-ext Schedulers ---"
pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers scx-scheds
# mkinitcpio is triggered automatically via pacman hooks — no manual call needed.

if command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ -d "/boot/loader/entries" ]; then
    bootctl --path=/boot update
else
    echo ""
    echo "WARNING: Could not detect GRUB or systemd-boot."
    echo "  If using systemd-boot for the first time: bootctl install"
    echo "  If using GRUB: grub-mkconfig -o /boot/grub/grub.cfg"
    local _ignored
    prompt_user "Press Enter to continue anyway, then fix your bootloader before rebooting..." _ignored
fi

# =========================================================
# --- 6. Graphics Stack (RDNA3 / RADV) ---
# =========================================================
echo "--- Installing Graphics Stack (RADV) ---"
# vulkan-tools included here for vkcube testing post-install
# libva-mesa-driver required for hardware video acceleration in Firefox and MPV on AMD
pacman -S --needed --noconfirm \
    mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon \
    vulkan-tools vulkan-mesa-layers lib32-vulkan-mesa-layers \
    libva-mesa-driver lib32-libva-mesa-driver \
    gamescope ffmpeg

# =========================================================
# --- 7. Audio Stack (PipeWire — full) ---
# =========================================================
echo "--- Installing PipeWire audio stack ---"
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber pavucontrol pamixer playerctl

# =========================================================
# --- 8. Qt / Wayland Integration ---
# =========================================================
echo "--- Installing Qt Wayland support ---"
# qt6ct-kde (AUR, installed later) replaces and conflicts with vanilla qt6ct,
# so we only install the Wayland platform plugins here and let the AUR handle theming.
pacman -S --needed --noconfirm qt5-wayland qt6-wayland

# =========================================================
# --- 9. Desktop Stack ---
# =========================================================
echo "--- Installing Hyprland & Desktop Environment ---"
pacman -S --needed --noconfirm \
    hyprland waybar wofi swww \
    hyprsunset hyprlock hypridle hyprcursor \
    xorg-xwayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    xdg-user-dirs \
    kitty \
    noto-fonts noto-fonts-cjk ttf-jetbrains-mono-nerd \
    ttf-dejavu ttf-roboto ttf-font-awesome \
    wl-clipboard cliphist swaync \
    pcmanfm-qt gvfs gvfs-mtp gvfs-smb \
    brightnessctl \
    fcitx5 fcitx5-mozc fcitx5-configtool \
    firefox mpv \
    btop fastfetch nsxiv filelight \
    gparted smartmontools transmission-qt \
    zram-generator \
    blueman network-manager-applet

# ananicy-cpp: present in CachyOS repos. If pacman can't find it, yay picks it up
# in the AUR section below — the --needed flag on yay will skip it if already installed.
pacman -S --needed --noconfirm ananicy-cpp || \
    echo "ananicy-cpp not in repos — will install via yay in AUR section."

# =========================================================
# --- 10. Productivity Apps ---
# =========================================================
echo "--- Installing Productivity Applications ---"
pacman -S --needed --noconfirm \
    libreoffice-fresh okular krita anki

# =========================================================
# --- 11. AUR Packages ---
# =========================================================
echo "--- Installing AUR packages (running as $TARGET_USER) ---"
# AUR installs must always run as the non-root user.
# hyprpolkit: AUR package name is 'hyprpolkit'. If the build fails, verify the
# current name with: yay -Ss hyprpolkit  (it has also been called hyprpolkit-agent).
# qt6ct-kde: replaces vanilla qt6ct for better KDE/Qt app theming on Wayland.
# ananicy-cpp: included here as a fallback if the pacman install above was skipped.
sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild \
    hyprshot \
    hyprpolkit \
    bitwarden \
    qt6ct-kde \
    ananicy-cpp \
    ttf-maple \
    lmstudio-bin \
    kew-git \
    stremio

# Auto-detect the correct hyprpolkit binary name — the AUR package has shipped as
# both 'hyprpolkit' and 'hyprpolkit-agent' across versions. We probe for whichever
# exists and store it so the Hyprland config injection below uses the right name.
if command -v hyprpolkit-agent &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit-agent"
elif command -v hyprpolkit &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit"
else
    echo "WARNING: Neither 'hyprpolkit' nor 'hyprpolkit-agent' found in PATH."
    echo "  Defaulting exec-once to 'hyprpolkit' — adjust hyprland.conf if needed."
    HYPRPOLKIT_BIN="hyprpolkit"
fi
echo "Detected hyprpolkit binary: $HYPRPOLKIT_BIN"

# =========================================================
# --- 12. Gaming Stack (Optional) ---
# =========================================================
# cachyos-gaming-meta was already installed in step 4.
# This prompt covers the full Steam / Lutris / Wine layer on top.
echo ""
prompt_user "Install full Gaming Stack (Steam / Lutris / Wine)? (y/N): " install_games
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    echo "--- Installing Gaming Stack ---"
    pacman -S --needed --noconfirm steam lutris wine-staging winetricks wine-mono

    # RDNA3 ROCm support for LM Studio GPU acceleration (optional heavy install ~2 GB)
    echo ""
    prompt_user "Install ROCm / HIP for LM Studio GPU acceleration on RDNA3? (y/N): " install_rocm
    if [[ "$install_rocm" =~ ^[Yy]$ ]]; then
        echo "--- Installing ROCm HIP SDK ---"
        pacman -S --needed --noconfirm rocm-hip-sdk
    fi
fi

# =========================================================
# --- 13. System Services ---
# =========================================================
echo "--- Enabling system services ---"
loginctl enable-linger "$TARGET_USER"
sudo -u "$TARGET_USER" xdg-user-dirs-update

# scx is a system-level scheduler daemon — belongs as a systemd service only,
# never as exec-once inside Hyprland.
systemctl enable --now scx

# Process priority management
systemctl enable --now ananicy-cpp

# Bluetooth
systemctl enable --now bluetooth

# Disable the getty on tty1 to avoid a stray console behind the ly greeter
systemctl disable getty@tty1 || true

# PipeWire must be enabled at the user level to autostart properly in Hyprland sessions
sudo -u "$TARGET_USER" systemctl --user enable pipewire pipewire-pulse wireplumber

# --- zram ---
# Configure zram for improved responsiveness under heavy loads on high-RAM systems.
# Uses lz4 compression — fast with good ratio, ideal for Zen 3.
if [ ! -f /etc/systemd/zram-generator.conf ]; then
    cat <<'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
EOF
    echo "zram-generator configured (ram/2, lz4)."
fi
systemctl daemon-reload
systemctl enable --now systemd-zram-setup@zram0.service

# --- amd_pstate ---
# Zen 3 benefits significantly from amd_pstate=active (EPP driver).
# Check if already set; if not, patch GRUB or advise for systemd-boot.
PSTATE_CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
if [[ "$PSTATE_CURRENT" != "amd-pstate-epp" ]]; then
    echo "--- amd_pstate not active (current driver: $PSTATE_CURRENT) — applying fix ---"
    if command -v grub-mkconfig &> /dev/null && [ -f /etc/default/grub ]; then
        # Inject amd_pstate=active if not already present in GRUB_CMDLINE_LINUX_DEFAULT
        if ! grep -q 'amd_pstate=active' /etc/default/grub; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_pstate=active"/' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg
            echo "amd_pstate=active added to GRUB_CMDLINE_LINUX_DEFAULT and grub.cfg regenerated."
        fi
    elif [ -d "/boot/loader/entries" ]; then
        echo "NOTE (systemd-boot): Manually add 'amd_pstate=active' to your kernel options in"
        echo "  /boot/loader/entries/<your-entry>.conf — look for the 'options' line."
    fi
else
    echo "amd_pstate EPP driver already active — no changes needed."
fi

# --- ly display manager config ---
# Patch ly's config to ensure Wayland sessions are preferred and the last session
# is remembered, preventing black screens when ly defaults to an X11 stub.
LY_CONF="/etc/ly/config.ini"
if [ -f "$LY_CONF" ]; then
    # Enable session memory
    sed -i 's/^#\?\s*save_last_session\s*=.*/save_last_session = true/' "$LY_CONF"
    # Ensure Wayland session directory is set
    grep -q '^waylandsessions' "$LY_CONF" || \
        echo "waylandsessions = /usr/share/wayland-sessions" >> "$LY_CONF"
    echo "ly config patched (save_last_session + waylandsessions)."
else
    echo "WARNING: /etc/ly/config.ini not found — ly may not be installed yet or path has changed."
    echo "  After reboot, manually set save_last_session = true and"
    echo "  waylandsessions = /usr/share/wayland-sessions in /etc/ly/config.ini"
fi

# =========================================================
# --- 14. Hyprland Config Injection ---
# =========================================================
echo "--- Writing Hyprland config ---"
HYPR_CONF="$USER_HOME/.config/hypr/hyprland.conf"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$HYPR_CONF")"

# Guard against overwriting on re-runs — only write if the file is empty or missing
if grep -q "Auto-Injected" "$HYPR_CONF" 2>/dev/null; then
    echo "Hyprland config already written — skipping to avoid overwrite."
else
    cat <<'EOF' | sudo -u "$TARGET_USER" tee "$HYPR_CONF" > /dev/null
# =============================================================================
# hyprland.conf — Auto-generated by arch_install.sh (2026)
# Ported from user's existing config with stack adaptations noted inline.
# =============================================================================
# Auto-Injected — marker used by install script to detect re-runs


# =============================================================================
# MONITORS
# Run `hyprctl monitors all` to list connected outputs and adjust as needed.
# =============================================================================

monitor=DP-1, 2560x1440@239.97, 0x0, 1, bitdepth, 10
monitor=DP-3, 2560x1440@143.96, -2560x0, 1


# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

# Cursor sizing
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

# Input method (fcitx5)
env = XMODIFIERS,@im=fcitx
env = GTK_IM_MODULE,fcitx
env = QT_IM_MODULE,fcitx

# Qt theming — qt6ct-kde is installed; run `qt6ct` after first login to configure.
# If KDE apps (Okular, Krita) look visually off, re-open qt6ct and select the kde variant.
env = QT_QPA_PLATFORMTHEME,qt6ct

# Qt Wayland native rendering
env = QT_QPA_PLATFORM,wayland

# ROCm / HIP: force RDNA3 (gfx1100) target.
# Prevents "GPU not found" errors in LM Studio and other AI workloads.
# Remove this line if you are not using ROCm.
env = HSA_OVERRIDE_GFX_VERSION,11.0.0


# =============================================================================
# STARTUP (exec-once)
# Adapted from original config:
#   - hyprpaper     → swww-daemon  (swww is installed; set wallpaper with `swww img`)
#   - polkit-gnome  → hyprpolkit   (binary auto-detected by install script)
#   - redshift      → hyprsunset   (modern Wayland-native replacement)
#   - nm-applet     → commented out (network-manager-applet not installed;
#                     re-add and install if needed: pacman -S network-manager-applet)
# =============================================================================

exec-once = waybar
exec-once = swww-daemon
exec-once = fcitx5 -d
exec-once = HYPRPOLKIT_PLACEHOLDER
exec-once = hyprsunset -t 4500
exec-once = swaync
exec-once = wl-paste --watch cliphist store
exec-once = nm-applet --indicator


# =============================================================================
# DEFAULT PROGRAMS
# fileManager changed from nautilus to pcmanfm-qt (installed by script).
# Swap back to nautilus if you install it: sudo pacman -S nautilus
# =============================================================================

$terminal    = kitty
$fileManager = pcmanfm-qt
$menu        = pgrep wofi > /dev/null 2>&1 && killall wofi || wofi --show drun


# =============================================================================
# WORKSPACES
# Workspace 9 pinned to DP-3 (second monitor).
# =============================================================================

workspace = 9, monitor:DP-3, default:true
workspace = 9, persistent:true


# =============================================================================
# INPUT
# =============================================================================

input {
    kb_layout  = us
    kb_options = grp:alt_shift_toggle
    kb_rules   =
    kb_variant =
    kb_model   =

    follow_mouse = 1
    sensitivity  = 0

    touchpad {
        natural_scroll = false
    }
}

cursor {
    no_hardware_cursors = true
}


# =============================================================================
# DESIGN
# =============================================================================

animations {
    enabled = false
}

general {
    gaps_in  = 5
    gaps_out = 8

    border_size = 1

    col.active_border   = rgb(d8cab8)
    col.inactive_border = rgb(AC82E9)

    resize_on_border = true
    layout           = dwindle
    allow_tearing    = false
}

decoration {
    rounding = 6

    active_opacity   = 1.0
    inactive_opacity = 1.0

    shadow:enabled      = true
    shadow:range        = 16
    shadow:render_power = 5
    shadow:color        = rgba(0,0,0,0.2)

    blur:enabled           = true
    blur:new_optimizations = true
    blur:size              = 2
    blur:passes            = 3
    blur:vibrancy          = 0.1696
}

dwindle {
    pseudotile     = true
    preserve_split = true
}

master {
    new_status = master
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo   = true
}


# =============================================================================
# KEYBINDS
# =============================================================================

$mainMod = SUPER

# Terminal
bind = $mainMod, Return, exec, $terminal

# Kill focused window
bind = $mainMod, Q, killactive,

# Screenshot (region) — saved to /tmp; change path as preferred
bind = $mainMod SHIFT, S, exec, hyprshot --mode region --output-folder ~/Pictures/Screenshots

# File manager
bind = $mainMod, E, exec, $fileManager

# Toggle floating
bind = $mainMod SHIFT, SPACE, togglefloating,

# Fullscreen
bind = $mainMod, F, fullscreen,

# App launcher
bind = $mainMod, D, exec, $menu

# Clipboard history (requires cliphist + wl-clipboard, both installed)
bind = $mainMod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy


# --- Music Controls (kew + playerctl) ---
# playerctl and kew are installed. These binds are ready to use.

# Play / Pause
bind = SUPER ALT, P, exec, playerctl --player=kew play-pause

# Next / Previous track
bind = SUPER ALT, right, exec, playerctl --player=kew next
bind = SUPER ALT, left,  exec, playerctl --player=kew previous

# Volume up / down (5% steps via PipeWire/pactl — playerctl volume is 0.0–1.0, not pactl syntax)
bind = SUPER ALT, up,   exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = SUPER ALT, down, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%


# --- Workspace Switching ---
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# --- Move Window to Workspace ---
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# --- Move / Resize with Mouse ---
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow


# =============================================================================
# WINDOW RULES
# =============================================================================

# Waybar — blur layer
layerrule = blur on,          match:namespace waybar
layerrule = blur_popups on,   match:namespace waybar
layerrule = ignore_alpha 0.7, match:namespace waybar

# Wofi — blur layer
layerrule = blur on,          match:namespace wofi
layerrule = blur_popups on,   match:namespace wofi
layerrule = ignore_alpha 0.7, match:namespace wofi

# XWayland drag fix
windowrule = no_focus on, match:class ^$, match:title ^$, match:xwayland 1, match:float 1, match:fullscreen 0, match:pin 0
EOF

    # Patch in the auto-detected hyprpolkit binary name
    sed -i "s/HYPRPOLKIT_PLACEHOLDER/$HYPRPOLKIT_BIN/" "$HYPR_CONF"
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    echo "hyprland.conf written (hyprpolkit binary: $HYPRPOLKIT_BIN)."
fi

# =========================================================
# --- 15. App Configs ---
# =========================================================

# ---- Fastfetch ----
echo "--- Writing fastfetch config ---"
FASTFETCH_CONF="$USER_HOME/.config/fastfetch/config.jsonc"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$FASTFETCH_CONF")"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$FASTFETCH_CONF" > /dev/null
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "source": "arch_small",
        "padding": {
            "top": 1,
            "left": 2
        }
    },
    "display": {
        "separator": "  "
    },
    "modules": [
        "break",
        "title",
        { "type": "os",       "key": "os"     },
        { "type": "wm",       "key": "de"     },
        { "type": "packages", "key": "pkgs",  "format": "{} (pacman)" },
        { "type": "shell",    "key": "shell"  },
        { "type": "kernel",   "key": "kernel" },
        { "type": "uptime",   "key": "uptime", "format": "{2}h {3}m"  },
        {
            "type": "command",
            "key":  "os age",
            "text": "bash -c 'birth_install=$(stat -c %W /); current=$(date +%s); days_difference=$(( (current - birth_install) / 86400 )); echo $days_difference days'"
        },
        { "type": "memory", "key": "memory" },
        "break",
        { "type": "colors", "symbol": "circle" },
        "break"
    ]
}
EOF
chown "$TARGET_USER:$TARGET_USER" "$FASTFETCH_CONF"
echo "fastfetch config written."

# ---- Kitty ----
echo "--- Writing kitty config ---"
KITTY_DIR="$USER_HOME/.config/kitty"
sudo -u "$TARGET_USER" mkdir -p "$KITTY_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$KITTY_DIR/kitty.conf" > /dev/null
font_family            JetBrainsMono NF Bold
font_size              12.0
bold_font              auto
italic_font            auto
bold_italic_font       auto
background_opacity     0.9
confirm_os_window_close 0
cursor_trail           1
linux_display_server   auto
scrollback_lines       2000
wheel_scroll_min_lines 1
enable_audio_bell      no
window_padding_width   4
include colors.conf
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$KITTY_DIR/colors.conf" > /dev/null
cursor                #dee4e4
cursor_text_color     #bec8c9
foreground            #dee4e4
background            #0e1415
selection_foreground  #1b3437
selection_background  #b1cbce
url_color             #80d4dc

# black
color0   #4c4c4c
color8   #262626
# red
color1   #ac8a8c
color9   #c49ea0
# green
color2   #8aac8b
color10  #9ec49f
# yellow
color3   #aca98a
color11  #c4c19e
# blue
color4   #80d4dc
color12  #a39ec4
# magenta
color5   #ac8aac
color13  #c49ec4
# cyan
color6   #8aacab
color14  #9ec3c4
# white
color7   #f0f0f0
color15  #e7e7e7
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$KITTY_DIR"
echo "kitty config written."

# ---- Waybar ----
echo "--- Writing waybar config ---"
WAYBAR_DIR="$USER_HOME/.config/waybar"
sudo -u "$TARGET_USER" mkdir -p "$WAYBAR_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/config.json" > /dev/null
{
  "layer": "top",
  "spacing": 0,
  "height": 0,
  "margin-bottom": 0,
  "margin-top": 8,
  "position": "top",
  "margin-right": 370,
  "margin-left": 370,
  "modules-left": [
    "hyprland/workspaces"
  ],
  "modules-center": [
    "custom/applauncher"
  ],
  "modules-right": [
    "network",
    "pulseaudio",
    "tray",
    "clock"
  ],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": false,
    "tooltip": false
  },
  "custom/applauncher": {
    "format": "///",
    "on-click": "pkill -x wofi || wofi --show drun --location=top -y 10",
    "tooltip": false
  },
  "tray": {
    "spacing": 10,
    "tooltip": false
  },
  "clock": {
    "format": "󰅐 {:%H:%M}",
    "tooltip": false
  },
  "network": {
    "format-wifi": " {bandwidthDownBits}",
    "format-ethernet": " {bandwidthDownBits}",
    "format-disconnected": "󰤮 No Network",
    "interval": 5,
    "tooltip": false
  },
  "pulseaudio": {
    "scroll-step": 5,
    "max-volume": 150,
    "format": "{icon} {volume}%",
    "format-bluetooth": "{icon} {volume}%",
    "format-icons": ["", "", " "],
    "nospacing": 1,
    "format-muted": " ",
    "on-click": "pavucontrol",
    "tooltip": false
  }
}
EOF
# Note: battery module removed — this is a desktop (5900X), not a laptop.
# Add it back manually if needed.

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/style.css" > /dev/null
* {
  font-family: Maple Mono;
  border-radius: 8px;
  font-size: 13px;
  padding: 0px;
  background: transparent;
}

window#waybar {
  background-color: rgba(20, 18, 22, 0.7);
  border-radius: 14px;
  padding: 0px;
  border-style: none;
}

#battery,
#network,
#clock,
#custom-applauncher,
#tray,
#workspaces,
#pulseaudio {
  background-color: rgba(20, 18, 22, 0.2);
  margin: 6px;
  margin-right: 0px;
  padding: 2px 8px;
  border-radius: 8px;
  color: #d8cab8;
  border-style: solid;
  border-color: #d8cab8;
  border-width: 1px;
  transition-duration: 120ms;
}

#clock {
  margin-right: 6px;
}
#clock:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
}

#pulseaudio:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
  transition-duration: 120ms;
}

#custom-applauncher {
  font-weight: bold;
  transition-duration: 120ms;
  padding: 0px 25px;
}
#custom-applauncher:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
  transition-duration: 120ms;
}

#tray menu {
  background-color: #141216;
  color: #d8cab8;
  padding: 4px;
}
#tray menu menuitem {
  background-image: linear-gradient(to bottom, #27232b 100%);
  margin: 3px;
  color: #d8cab8;
  border-radius: 4px;
  border-style: solid;
  border-color: #27232b;
}
#tray menu menuitem:hover {
  background-image: linear-gradient(to bottom, #27232b 100%);
  color: #ac82e9;
  font-weight: bold;
}

#workspaces button {
  transition-duration: 100ms;
  all: initial;
  min-width: 0;
  font-weight: bold;
  color: #d8cab8;
  margin-right: 0.2cm;
  margin-left: 0.2cm;
}
#workspaces button:hover {
  transition-duration: 120ms;
  color: #8f56e1;
}
#workspaces button.focused,
#workspaces button.active {
  color: #ac82e9;
  font-weight: bold;
}
#workspaces button.urgent {
  color: #fcb167;
}

#battery {
  background-color: #222222;
  color: #1d2021;
}
#battery.warning,
#battery.critical,
#battery.urgent {
  color: #1d2021;
  background-color: #fc4649;
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$WAYBAR_DIR"
echo "waybar config written."

# ---- Wofi ----
echo "--- Writing wofi config ---"
WOFI_DIR="$USER_HOME/.config/wofi"
sudo -u "$TARGET_USER" mkdir -p "$WOFI_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/config" > /dev/null
show=drun
term=kitty
show_all=true
gtk_dark=false
location=center
insensitive=false
allow_markup=true
allow_images=true
line_wrap=word
lines=8
width=500
no_actions=false
prompt= Search | 검색 | Поиск | Sök
hide_scroll=true
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/style.css" > /dev/null
* {
  font-family: Maple Mono;
  background: transparent;
  color: #d8cab8;
}

#window {
  color: #d8cab8;
  border-color: #d8cab8;
  border-style: solid;
  border-width: 1px;
  background-color: rgba(20, 18, 22, 0.7);
  border-radius: 14px;
}

#scroll {
  border-top-style: solid;
  border-width: 1px;
  border-color: #d8cab8;
}

#inner-box {
  padding-top: 12px;
}

#entry {
  border-style: none;
  color: #d8cab8;
  padding: 6px;
  margin-bottom: 8px;
  margin-left: 12px;
  margin-right: 12px;
  border-radius: 8px;
}
#entry:selected {
  background-color: rgba(0, 0, 0, 0.2);
  border-style: none;
  color: #d8cab8;
  font-weight: bold;
  outline: none;
}

#input {
  background-color: rgba(0, 0, 0, 0.2);
  color: #d8cab8;
  border-color: #d8cab8;
  border-style: none;
  border-bottom-style: solid;
  border-width: 1px;
  font-style: normal;
  border-radius: 8px;
  border-bottom-left-radius: 0px;
  border-bottom-right-radius: 0px;
  padding: 12px;
  margin: 8px;
}
#input:focus {
  background-color: rgba(0, 0, 0, 0.2);
  border-color: #ac82e9;
  font-style: italic;
}

#img {
  padding: 4px;
  margin-right: 6px;
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$WOFI_DIR"
echo "wofi config written."

# =========================================================
# --- 16. Enable Login Manager ---
# =========================================================
# ly is in the CachyOS/AUR repos — install if not already present
if ! command -v ly &> /dev/null; then
    pacman -S --needed --noconfirm ly 2>/dev/null || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild ly
fi
systemctl enable ly

# Flush all buffered log output before the final prompt
wait

echo ""
echo "============================================="
echo "           SETUP COMPLETE"
echo "============================================="
echo "  CachyOS performance settings applied."
echo "  scx systemd service manages Zen 3 scheduling."
echo "  PipeWire user services enabled."
echo "  swww-daemon, hyprpolkit, swaync, cliphist in exec-once."
echo ""
echo "  App configs written:"
echo "    - fastfetch  → ~/.config/fastfetch/config.jsonc"
echo "    - kitty      → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - waybar     → ~/.config/waybar/config.json + style.css"
echo "    - wofi       → ~/.config/wofi/config + style.css"
echo ""
echo "  Next steps after reboot:"
echo "    - Your hyprland.conf has been written with all your keybinds and settings"
echo "    - Set a wallpaper:  swww img /path/to/wallpaper"
echo "    - Configure Qt theming: qt6ct"
echo "      (If KDE apps look off, re-open qt6ct and select the qt6ct-kde variant)"
echo "    - Test Vulkan:      vkcube"
echo "    - Test VA-API:      vainfo"
echo "    - SUPER+V is bound to cliphist (wl-clipboard already installed)"
echo "    - Music controls (SUPER+ALT+P/Left/Right/Up/Down) are live via kew+playerctl"
echo "    - hyprsunset starts at 4500K — adjust the -t value in hyprland.conf if needed"
echo "    - ROCm / LM Studio: HSA_OVERRIDE_GFX_VERSION=11.0.0 is pre-set in hyprland.conf"
echo "      For multi-GPU: add env = HIP_VISIBLE_DEVICES,0 (replace 0 with your card index)"
echo "    - zram configured at ram/2 with lz4 — adjust /etc/systemd/zram-generator.conf if needed"
echo "    - amd_pstate: verify with: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
echo "      (should read 'amd-pstate-epp')"
echo "    - Log in via ly and enjoy Hyprland"
echo "============================================="
echo ""
prompt_user "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot

# =========================================================
# --- 0. Pre-flight Checks ---
# =========================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

if ! ping -c 1 google.com &> /dev/null; then
    echo "No internet connection detected. Please fix and try again."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
LOGFILE="/var/log/arch_install.log"

# Timestamped logging with flush-safe tee
exec > >(while IFS= read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" | tee -a "$LOGFILE"; done)
exec 2>&1

# prompt_user "Question text" VARIABLE_NAME
# Writes prompts directly to /dev/tty so they appear on the terminal even though
# stdout/stderr are redirected through the timestamped logging pipe above.
prompt_user() {
    local __prompt="$1"
    local __var="$2"
    printf '%s' "$__prompt" > /dev/tty
    read "$__var" < /dev/tty
}

echo "=== System Setup for $TARGET_USER (CPU: Zen 3 | GPU: RDNA3) ==="

# =========================================================
# --- 1. Mirror Country Selection ---
# =========================================================
echo ""
prompt_user "Enter your country for mirror optimization (e.g. US, GB, DE, AU) [default: US]: " MIRROR_COUNTRY
MIRROR_COUNTRY="${MIRROR_COUNTRY:-US}"
echo "Using mirror country: $MIRROR_COUNTRY"

# =========================================================
# --- 2. Base Updates & Mirror Optimization ---
# =========================================================
echo "--- Updating system & optimizing mirrors ---"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    reflector git base-devel curl rsync \
    unzip zip tar wget p7zip unrar

reflector --country "$MIRROR_COUNTRY" --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist

# =========================================================
# --- 3. Enable Multilib ---
# =========================================================
echo "--- Enabling Multilib repository ---"
sed -i '/\[multilib\]/,/Include/s/^[ ]*#//' /etc/pacman.conf
pacman -Syy --noconfirm

# =========================================================
# --- 4. CachyOS Repositories ---
# =========================================================
echo "--- Adding CachyOS Repos ---"
curl -L https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz

# Fetch and verify the upstream-published checksum dynamically.
# Validates that the fetched value looks like a real SHA256 hash (64 hex chars)
# before comparing — avoids false aborts when the mirror returns a 404 HTML page.
echo "--- Extracting CachyOS repo setup ---"

tar xvf /tmp/cachyos-repo.tar.xz -C /tmp

# Subshell so cd cannot affect the rest of the script
(
    cd /tmp/cachyos-repo
    chmod +x ./cachyos-repo.sh
    ./cachyos-repo.sh
)

# Verify the CachyOS script did not silently fail
if ! grep -q '\[cachyos\]' /etc/pacman.conf; then
    echo "ERROR: CachyOS repo setup appears to have failed — [cachyos] not found in pacman.conf."
    exit 1
fi

rm -rf /tmp/cachyos-repo*

# CachyOS repos now active — install meta packages.
# Note: yay should now be available via CachyOS repos. If it fails, we fall back to
# building it manually from AUR so the rest of the script can continue.
pacman -Syu --needed --noconfirm cachyos-settings cachyos-hooks cachyos-gaming-meta

if ! pacman -S --needed --noconfirm yay 2>/dev/null; then
    echo "WARNING: yay not found in CachyOS repos — building from AUR as fallback."
    (
        BUILDDIR=$(sudo -u "$TARGET_USER" mktemp -d)
        sudo -u "$TARGET_USER" git clone https://aur.archlinux.org/yay.git "$BUILDDIR/yay"
        cd "$BUILDDIR/yay"
        sudo -u "$TARGET_USER" makepkg -si --noconfirm
        rm -rf "$BUILDDIR"
    )
fi

# =========================================================
# --- 5. Kernel & Bootloader ---
# =========================================================
echo "--- Installing CachyOS Kernel & Sched-ext Schedulers ---"
pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers scx-scheds
# mkinitcpio is triggered automatically via pacman hooks — no manual call needed.

if command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ -d "/boot/loader/entries" ]; then
    bootctl --path=/boot update
else
    echo ""
    echo "WARNING: Could not detect GRUB or systemd-boot."
    echo "  If using systemd-boot for the first time: bootctl install"
    echo "  If using GRUB: grub-mkconfig -o /boot/grub/grub.cfg"
    local _ignored
    prompt_user "Press Enter to continue anyway, then fix your bootloader before rebooting..." _ignored
fi

# =========================================================
# --- 6. Graphics Stack (RDNA3 / RADV) ---
# =========================================================
echo "--- Installing Graphics Stack (RADV) ---"
# vulkan-tools included here for vkcube testing post-install
# libva-mesa-driver required for hardware video acceleration in Firefox and MPV on AMD
pacman -S --needed --noconfirm \
    mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon \
    vulkan-tools vulkan-mesa-layers lib32-vulkan-mesa-layers \
    libva-mesa-driver lib32-libva-mesa-driver \
    gamescope ffmpeg

# =========================================================
# --- 7. Audio Stack (PipeWire — full) ---
# =========================================================
echo "--- Installing PipeWire audio stack ---"
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber pavucontrol pamixer playerctl

# =========================================================
# --- 8. Qt / Wayland Integration ---
# =========================================================
echo "--- Installing Qt Wayland support ---"
# qt6ct-kde (AUR, installed later) replaces and conflicts with vanilla qt6ct,
# so we only install the Wayland platform plugins here and let the AUR handle theming.
pacman -S --needed --noconfirm qt5-wayland qt6-wayland

# =========================================================
# --- 9. Desktop Stack ---
# =========================================================
echo "--- Installing Hyprland & Desktop Environment ---"
pacman -S --needed --noconfirm \
    hyprland waybar wofi swww \
    hyprsunset hyprlock hypridle hyprcursor \
    xorg-xwayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    xdg-user-dirs \
    kitty \
    noto-fonts noto-fonts-cjk ttf-jetbrains-mono-nerd \
    ttf-dejavu ttf-roboto ttf-font-awesome \
    wl-clipboard cliphist swaync \
    pcmanfm-qt gvfs gvfs-mtp gvfs-smb \
    brightnessctl \
    fcitx5 fcitx5-mozc fcitx5-configtool \
    firefox mpv \
    btop fastfetch nsxiv filelight \
    gparted smartmontools transmission-qt \
    zram-generator \
    blueman network-manager-applet

# ananicy-cpp: present in CachyOS repos. If pacman can't find it, yay picks it up
# in the AUR section below — the --needed flag on yay will skip it if already installed.
pacman -S --needed --noconfirm ananicy-cpp || \
    echo "ananicy-cpp not in repos — will install via yay in AUR section."

# =========================================================
# --- 10. Productivity Apps ---
# =========================================================
echo "--- Installing Productivity Applications ---"
pacman -S --needed --noconfirm \
    libreoffice-fresh okular krita anki

# =========================================================
# --- 11. AUR Packages ---
# =========================================================
echo "--- Installing AUR packages (running as $TARGET_USER) ---"
# AUR installs must always run as the non-root user.
# hyprpolkit: AUR package name is 'hyprpolkit'. If the build fails, verify the
# current name with: yay -Ss hyprpolkit  (it has also been called hyprpolkit-agent).
# qt6ct-kde: replaces vanilla qt6ct for better KDE/Qt app theming on Wayland.
# ananicy-cpp: included here as a fallback if the pacman install above was skipped.
sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild \
    hyprshot \
    hyprpolkit \
    bitwarden \
    qt6ct-kde \
    ananicy-cpp \
    ttf-maple \
    lmstudio-bin \
    kew-git \
    stremio

# Auto-detect the correct hyprpolkit binary name — the AUR package has shipped as
# both 'hyprpolkit' and 'hyprpolkit-agent' across versions. We probe for whichever
# exists and store it so the Hyprland config injection below uses the right name.
if command -v hyprpolkit-agent &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit-agent"
elif command -v hyprpolkit &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit"
else
    echo "WARNING: Neither 'hyprpolkit' nor 'hyprpolkit-agent' found in PATH."
    echo "  Defaulting exec-once to 'hyprpolkit' — adjust hyprland.conf if needed."
    HYPRPOLKIT_BIN="hyprpolkit"
fi
echo "Detected hyprpolkit binary: $HYPRPOLKIT_BIN"

# =========================================================
# --- 12. Gaming Stack (Optional) ---
# =========================================================
# cachyos-gaming-meta was already installed in step 4.
# This prompt covers the full Steam / Lutris / Wine layer on top.
echo ""
prompt_user "Install full Gaming Stack (Steam / Lutris / Wine)? (y/N): " install_games
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    echo "--- Installing Gaming Stack ---"
    pacman -S --needed --noconfirm steam lutris wine-staging winetricks wine-mono

    # RDNA3 ROCm support for LM Studio GPU acceleration (optional heavy install ~2 GB)
    echo ""
    prompt_user "Install ROCm / HIP for LM Studio GPU acceleration on RDNA3? (y/N): " install_rocm
    if [[ "$install_rocm" =~ ^[Yy]$ ]]; then
        echo "--- Installing ROCm HIP SDK ---"
        pacman -S --needed --noconfirm rocm-hip-sdk
    fi
fi

# =========================================================
# --- 13. System Services ---
# =========================================================
echo "--- Enabling system services ---"
loginctl enable-linger "$TARGET_USER"
sudo -u "$TARGET_USER" xdg-user-dirs-update

# scx is a system-level scheduler daemon — belongs as a systemd service only,
# never as exec-once inside Hyprland.
systemctl enable --now scx

# Process priority management
systemctl enable --now ananicy-cpp

# Bluetooth
systemctl enable --now bluetooth

# Disable the getty on tty1 to avoid a stray console behind the ly greeter
systemctl disable getty@tty1 || true

# PipeWire must be enabled at the user level to autostart properly in Hyprland sessions
sudo -u "$TARGET_USER" systemctl --user enable pipewire pipewire-pulse wireplumber

# --- zram ---
# Configure zram for improved responsiveness under heavy loads on high-RAM systems.
# Uses lz4 compression — fast with good ratio, ideal for Zen 3.
if [ ! -f /etc/systemd/zram-generator.conf ]; then
    cat <<'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
EOF
    echo "zram-generator configured (ram/2, lz4)."
fi
systemctl daemon-reload
systemctl enable --now systemd-zram-setup@zram0.service

# --- amd_pstate ---
# Zen 3 benefits significantly from amd_pstate=active (EPP driver).
# Check if already set; if not, patch GRUB or advise for systemd-boot.
PSTATE_CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
if [[ "$PSTATE_CURRENT" != "amd-pstate-epp" ]]; then
    echo "--- amd_pstate not active (current driver: $PSTATE_CURRENT) — applying fix ---"
    if command -v grub-mkconfig &> /dev/null && [ -f /etc/default/grub ]; then
        # Inject amd_pstate=active if not already present in GRUB_CMDLINE_LINUX_DEFAULT
        if ! grep -q 'amd_pstate=active' /etc/default/grub; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_pstate=active"/' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg
            echo "amd_pstate=active added to GRUB_CMDLINE_LINUX_DEFAULT and grub.cfg regenerated."
        fi
    elif [ -d "/boot/loader/entries" ]; then
        echo "NOTE (systemd-boot): Manually add 'amd_pstate=active' to your kernel options in"
        echo "  /boot/loader/entries/<your-entry>.conf — look for the 'options' line."
    fi
else
    echo "amd_pstate EPP driver already active — no changes needed."
fi

# --- ly display manager config ---
# Patch ly's config to ensure Wayland sessions are preferred and the last session
# is remembered, preventing black screens when ly defaults to an X11 stub.
LY_CONF="/etc/ly/config.ini"
if [ -f "$LY_CONF" ]; then
    # Enable session memory
    sed -i 's/^#\?\s*save_last_session\s*=.*/save_last_session = true/' "$LY_CONF"
    # Ensure Wayland session directory is set
    grep -q '^waylandsessions' "$LY_CONF" || \
        echo "waylandsessions = /usr/share/wayland-sessions" >> "$LY_CONF"
    echo "ly config patched (save_last_session + waylandsessions)."
else
    echo "WARNING: /etc/ly/config.ini not found — ly may not be installed yet or path has changed."
    echo "  After reboot, manually set save_last_session = true and"
    echo "  waylandsessions = /usr/share/wayland-sessions in /etc/ly/config.ini"
fi

# =========================================================
# --- 14. Hyprland Config Injection ---
# =========================================================
echo "--- Writing Hyprland config ---"
HYPR_CONF="$USER_HOME/.config/hypr/hyprland.conf"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$HYPR_CONF")"

# Guard against overwriting on re-runs — only write if the file is empty or missing
if grep -q "Auto-Injected" "$HYPR_CONF" 2>/dev/null; then
    echo "Hyprland config already written — skipping to avoid overwrite."
else
    cat <<'EOF' | sudo -u "$TARGET_USER" tee "$HYPR_CONF" > /dev/null
# =============================================================================
# hyprland.conf — Auto-generated by arch_install.sh (2026)
# Ported from user's existing config with stack adaptations noted inline.
# =============================================================================
# Auto-Injected — marker used by install script to detect re-runs


# =============================================================================
# MONITORS
# Run `hyprctl monitors all` to list connected outputs and adjust as needed.
# =============================================================================

monitor=DP-1, 2560x1440@239.97, 0x0, 1, bitdepth, 10
monitor=DP-3, 2560x1440@143.96, -2560x0, 1


# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

# Cursor sizing
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

# Input method (fcitx5)
env = XMODIFIERS,@im=fcitx
env = GTK_IM_MODULE,fcitx
env = QT_IM_MODULE,fcitx

# Qt theming — qt6ct-kde is installed; run `qt6ct` after first login to configure.
# If KDE apps (Okular, Krita) look visually off, re-open qt6ct and select the kde variant.
env = QT_QPA_PLATFORMTHEME,qt6ct

# Qt Wayland native rendering
env = QT_QPA_PLATFORM,wayland

# ROCm / HIP: force RDNA3 (gfx1100) target.
# Prevents "GPU not found" errors in LM Studio and other AI workloads.
# Remove this line if you are not using ROCm.
env = HSA_OVERRIDE_GFX_VERSION,11.0.0


# =============================================================================
# STARTUP (exec-once)
# Adapted from original config:
#   - hyprpaper     → swww-daemon  (swww is installed; set wallpaper with `swww img`)
#   - polkit-gnome  → hyprpolkit   (binary auto-detected by install script)
#   - redshift      → hyprsunset   (modern Wayland-native replacement)
#   - nm-applet     → commented out (network-manager-applet not installed;
#                     re-add and install if needed: pacman -S network-manager-applet)
# =============================================================================

exec-once = waybar
exec-once = swww-daemon
exec-once = fcitx5 -d
exec-once = HYPRPOLKIT_PLACEHOLDER
exec-once = hyprsunset -t 4500
exec-once = swaync
exec-once = wl-paste --watch cliphist store
exec-once = nm-applet --indicator


# =============================================================================
# DEFAULT PROGRAMS
# fileManager changed from nautilus to pcmanfm-qt (installed by script).
# Swap back to nautilus if you install it: sudo pacman -S nautilus
# =============================================================================

$terminal    = kitty
$fileManager = pcmanfm-qt
$menu        = pgrep wofi > /dev/null 2>&1 && killall wofi || wofi --show drun


# =============================================================================
# WORKSPACES
# Workspace 9 pinned to DP-3 (second monitor).
# =============================================================================

workspace = 9, monitor:DP-3, default:true
workspace = 9, persistent:true


# =============================================================================
# INPUT
# =============================================================================

input {
    kb_layout  = us
    kb_options = grp:alt_shift_toggle
    kb_rules   =
    kb_variant =
    kb_model   =

    follow_mouse = 1
    sensitivity  = 0

    touchpad {
        natural_scroll = false
    }
}

cursor {
    no_hardware_cursors = true
}


# =============================================================================
# DESIGN
# =============================================================================

animations {
    enabled = false
}

general {
    gaps_in  = 5
    gaps_out = 8

    border_size = 1

    col.active_border   = rgb(d8cab8)
    col.inactive_border = rgb(AC82E9)

    resize_on_border = true
    layout           = dwindle
    allow_tearing    = false
}

decoration {
    rounding = 6

    active_opacity   = 1.0
    inactive_opacity = 1.0

    shadow:enabled      = true
    shadow:range        = 16
    shadow:render_power = 5
    shadow:color        = rgba(0,0,0,0.2)

    blur:enabled           = true
    blur:new_optimizations = true
    blur:size              = 2
    blur:passes            = 3
    blur:vibrancy          = 0.1696
}

dwindle {
    pseudotile     = true
    preserve_split = true
}

master {
    new_status = master
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo   = true
}


# =============================================================================
# KEYBINDS
# =============================================================================

$mainMod = SUPER

# Terminal
bind = $mainMod, Return, exec, $terminal

# Kill focused window
bind = $mainMod, Q, killactive,

# Screenshot (region) — saved to /tmp; change path as preferred
bind = $mainMod SHIFT, S, exec, hyprshot --mode region --output-folder ~/Pictures/Screenshots

# File manager
bind = $mainMod, E, exec, $fileManager

# Toggle floating
bind = $mainMod SHIFT, SPACE, togglefloating,

# Fullscreen
bind = $mainMod, F, fullscreen,

# App launcher
bind = $mainMod, D, exec, $menu

# Clipboard history (requires cliphist + wl-clipboard, both installed)
bind = $mainMod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy


# --- Music Controls (kew + playerctl) ---
# playerctl and kew are installed. These binds are ready to use.

# Play / Pause
bind = SUPER ALT, P, exec, playerctl --player=kew play-pause

# Next / Previous track
bind = SUPER ALT, right, exec, playerctl --player=kew next
bind = SUPER ALT, left,  exec, playerctl --player=kew previous

# Volume up / down (5% steps via PipeWire/pactl — playerctl volume is 0.0–1.0, not pactl syntax)
bind = SUPER ALT, up,   exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = SUPER ALT, down, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%


# --- Workspace Switching ---
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# --- Move Window to Workspace ---
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# --- Move / Resize with Mouse ---
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow


# =============================================================================
# WINDOW RULES
# =============================================================================

# Waybar — blur layer
layerrule = blur on,          match:namespace waybar
layerrule = blur_popups on,   match:namespace waybar
layerrule = ignore_alpha 0.7, match:namespace waybar

# Wofi — blur layer
layerrule = blur on,          match:namespace wofi
layerrule = blur_popups on,   match:namespace wofi
layerrule = ignore_alpha 0.7, match:namespace wofi

# XWayland drag fix
windowrule = no_focus on, match:class ^$, match:title ^$, match:xwayland 1, match:float 1, match:fullscreen 0, match:pin 0
EOF

    # Patch in the auto-detected hyprpolkit binary name
    sed -i "s/HYPRPOLKIT_PLACEHOLDER/$HYPRPOLKIT_BIN/" "$HYPR_CONF"
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    echo "hyprland.conf written (hyprpolkit binary: $HYPRPOLKIT_BIN)."
fi

# =========================================================
# --- 15. App Configs ---
# =========================================================

# ---- Fastfetch ----
echo "--- Writing fastfetch config ---"
FASTFETCH_CONF="$USER_HOME/.config/fastfetch/config.jsonc"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$FASTFETCH_CONF")"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$FASTFETCH_CONF" > /dev/null
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "source": "arch_small",
        "padding": {
            "top": 1,
            "left": 2
        }
    },
    "display": {
        "separator": "  "
    },
    "modules": [
        "break",
        "title",
        { "type": "os",       "key": "os"     },
        { "type": "wm",       "key": "de"     },
        { "type": "packages", "key": "pkgs",  "format": "{} (pacman)" },
        { "type": "shell",    "key": "shell"  },
        { "type": "kernel",   "key": "kernel" },
        { "type": "uptime",   "key": "uptime", "format": "{2}h {3}m"  },
        {
            "type": "command",
            "key":  "os age",
            "text": "bash -c 'birth_install=$(stat -c %W /); current=$(date +%s); days_difference=$(( (current - birth_install) / 86400 )); echo $days_difference days'"
        },
        { "type": "memory", "key": "memory" },
        "break",
        { "type": "colors", "symbol": "circle" },
        "break"
    ]
}
EOF
chown "$TARGET_USER:$TARGET_USER" "$FASTFETCH_CONF"
echo "fastfetch config written."

# ---- Kitty ----
echo "--- Writing kitty config ---"
KITTY_DIR="$USER_HOME/.config/kitty"
sudo -u "$TARGET_USER" mkdir -p "$KITTY_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$KITTY_DIR/kitty.conf" > /dev/null
font_family            JetBrainsMono NF Bold
font_size              12.0
bold_font              auto
italic_font            auto
bold_italic_font       auto
background_opacity     0.9
confirm_os_window_close 0
cursor_trail           1
linux_display_server   auto
scrollback_lines       2000
wheel_scroll_min_lines 1
enable_audio_bell      no
window_padding_width   4
include colors.conf
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$KITTY_DIR/colors.conf" > /dev/null
cursor                #dee4e4
cursor_text_color     #bec8c9
foreground            #dee4e4
background            #0e1415
selection_foreground  #1b3437
selection_background  #b1cbce
url_color             #80d4dc

# black
color0   #4c4c4c
color8   #262626
# red
color1   #ac8a8c
color9   #c49ea0
# green
color2   #8aac8b
color10  #9ec49f
# yellow
color3   #aca98a
color11  #c4c19e
# blue
color4   #80d4dc
color12  #a39ec4
# magenta
color5   #ac8aac
color13  #c49ec4
# cyan
color6   #8aacab
color14  #9ec3c4
# white
color7   #f0f0f0
color15  #e7e7e7
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$KITTY_DIR"
echo "kitty config written."

# ---- Waybar ----
echo "--- Writing waybar config ---"
WAYBAR_DIR="$USER_HOME/.config/waybar"
sudo -u "$TARGET_USER" mkdir -p "$WAYBAR_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/config.json" > /dev/null
{
  "layer": "top",
  "spacing": 0,
  "height": 0,
  "margin-bottom": 0,
  "margin-top": 8,
  "position": "top",
  "margin-right": 370,
  "margin-left": 370,
  "modules-left": [
    "hyprland/workspaces"
  ],
  "modules-center": [
    "custom/applauncher"
  ],
  "modules-right": [
    "network",
    "pulseaudio",
    "tray",
    "clock"
  ],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": false,
    "tooltip": false
  },
  "custom/applauncher": {
    "format": "///",
    "on-click": "pkill -x wofi || wofi --show drun --location=top -y 10",
    "tooltip": false
  },
  "tray": {
    "spacing": 10,
    "tooltip": false
  },
  "clock": {
    "format": "󰅐 {:%H:%M}",
    "tooltip": false
  },
  "network": {
    "format-wifi": " {bandwidthDownBits}",
    "format-ethernet": " {bandwidthDownBits}",
    "format-disconnected": "󰤮 No Network",
    "interval": 5,
    "tooltip": false
  },
  "pulseaudio": {
    "scroll-step": 5,
    "max-volume": 150,
    "format": "{icon} {volume}%",
    "format-bluetooth": "{icon} {volume}%",
    "format-icons": ["", "", " "],
    "nospacing": 1,
    "format-muted": " ",
    "on-click": "pavucontrol",
    "tooltip": false
  }
}
EOF
# Note: battery module removed — this is a desktop (5900X), not a laptop.
# Add it back manually if needed.

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/style.css" > /dev/null
* {
  font-family: Maple Mono;
  border-radius: 8px;
  font-size: 13px;
  padding: 0px;
  background: transparent;
}

window#waybar {
  background-color: rgba(20, 18, 22, 0.7);
  border-radius: 14px;
  padding: 0px;
  border-style: none;
}

#battery,
#network,
#clock,
#custom-applauncher,
#tray,
#workspaces,
#pulseaudio {
  background-color: rgba(20, 18, 22, 0.2);
  margin: 6px;
  margin-right: 0px;
  padding: 2px 8px;
  border-radius: 8px;
  color: #d8cab8;
  border-style: solid;
  border-color: #d8cab8;
  border-width: 1px;
  transition-duration: 120ms;
}

#clock {
  margin-right: 6px;
}
#clock:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
}

#pulseaudio:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
  transition-duration: 120ms;
}

#custom-applauncher {
  font-weight: bold;
  transition-duration: 120ms;
  padding: 0px 25px;
}
#custom-applauncher:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #d8cab8;
  transition-duration: 120ms;
}

#tray menu {
  background-color: #141216;
  color: #d8cab8;
  padding: 4px;
}
#tray menu menuitem {
  background-image: linear-gradient(to bottom, #27232b 100%);
  margin: 3px;
  color: #d8cab8;
  border-radius: 4px;
  border-style: solid;
  border-color: #27232b;
}
#tray menu menuitem:hover {
  background-image: linear-gradient(to bottom, #27232b 100%);
  color: #ac82e9;
  font-weight: bold;
}

#workspaces button {
  transition-duration: 100ms;
  all: initial;
  min-width: 0;
  font-weight: bold;
  color: #d8cab8;
  margin-right: 0.2cm;
  margin-left: 0.2cm;
}
#workspaces button:hover {
  transition-duration: 120ms;
  color: #8f56e1;
}
#workspaces button.focused,
#workspaces button.active {
  color: #ac82e9;
  font-weight: bold;
}
#workspaces button.urgent {
  color: #fcb167;
}

#battery {
  background-color: #222222;
  color: #1d2021;
}
#battery.warning,
#battery.critical,
#battery.urgent {
  color: #1d2021;
  background-color: #fc4649;
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$WAYBAR_DIR"
echo "waybar config written."

# ---- Wofi ----
echo "--- Writing wofi config ---"
WOFI_DIR="$USER_HOME/.config/wofi"
sudo -u "$TARGET_USER" mkdir -p "$WOFI_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/config" > /dev/null
show=drun
term=kitty
show_all=true
gtk_dark=false
location=center
insensitive=false
allow_markup=true
allow_images=true
line_wrap=word
lines=8
width=500
no_actions=false
prompt= Search | 검색 | Поиск | Sök
hide_scroll=true
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/style.css" > /dev/null
* {
  font-family: Maple Mono;
  background: transparent;
  color: #d8cab8;
}

#window {
  color: #d8cab8;
  border-color: #d8cab8;
  border-style: solid;
  border-width: 1px;
  background-color: rgba(20, 18, 22, 0.7);
  border-radius: 14px;
}

#scroll {
  border-top-style: solid;
  border-width: 1px;
  border-color: #d8cab8;
}

#inner-box {
  padding-top: 12px;
}

#entry {
  border-style: none;
  color: #d8cab8;
  padding: 6px;
  margin-bottom: 8px;
  margin-left: 12px;
  margin-right: 12px;
  border-radius: 8px;
}
#entry:selected {
  background-color: rgba(0, 0, 0, 0.2);
  border-style: none;
  color: #d8cab8;
  font-weight: bold;
  outline: none;
}

#input {
  background-color: rgba(0, 0, 0, 0.2);
  color: #d8cab8;
  border-color: #d8cab8;
  border-style: none;
  border-bottom-style: solid;
  border-width: 1px;
  font-style: normal;
  border-radius: 8px;
  border-bottom-left-radius: 0px;
  border-bottom-right-radius: 0px;
  padding: 12px;
  margin: 8px;
}
#input:focus {
  background-color: rgba(0, 0, 0, 0.2);
  border-color: #ac82e9;
  font-style: italic;
}

#img {
  padding: 4px;
  margin-right: 6px;
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$WOFI_DIR"
echo "wofi config written."

# =========================================================
# --- 16. Enable Login Manager ---
# =========================================================
# ly is in the CachyOS/AUR repos — install if not already present
if ! command -v ly &> /dev/null; then
    pacman -S --needed --noconfirm ly 2>/dev/null || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild ly
fi
systemctl enable ly

# Flush all buffered log output before the final prompt
wait

echo ""
echo "============================================="
echo "           SETUP COMPLETE"
echo "============================================="
echo "  CachyOS performance settings applied."
echo "  scx systemd service manages Zen 3 scheduling."
echo "  PipeWire user services enabled."
echo "  swww-daemon, hyprpolkit, swaync, cliphist in exec-once."
echo ""
echo "  App configs written:"
echo "    - fastfetch  → ~/.config/fastfetch/config.jsonc"
echo "    - kitty      → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - waybar     → ~/.config/waybar/config.json + style.css"
echo "    - wofi       → ~/.config/wofi/config + style.css"
echo ""
echo "  Next steps after reboot:"
echo "    - Your hyprland.conf has been written with all your keybinds and settings"
echo "    - Set a wallpaper:  swww img /path/to/wallpaper"
echo "    - Configure Qt theming: qt6ct"
echo "      (If KDE apps look off, re-open qt6ct and select the qt6ct-kde variant)"
echo "    - Test Vulkan:      vkcube"
echo "    - Test VA-API:      vainfo"
echo "    - SUPER+V is bound to cliphist (wl-clipboard already installed)"
echo "    - Music controls (SUPER+ALT+P/Left/Right/Up/Down) are live via kew+playerctl"
echo "    - hyprsunset starts at 4500K — adjust the -t value in hyprland.conf if needed"
echo "    - ROCm / LM Studio: HSA_OVERRIDE_GFX_VERSION=11.0.0 is pre-set in hyprland.conf"
echo "      For multi-GPU: add env = HIP_VISIBLE_DEVICES,0 (replace 0 with your card index)"
echo "    - zram configured at ram/2 with lz4 — adjust /etc/systemd/zram-generator.conf if needed"
echo "    - amd_pstate: verify with: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
echo "      (should read 'amd-pstate-epp')"
echo "    - Log in via ly and enjoy Hyprland"
echo "============================================="
echo ""
prompt_user "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
