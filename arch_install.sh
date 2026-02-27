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

# Simple timestamped logger — writes to terminal AND logfile without redirecting
# stdout/stderr, so pacman, interactive scripts and prompts all work normally.
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

log "=== System Setup for $TARGET_USER (CPU: Zen 3 | GPU: RDNA3) ==="

# =========================================================
# --- 1. Collect All Prompts Upfront ---
# All questions asked before any downloads begin so the rest runs unattended.
# =========================================================
echo ""
read -p "Enter your country for mirror optimization (e.g. US, GB, DE, AU) [default: US]: " MIRROR_COUNTRY
MIRROR_COUNTRY="${MIRROR_COUNTRY:-US}"

read -p "Install Gaming Stack (Steam / Lutris)? (y/N): " install_games
install_games="${install_games:-N}"

install_rocm="N"
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    read -p "Install ROCm / HIP for LM Studio GPU acceleration on RDNA3? (~2 GB) (y/N): " install_rocm
    install_rocm="${install_rocm:-N}"
fi

echo ""
log "Mirror country : $MIRROR_COUNTRY"
log "Gaming stack   : $install_games"
log "ROCm           : $install_rocm"
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
# Enable parallel downloads if not already set (speeds up large installs)
grep -q '^ParallelDownloads' /etc/pacman.conf || \
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
pacman -Syy --noconfirm

# =========================================================
# --- 4. CachyOS Repositories ---
# =========================================================
log "--- Adding CachyOS Repos ---"
curl -L https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz
tar xf /tmp/cachyos-repo.tar.xz -C /tmp

# Subshell so cd cannot affect the rest of the script
(
    cd /tmp/cachyos-repo
    chmod +x ./cachyos-repo.sh
    ./cachyos-repo.sh
)

if ! grep -q '\[cachyos\]' /etc/pacman.conf; then
    log "ERROR: CachyOS repo setup failed — [cachyos] not found in pacman.conf."
    exit 1
fi

rm -rf /tmp/cachyos-repo*

# cachyos-gaming-meta brings in a full optimised stack: mesa-git, vulkan-radeon-git,
# libva, jack, wine etc. Do NOT install conflicting stable versions in later sections.
pacman -Syu --needed --noconfirm cachyos-settings cachyos-hooks cachyos-gaming-meta

# yay available in CachyOS repos — fall back to building from AUR if not found.
if ! pacman -S --needed --noconfirm yay 2>/dev/null; then
    log "WARNING: yay not in CachyOS repos — building from AUR as fallback."
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
log "--- Installing CachyOS Kernel & Sched-ext Schedulers ---"
pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers scx-scheds
# mkinitcpio triggered automatically via pacman hooks.

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
# --- 6. Graphics Stack extras ---
# =========================================================
log "--- Installing Graphics Stack extras ---"
# cachyos-gaming-meta already provides mesa-git/vulkan-radeon-git/libva — installing
# stable versions here would conflict. Only add tools that sit on top.
pacman -S --needed --noconfirm \
    vulkan-tools \
    gamescope ffmpeg

# =========================================================
# --- 7. Audio Stack (PipeWire) ---
# =========================================================
log "--- Installing PipeWire audio stack ---"
# pipewire-jack omitted — cachyos-gaming-meta installs jack which conflicts with it.
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse \
    wireplumber pavucontrol pamixer playerctl

# =========================================================
# --- 8. Qt / Wayland Integration ---
# =========================================================
log "--- Installing Qt Wayland support ---"
# qt6ct-kde (AUR, section 11) replaces vanilla qt6ct — only install platform plugins here.
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
    blueman network-manager-applet

pacman -S --needed --noconfirm ananicy-cpp || \
    log "ananicy-cpp not in repos — will install via yay in AUR section."

# =========================================================
# --- 10. Productivity Apps ---
# =========================================================
log "--- Installing Productivity Applications ---"
pacman -S --needed --noconfirm \
    libreoffice-fresh okular krita anki

# =========================================================
# --- 11. AUR Packages ---
# =========================================================
log "--- Installing AUR packages (running as $TARGET_USER) ---"
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

# Auto-detect hyprpolkit binary name — shipped as both 'hyprpolkit' and 'hyprpolkit-agent'
if command -v hyprpolkit-agent &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit-agent"
elif command -v hyprpolkit &> /dev/null; then
    HYPRPOLKIT_BIN="hyprpolkit"
else
    log "WARNING: hyprpolkit binary not found — defaulting to 'hyprpolkit', adjust if needed."
    HYPRPOLKIT_BIN="hyprpolkit"
fi
log "Detected hyprpolkit binary: $HYPRPOLKIT_BIN"

# =========================================================
# --- 12. Gaming Stack (Optional) ---
# =========================================================
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    log "--- Installing Gaming Stack ---"
    # wine/winetricks omitted — cachyos-gaming-meta already provides its own wine build.
    pacman -S --needed --noconfirm steam lutris

    if [[ "$install_rocm" =~ ^[Yy]$ ]]; then
        log "--- Installing ROCm HIP SDK ---"
        pacman -S --needed --noconfirm rocm-hip-sdk
    fi
fi

# =========================================================
# --- 13. System Services ---
# =========================================================
log "--- Enabling system services ---"
loginctl enable-linger "$TARGET_USER"
sudo -u "$TARGET_USER" xdg-user-dirs-update

systemctl enable --now scx
systemctl enable --now ananicy-cpp
systemctl enable --now bluetooth

# ly runs on tty2 — disable getty@tty2 to free it up
systemctl disable getty@tty2 || true

# PipeWire must be enabled at the user level to autostart in Hyprland sessions
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

# --- amd_pstate ---
PSTATE_CURRENT=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
if [[ "$PSTATE_CURRENT" != "amd-pstate-epp" ]]; then
    log "--- amd_pstate not active (current: $PSTATE_CURRENT) — applying fix ---"
    if command -v grub-mkconfig &> /dev/null && [ -f /etc/default/grub ]; then
        if ! grep -q 'amd_pstate=active' /etc/default/grub; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_pstate=active"/' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg
            log "amd_pstate=active added to GRUB and grub.cfg regenerated."
        fi
    elif [ -d "/boot/loader/entries" ]; then
        log "NOTE (systemd-boot): Manually add 'amd_pstate=active' to options line in"
        log "  /boot/loader/entries/<your-entry>.conf"
    fi
else
    log "amd_pstate EPP driver already active — no changes needed."
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
# hyprland.conf — Auto-generated by arch_install.sh (2026)
# =============================================================================
# Auto-Injected — marker used by install script to detect re-runs


# =============================================================================
# MONITORS
# =============================================================================

monitor=DP-1, 2560x1440@239.97, 0x0, 1, bitdepth, 10
monitor=DP-3, 2560x1440@143.96, -2560x0, 1


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

# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

env = XMODIFIERS,@im=fcitx

env = QT_QPA_PLATFORMTHEME,qt6ct
env = QT_QPA_PLATFORM,wayland

# ROCm / HIP: force RDNA3 (gfx1100) target — remove if not using ROCm.
env = HSA_OVERRIDE_GFX_VERSION,11.0.0

# =============================================================================
# DEFAULT PROGRAMS
# =============================================================================

$terminal    = kitty
$fileManager = pcmanfm-qt
$menu        = pgrep wofi > /dev/null 2>&1 && killall wofi || wofi --show drun


# =============================================================================
# WORKSPACES
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

bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive,
bind = $mainMod SHIFT, S, exec, hyprshot --mode region --output-folder ~/Pictures/Screenshots
bind = $mainMod, E, exec, $fileManager
bind = $mainMod SHIFT, SPACE, togglefloating,
bind = $mainMod, F, fullscreen,
bind = $mainMod, D, exec, $menu
bind = $mainMod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

# Music Controls (kew + playerctl)
bind = SUPER ALT, P,     exec, playerctl --player=kew play-pause
bind = SUPER ALT, right, exec, playerctl --player=kew next
bind = SUPER ALT, left,  exec, playerctl --player=kew previous
bind = SUPER ALT, up,    exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = SUPER ALT, down,  exec, pactl set-sink-volume @DEFAULT_SINK@ -5%

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
        { "type": "memory", "key": "memory" },
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
  "margin-right": 370,
  "margin-left": 370,
  "modules-left": [
    "hyprland/workspaces",
    "sway/workspaces"
  ],
  "modules-center": [
    "custom/applauncher"
  ],
  "modules-right": [
    "network",
    "battery",
    "pulseaudio",
    "tray",
    "clock"
  ],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": false,
    "tooltip": false
  },
  "sway/workspaces": {
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
    "format-icons": [
      "",
      "",
      " "
    ],
    "nospacing": 1,
    "format-muted": " ",
    "on-click": "pavucontrol",
    "tooltip": false
  },
  "battery": {
    "states": {
      "warning": 30,
      "critical": 15
    },
    "format": "{icon} {capacity}%",
    "format-charging": "󰂄 {capacity}%",
    "format-plugged": "󰂄{capacity}%",
    "format-alt": "{icon} {time}",
    "format-full": "󱈑 {capacity}%",
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
  /* General taskbar font, I like maple mono ^-^*/
  font-family: Maple Mono;
  border-radius: 8;
  font-size: 13px;
  padding: 0px;
  background: transparent;
}

window#waybar {
  /* Linear gradients are used because it makes less harsh rounded border radius, gtk bug :p */
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
  letter-spacing: 3px;
}

/*  */
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
  padding: 0px 25px 0px 25px;
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
log "waybar config written."

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

# ---- Fastfetch on terminal open ----
BASHRC="$USER_HOME/.bashrc"
sudo -u "$TARGET_USER" touch "$BASHRC"
if ! grep -q "fastfetch auto-run" "$BASHRC"; then
    cat <<'EOF' | sudo -u "$TARGET_USER" tee -a "$BASHRC" > /dev/null

# fastfetch auto-run — added by arch_install.sh
fastfetch
EOF
    log ".bashrc updated — fastfetch will run on every new terminal."
fi

# ---- Screenshots directory ----
# Pre-create so hyprshot doesn't fail silently on first use
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/Screenshots"

# =========================================================
# --- 16. Enable Login Manager ---
# =========================================================
if ! command -v ly &> /dev/null; then
    pacman -S --needed --noconfirm ly 2>/dev/null || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild ly
fi
# ly@tty2 is the correct service name — ly runs on tty2
systemctl enable ly@tty2

echo ""
echo "============================================="
echo "           SETUP COMPLETE"
echo "============================================="
echo "  CachyOS performance settings applied."
echo "  scx systemd service manages Zen 3 scheduling."
echo "  PipeWire user services enabled."
echo "  swww-daemon, $HYPRPOLKIT_BIN, swaync, cliphist in exec-once."
echo ""
echo "  App configs written:"
echo "    - fastfetch  → ~/.config/fastfetch/config.jsonc"
echo "    - kitty      → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - waybar     → ~/.config/waybar/config.json + style.css"
echo "    - wofi       → ~/.config/wofi/config + style.css"
echo "    - fastfetch runs automatically on every new terminal (via .bashrc)"
echo "    - Screenshots pre-created at ~/Pictures/Screenshots"
echo ""
echo "  Next steps after reboot:"
echo "    - Set a wallpaper:  swww img /path/to/wallpaper"
echo "    - Configure Qt theming: qt6ct"
echo "      (If KDE apps look off, re-open qt6ct and select the qt6ct-kde variant)"
echo "    - Test Vulkan: vkcube  |  Test VA-API: vainfo"
echo "    - amd_pstate: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
echo "      (should read 'amd-pstate-epp')"
echo "    - Music controls: SUPER+ALT+P/Left/Right/Up/Down via kew+playerctl"
echo "    - ROCm / LM Studio: HSA_OVERRIDE_GFX_VERSION=11.0.0 pre-set in hyprland.conf"
echo "    - Log in via ly and enjoy Hyprland"
echo "============================================="
echo ""
read -p "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
