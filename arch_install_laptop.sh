#!/usr/bin/env bash
# Arch + i3 + nvidia-390xx (2026 Edition)
# Optimized for: Dell Precision M4600 (Intel Sandy Bridge + Quadro 1000M)
# GPU driver: nvidia-390xx-dkms (last driver supporting Fermi)
# ---------------------------------------------------------
set -euo pipefail

# =========================================================
# --- 0. Pre-flight Checks ---
# =========================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

if ! ping -c 1 1.1.1.1 &> /dev/null; then
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

log "=== i3 Setup for $TARGET_USER (CPU: Sandy Bridge | GPU: Quadro 1000M/nvidia-390xx) ==="

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
if grep -q '^ParallelDownloads' /etc/pacman.conf; then
    : # already set, nothing to do
elif grep -q '^#ParallelDownloads' /etc/pacman.conf; then
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
else
    echo 'ParallelDownloads = 10' >> /etc/pacman.conf
fi
pacman -Syy --noconfirm

# =========================================================
# --- 4. yay (AUR helper) ---
# =========================================================
log "--- Installing yay ---"
if ! command -v yay &> /dev/null; then
    BUILDDIR="/tmp/yay_build_$$"
    sudo -u "$TARGET_USER" mkdir -p "$BUILDDIR"
    sudo -u "$TARGET_USER" git clone https://aur.archlinux.org/yay.git "$BUILDDIR/yay"
    ( cd "$BUILDDIR/yay" && sudo -u "$TARGET_USER" makepkg -si --noconfirm )
    rm -rf "$BUILDDIR"
else
    log "yay already installed — skipping."
fi

# =========================================================
# --- 5. Kernel, Microcode & Bootloader ---
# =========================================================
log "--- Installing linux-lts kernel & Intel Microcode ---"
pacman -S --needed --noconfirm linux-lts linux-lts-headers intel-ucode dkms

# =========================================================
# --- 6. nvidia-390xx Driver ---
# =========================================================
log "--- Installing legacy NVIDIA 390xx driver (Fermi/Quadro 1000M only viable accel option) ---"

# Blacklist nouveau aggressively
cat <<'EOF' > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

# Install from AUR — expect possible build issues after kernel updates
log "Installing nvidia-390xx packages via yay (may require manual patching if build fails)..."
log "  NOTE: DKMS compile on Sandy Bridge takes 20-30+ minutes — go grab a coffee!"
sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild \
    nvidia-390xx-dkms \
    nvidia-390xx-utils \
    lib32-nvidia-390xx-utils || {
    log "ERROR: nvidia-390xx AUR install failed."
    log "  -> Check AUR comments for patches: https://aur.archlinux.org/packages/nvidia-390xx-dkms"
    log "  -> Common fix: apply community patches for kernel/gcc version mismatch."
    log "  -> Fallback: sudo rm /etc/modprobe.d/blacklist-nouveau.conf && mkinitcpio -P && reboot"
    log "  -> Continuing script -- fix driver manually after reboot."
}

# DO NOT add nvidia modules to mkinitcpio MODULES array.
# Early loading causes black screen on many Fermi laptops (GF108/GF116 family).
# The driver loads fine via modprobe after boot without early preload.

# Regenerate initramfs (without nvidia preload -- intentional)
mkinitcpio -P
log "initramfs regenerated (nvidia modules NOT preloaded -- intentional for Fermi stability)."

# Add nvidia-drm.modeset=1 to GRUB and remove i915 params (idempotent)
if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub; then
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' /etc/default/grub
fi
sed -i 's/ i915\.enable_psr=[01]//g' /etc/default/grub
sed -i 's/ i915\.enable_fbc=[01]//g' /etc/default/grub

if command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ -d "/boot/loader/entries" ]; then
    bootctl --path=/boot update
fi
log "GRUB updated with nvidia-drm.modeset=1."

# Write Xorg config to explicitly use nvidia driver
# Without this, X11 may fall back to modesetting even with nvidia installed
mkdir -p /etc/X11/xorg.conf.d
cat <<'EOF' > /etc/X11/xorg.conf.d/20-nvidia.conf
Section "Device"
    Identifier "Nvidia Card"
    Driver     "nvidia"
    VendorName "NVIDIA Corporation"
    BoardName  "Quadro 1000M"
    Option     "NoLogo" "1"
    Option     "RenderAccel" "1"
    Option     "TripleBuffer" "1"
EndSection
EOF
log "Xorg nvidia config written to /etc/X11/xorg.conf.d/20-nvidia.conf"

# Quick smoke test (non-fatal -- driver may not be active until reboot)
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    log "SUCCESS: nvidia-smi reports driver loaded."
else
    log "NOTE: nvidia-smi not yet active -- expected before reboot."
    log "  -> If black screen after reboot: add 'nomodeset' to GRUB line temporarily."
    log "  -> Check /var/log/Xorg.0.log for errors."
    log "  -> Nouveau fallback: sudo rm /etc/modprobe.d/blacklist-nouveau.conf && mkinitcpio -P && reboot"
fi

# =========================================================
# --- 7. Audio Stack (PipeWire) ---
# =========================================================
log "--- Installing PipeWire audio stack ---"
pacman -S --needed --noconfirm \
    pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber pavucontrol pamixer playerctl

# =========================================================
# --- 8. X11 ---
# =========================================================
log "--- Installing X11 ---"
pacman -S --needed --noconfirm \
    xorg-server xorg-xinit xorg-xrandr xorg-xset xorg-xinput \
    xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-gtk \
    qt5-x11extras qt6-base

# =========================================================
# --- 9. Desktop Stack ---
# =========================================================
log "--- Installing i3 & Desktop Environment ---"
pacman -S --needed --noconfirm \
    i3-wm i3lock \
    polybar \
    rofi \
    picom \
    feh \
    dunst \
    xautolock \
    redshift \
    maim xdotool xclip \
    kitty \
    noto-fonts noto-fonts-cjk ttf-jetbrains-mono-nerd \
    ttf-dejavu ttf-roboto ttf-font-awesome \
    pcmanfm-qt gvfs gvfs-mtp gvfs-smb gvfs-afc \
    brightnessctl \
    fcitx5 fcitx5-mozc fcitx5-configtool \
    firefox mpv \
    btop fastfetch nsxiv filelight \
    gparted smartmontools transmission-qt \
    zram-generator \
    networkmanager blueman network-manager-applet \
    bluez bluez-utils \
    imagemagick \
    flatpak

# =========================================================
# --- 10. Laptop Power Management ---
# =========================================================
log "--- Installing laptop power management ---"
pacman -S --needed --noconfirm \
    tlp \
    thermald \
    acpid \
    powertop

# =========================================================
# --- 11. Productivity Apps ---
# =========================================================
log "--- Installing Productivity Applications ---"
pacman -S --needed --noconfirm \
    libreoffice-fresh okular krita anki code

# =========================================================
# --- 12. AUR Packages ---
# =========================================================
log "--- Installing AUR packages (running as $TARGET_USER) ---"
sudo -u "$TARGET_USER" yay -S --needed --noconfirm --norebuild \
    bitwarden \
    qt6ct-kde \
    ttf-maple \
    kew-git \
    greenclip

# Stremio via Flatpak
log "--- Installing Flatpak apps ---"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.stremio.Stremio

# =========================================================
# --- 13. System Services ---
# =========================================================
log "--- Enabling system services ---"
loginctl enable-linger "$TARGET_USER"

systemctl enable tlp
systemctl enable NetworkManager
systemctl mask systemd-rfkill.service || true
systemctl mask systemd-rfkill.socket || true

systemctl enable thermald
systemctl enable acpid
systemctl enable bluetooth

systemctl disable getty@tty2 || true

sudo -u "$TARGET_USER" systemctl --user enable pipewire pipewire-pulse wireplumber || true
sudo -u "$TARGET_USER" xdg-user-dirs-update || true

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

# --- ly display manager config ---
LY_CONF="/etc/ly/config.ini"
if [ -f "$LY_CONF" ]; then
    sed -i 's/^#\?\s*save_last_session\s*=.*/save_last_session = true/' "$LY_CONF"
    grep -q '^xsessions' "$LY_CONF" || \
        echo "xsessions = /usr/share/xsessions" >> "$LY_CONF"
    log "ly config patched for X11 sessions."
else
    log "WARNING: /etc/ly/config.ini not found — patch manually after install."
fi

# =========================================================
# --- 14. Backup Existing Configs ---
# =========================================================
BACKUP_DIR="$USER_HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"
BACKED_UP=0
for d in i3 polybar rofi picom dunst kitty redshift fastfetch; do
    if [ -d "$USER_HOME/.config/$d" ]; then
        sudo -u "$TARGET_USER" mkdir -p "$BACKUP_DIR"
        sudo -u "$TARGET_USER" cp -r "$USER_HOME/.config/$d" "$BACKUP_DIR/$d"
        BACKED_UP=1
    fi
done
for f in .xprofile .xinitrc; do
    if [ -f "$USER_HOME/$f" ]; then
        sudo -u "$TARGET_USER" mkdir -p "$BACKUP_DIR"
        sudo -u "$TARGET_USER" cp "$USER_HOME/$f" "$BACKUP_DIR/$f"
        BACKED_UP=1
    fi
done
if [ "$BACKED_UP" -eq 1 ]; then
    log "Existing configs backed up to $BACKUP_DIR"
else
    log "No existing configs found — skipping backup."
fi

# =========================================================
# --- 15. i3 Config ---
# =========================================================
log "--- Writing i3 config ---"
I3_DIR="$USER_HOME/.config/i3"
sudo -u "$TARGET_USER" mkdir -p "$I3_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$I3_DIR/config" > /dev/null
# =============================================================================
# i3 config — Auto-generated by arch_install_laptop_i3.sh (2026)
# Dell Precision M4600 — Intel Sandy Bridge + Quadro 1000M (nvidia-390xx)
# =============================================================================

set $mod Mod4

font pango:Maple Mono 11

# =========================================================
# STARTUP
# =========================================================

exec_always --no-startup-id $HOME/.config/polybar/launch.sh
exec_always --no-startup-id sh -c 'pkill picom 2>/dev/null || true; picom'
exec_always --no-startup-id sh -c 'feh --bg-fill ~/.config/i3/wallpaper 2>/dev/null || true'
exec --no-startup-id fcitx5 -d
exec --no-startup-id dunst
exec --no-startup-id nm-applet
exec --no-startup-id redshift
exec --no-startup-id xautolock -time 10 -locker i3lock
exec --no-startup-id greenclip daemon
exec --no-startup-id kew
exec --no-startup-id xset r rate 300 50

# =========================================================
# APPEARANCE
# =========================================================

client.focused               #d8cab8   #141216   #d8cab8   #ac82e9   #d8cab8
client.unfocused             #ac82e9   #141216   #ac82e9   #ac82e9   #ac82e9
client.focused_inactive      #ac82e9   #141216   #ac82e9   #ac82e9   #ac82e9
client.urgent                #fcb167   #141216   #fcb167   #fcb167   #fcb167

default_border pixel 1
default_floating_border pixel 1
gaps inner 5
gaps outer 8
smart_gaps on

# =========================================================
# KEYBINDS
# =========================================================

bindsym $mod+Return exec kitty
bindsym $mod+q kill
bindsym $mod+d exec rofi -show drun
bindsym $mod+e exec pcmanfm-qt
bindsym $mod+v exec rofi -modi "clipboard:greenclip print" -show clipboard
bindsym $mod+Shift+s exec maim -s ~/Pictures/Screenshots/$(date +%Y-%m-%d_%H-%M-%S).png
bindsym $mod+z exec $HOME/.config/polybar/scripts/wallpaper_picker.sh
bindsym $mod+Shift+space floating toggle
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+r reload
bindsym $mod+ctrl+l exec i3lock

# Laptop brightness
bindsym XF86MonBrightnessUp   exec brightnessctl set +5%
bindsym XF86MonBrightnessDown exec brightnessctl set 5%-

# Laptop volume
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute @DEFAULT_SINK@ toggle

# Music controls
bindsym $mod+mod1+p     exec playerctl --player=kew play-pause
bindsym $mod+mod1+Right exec playerctl --player=kew next
bindsym $mod+mod1+Left  exec playerctl --player=kew previous
bindsym $mod+mod1+Up    exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym $mod+mod1+Down  exec pactl set-sink-volume @DEFAULT_SINK@ -5%

# Focus
bindsym $mod+h focus left
bindsym $mod+l focus right
bindsym $mod+k focus up
bindsym $mod+j focus down

# Move window
bindsym $mod+Shift+h move left
bindsym $mod+Shift+l move right
bindsym $mod+Shift+k move up
bindsym $mod+Shift+j move down

# Split
bindsym $mod+b split h
bindsym $mod+n split v

# Layout
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+t layout toggle split

# Resize mode
mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Workspaces
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9
bindsym $mod+0 workspace number 10

bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9
bindsym $mod+Shift+0 move container to workspace number 10

floating_modifier $mod
bindsym $mod+Shift+q exec i3-msg exit
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$I3_DIR"
log "i3 config written."

# =========================================================
# --- 16. App Configs ---
# =========================================================

# ---- Picom ----
log "--- Writing picom config ---"
PICOM_CONF="$USER_HOME/.config/picom/picom.conf"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$PICOM_CONF")"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$PICOM_CONF" > /dev/null
backend = "glx";
glx-no-stencil = true;
shadow = false;
fading = false;
inactive-opacity = 1.0;
active-opacity = 1.0;
frame-opacity = 1.0;
vsync = true;
corner-radius = 6;
rounded-corners-exclude = [
    "window_type = 'dock'",
    "window_type = 'desktop'"
];
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$(dirname "$PICOM_CONF")"
log "picom config written."

# ---- Dunst ----
log "--- Writing dunst config ---"
DUNST_DIR="$USER_HOME/.config/dunst"
sudo -u "$TARGET_USER" mkdir -p "$DUNST_DIR"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$DUNST_DIR/dunstrc" > /dev/null
[global]
    font = Maple Mono 11
    corner_radius = 8
    frame_width = 1
    frame_color = "#d8cab8"
    background = "#141216"
    foreground = "#d8cab8"
    highlight = "#ac82e9"
    separator_color = "#d8cab8"
    gap_size = 6
    origin = top-right
    offset = 10x10
    width = 300
    padding = 10
    horizontal_padding = 10
    timeout = 5

[urgency_low]
    background = "#141216"
    foreground = "#d8cab8"
    frame_color = "#d8cab8"

[urgency_normal]
    background = "#141216"
    foreground = "#d8cab8"
    frame_color = "#d8cab8"

[urgency_critical]
    background = "#141216"
    foreground = "#fc4649"
    frame_color = "#fc4649"

[kew]
    appname = kew
    skip_display = true
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$DUNST_DIR"
log "dunst config written."

# ---- Redshift ----
log "--- Writing redshift config ---"
REDSHIFT_CONF="$USER_HOME/.config/redshift/redshift.conf"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$REDSHIFT_CONF")"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$REDSHIFT_CONF" > /dev/null
[redshift]
temp-day=6500
temp-night=4500
lat=33.98
lon=-117.38
fade=1
gamma=1.0
adjustment-method=randr
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$(dirname "$REDSHIFT_CONF")"
log "redshift config written."

# ---- Rofi ----
log "--- Writing rofi config ---"
ROFI_DIR="$USER_HOME/.config/rofi"
sudo -u "$TARGET_USER" mkdir -p "$ROFI_DIR"

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$ROFI_DIR/config.rasi" > /dev/null
configuration {
    modi: "drun,run";
    font: "Maple Mono 11";
    show-icons: true;
    drun-display-format: "{name}";
    location: 0;
    disable-history: false;
    hide-scrollbar: true;
    display-drun: " Search";
    sidebar-mode: false;
}

@theme "~/.config/rofi/theme.rasi"
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "$ROFI_DIR/theme.rasi" > /dev/null
* {
    bg:           rgba(20, 18, 22, 0.95);
    bg-alt:       rgba(0, 0, 0, 0.2);
    fg:           #d8cab8;
    accent:       #ac82e9;
    border-col:   #d8cab8;
    background-color: transparent;
    text-color:   @fg;
}

window {
    background-color: @bg;
    border:           1px;
    border-color:     @border-col;
    border-radius:    14px;
    width:            500px;
    padding:          0px;
}

mainbox {
    background-color: transparent;
    children:         [ inputbar, listview ];
    spacing:          0px;
    padding:          8px;
}

inputbar {
    background-color: @bg-alt;
    border:           0px 0px 1px 0px;
    border-color:     @border-col;
    border-radius:    8px 8px 0px 0px;
    padding:          12px;
    margin:           0px 0px 8px 0px;
    children:         [ prompt, entry ];
}

prompt {
    background-color: transparent;
    text-color:       @accent;
    padding:          0px 8px 0px 0px;
}

entry {
    background-color: transparent;
    text-color:       @fg;
    placeholder:      "Type to search...";
    placeholder-color: rgba(216, 202, 184, 0.4);
}

listview {
    background-color: transparent;
    lines:            8;
    scrollbar:        false;
    spacing:          4px;
    padding:          4px;
}

element {
    background-color: transparent;
    border-radius:    8px;
    padding:          6px 8px;
    spacing:          8px;
    children:         [ element-icon, element-text ];
}

element selected {
    background-color: @bg-alt;
}

element-icon {
    background-color: transparent;
    size:             24px;
}

element-text {
    background-color: transparent;
    text-color:       inherit;
    vertical-align:   0.5;
}
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$ROFI_DIR"
log "rofi config written."

# ---- Polybar ----
log "--- Writing polybar config ---"
POLYBAR_DIR="$USER_HOME/.config/polybar"
POLYBAR_SCRIPTS="$POLYBAR_DIR/scripts"
sudo -u "$TARGET_USER" mkdir -p "$POLYBAR_SCRIPTS"

# Launch script
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$POLYBAR_DIR/launch.sh" > /dev/null
#!/bin/bash
killall -q polybar
while pgrep -u $UID -x polybar >/dev/null; do sleep 1; done
polybar main &
EOF
chmod +x "$POLYBAR_DIR/launch.sh"

# Main polybar config
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$POLYBAR_DIR/config.ini" > /dev/null
[colors]
bg         = #b2141216
fg         = #d8cab8
border     = #d8cab8
accent     = #ac82e9
accent-dim = #8f56e1
warning    = #fcb167
critical   = #fc4649
transparent= #00000000

[bar/main]
width                = 75%
height               = 36
offset-x             = 12.5%
offset-y             = 8
radius               = 14
fixed-center         = true

background           = ${colors.bg}
foreground           = ${colors.fg}

line-size            = 0
border-size          = 0
padding-left         = 2
padding-right        = 2
module-margin-left   = 0
module-margin-right  = 0

font-0               = "Maple Mono:size=11:weight=bold;3"
font-1               = "JetBrainsMono NF:size=13;3"
font-2               = "Noto Sans CJK JP:size=11;3"
font-3               = "monospace:size=11;3"

modules-left         = workspaces
modules-center       = media
modules-right        = wallpaper network battery pulseaudio tray weather clock

wm-restack           = i3
override-redirect    = false
enable-ipc           = true

cursor-click         = pointer
cursor-scroll        = ns-resize

[module/workspaces]
type                 = internal/i3
format               = <label-state>
index-sort           = true
wrapping-scroll      = false
label-focused        = %index%
label-focused-foreground = ${colors.accent}
label-focused-font   = 1
label-focused-padding = 4
label-unfocused      = %index%
label-unfocused-foreground = ${colors.fg}
label-unfocused-padding = 4
label-urgent         = %index%
label-urgent-foreground = ${colors.warning}
label-urgent-padding = 4

[module/media]
type                 = custom/script
exec                 = $HOME/.config/polybar/scripts/scroll_text.sh
tail                 = true
click-left           = playerctl -p kew play-pause
format               = <label>
format-prefix        = "󰎈 "
format-prefix-font   = 2
format-prefix-foreground = ${colors.accent}
label                = %output%
label-foreground     = ${colors.accent}
label-font           = 4
format-background    = ${colors.bg}
format-foreground    = ${colors.accent}
format-padding       = 8
format-underline     = ${colors.accent}

[module/wallpaper]
type                 = custom/text
content              = "󰋩"
content-font         = 2
content-foreground   = ${colors.fg}
content-background   = ${colors.bg}
content-padding      = 2
click-left           = $HOME/.config/polybar/scripts/wallpaper_picker.sh

[module/network]
type                 = internal/network
interface-type       = wireless
interval             = 3
format-connected     = <label-connected>
format-connected-prefix = "  "
format-connected-prefix-font = 2
format-connected-prefix-foreground = ${colors.fg}
label-connected      = %downspeed%
label-connected-foreground = ${colors.fg}
format-disconnected  = <label-disconnected>
format-disconnected-prefix = "󰤮  "
format-disconnected-prefix-font = 2
label-disconnected   = No Network
label-disconnected-foreground = ${colors.critical}
format-connected-background  = ${colors.bg}
format-disconnected-background = ${colors.bg}
format-connected-padding  = 2
format-disconnected-padding = 2

[module/battery]
type                 = internal/battery
battery              = BAT0
adapter              = AC
; NOTE: if battery shows N/A run: ls /sys/class/power_supply/
; adapter may be named ACAD, AC0, or ADP1 on some Dell models
full-at              = 99
poll-interval        = 5
format-charging      = <label-charging>
format-charging-prefix = "󰂄  "
format-charging-prefix-font = 2
label-charging       = %percentage%%
ramp-capacity-0      = 󱊡
ramp-capacity-1      = 󱊢
ramp-capacity-2      = 󱊣
ramp-capacity-font   = 2
format-discharging   = <ramp-capacity>  <label-discharging>
label-discharging    = %percentage%%
format-full          = <label-full>
format-full-prefix   = "󱈑  "
format-full-prefix-font = 2
label-full           = %percentage%%
label-discharging-foreground = ${colors.fg}
label-charging-foreground = ${colors.fg}
label-full-foreground = ${colors.fg}
format-charging-background  = ${colors.bg}
format-discharging-background = ${colors.bg}
format-full-background = ${colors.bg}
format-charging-padding  = 2
format-discharging-padding = 2
format-full-padding  = 2

[module/pulseaudio]
type                 = internal/pulseaudio
use-ui-max           = false
interval             = 5
format-volume        = <ramp-volume>  <label-volume>
ramp-volume-0        = 
ramp-volume-1        = 
ramp-volume-2        = 
ramp-volume-font     = 2
label-volume         = %percentage%%
label-volume-foreground = ${colors.fg}
format-muted         = <label-muted>
format-muted-prefix  = "  "
format-muted-prefix-font = 2
label-muted          = Muted
label-muted-foreground = ${colors.fg}
click-right          = pavucontrol
format-volume-background  = ${colors.bg}
format-muted-background   = ${colors.bg}
format-volume-padding = 2
format-muted-padding  = 2

[module/tray]
type                 = internal/tray
tray-spacing         = 6px
tray-background      = ${colors.bg}
tray-padding         = 2

[module/weather]
type                 = custom/script
exec                 = $HOME/.config/polybar/scripts/weather.sh
interval             = 900
format               = <label>
label                = %output%
label-foreground     = ${colors.fg}
format-background    = ${colors.bg}
format-padding       = 2

[module/clock]
type                 = internal/date
interval             = 30
date                 = "󰅐  %H:%M"
date-alt             = "󰅐  %Y-%m-%d %H:%M"
label                = %date%
label-foreground     = ${colors.fg}
format-background    = ${colors.bg}
format-padding       = 2
EOF

# scroll_text.sh
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$POLYBAR_SCRIPTS/scroll_text.sh" > /dev/null
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

    [ "$padded_len" -gt 0 ] && offset=$(( (offset + 1) % padded_len ))
    tick=$((tick + 1))
    sleep "$SCROLL_DELAY"
done
EOF

# weather.sh
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$POLYBAR_SCRIPTS/weather.sh" > /dev/null
#!/bin/bash

LAT="33.9806"
LON="-117.3755"
CACHE_FILE="$HOME/.cache/polybar_weather.txt"

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

# wallpaper_picker.sh — uses feh instead of swww
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$POLYBAR_SCRIPTS/wallpaper_picker.sh" > /dev/null
#!/bin/bash

WALLPAPER_DIR="$HOME/Pictures/wallpapers"
CACHE_DIR="$HOME/.cache/wallpaper_thumbs"
LIST_CACHE="$CACHE_DIR/rofi_list.txt"

mkdir -p "$CACHE_DIR"

if [ ! -f "$LIST_CACHE" ] || [ "$WALLPAPER_DIR" -nt "$LIST_CACHE" ]; then
    > "$LIST_CACHE"
    find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | while read -r img; do
        thumb="$CACHE_DIR/$(basename "$img").thumb.png"
        if [ ! -f "$thumb" ]; then
            magick "$img"[0] -thumbnail 200x200^ -gravity center -extent 200x200 "$thumb" 2>/dev/null
        fi
        echo "$(basename "$img")|$img"
    done > "$LIST_CACHE"
fi

selected=$(awk -F'|' '{print $1}' "$LIST_CACHE" | rofi -dmenu -p "Wallpaper" -i)

if [ -n "$selected" ]; then
    full_path=$(awk -F'|' -v sel="$selected" '$1==sel {print $2; exit}' "$LIST_CACHE")
    feh --bg-fill "$full_path"
    cp "$full_path" ~/.config/i3/wallpaper
fi
EOF

chmod +x "$POLYBAR_SCRIPTS/scroll_text.sh"
chmod +x "$POLYBAR_SCRIPTS/weather.sh"
chmod +x "$POLYBAR_SCRIPTS/wallpaper_picker.sh"
chown -R "$TARGET_USER:$TARGET_USER" "$POLYBAR_DIR"
log "polybar config and scripts written."

# ---- Fastfetch ----
log "--- Writing fastfetch config ---"
FASTFETCH_CONF="$USER_HOME/.config/fastfetch/config.jsonc"
sudo -u "$TARGET_USER" mkdir -p "$(dirname "$FASTFETCH_CONF")"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$FASTFETCH_CONF" > /dev/null
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "source": "arch_small",
        "padding": { "top": 1, "left": 2 }
    },
    "display": { "separator": "  " },
    "modules": [
        "break",
        "title",
        { "type": "os",       "key": "os"     },
        { "type": "wm",       "key": "wm"     },
        { "type": "packages", "key": "pkgs",  "format": "{} (pacman)" },
        { "type": "shell",    "key": "shell"  },
        { "type": "kernel",   "key": "kernel" },
        { "type": "uptime",   "key": "uptime", "format": "{2}h {3}m" },
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

# ---- xprofile (fcitx5 input method env vars + X11 cursor) ----
log "--- Writing ~/.xprofile ---"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$USER_HOME/.xprofile" > /dev/null
# fcitx5 input method — required for Japanese input in GTK/Qt apps on X11
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx

# Qt platform
export QT_QPA_PLATFORM=xcb

# Cursor
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24
EOF
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.xprofile"
log "~/.xprofile written (fcitx5 env vars set)."

# ---- Fastfetch on terminal open ----
BASHRC="$USER_HOME/.bashrc"
sudo -u "$TARGET_USER" touch "$BASHRC"
if ! grep -q "fastfetch auto-run" "$BASHRC"; then
    cat <<'EOF' | sudo -u "$TARGET_USER" tee -a "$BASHRC" > /dev/null

# fastfetch auto-run — added by arch_install_laptop_i3.sh
fastfetch
EOF
    log ".bashrc updated."
fi

# ---- .xinitrc fallback (for startx if ly fails) ----
log "--- Writing ~/.xinitrc fallback ---"
cat <<'EOF' | sudo -u "$TARGET_USER" tee "$USER_HOME/.xinitrc" > /dev/null
#!/bin/sh
# Fallback: run this with 'startx' if ly display manager fails
[ -f ~/.xprofile ] && . ~/.xprofile
exec i3
EOF
chmod +x "$USER_HOME/.xinitrc"
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.xinitrc"
log "~/.xinitrc written (startx fallback)."

# ---- Directories ----
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/Screenshots"
sudo -u "$TARGET_USER" mkdir -p "$USER_HOME/Pictures/wallpapers"

# Generate a default solid-color wallpaper so feh doesn't error on first boot
# before the user picks one via SUPER+Z
DEFAULT_WALL="$USER_HOME/Pictures/wallpapers/default.png"
if [ ! -f "$DEFAULT_WALL" ]; then
    sudo -u "$TARGET_USER" magick -size 1920x1080 xc:#141216 "$DEFAULT_WALL" 2>/dev/null &&         log "Default wallpaper generated." ||         log "WARNING: Could not generate default wallpaper — run 'magick -size 1920x1080 xc:#141216 ~/Pictures/wallpapers/default.png' manually."
fi
# Pre-set it as the active wallpaper for feh to load on first login
cp "$DEFAULT_WALL" "$USER_HOME/.config/i3/wallpaper" 2>/dev/null || true
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/i3/wallpaper" 2>/dev/null || true

# =========================================================
# --- 17. Enable Login Manager ---
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
echo "  Standard Arch repos, linux-lts kernel."
echo "  nvidia-390xx-dkms installed — nouveau blacklisted."
echo "  i3 window manager with polybar."
echo "  TLP power management enabled."
echo "  PipeWire audio enabled."
echo ""
echo "  App configs written:"
echo "    - i3        → ~/.config/i3/config"
echo "    - polybar   → ~/.config/polybar/config.ini + scripts/"
echo "    - picom     → ~/.config/picom/picom.conf"
echo "    - dunst     → ~/.config/dunst/dunstrc"
echo "    - redshift  → ~/.config/redshift/redshift.conf"
echo "    - rofi      → ~/.config/rofi/config.rasi + theme.rasi"
echo "    - kitty     → ~/.config/kitty/kitty.conf + colors.conf"
echo "    - fastfetch → ~/.config/fastfetch/config.jsonc"
echo ""
echo "  Replacements from Hyprland setup:"
echo "    wofi       → rofi"
echo "    waybar     → polybar"
echo "    swww       → feh (SUPER+Z to pick)"
echo "    hyprlock   → i3lock"
echo "    hypridle   → xautolock (10 min)"
echo "    hyprsunset → redshift"
echo "    hyprshot   → maim (SUPER+SHIFT+S)"
echo "    swaync     → dunst (kew silenced)"
echo ""
echo "  IMPORTANT after each kernel update:"
echo "    sudo mkinitcpio -P"
echo ""
echo "  Next steps after reboot:"
echo "    - Add wallpapers to ~/Pictures/wallpapers"
echo "    - Pick wallpaper: SUPER+Z"
echo "    - Configure Qt: qt6ct"
echo "    - Log in via ly and enjoy i3"
echo ""
echo "  Post-reboot checks:"
echo "    nvidia-smi                   -> should show Quadro 1000M"
echo "    glxinfo | grep render        -> should show NVIDIA, not llvmpipe"
echo "    cat /proc/driver/nvidia/version -> confirms driver version"
echo ""
echo "  If black screen on reboot:"
echo "    1. At GRUB menu press 'e', add 'nomodeset' to kernel line, boot"
echo "    2. Check /var/log/Xorg.0.log for errors"
echo "    3. Check AUR patches: https://aur.archlinux.org/packages/nvidia-390xx-dkms"
echo ""
echo "  Nouveau fallback (if nvidia-390xx won't cooperate):"
echo "    sudo rm /etc/modprobe.d/blacklist-nouveau.conf"
echo "    sudo mkinitcpio -P"
echo "    sudo sed -i \'s/ nvidia-drm.modeset=1//\' /etc/default/grub"
echo "    sudo grub-mkconfig -o /boot/grub/grub.cfg"
echo "    reboot"
echo "============================================="
echo ""
read -p "Reboot now? (y/N): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
