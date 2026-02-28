#!/usr/bin/env bash
# Arch + Hyprland (2026 Edition)
# Optimized for: Dell Precision M4600 (Intel Sandy Bridge + Quadro 1000M)
# GPU driver: nouveau (Fermi — proprietary nvidia dropped support after 390xx)
# Note: CachyOS repos require x86_64_v3 (AVX2) — Sandy Bridge is v2 only.
#       Using standard Arch repos with linux-lts kernel instead.
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

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

log "=== System Setup for $TARGET_USER (CPU: Sandy Bridge | GPU: Quadro 1000M/nouveau) ==="

# =========================================================
# --- 1. Collect All Prompts Upfront ---
# =========================================================
echo ""
read -p "Enter your country for mirror optimization (e.g. US, GB, DE, AU) [default: US]: " MIRROR_COUNTRY
MIRROR_COUNTRY="${MIRROR_COUNTRY:-US}"

echo ""
log "Mirror country : $MIRROR_COUNTRY"
log "Starting unattended install..."
echo ""

# =========================================================
# --- 2. Base Updates & Mirror Optimization ---
# =========================================================
log "--- Updating system & optimizing mirrors ---"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    reflector git base-devel curl rsync \
    unzip zip tar wget p7zip unrar \
    nano cpio

reflector --country "$MIRROR_COUNTRY" --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist

# =========================================================
# --- 3. Enable Multilib & Parallel Downloads ---
# =========================================================
log "--- Enabling Multilib repository & parallel downloads ---"
sed -i '/\[multilib\]/,/Include/s/^[ ]*#//' /etc/pacman.conf
grep -q '^ParallelDownloads' /etc/pacman.conf || \
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
pacman -Syy --noconfirm

# =========================================================
# --- 4. yay (AUR helper) ---
# =========================================================
log "--- Installing yay ---"
if ! command -v yay &> /dev/null; then
    (
        BUILDDIR=$(sudo -u "$TARGET_USER" mktemp -d)
        sudo -u "$TARGET_USER" git clone https://aur.archlinux.org/yay.git "$BUILDDIR/yay"
        cd "$BUILDDIR/yay"
        sudo -u "$TARGET_USER" makepkg -si --noconfirm
        rm -rf "$BUILDDIR"
    )
else
    log "yay already installed — skipping."
fi

# =========================================================
# --- 5. Kernel, Microcode & Bootloader ---
# =========================================================
log "--- Installing linux-lts kernel & Intel Microcode ---"
# linux-lts: more stable than mainline, better suited for older hardware.
# intel-ucode: loads CPU microcode updates at boot — important for Sandy Bridge security fixes.
pacman -S --needed --noconfirm linux-lts linux-lts-headers intel-ucode

if command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ -d "/boot/loader/entries" ]; then
    bootctl --path=/boot update
else
    log "WARNING: Could not detect GRUB or systemd-boot."
    log "  systemd-boot: bootctl install"
    log "  GRUB: grub-mkconfig -o /boot/grub/grub.cfg"
    read -p "Press Enter to continue, then fix bootloader before rebooting..."
fi

# =========================================================
# --- 6. Graphics Stack (nouveau / Fermi) ---
# =========================================================
log "--- Installing Graphics Stack (nouveau) ---"
# Quadro 1000M is Fermi (GF108M). Proprietary nvidia support ended at 390xx which
# is EOL and difficult on Wayland. nouveau via mesa/gallium is the stable choice.
pacman -S --needed --noconfirm \
    mesa lib32-mesa \
    libva-mesa-driver \
    ffmpeg

# =========================================================
# --- 7. Audio Stack (PipeWire) ---
# =========================================================
log "--- Installing PipeWire audio stack ---"
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber pavucontrol pamixer playerctl

# =========================================================
# --- 8. Qt / Wayland Integration ---
# =========================================================
log "--- Installing Qt Wayland support ---"
pacman -S --needed --noconfirm qt5-wayland qt6-wayland

# =========================================================
# --- 9. Desktop Stack ---
# =========================================================
log "--- Installing Hyprland & Desktop Environment ---"
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
    blueman network-manager-applet \
    imagemagick \
    flatpak

# =========================================================
# --- 10. Laptop Power Management ---
# =========================================================
log "--- Installing laptop power management ---"
pacman -S --needed --noconfirm \
    tlp tlp-rdw \
    thermald \
    acpid \
    powertop

# =========================================================
# --- 11. Productivity Apps ---
# =========================================================
log "--- Installing Productivity Applications ---"
pacman -S --needed --noconfirm \
    libreoffice-fresh okular krita anki

# =========================================================
# --- 12. AUR Packages ---
# =========================================================
log "--- Installing AUR packages (running as $TARGET_USER) ---"
sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild \
    hyprshot \
    hyprpolkit \
    bitwarden \
    qt6ct-kde \
    ttf-maple \
    kew-git

# Stremio via Flatpak — avoids compiling qt5-webengine which fails on low-RAM machines
log "--- Installing Flatpak apps ---"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.stremio.Stremio

if command -v hyprpolkit-agent &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit-agent"
elif command -v hyprpolkit &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit"
else
    log "WARNING: hyprpolkit binary not found — defaulting to 'hyprpolkit'."
    HYPRPOLKIT_BIN="hyprpolkit"
fi
log "Detected hyprpolkit binary: $HYPRPOLKIT_BIN"

# =========================================================
# --- 13. System Services ---
# =========================================================
log "--- Enabling system services ---"
loginctl enable-linger "$TARGET_USER"
sudo -u "$TARGET_USER" xdg-user-dirs-update

# TLP for power saving — mask rfkill services so they don't conflict
systemctl enable tlp
systemctl mask systemd-rfkill.service || true
systemctl mask systemd-rfkill.socket || true

systemctl enable thermald
systemctl enable acpid
systemctl enable bluetooth

# ly runs on tty2 — disable getty@tty2 to free it up
systemctl disable getty@tty2 || true

# PipeWire at user level
sudo -u "$TARGET_USER" systemctl --user enable pipewire pipewire-pulse wireplumber

# --- zram ---
if [ ! -f /etc/systemd/zram-generator.conf ]; then
    cat <<'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
EOF
    log "zram-generator configured (ram/2, lz4)."
fi
systemctl daemon-reload
systemctl enable --now systemd-zram-setup@zram0.service

# --- Intel power saving kernel params ---
# Sandy Bridge supports i915 power saving features.
if command -v grub-mkconfig &> /dev/null && [ -f /etc/default/grub ]; then
    NEEDS_UPDATE=0
    if ! grep -q 'i915.enable_psr=1' /etc/default/grub; then
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 i915.enable_psr=1"/' /etc/default/grub
        NEEDS_UPDATE=1
    fi
    if ! grep -q 'i915.enable_fbc=1' /etc/default/grub; then
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 i915.enable_fbc=1"/' /etc/default/grub
        NEEDS_UPDATE=1
    fi
    if [ "$NEEDS_UPDATE" -eq 1 ]; then
        grub-mkconfig -o /boot/grub/grub.cfg
        log "i915 power saving params added to GRUB (PSR + FBC)."
    fi
elif [ -d "/boot/loader/entries" ]; then
    log "NOTE (systemd-boot): Manually add 'i915.enable_psr=1 i915.enable_fbc=1' to"
    log "  your kernel options in /boot/loader/entries/<your-entry>.conf"
fi

# --- ly display manager config ---
LY_CONF="/etc/ly/config.ini"
if [ -f "$LY_CONF" ]; then
    sed -i 's/^#\?\s*save_last_session\s*=.*/save_last_session = true/' "$LY_CONF"
    grep -q '^waylandsessions' "$LY_CONF" || \
        echo "waylandsessions = /usr/share/wayland-sessions" >> "$LY_CONF"
    log "ly config patched (save_last_session + waylandsessions)."
else
    log "WARNING: /etc/ly/config.ini not found — patch manually after install."
fi

# =========================================================
# --- 14. Hyprland Config ---
# =========================================================
log "--- Writing Hyprland config ---"
HYPR_CONF="$USER_HOME/.config/hypr/hyprland.conf"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$HYPR_CONF")"

if grep -q "Auto-Injected" "$HYPR_CONF" 2>/dev/null; then
    log "Hyprland config already written — skipping to avoid overwrite."
else
    cat <<'EOF' | sudo -u "$TARGET_USER" tee "$HYPR_CONF" > /dev/null
# =============================================================================
# hyprland.conf — Auto-generated by arch_install_laptop.sh (2026)
# Dell Precision M4600 — Intel Sandy Bridge + Quadro 1000M (nouveau)
# =============================================================================
# Auto-Injected — marker used by install script to detect re-runs


# =============================================================================
# MONITORS
# eDP-1 is the internal laptop display. Run `hyprctl monitors all` to confirm.
# =============================================================================

monitor=eDP-1, 1920x1080@60, 0x0, 1


# =============================================================================
# STARTUP (exec-once)
# =============================================================================

exec-once = waybar
exec-once = swww-daemon
exec-once = fcitx5 -d
exec-once = HYPRPOLKIT_PLACEHOLDER
exec-once = hyprsunset -t 4500
exec-once = swaync
exec-once = wl-paste --watch cliphist store
exec-once = nm-applet --indicator
exec-once = kew


# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

env = XMODIFIERS,@im=fcitx

env = QT_QPA_PLATFORMTHEME,qt6ct
env = QT_QPA_PLATFORM,wayland

# nouveau requires software cursors on Wayland
env = WLR_NO_HARDWARE_CURSORS,1

# Ensure nouveau is used for VA-API (limited on Fermi but available)
env = LIBVA_DRIVER_NAME,nouveau


# =============================================================================
# DEFAULT PROGRAMS
# =============================================================================

$terminal    = kitty
$fileManager = pcmanfm-qt
$menu        = pgrep wofi > /dev/null 2>&1 && killall wofi || wofi --show drun


# =============================================================================
# WORKSPACES
# =============================================================================

workspace = 1, monitor:eDP-1, default:true


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
        natural_scroll       = true
        tap-to-click         = true
        disable_while_typing = true
    }
}

cursor {
    no_hardware_cursors = true
}

gestures {
    workspace_swipe         = true
    workspace_swipe_fingers = 3
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

bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive,
bind = $mainMod SHIFT, S, exec, hyprshot --mode region --output-folder ~/Pictures/Screenshots
bind = $mainMod, E, exec, $fileManager
bind = $mainMod SHIFT, SPACE, togglefloating,
bind = $mainMod, F, fullscreen,
bind = $mainMod, D, exec, $menu
bind = $mainMod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy
bind = $mainMod, Z, exec, $HOME/.config/waybar/scripts/wallpaper_picker.sh

# Laptop brightness keys
bind = , XF86MonBrightnessUp,   exec, brightnessctl set +5%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 5%-

# Laptop volume keys
bind = , XF86AudioRaiseVolume,  exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = , XF86AudioLowerVolume,  exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
bind = , XF86AudioMute,         exec, pactl set-sink-mute @DEFAULT_SINK@ toggle

# Music Controls (kew + playerctl)
bind = SUPER ALT, P,     exec, playerctl --player=kew play-pause
bind = SUPER ALT, right, exec, playerctl --player=kew next
bind = SUPER ALT, left,  exec, playerctl --player=kew previous

# Workspace Switching
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

# Move Window to Workspace
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

# Move / Resize with Mouse
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow


# =============================================================================
# WINDOW RULES
# =============================================================================

layerrule = blur on,          match:namespace waybar
layerrule = blur_popups on,   match:namespace waybar
layerrule = ignore_alpha 0.7, match:namespace waybar

layerrule = blur on,          match:namespace wofi
layerrule = blur_popups on,   match:namespace wofi
layerrule = ignore_alpha 0.7, match:namespace wofi

windowrule = no_focus on, match:class ^$, match:title ^$, match:xwayland 1, match:float 1, match:fullscreen 0, match:pin 0
EOF

    sed -i "s/HYPRPOLKIT_PLACEHOLDER/$HYPRPOLKIT_BIN/" "$HYPR_CONF"
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    log "hyprland.conf written (hyprpolkit binary: $HYPRPOLKIT_BIN)."
fi

# =========================================================
# --- 15. App Configs ---
# =========================================================

# ---- Fastfetch ----
log "--- Writing fastfetch config ---"
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
        { "type": "memory",  "key": "memory"  },
        { "type": "battery", "key": "battery" },
        "break",
        { "type": "colors", "symbol": "circle" },
        "break"
    ]
}
EOF
chown "$TARGET_USER:$TARGET_USER" "$FASTFETCH_CONF"
log "fastfetch config written."

# ---- Kitty ----
log "--- Writing kitty config ---"
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
log "kitty config written."

# ---- Waybar ----
log "--- Writing waybar config ---"
WAYBAR_DIR="$USER_HOME/.config/waybar"
sudo -u "$TARGET_USER" mkdir -p "$WAYBAR_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/config.json" > /dev/null
{
  "layer": "bot",
  "spacing": 0,
  "height": 0,
  "margin-bottom": 0,
  "margin-top": 8,
  "position": "top",
  "margin-right": 200,
  "margin-left": 200,
  "modules-left": [
    "hyprland/workspaces"
  ],
  "modules-center": [
    "custom/media"
  ],
  "modules-right": [
    "custom/wallpaper",
    "network",
    "battery",
    "pulseaudio",
    "tray",
    "custom/weather",
    "clock"
  ],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": false,
    "tooltip": false
  },
  "custom/media": {
    "format": "󰎈 {}",
    "exec": "$HOME/.config/waybar/scripts/scroll_text.sh",
    "on-click": "playerctl -p kew play-pause",
    "tooltip": false
  },
  "custom/wallpaper": {
    "format": "󰋩",
    "on-click": "$HOME/.config/waybar/scripts/wallpaper_picker.sh",
    "tooltip": false
  },
  "custom/weather": {
    "format": "{}",
    "exec": "$HOME/.config/waybar/scripts/weather.sh",
    "interval": 900,
    "tooltip": false
  },
  "tray": {
    "spacing": 10,
    "tooltip": false
  },
  "clock": {
    "format": "󰅐  {:%H:%M}",
    "tooltip": false
  },
  "network": {
    "format-wifi": "  {bandwidthDownBits}",
    "format-ethernet": "  {bandwidthDownBits}",
    "format-disconnected": "󰤮  No Network",
    "interval": 5,
    "tooltip": false
  },
  "pulseaudio": {
    "scroll-step": 5,
    "max-volume": 150,
    "format": "{icon}  {volume}%",
    "format-bluetooth": "{icon}  {volume}%",
    "format-icons": [
      "",
      "",
      " "
    ],
    "nospacing": 1,
    "format-muted": "  ",
    "on-click": "pavucontrol",
    "tooltip": false
  },
  "battery": {
    "states": {
      "warning": 30,
      "critical": 15
    },
    "format": "{icon}  {capacity}%",
    "format-charging": "󰂄  {capacity}%",
    "format-plugged": "󰂄  {capacity}%",
    "format-alt": "{icon}  {time}",
    "format-full": "󱈑  {capacity}%",
    "format-icons": [
      "󱊡",
      "󱊢",
      "󱊣"
    ]
  }
}
EOF

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

#network,
#clock,
#custom-media,
#custom-weather,
#custom-wallpaper,
#battery,
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
  letter-spacing: 1px;
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

#custom-media {
  font-weight: bold;
  transition-duration: 120ms;
  padding: 0px 25px 0px 25px;
  min-width: 280px;
  font-family: monospace;
  color: #ac82e9;
  border-color: #ac82e9;
}

#custom-media:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #ac82e9;
  transition-duration: 120ms;
}

#custom-wallpaper {
  transition-duration: 120ms;
  padding: 0px 8px;
}

#custom-wallpaper:hover {
  background-color: rgba(20, 18, 22, 0.7);
  color: #ac82e9;
  transition-duration: 120ms;
}

#custom-weather:hover {
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
  background-color: #27232b;
  margin: 3px;
  color: #d8cab8;
  border-radius: 4px;
  border-style: solid;
  border-color: #27232b;
}

#tray menu menuitem:hover {
  background-color: #27232b;
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

#workspaces button.focused {
  color: #ac82e9;
  font-weight: bold;
}

#workspaces button.active {
  color: #ac82e9;
  font-weight: bold;
}

#workspaces button.urgent {
  color: #fcb167;
}

#battery {
  background-color: rgba(20, 18, 22, 0.2);
  color: #d8cab8;
}

#battery.warning {
  color: #fcb167;
}

#battery.critical,
#battery.urgent {
  color: #fc4649;
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$WAYBAR_DIR"
log "waybar config written."

# ---- Waybar Scripts ----
log "--- Writing waybar scripts ---"
SCRIPTS_DIR="$USER_HOME/.config/waybar/scripts"
sudo -u "$TARGET_USER" mkdir -p "$SCRIPTS_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SCRIPTS_DIR/scroll_text.sh" > /dev/null
#!/bin/bash

PLAYER="kew"
MAX_LEN=30
SCROLL_DELAY=0.3

get_text() {
    playerctl -p "$PLAYER" metadata --format '{{artist}} – {{title}}' 2>/dev/null
}

text=""
padded=""
padded_len=0
offset=0
tick=0

while true; do
    status=$(playerctl -p "$PLAYER" status 2>/dev/null)

    if [ "$status" != "Playing" ] && [ "$status" != "Paused" ]; then
        echo ""
        sleep 2
        continue
    fi

    if [ $((tick % 10)) -eq 0 ]; then
        current_text=$(get_text)
        if [ "$current_text" != "$text" ]; then
            text="$current_text"
            padded="$text     "
            padded_len=${#padded}
            offset=0
        fi
    fi

    chunk="${padded:$offset:$MAX_LEN}"
    while [ ${#chunk} -lt $MAX_LEN ]; do
        chunk="$chunk${padded:0:$((MAX_LEN - ${#chunk}))}"
    done

    if [ "$status" = "Paused" ]; then
        echo "⏸ $chunk"
    else
        echo "$chunk"
    fi

    offset=$(( (offset + 1) % padded_len ))
    tick=$((tick + 1))
    sleep "$SCROLL_DELAY"
done
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SCRIPTS_DIR/weather.sh" > /dev/null
#!/bin/bash

LAT="33.9806"
LON="-117.3755"
CACHE_FILE="$HOME/.cache/waybar_weather.txt"

data=$(curl -sf --max-time 5 "https://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&current_weather=true&temperature_unit=fahrenheit" 2>/dev/null)

if [ -z "$data" ]; then
    if [ -f "$CACHE_FILE" ]; then
        cat "$CACHE_FILE"
    else
        echo "N/A"
    fi
    exit 0
fi

temp=$(echo "$data" | grep -o '"temperature":[0-9.]*' | tail -1 | cut -d: -f2)
code=$(echo "$data" | grep -o '"weathercode":[0-9]*' | tail -1 | cut -d: -f2)

case $code in
    0) condition="Clear"   icon="󰖙" ;;
    1|2|3) condition="Cloudy"  icon="󰖕" ;;
    45|48) condition="Foggy"   icon="󰖑" ;;
    51|53|55|61|63|65) condition="Rainy"   icon="󰖗" ;;
    71|73|75) condition="Snowy"   icon="󰼶" ;;
    80|81|82) condition="Showers" icon="󰖖" ;;
    95|96|99) condition="Stormy"  icon="󰖓" ;;
    *) condition="Unknown" icon="󰖔" ;;
esac

result="$icon  ${temp}°F $condition"
echo "$result" > "$CACHE_FILE"
echo "$result"
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SCRIPTS_DIR/wallpaper_picker.sh" > /dev/null
#!/bin/bash

WALLPAPER_DIR="$HOME/Pictures/wallpapers"
CACHE_DIR="$HOME/.cache/wallpaper_thumbs"
LIST_CACHE="$CACHE_DIR/wofi_list.txt"

mkdir -p "$CACHE_DIR"

if [ ! -f "$LIST_CACHE" ] || [ "$WALLPAPER_DIR" -nt "$LIST_CACHE" ]; then
    > "$LIST_CACHE"
    find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | while read -r img; do
        thumb="$CACHE_DIR/$(basename "$img").thumb.png"
        if [ ! -f "$thumb" ]; then
            magick "$img"[0] -thumbnail 200x200^ -gravity center -extent 200x200 "$thumb" 2>/dev/null
        fi
        echo "img:$thumb:text:$img"
    done > "$LIST_CACHE"
fi

selected=$(cat "$LIST_CACHE" | wofi --dmenu --allow-images --prompt "Wallpaper" --location=center)

if [ -n "$selected" ]; then
    full_path=$(echo "$selected" | sed 's/.*text://')
    swww img "$full_path" --transition-type wipe --transition-duration 1 --transition-fps 60
fi
EOF

chmod +x "$SCRIPTS_DIR/scroll_text.sh"
chmod +x "$SCRIPTS_DIR/weather.sh"
chmod +x "$SCRIPTS_DIR/wallpaper_picker.sh"
chown -R "$TARGET_USER:$TARGET_USER" "$SCRIPTS_DIR"
log "waybar scripts written."

# ---- Wofi ----
log "--- Writing wofi config ---"
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
log "wofi config written."

# ---- Swaync ----
log "--- Writing swaync config ---"
SWAYNC_DIR="$USER_HOME/.config/swaync"
sudo -u "$TARGET_USER" mkdir -p "$SWAYNC_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SWAYNC_DIR/config.json" > /dev/null
{
  "notification-visibility": {
    "kew": {
      "state": "ignored",
      "app-name": "kew"
    }
  }
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$SWAYNC_DIR"
log "swaync config written."

# ---- Fastfetch on terminal open ----
BASHRC="$USER_HOME/.bashrc"
sudo -u "$TARGET_USER" touch "$BASHRC"
if ! grep -q "fastfetch auto-run" "$BASHRC"; then
    cat <<'EOF' | sudo -u "$TARGET_USER" tee -a "$BASHRC" > /dev/null

# fastfetch auto-run — added by arch_install_laptop.sh
fastfetch
EOF
    log ".bashrc updated — fastfetch will run on every new terminal."
fi

# ---- Screenshots & Wallpapers directories ----
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/Screenshots"
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/wallpapers"

# =========================================================
# --- 16. Enable Login Manager ---
# =========================================================
if ! command -v ly &> /dev/null; then
    pacman -S --needed --noconfirm ly 2>/dev/null || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild ly
fi
systemctl enable ly@tty2

echo ""
echo "============================================="
echo "           SETUP COMPLETE"
echo "============================================="
echo "  Standard Arch repos (no CachyOS — Sandy Bridge is x86_64_v2)."
echo "  linux-lts kernel installed (stable, better for older hardware)."
echo "  Intel microcode (intel-ucode) installed."
echo "  nouveau graphics stack via mesa/gallium."
echo "  TLP power management enabled."
echo "  PipeWire user services enabled."
echo "  swww-daemon, $HYPRPOLKIT_BIN, swaync, cliphist, kew in exec-once."
echo ""
echo "  App configs written:"
echo "    - fastfetch      → ~/.config/fastfetch/config.jsonc (includes battery)"
echo "    - kitty          → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - waybar         → ~/.config/waybar/config.json + style.css"
echo "    - waybar scripts → scroll_text.sh, weather.sh, wallpaper_picker.sh"
echo "    - wofi           → ~/.config/wofi/config + style.css"
echo "    - swaync         → ~/.config/swaync/config.json (kew notifications silenced)"
echo "    - fastfetch runs automatically on every new terminal (via .bashrc)"
echo "    - Screenshots pre-created at ~/Pictures/Screenshots"
echo "    - Wallpapers directory pre-created at ~/Pictures/wallpapers"
echo ""
echo "  Next steps after reboot:"
echo "    - Add wallpapers to ~/Pictures/wallpapers"
echo "    - Set initial wallpaper: swww img /path/to/wallpaper"
echo "    - Open wallpaper picker: SUPER+Z"
echo "    - Configure Qt theming: qt6ct"
echo "    - Check battery status: cat /sys/class/power_supply/BAT0/status"
echo "    - Monitor power usage: sudo powertop"
echo "    - Check TLP status: sudo tlp-stat -s"
echo "    - If display is wrong resolution: hyprctl monitors all"
echo "      then adjust eDP-1 line in ~/.config/hypr/hyprland.conf"
echo "    - Brightness keys (Fn+F4/F5) and volume keys work out of the box"
echo "    - Music controls: SUPER+ALT+P/Left/Right via kew+playerctl"
echo "    - Log in via ly and enjoy Hyprland"
echo "============================================="
echo ""
read -p "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
