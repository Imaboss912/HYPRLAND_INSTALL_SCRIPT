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

# Simple timestamped logger
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

read -p "Install Gaming Stack (Steam / Lutris / cachyos-gaming-meta)? (y/N): " install_games
install_games="${install_games:-N}"

install_rocm="N"
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    read -p "Install ROCm / HIP for LM Studio GPU acceleration on RDNA3? (~2 GB) (y/N): " install_rocm
    install_rocm="${install_rocm:-N}"
fi

echo ""
read -p "Weather widget latitude  [default: 33.9806 (Riverside, CA)]: " WEATHER_LAT
WEATHER_LAT="${WEATHER_LAT:-33.9806}"
read -p "Weather widget longitude [default: -117.3755 (Riverside, CA)]: " WEATHER_LON
WEATHER_LON="${WEATHER_LON:-117.3755}"

echo ""
log "Mirror country : $MIRROR_COUNTRY"
log "Gaming stack   : $install_games"
log "ROCm           : $install_rocm"
log "Weather coords : $WEATHER_LAT, $WEATHER_LON"
log "Starting unattended install..."
echo ""

# =========================================================
# --- 2. Base Tools & Mirror Optimization ---
# NOTE: No full system upgrade yet — CachyOS repos are added in section 4
# so the upgrade picks up all CachyOS packages in one pass.
# =========================================================
log "--- Installing base tools & optimizing mirrors ---"
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
# --- 4. CachyOS Repositories & Full System Upgrade ---
# Upgrade happens here so CachyOS optimized packages are included from start.
# =========================================================
log "--- Adding CachyOS Repos ---"
curl -L https://mirror.cachyos.org/cachyos-repo.tar.xz -o /tmp/cachyos-repo.tar.xz
tar xf /tmp/cachyos-repo.tar.xz -C /tmp

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

log "--- Full system upgrade with CachyOS repos active ---"
pacman -Syu --needed --noconfirm cachyos-settings cachyos-hooks

# yay — available in CachyOS repos, fall back to AUR build if not found
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
# --- 6. Graphics Stack ---
# =========================================================
log "--- Installing Graphics Stack ---"
# cachyos-gaming-meta (mesa-git, vulkan-radeon-git, wine etc.) is installed
# conditionally in section 12 — do not add conflicting stable versions here.
pacman -S --needed --noconfirm \
    vulkan-tools \
    gamescope ffmpeg

# =========================================================
# --- 7. Audio Stack (PipeWire) ---
# =========================================================
log "--- Installing PipeWire audio stack ---"
# pipewire-jack omitted — cachyos-gaming-meta installs jack which conflicts.
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse \
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
    nwg-look papirus-icon-theme \
    qt5ct kvantum tumbler

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
    stremio \
    matugen \
    adw-gtk-theme-git

# Auto-detect hyprpolkit binary name
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
# --- 12. Gaming Stack (Optional) ---
# cachyos-gaming-meta installs here to avoid conflicts with stable
# mesa/vulkan packages that would be pulled in unconditionally.
# =========================================================
if [[ "$install_games" =~ ^[Yy]$ ]]; then
    log "--- Installing Gaming Stack ---"
    pacman -S --needed --noconfirm steam lutris cachyos-gaming-meta

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

# PipeWire must be enabled at user level to autostart in Hyprland sessions
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

# Material You border colors — regenerated by matugen on every wallpaper change
source = ~/.config/hypr/colors.conf


# =============================================================================
# MONITORS
# =============================================================================

monitor=DP-1, 2560x1440@239.97, 0x0, 1, bitdepth, 10
monitor=DP-3, 2560x1440@143.96, -2560x0, 1


# =============================================================================
# STARTUP (exec-once)
# =============================================================================

# Pass Wayland environment to DBus and systemd before anything else —
# required for xdg-desktop-portal to initialize quickly and correctly.
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

exec-once = swww-daemon
exec-once = HYPRPOLKIT_PLACEHOLDER
exec-once = swaync
exec-once = fcitx5 -d
exec-once = hyprsunset -t 4500
exec-once = wl-paste --watch cliphist store

# Restore last wallpaper and regenerate matugen colors
exec-once = sleep 0.3 && ~/.config/scripts/wallpaper.sh --reload
# Start waybar after wallpaper/colors are ready
exec-once = sleep 0.5 && waybar
# Pre-warm xdg-desktop-portal so first app launch isn't slow
exec-once = sleep 1 && /usr/lib/xdg-desktop-portal-hyprland
exec-once = sleep 1.5 && systemctl --user restart xdg-desktop-portal
exec-once = sleep 2 && kew


# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

env = XMODIFIERS,@im=fcitx

# Qt theming — qt6ct-kde is installed; run qt6ct after first login to configure.
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

workspace = 9, monitor:DP-3, default:true, persistent:true


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

    col.active_border   = $active_border
    col.inactive_border = $inactive_border

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

# ---- Matugen ----
log "--- Writing matugen config and templates ---"
MATUGEN_DIR="$USER_HOME/.config/matugen"
sudo -u "$TARGET_USER" mkdir -p "$MATUGEN_DIR/templates"

# config.toml — unquoted heredoc so $USER_HOME expands
cat << EOF | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/config.toml" > /dev/null
# ~/.config/matugen/config.toml
# Matugen generates Material You colors from your wallpaper
# and renders all templates below automatically.

[config]
reload_gtk_theme = true
set_wallpaper = false

[templates.waybar-colors]
input_path  = "$USER_HOME/.config/matugen/templates/waybar-colors.css"
output_path = "$USER_HOME/.config/waybar/colors.css"

[templates.kitty-colors]
input_path  = "$USER_HOME/.config/matugen/templates/kitty-colors.conf"
output_path = "$USER_HOME/.config/kitty/colors.conf"

[templates.wofi-colors]
input_path  = "$USER_HOME/.config/matugen/templates/wofi-colors.css"
output_path = "$USER_HOME/.config/wofi/colors.css"

[templates.gtk-colors]
input_path  = "$USER_HOME/.config/matugen/templates/gtk-colors.css"
output_path = "$USER_HOME/.config/gtk-3.0/colors.css"

[templates.gtk4-colors]
input_path  = "$USER_HOME/.config/matugen/templates/gtk-colors.css"
output_path = "$USER_HOME/.config/gtk-4.0/colors.css"

[templates.hyprland-colors]
input_path  = "$USER_HOME/.config/matugen/templates/hyprland-colors.conf"
output_path = "$USER_HOME/.config/hypr/colors.conf"

[templates.swaync]
input_path  = "$USER_HOME/.config/matugen/templates/swaync-style.css"
output_path = "$USER_HOME/.config/swaync/style.css"
EOF

# Waybar colors template
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/waybar-colors.css" > /dev/null
/* Auto-generated by matugen — do not edit by hand. */

@define-color primary                  {{colors.primary.default.hex}};
@define-color on_primary               {{colors.on_primary.default.hex}};
@define-color primary_container        {{colors.primary_container.default.hex}};
@define-color on_primary_container     {{colors.on_primary_container.default.hex}};
@define-color secondary                {{colors.secondary.default.hex}};
@define-color on_secondary             {{colors.on_secondary.default.hex}};
@define-color secondary_container      {{colors.secondary_container.default.hex}};
@define-color on_secondary_container   {{colors.on_secondary_container.default.hex}};
@define-color tertiary                 {{colors.tertiary.default.hex}};
@define-color on_tertiary              {{colors.on_tertiary.default.hex}};
@define-color background               {{colors.background.default.hex}};
@define-color on_background            {{colors.on_background.default.hex}};
@define-color surface                  {{colors.surface.default.hex}};
@define-color on_surface               {{colors.on_surface.default.hex}};
@define-color surface_variant          {{colors.surface_variant.default.hex}};
@define-color on_surface_variant       {{colors.on_surface_variant.default.hex}};
@define-color outline                  {{colors.outline.default.hex}};
@define-color outline_variant          {{colors.outline_variant.default.hex}};
@define-color error                    {{colors.error.default.hex}};
@define-color on_error                 {{colors.on_error.default.hex}};
EOF

# Kitty colors template
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/kitty-colors.conf" > /dev/null
# Auto-generated by matugen — source of truth is the template.
# Included by kitty.conf via: include colors.conf

background            {{colors.background.default.hex}}
foreground            {{colors.on_background.default.hex}}

selection_background  {{colors.primary.default.hex}}
selection_foreground  {{colors.on_primary.default.hex}}

cursor                {{colors.primary.default.hex}}
cursor_text_color     {{colors.on_primary.default.hex}}

url_color             {{colors.tertiary.default.hex}}

color0  {{colors.surface.default.hex}}
color8  {{colors.surface_variant.default.hex}}
color1  {{colors.error.default.hex}}
color9  {{colors.error.default.hex}}
color2  {{colors.tertiary.default.hex}}
color10 {{colors.tertiary_container.default.hex}}
color3  {{colors.secondary.default.hex}}
color11 {{colors.secondary_container.default.hex}}
color4  {{colors.primary.default.hex}}
color12 {{colors.primary_container.default.hex}}
color5  {{colors.on_tertiary_container.default.hex}}
color13 {{colors.tertiary.default.hex}}
color6  {{colors.on_secondary_container.default.hex}}
color14 {{colors.secondary.default.hex}}
color7  {{colors.on_surface.default.hex}}
color15 {{colors.on_background.default.hex}}
EOF

# Wofi colors template
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/wofi-colors.css" > /dev/null
/* Auto-generated by matugen — do not edit by hand. */

@define-color primary               {{colors.primary.default.hex}};
@define-color on_primary            {{colors.on_primary.default.hex}};
@define-color primary_container     {{colors.primary_container.default.hex}};
@define-color on_primary_container  {{colors.on_primary_container.default.hex}};
@define-color secondary             {{colors.secondary.default.hex}};
@define-color on_secondary          {{colors.on_secondary.default.hex}};
@define-color background            {{colors.background.default.hex}};
@define-color on_background         {{colors.on_background.default.hex}};
@define-color surface               {{colors.surface.default.hex}};
@define-color on_surface            {{colors.on_surface.default.hex}};
@define-color surface_variant       {{colors.surface_variant.default.hex}};
@define-color on_surface_variant    {{colors.on_surface_variant.default.hex}};
@define-color outline               {{colors.outline.default.hex}};
@define-color outline_variant       {{colors.outline_variant.default.hex}};
EOF

# GTK colors template (shared by gtk-3.0 and gtk-4.0)
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/gtk-colors.css" > /dev/null
/* Auto-generated by matugen. Imported by gtk.css */

@define-color accent_color           {{colors.primary.default.hex}};
@define-color accent_bg_color        {{colors.primary.default.hex}};
@define-color accent_fg_color        {{colors.on_primary.default.hex}};
@define-color window_bg_color        {{colors.background.default.hex}};
@define-color window_fg_color        {{colors.on_background.default.hex}};
@define-color view_bg_color          {{colors.surface.default.hex}};
@define-color view_fg_color          {{colors.on_surface.default.hex}};
@define-color headerbar_bg_color     {{colors.surface_variant.default.hex}};
@define-color headerbar_fg_color     {{colors.on_surface_variant.default.hex}};
@define-color headerbar_border_color {{colors.outline_variant.default.hex}};
@define-color popover_bg_color       {{colors.surface_variant.default.hex}};
@define-color popover_fg_color       {{colors.on_surface_variant.default.hex}};
@define-color card_bg_color          {{colors.surface_variant.default.hex}};
@define-color card_fg_color          {{colors.on_surface_variant.default.hex}};
@define-color sidebar_bg_color       {{colors.surface.default.hex}};
@define-color sidebar_fg_color       {{colors.on_surface.default.hex}};
@define-color error_color            {{colors.error.default.hex}};
EOF

# Hyprland border colors template
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/hyprland-colors.conf" > /dev/null
# Auto-generated by matugen — do not edit by hand.
$active_border   = rgb({{colors.primary.default.hex_stripped}})
$inactive_border = rgb({{colors.surface_variant.default.hex_stripped}})
EOF

# Swaync style template
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$MATUGEN_DIR/templates/swaync-style.css" > /dev/null
/* Auto-generated by matugen — do not edit by hand. */

* {
    font-family: "JetBrainsMono Nerd Font", monospace;
    font-size:   13px;
}

.control-center,
.notification-row .notification {
    background:    {{colors.surface.default.hex}};
    border:        1px solid {{colors.outline_variant.default.hex}};
    border-radius: 12px;
    color:         {{colors.on_surface.default.hex}};
}

.control-center {
    margin:  8px;
    padding: 8px;
}

.notification-row .notification {
    margin:  4px 8px;
    padding: 12px;
}

.notification-row .summary {
    font-weight: 700;
    color:       {{colors.on_surface.default.hex}};
}

.notification-row .body {
    color: {{colors.on_surface_variant.default.hex}};
}

.notification-row .time {
    color:     {{colors.on_surface_variant.default.hex}};
    font-size: 11px;
}

.notification-row .close-button {
    background:    {{colors.surface_variant.default.hex}};
    color:         {{colors.on_surface_variant.default.hex}};
    border-radius: 6px;
    border:        none;
    padding:       2px 6px;
}

.notification-row .close-button:hover {
    background: {{colors.primary.default.hex}};
    color:      {{colors.on_primary.default.hex}};
}

.notification-row.critical .notification {
    border-color: {{colors.error.default.hex}};
}

.widget-title {
    font-size:   15px;
    font-weight: 700;
    color:       {{colors.on_surface.default.hex}};
    padding:     8px 4px;
}

.widget-dnd {
    background:    {{colors.surface_variant.default.hex}};
    border-radius: 8px;
    padding:       4px 8px;
    color:         {{colors.on_surface_variant.default.hex}};
}

.widget-dnd > switch:checked {
    background: {{colors.primary.default.hex}};
}
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$MATUGEN_DIR"
log "matugen config and templates written."

# ---- Central wallpaper script ----
log "--- Writing central wallpaper script ---"
SCRIPTS_DIR_MAIN="$USER_HOME/.config/scripts"
sudo -u "$TARGET_USER" mkdir -p "$SCRIPTS_DIR_MAIN"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SCRIPTS_DIR_MAIN/wallpaper.sh" > /dev/null
#!/usr/bin/env bash
# ~/.config/scripts/wallpaper.sh
# ─────────────────────────────────────────────────────────────────────
# Central wallpaper + theme switcher.
# Usage:
#   wallpaper.sh /path/to/image.jpg         — set wallpaper + regen colors
#   wallpaper.sh --random ~/Pictures/Walls  — pick a random image from dir
#   wallpaper.sh --reload                   — re-run matugen on last wallpaper
# ─────────────────────────────────────────────────────────────────────

LAST_WALL_FILE="$HOME/.cache/current_wallpaper"

log() { echo "[wallpaper] $*"; }
die() { echo "[wallpaper] ERROR: $*" >&2; exit 1; }

reload_waybar() {
    if pkill -SIGUSR2 waybar 2>/dev/null; then
        log "Waybar CSS reloaded"
    else
        log "Waybar not running, starting it..."
        waybar &
    fi
}

reload_kitty() {
    pkill -SIGUSR1 kitty 2>/dev/null && log "Kitty reloaded" || log "No kitty instances found"
}

reload_swaync() {
    swaync-client --reload-css 2>/dev/null && log "Swaync reloaded" || true
}

reload_hyprland() {
    hyprctl reload 2>/dev/null && log "Hyprland reloaded" || true
}

case "$1" in
    --reload)
        WALLPAPER=$(cat "$LAST_WALL_FILE" 2>/dev/null)
        [[ -z "$WALLPAPER" ]] && die "No cached wallpaper found. Set one first."
        log "Reloading colors from cached wallpaper: $WALLPAPER"
        ;;
    --random)
        DIR="${2:-$HOME/Pictures}"
        WALLPAPER=$(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \
            -o -iname "*.png" -o -iname "*.webp" \) | shuf -n 1)
        [[ -z "$WALLPAPER" ]] && die "No images found in $DIR"
        log "Random pick: $WALLPAPER"
        ;;
    "")
        die "No wallpaper specified. Usage: wallpaper.sh /path/to/image.jpg"
        ;;
    *)
        WALLPAPER="$1"
        [[ -f "$WALLPAPER" ]] || die "File not found: $WALLPAPER"
        ;;
esac

log "Setting wallpaper: $WALLPAPER"
swww img "$WALLPAPER" \
    --transition-type     wipe \
    --transition-duration 1 \
    --transition-fps      143

echo "$WALLPAPER" > "$LAST_WALL_FILE"

log "Running matugen..."
matugen image "$WALLPAPER" || die "matugen failed. Is it installed? (yay -S matugen)"

sleep 0.3

reload_waybar
reload_kitty
reload_swaync
reload_hyprland

log "Done! Theme updated from: $(basename "$WALLPAPER")"
EOF

chmod +x "$SCRIPTS_DIR_MAIN/wallpaper.sh"
chown "$TARGET_USER:$TARGET_USER" "$SCRIPTS_DIR_MAIN/wallpaper.sh"
log "wallpaper.sh written."

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

# Default colors.conf — matugen overwrites this on first wallpaper change
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$KITTY_DIR/colors.conf" > /dev/null
# Default colors — replaced by matugen on first wallpaper change.
background            #0e1415
foreground            #dee4e4
selection_background  #80d4dc
selection_foreground  #003735
cursor                #80d4dc
cursor_text_color     #003735
url_color             #c2c4eb
color0   #4c4c4c
color8   #262626
color1   #ac8a8c
color9   #c49ea0
color2   #8aac8b
color10  #9ec49f
color3   #aca98a
color11  #c4c19e
color4   #80d4dc
color12  #a39ec4
color5   #ac8aac
color13  #c49ec4
color6   #8aacab
color14  #9ec3c4
color7   #f0f0f0
color15  #e7e7e7
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$KITTY_DIR"
log "kitty config written."

# ---- Waybar ----
log "--- Writing waybar config ---"
WAYBAR_DIR="$USER_HOME/.config/waybar"
sudo -u "$TARGET_USER" mkdir -p "$WAYBAR_DIR/scripts"

# Named 'config' (not config.json) — waybar loads this by default
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/config" > /dev/null
{
  "layer": "top",
  "spacing": 0,
  "height": 0,
  "margin-top": 8,
  "margin-bottom": 0,
  "position": "top",
  "margin-right": 370,
  "margin-left": 370,

  "modules-left": [
    "hyprland/workspaces"
  ],
  "modules-center": [
    "custom/media"
  ],
  "modules-right": [
    "custom/wallpaper",
    "network",
    "pulseaudio",
    "tray",
    "custom/weather",
    "clock"
  ],

  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": false,
    "tooltip": false,
    "format": "{icon}",
    "format-icons": {
      "1": "一", "2": "二", "3": "三", "4": "四", "5": "五",
      "6": "六", "7": "七", "8": "八", "9": "九",
      "urgent": "", "default": "·"
    },
    "persistent-workspaces": {
      "1": [], "2": [], "3": [], "4": [], "5": []
    }
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

  "network": {
    "format-wifi":         "  {bandwidthDownBits}",
    "format-ethernet":     "  {bandwidthDownBits}",
    "format-disconnected": "󰤮  No Network",
    "interval": 5,
    "tooltip": false
  },

  "pulseaudio": {
    "scroll-step": 5,
    "max-volume": 150,
    "format":           "{icon}  {volume}%",
    "format-bluetooth": "{icon}  {volume}%",
    "format-muted":     " ",
    "format-icons":     ["", "", " "],
    "nospacing": 1,
    "on-click": "pavucontrol",
    "tooltip": false
  },

  "tray": {
    "spacing": 10,
    "tooltip": false
  },

  "clock": {
    "format": "󰅐  {:%H:%M}",
    "tooltip": false
  }
}
EOF

# style.css — imports matugen-generated colors.css
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/style.css" > /dev/null
/* Colors live in colors.css — regenerated by matugen on wallpaper change. */
@import "colors.css";

* {
    font-family:    "Maple Mono", "JetBrainsMono Nerd Font", monospace;
    font-size:      13px;
    font-weight:    500;
    border:         none;
    border-radius:  0;
    min-height:     0;
    margin:         0;
    padding:        0;
}

window#waybar {
    background:    alpha(@surface, 0.88);
    border:        1px solid alpha(@outline_variant, 0.35);
    border-radius: 12px;
    color:         @on_surface;
}

.modules-left,
.modules-center,
.modules-right {
    background:    transparent;
    border:        none;
    border-radius: 0;
    padding:       0 4px;
}

#workspaces {
    background:  transparent;
    padding:     0 2px;
}

#workspaces button {
    padding:       2px 10px;
    margin:        4px 2px;
    border-radius: 8px;
    color:         @on_surface_variant;
    background:    transparent;
    font-size:     12px;
    transition:    all 150ms ease;
}

#workspaces button:hover {
    background:  alpha(@primary, 0.15);
    color:       @primary;
}

#workspaces button.active {
    background:  @primary_container;
    color:       @on_primary_container;
    font-weight: 700;
}

#workspaces button.urgent {
    background: @error;
    color:      @on_error;
}

#custom-media {
    padding:        0 16px;
    color:          @primary;
    font-style:     italic;
    font-size:      12px;
    letter-spacing: 0.02em;
    min-width:      280px;
}

#custom-wallpaper,
#custom-weather,
#network,
#pulseaudio,
#tray,
#clock {
    padding:    0 12px;
    color:      @on_surface_variant;
    transition: color 150ms ease, background 150ms ease;
}

#custom-wallpaper:hover,
#custom-weather:hover,
#network:hover,
#pulseaudio:hover {
    color:         @primary;
    background:    alpha(@primary, 0.1);
    border-radius: 8px;
}

#custom-wallpaper {
    font-size: 15px;
    color:     @secondary;
}

#custom-weather {
    color: @tertiary;
}

#network.disconnected {
    color: @error;
}

#pulseaudio.muted {
    color: @error;
}

#clock {
    color:          @on_surface;
    font-weight:    700;
    letter-spacing: 0.03em;
}

#tray {
    padding: 0 8px;
}

#tray > .passive {
    -gtk-icon-effect: dim;
}

#tray > .needs-attention {
    -gtk-icon-effect: highlight;
    background:       alpha(@error, 0.15);
    border-radius:    6px;
}
EOF

# Default colors.css — matugen overwrites on first wallpaper change
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WAYBAR_DIR/colors.css" > /dev/null
/* Default colors — replaced by matugen on first wallpaper change. */
@define-color primary                  #80d5d0;
@define-color on_primary               #003735;
@define-color primary_container        #00504d;
@define-color on_primary_container     #b4ebff;
@define-color secondary                #b3cad4;
@define-color on_secondary             #1d333b;
@define-color secondary_container      #344a52;
@define-color on_secondary_container   #cee6f0;
@define-color tertiary                 #c2c4eb;
@define-color on_tertiary              #2b2e4d;
@define-color background               #0f1416;
@define-color on_background            #dee3e6;
@define-color surface                  #0f1416;
@define-color on_surface               #dee3e6;
@define-color surface_variant          #40484b;
@define-color on_surface_variant       #bfc8cc;
@define-color outline                  #899296;
@define-color outline_variant          #40484b;
@define-color error                    #ffb4ab;
@define-color on_error                 #690005;
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

# weather.sh — written with placeholder coords, then injected via sed
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$SCRIPTS_DIR/weather.sh" > /dev/null
#!/bin/bash

LAT="WEATHER_LAT_PLACEHOLDER"
LON="WEATHER_LON_PLACEHOLDER"

# Wait for network, retry up to 10 times
for i in $(seq 1 10); do
    data=$(curl -sf --max-time 5 "https://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&current_weather=true&temperature_unit=fahrenheit" 2>/dev/null)
    [ -n "$data" ] && break
    sleep 3
done

if [ -z "$data" ]; then
    echo "N/A"
    exit 0
fi

temp=$(echo "$data" | grep -o '"temperature":[0-9.]*' | tail -1 | cut -d: -f2)
code=$(echo "$data" | grep -o '"weathercode":[0-9]*' | tail -1 | cut -d: -f2)

case $code in
    0)           condition="Clear"   icon="󰖙" ;;
    1|2|3)       condition="Cloudy"  icon="󰖕" ;;
    45|48)       condition="Foggy"   icon="󰖑" ;;
    51|53|55|61|63|65) condition="Rainy" icon="󰖗" ;;
    71|73|75)    condition="Snowy"   icon="󰼶" ;;
    80|81|82)    condition="Showers" icon="󰖖" ;;
    95|96|99)    condition="Stormy"  icon="󰖓" ;;
    *)           condition="Unknown" icon="󰖔" ;;
esac

echo "$icon  ${temp}°F $condition"
EOF

# Inject user-provided coordinates
sed -i "s|WEATHER_LAT_PLACEHOLDER|$WEATHER_LAT|" "$SCRIPTS_DIR/weather.sh"
sed -i "s|WEATHER_LON_PLACEHOLDER|$WEATHER_LON|" "$SCRIPTS_DIR/weather.sh"

# wallpaper_picker.sh — calls central wallpaper.sh so matugen fires on pick
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
        echo "img:$thumb:text:$(basename $img)"
    done > "$LIST_CACHE"
fi

selected=$(cat "$LIST_CACHE" | wofi --dmenu --allow-images --prompt "Wallpaper" --location=top --location=center)

if [ -n "$selected" ]; then
    filename=$(echo "$selected" | sed 's/.*text://')
    full_path="$WALLPAPER_DIR/$filename"
    ~/.config/scripts/wallpaper.sh "$full_path"
fi
EOF

chmod +x "$SCRIPTS_DIR/scroll_text.sh"
chmod +x "$SCRIPTS_DIR/weather.sh"
chmod +x "$SCRIPTS_DIR/wallpaper_picker.sh"
chown -R "$TARGET_USER:$TARGET_USER" "$SCRIPTS_DIR"
log "waybar scripts written."

# ---- GTK 3.0 & 4.0 ----
log "--- Writing GTK configs ---"
GTK3_DIR="$USER_HOME/.config/gtk-3.0"
GTK4_DIR="$USER_HOME/.config/gtk-4.0"
sudo -u "$TARGET_USER" mkdir -p "$GTK3_DIR" "$GTK4_DIR"

for GTK_DIR in "$GTK3_DIR" "$GTK4_DIR"; do
    cat <<'EOF' | sudo -u "$TARGET_USER" tee "$GTK_DIR/gtk.css" > /dev/null
/* Imports matugen-generated colors — regenerated on every wallpaper change. */
@import "colors.css";

@define-color theme_selected_bg_color @primary;
@define-color theme_selected_fg_color @on_primary;

headerbar {
    background-color: @headerbar_bg_color;
    color:            @headerbar_fg_color;
}

window,
.background {
    background-color: @window_bg_color;
    color:            @window_fg_color;
}
EOF

    # Default colors.css — matugen overwrites on first wallpaper change
    cat <<'EOF' | sudo -u "$TARGET_USER" tee "$GTK_DIR/colors.css" > /dev/null
/* Default colors — replaced by matugen on first wallpaper change. */
@define-color accent_color           #80d5d0;
@define-color accent_bg_color        #80d5d0;
@define-color accent_fg_color        #003735;
@define-color window_bg_color        #0f1416;
@define-color window_fg_color        #dee3e6;
@define-color view_bg_color          #0f1416;
@define-color view_fg_color          #dee3e6;
@define-color headerbar_bg_color     #40484b;
@define-color headerbar_fg_color     #bfc8cc;
@define-color headerbar_border_color #40484b;
@define-color popover_bg_color       #40484b;
@define-color popover_fg_color       #bfc8cc;
@define-color card_bg_color          #40484b;
@define-color card_fg_color          #bfc8cc;
@define-color sidebar_bg_color       #0f1416;
@define-color sidebar_fg_color       #dee3e6;
@define-color error_color            #ffb4ab;
EOF
done

chown -R "$TARGET_USER:$TARGET_USER" "$GTK3_DIR" "$GTK4_DIR"
log "GTK 3.0 and 4.0 configs written."

# ---- Wofi ----
log "--- Writing wofi config ---"
WOFI_DIR="$USER_HOME/.config/wofi"
sudo -u "$TARGET_USER" mkdir -p "$WOFI_DIR"

# Unquoted heredoc so $USER_HOME expands for the style path
cat << EOF | sudo -u "$TARGET_USER" tee "$WOFI_DIR/config" > /dev/null
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
style=$USER_HOME/.config/wofi/style.css
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/style.css" > /dev/null
/* Colors imported from matugen-generated colors.css */
@import "colors.css";

* {
    font-family: "Maple Mono", "JetBrainsMono Nerd Font", monospace;
    font-size:   14px;
    border:      none;
    margin:      0;
    padding:     0;
}

window {
    background:    alpha(@background, 0.92);
    border:        1px solid alpha(@outline_variant, 0.6);
    border-radius: 16px;
}

#outer-box {
    padding: 12px;
}

#input {
    background:    @surface_variant;
    color:         @on_surface;
    border:        1px solid @outline_variant;
    border-radius: 10px;
    padding:       10px 14px;
    margin-bottom: 8px;
    caret-color:   @primary;
    outline:       none;
}

#input:focus {
    border-color: @primary;
    background:   alpha(@primary, 0.08);
}

#scroll {
    margin: 0;
}

#inner-box {
    margin: 0;
}

.entry {
    padding:       9px 12px;
    border-radius: 8px;
    color:         @on_surface;
    margin:        2px 0;
}

.entry:selected {
    background: @primary_container;
    color:      @on_primary_container;
}

.entry:selected .text {
    color: @on_primary_container;
}

.text {
    color:       @on_surface;
    margin-left: 4px;
}

image {
    margin-right:  10px;
    border-radius: 6px;
}
EOF

# Default wofi colors.css — matugen overwrites on first wallpaper change
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$WOFI_DIR/colors.css" > /dev/null
/* Default colors — replaced by matugen on first wallpaper change. */
@define-color primary               #80d5d0;
@define-color on_primary            #003735;
@define-color primary_container     #00504d;
@define-color on_primary_container  #b4ebff;
@define-color secondary             #b3cad4;
@define-color on_secondary          #1d333b;
@define-color background            #0f1416;
@define-color on_background         #dee3e6;
@define-color surface               #0f1416;
@define-color on_surface            #dee3e6;
@define-color surface_variant       #40484b;
@define-color on_surface_variant    #bfc8cc;
@define-color outline               #899296;
@define-color outline_variant       #40484b;
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

# ---- Hyprland initial colors.conf ----
log "--- Writing initial hyprland colors.conf ---"
HYPR_DIR="$USER_HOME/.config/hypr"
sudo -u "$TARGET_USER" mkdir -p "$HYPR_DIR"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$HYPR_DIR/colors.conf" > /dev/null
# Default border colors — replaced by matugen on first wallpaper change.
$active_border   = rgb(80d5d0)
$inactive_border = rgb(40484b)
EOF
chown "$TARGET_USER:$TARGET_USER" "$HYPR_DIR/colors.conf"
log "hyprland colors.conf written."

# ---- XDG Desktop Portal ----
log "--- Writing xdg-desktop-portal config ---"
XDG_PORTAL_DIR="$USER_HOME/.config/xdg-desktop-portal"
sudo -u "$TARGET_USER" mkdir -p "$XDG_PORTAL_DIR"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$XDG_PORTAL_DIR/hyprland-portals.conf" > /dev/null
[preferred]
default=hyprland;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Screenshot=hyprland
org.freedesktop.impl.portal.ScreenCast=hyprland
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$XDG_PORTAL_DIR"
log "xdg-desktop-portal config written."

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

# ---- Pre-create directories ----
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/Screenshots"
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/wallpapers"
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/.cache/wallpaper_thumbs"

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
echo "  CachyOS performance settings applied."
echo "  scx systemd service manages Zen 3 scheduling."
echo "  PipeWire user services enabled."
echo "  Matugen theme pipeline fully configured."
echo ""
echo "  App configs written:"
echo "    - matugen        → ~/.config/matugen/ (config + all templates)"
echo "    - wallpaper.sh   → ~/.config/scripts/wallpaper.sh"
echo "    - fastfetch      → ~/.config/fastfetch/config.jsonc"
echo "    - kitty          → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - waybar         → ~/.config/waybar/config + style.css + colors.css"
echo "    - waybar scripts → scroll_text.sh, weather.sh, wallpaper_picker.sh"
echo "    - wofi           → ~/.config/wofi/config + style.css + colors.css"
echo "    - swaync         → ~/.config/swaync/config.json"
echo "    - gtk-3.0 & 4.0  → gtk.css + colors.css"
echo "    - hyprland       → colors.conf (default placeholder)"
echo "    - xdg-portal     → hyprland-portals.conf"
echo ""
echo "  Next steps after reboot:"
echo "    - Add wallpapers to ~/Pictures/wallpapers"
echo "    - Set initial wallpaper + generate theme:"
echo "        ~/.config/scripts/wallpaper.sh ~/Pictures/wallpapers/yourwall.jpg"
echo "    - Open wallpaper picker: SUPER+Z"
echo "    - Configure Qt theming: qt6ct → style: kvantum"
echo "    - Configure Kvantum: kvantummanager → select a dark theme"
echo "    - Configure GTK: nwg-look → adw-gtk3-dark + Papirus-Dark icons"
echo "    - Test Vulkan: vkcube  |  Test VA-API: vainfo"
echo "    - amd_pstate: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
echo "      (should read 'amd-pstate-epp')"
echo "    - Music controls: SUPER+ALT+P/Left/Right/Up/Down via kew+playerctl"
echo "    - ROCm / LM Studio: HSA_OVERRIDE_GFX_VERSION=11.0.0 pre-set"
echo "    - Log in via ly and enjoy Hyprland"
echo "============================================="
echo ""
read -p "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
