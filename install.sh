#!/bin/bash

# Installer script to install Odin Linux (Arch-based) from Arch Linux ISO
# Features: A/B partitioning, immutable root, AwesomeWM (Super as modkey),
# Alacritty as default terminal, .xinitrc setup, PipeWire audio, Firefox
# Run as root in Arch Linux live ISO environment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Step 1: Prompt for target disk
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL
echo -e "${RED}WARNING: This script will WIPE the selected disk!${NC}"
read -p "Enter target disk (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK

# Validate disk
if [ ! -b "$TARGET_DISK" ]; then
    echo -e "${RED}Error: $TARGET_DISK is not a valid block device.${NC}"
    exit 1
fi

echo -e "Selected disk: $TARGET_DISK"
read -p "Confirm wiping and installing Odin Linux on $TARGET_DISK? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Installation aborted."
    exit 1
fi

# Step 2: Partition the disk
echo "Partitioning $TARGET_DISK..."
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 256MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart primary ext4 256MiB 40%  # root-a
parted -s "$TARGET_DISK" mkpart primary ext4 40% 80%   # root-b
parted -s "$TARGET_DISK" mkpart primary ext4 80% 100%  # user-data

# Wait for partitions to be recognized
sleep 2

# Format partitions
echo "Formatting partitions..."
mkfs.vfat -n EFI "${TARGET_DISK}1"
mkfs.ext4 -L root-a "${TARGET_DISK}2"
mkfs.ext4 -L root-b "${TARGET_DISK}3"
mkfs.ext4 -L user-data "${TARGET_DISK}4"

# Step 3: Mount partitions
echo "Mounting partitions..."
mkdir -p /mnt
mount "${TARGET_DISK}2" /mnt
mkdir -p /mnt/boot/efi /mnt/writable
mount "${TARGET_DISK}1" /mnt/boot/efi
mount "${TARGET_DISK}4" /mnt/writable

# Step 4: Install base system
echo "Installing Odin Linux base system..."
pacstrap -C /etc/pacman.conf /mnt base linux linux-firmware vim awesome alacritty xorg-server xorg-xinit pipewire pipewire-pulse pipewire-alsa firefox

# Step 5: Configure the system
echo "Configuring Odin Linux..."

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab
# Ensure root is read-only
sed -i "s|${TARGET_DISK}2.*ext4.*defaults|${TARGET_DISK}2 / ext4 ro,defaults|" /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt /bin/bash << 'EOF'
set -e

# Update system
pacman -Syu --noconfirm
pacman -S --noconfirm systemd

# Enable overlayfs service
mkdir -p /writable
cat << 'SERVICE' > /etc/systemd/system/overlayfs-setup.service
[Unit]
Description=Setup overlayfs for writable areas
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/mount -t overlay overlay -o lowerdir=/var,upperdir=/writable/var,workdir=/writable/work/var /var
ExecStart=/bin/mount -t overlay overlay -o lowerdir=/home,upperdir=/writable/home,workdir=/writable/work/home /home
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable overlayfs-setup.service

# Set root password
echo "root:root" | chpasswd

# Configure /etc/os-release
cat << 'OSRELEASE' > /etc/os-release
NAME="Odin Linux"
PRETTY_NAME="Odin Linux"
ID=odin
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://odinlinux.org/"
DOCUMENTATION_URL="https://wiki.odinlinux.org/"
SUPPORT_URL="https://forum.odinlinux.org/"
BUG_REPORT_URL="https://bugs.odinlinux.org/"
PRIVACY_POLICY_URL="https://odinlinux.org/privacy/"
LOGO=odinlinux-logo
OSRELEASE

# Configure PipeWire services
mkdir -p /root/.config/systemd/user
ln -s /usr/lib/systemd/user/pipewire.service /root/.config/systemd/user/pipewire.service
ln -s /usr/lib/systemd/user/pipewire-pulse.service /root/.config/systemd/user/pipewire-pulse.service
systemctl --user enable pipewire pipewire-pulse

# Configure AwesomeWM
mkdir -p /etc/xdg/awesome
cat << 'AWESOME' > /etc/xdg/awesome/rc.lua
-- Custom AwesomeWM configuration
local awful = require("awful")
require("awful.autofocus")
local beautiful = require("beautiful")

-- Initialize theme
beautiful.init(beautiful.theme_assets.gen_theme("default", "#222222", "#ffffff", "#00ff00"))

-- Set modkey to Super (Win key)
modkey = "Mod4"

-- Default terminal and browser
terminal = "alacritty"
browser = "firefox"

-- Key bindings
globalkeys = awful.util.table.join(
    awful.key({ modkey,           }, "Return", function () awful.spawn(terminal) end,
              {description = "open a terminal", group = "launcher"}),
    awful.key({ modkey,           }, "f", function () awful.spawn(browser) end,
              {description = "open firefox", group = "launcher"}),
    awful.key({ modkey, "Control" }, "r", awesome.restart,
              {description = "reload awesome", group = "awesome"})
)

-- Set keys
root.keys(globalkeys)

-- Rules
awful.rules.rules = {
    { rule = { },
      properties = { border_width = beautiful.border_width,
                     border_color = beautiful.border_normal,
                     focus = awful.client.focus.filter,
                     raise = true,
                     keys = clientkeys,
                     buttons = clientbuttons } }
}

-- Layouts
awful.layout.layouts = {
    awful.layout.suit.tile,
    awful.layout.suit.floating,
}
AWESOME

# Configure .xinitrc
cat << 'XINIT' > /root/.xinitrc
#!/bin/sh
exec awesome
XINIT
chmod +x /root/.xinitrc

# Configure shell to run startx
cat << 'PROFILE' > /root/.bash_profile
#!/bin/bash
if [[ -z \$DISPLAY ]] && [[ \$(tty) = /dev/tty1 ]]; then
    exec startx
fi
PROFILE
chmod +x /root/.bash_profile

# Create update-root.sh
cat << 'UPDATE' > /usr/local/bin/update-root.sh
#!/bin/bash
CURRENT_ROOT=\$(findmnt -n -o SOURCE / | grep -o 'root-[ab]')
if [ "\$CURRENT_ROOT" = "root-a" ]; then
    NEW_ROOT="root-b"
else
    NEW_ROOT="root-a"
fi
grub-reboot "Odin Linux (\$NEW_ROOT)"
echo "Next boot will use \$NEW_ROOT. Reboot to apply."
UPDATE
chmod +x /usr/local/bin/update-root.sh

# Exit chroot
exit
EOF

# Step 6: Copy root-b
echo "Copying system to root-b..."
umount /mnt/boot/efi /mnt/writable /mnt
mount "${TARGET_DISK}3" /mnt
mkdir -p /mnt/boot/efi /mnt/writable
mount "${TARGET_DISK}1" /mnt/boot/efi
mount "${TARGET_DISK}4" /mnt/writable
rsync -a --exclude=/boot/efi --exclude=/writable "${TARGET_DISK}2/" /mnt/
umount /mnt/boot/efi /mnt/writable /mnt

# Step 7: Install GRUB
echo "Installing GRUB..."
mount "${TARGET_DISK}1" /mnt
mkdir -p /mnt/boot
mount --bind "${TARGET_DISK}2/boot" /mnt/boot
arch-chroot /mnt /bin/bash << 'EOF'
grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable
cat << 'GRUB' > /boot/grub/grub.cfg
set timeout=5
menuentry 'Odin Linux (root-a)' --id=odin-root-a {
    linux /boot/vmlinuz-linux root=LABEL=root-a ro
    initrd /boot/initramfs-linux.img
}
menuentry 'Odin Linux (root-b)' --id=odin-root-b {
    linux /boot/vmlinuz-linux root=LABEL=root-b ro
    initrd /boot/initramfs-linux.img
}
GRUB
EOF
umount /mnt/boot /mnt

# Step 8: Clean up
echo "Cleaning up..."
umount -R /mnt 2>/dev/null || true
sync

# Step 9: Output instructions
echo -e "${GREEN}Odin Linux installed on $TARGET_DISK!${NC}"
echo "Reboot and remove the Arch ISO to boot Odin Linux."
echo "Log in (root/root) at console; AwesomeWM starts via startx."
echo "Use Super+Return for Alacritty, Super+f for Firefox."
echo "Run 'update-root.sh' to switch partitions."

exit 0
