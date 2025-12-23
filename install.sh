#!/usr/bin/env bash
set -euo pipefail

# ========================
# CONFIG
# ========================
ESP="/boot"   # EFI System Partition mountpoint
# change also ESP="/boot" inside the kernel-signing hook
KERNEL="$ESP/vmlinuz-linux"

# ========================
# Install yay
# ========================
echo "==> Installing yay"
if ! command -v yay &>/dev/null; then
    sudo pacman -S --needed --noconfirm git base-devel
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    (cd /tmp/yay && makepkg -si --noconfirm)
fi

# ========================
# Install shim-signed
# ========================
echo "==> Installing shim-signed"
yay -S --noconfirm shim-signed

# ========================
# Prepare ESP
# ========================
echo "==> Preparing ESP bootloader directory"
sudo mkdir -p "$ESP/EFI/BOOT"

# Backup original BOOTx64 if present
if [[ -f "$ESP/EFI/BOOT/BOOTx64.EFI" ]]; then
    echo "==> Backing up BOOTx64.EFI to grubx64.efi"
    sudo mv "$ESP/EFI/BOOT/BOOTx64.EFI" "$ESP/EFI/BOOT/grubx64.efi"
fi

echo "==> Installing Shim"
sudo cp /usr/share/shim-signed/shimx64.efi "$ESP/EFI/BOOT/BOOTx64.EFI"
sudo cp /usr/share/shim-signed/mmx64.efi   "$ESP/EFI/BOOT/"

# ========================
# Disk overview
# ========================
echo "==> Disk layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT -e7 | sed 's/^/    /'
echo

read -rp "Enter disk for ESP (e.g. sda or nvme0n1): " DISK
read -rp "Enter EFI partition number (e.g. 1): " PART

# ========================
# Create EFI boot entry
# ========================
echo "==> Creating EFI Boot entry using Shim"
sudo efibootmgr --create \
    --disk "/dev/$DISK" \
    --part "$PART" \
    --label "Shim" \
    --loader "\EFI\BOOT\BOOTx64.EFI" \
    --unicode

# ========================
# Install signing tools
# ========================
echo "==> Installing sbsigntools"
sudo pacman -S --noconfirm sbsigntools openssl

# ========================
# MOK Key Generation
# ========================
echo "==> Generating MOK keys"
sudo mkdir -p "$ESP/EFI/BOOT/Mok"
cd "$ESP/EFI/BOOT/Mok"

sudo openssl req -newkey rsa:2048 -nodes \
    -keyout MOK.key \
    -new -x509 -sha256 -days 3650 \
    -subj "/CN=Machine Owner Key/" \
    -out MOK.crt

sudo openssl x509 -outform DER -in MOK.crt -out MOK.cer

# ========================
# Sign Kernel
# ========================
echo "==> Signing the kernel"

sudo sbsign \
    --key "$ESP/EFI/BOOT/Mok/MOK.key" \
    --cert "$ESP/EFI/BOOT/Mok/MOK.crt" \
    --output "$KERNEL" \
    "$KERNEL"

# ========================
# Install GRUB
# ========================
echo "==> Installing GRUB"
sudo grub-install \
  --target=x86_64-efi \
  --efi-directory="$ESP" \
  --bootloader-id=BOOT \
  --modules="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal ntfs part_apple part_msdos part_gpt password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label sleep smbios squash4 test true video xfs zfs zfscrypt zfsinfo cpuid tpm" \
  --sbat /usr/share/grub/sbat.csv

# ========================
# Sign GRUB
# ========================
echo "==> Signing grubx64.efi"
sudo sbsign \
    --key "$ESP/EFI/BOOT/Mok/MOK.key" \
    --cert "$ESP/EFI/BOOT/Mok/MOK.crt" \
    --output "$ESP/EFI/BOOT/grubx64.efi" \
    "$ESP/EFI/BOOT/grubx64.efi"

# ========================
# Kernel auto-sign hook
# ========================
echo "==> Creating automatic kernel-signing hook"

sudo mkdir -p /etc/initcpio/post

sudo tee /etc/initcpio/post/kernel-sbsign >/dev/null <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

kernel="$1"

# If mkinitcpio provides a full path, use it
if [[ ! -f "$kernel" ]]; then
    exit 0
fi

ESP="/boot"
KEY="$ESP/EFI/BOOT/Mok/MOK.key"
CRT="$ESP/EFI/BOOT/Mok/MOK.crt"

# Find all kernel images in $ESP
for kernel in "$ESP"/vmlinuz*; do
    [[ -f "$kernel" ]] || continue  # skip if no files match

    # Only sign if unsigned
    if ! sbverify --cert "$CRT" "$kernel" &>/dev/null; then
        echo "Signing kernel: $kernel"
        sbsign --key "$KEY" --cert "$CRT" --output "$kernel" "$kernel"
    fi
done

sudo chmod +x /etc/initcpio/post/kernel-sbsign

# ========================
# Done
# ========================
echo "==> Setup completed successfully!"
echo "Reboot and enroll MOK using the Shim MOK Manager."
