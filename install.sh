#!/usr/bin/env bash
set -euo pipefail

ESP="/boot"

echo "==> Installing yay"
if ! command -v yay &>/dev/null; then
    sudo pacman -S --needed --noconfirm git base-devel
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    pushd /tmp/yay
    makepkg -si --noconfirm
    popd
fi

echo "==> Installing shim-signed"
yay -S --noconfirm shim-signed

echo "==> Preparing ESP Bootloader directory"
sudo mkdir -p "$ESP/EFI/BOOT"

echo "==> Moving BOOTx64.EFI to grubx64.efi"
if [[ -f "$ESP/EFI/BOOT/BOOTx64.EFI" ]]; then
    sudo mv "$ESP/EFI/BOOT/BOOTx64.EFI" "$ESP/EFI/BOOT/grubx64.efi"
fi

echo "==> copying Shims"
sudo cp /usr/share/shim-signed/shimx64.efi "$ESP/EFI/BOOT/BOOTx64.EFI"
sudo cp /usr/share/shim-signed/mmx64.efi "$ESP/EFI/BOOT/"

echo "==> Disk layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT -e7 | sed 's/^/    /'

echo
read -rp "Enter disk for ESP (e.g. sda or nvme0n1): " DISK
read -rp "Enter EFI partition number (e.g. 1): " PART

echo "==> Creating EFI Boot entry (Shim → GRUB)"
sudo efibootmgr --unicode \
     --disk "/dev/$DISK" \
     --part "$PART" \
     --create \
     --label "Shim" \
     --loader "/EFI/BOOT/BOOTx64.EFI"

echo "==> Installing sbsigntools"
sudo pacman -S --noconfirm sbsigntools openssl

echo "==> Generating MOK keys"

sudo mkdir -p "$ESP/EFI/BOOT/Mok"
cd "$ESP/EFI/BOOT/Mok"

sudo openssl req -newkey rsa:2048 -nodes -keyout MOK.key \
    -new -x509 -sha256 -days 3650 \
    -subj "/CN=my Machine Owner Key/" \
    -out MOK.crt

sudo openssl x509 -outform DER -in MOK.crt -out MOK.cer

echo "==> Signing the kernel"
sudo sbsign --key "$ESP/EFI/BOOT/keys/MOK.key" \
            --cert "$ESP/EFI/BOOT/keys/MOK.crt" \
            --output /boot/vmlinuz-linux /boot/vmlinuz-linux

echo "==> Installing GRUB with full module set"
sudo grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot \
  --bootloader-id=BOOT \
  --modules="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal ntfs part_apple part_msdos part_gpt password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label sleep smbios squash4 test true video xfs zfs zfscrypt zfsinfo cpuid tpm" \
  --sbat /usr/share/grub/sbat.csv

echo "==> Signing grubx64.efi"
sudo sbsign --key MOK.key --cert MOK.crt \
     --output "$ESP/EFI/BOOT/grubx64.efi" \
     "$ESP/EFI/BOOT/grubx64.efi"

echo "==> Creating automatic kernel-signing hook"
sudo mkdir -p /etc/initcpio/post

sudo tee /etc/initcpio/post/kernel-sbsign >/dev/null <<'EOF'
#!/usr/bin/env bash

kernel="$1"
[[ -n "$kernel" ]] || exit 0

[[ ! -f "$KERNELDESTINATION" ]] || kernel="$KERNELDESTINATION"

keypairs=(/boot/EFI/BOOT/keys/MOK.key /boot/EFI/BOOT/keys/MOK.crt)

for (( i=0; i<${#keypairs[@]}; i+=2 )); do
    key="${keypairs[$i]}" cert="${keypairs[(( i + 1 ))]}"
    if ! sbverify --cert "$cert" "$kernel" &>/dev/null; then
        sbsign --key "$key" --cert "$cert" --output "$kernel" "$kernel"
    fi
done
EOF

sudo chmod +x /etc/initcpio/post/kernel-sbsign

echo "==> Setup completed successfully!"
echo "Reboot and enroll MOK using the Shim MOK Manager."
