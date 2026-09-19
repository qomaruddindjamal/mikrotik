#!/bin/bash
# ==============================================================================
# Script Instalasi Otomatis MikroTik Cloud Hosted Router (CHR) pada VPS
# PERINGATAN: Script ini akan langsung MENIMPA (OVERWRITE) seluruh disk sistem!
# Cocok untuk deployment cepat CHR pada VPS baru (fresh install).
# Telah diuji pada: Debian 12/13, Ubuntu 22.04/24.04, CentOS 9, Rocky Linux 9, AlmaLinux 9.
# ==============================================================================
#
# Panduan Penggunaan:
#   Ganti password:
#     NEW_PASSWORD='PasswordKuat123!' ./chr-install.sh
#
#   Ganti identity/hostname:
#     IDENTITY='CHR-Utama' ./chr-install.sh
#
#   Tentukan versi RouterOS tertentu (default: versi stable terbaru):
#     ROS_VER='7.24.4' ./chr-install.sh
#
#   Tentukan target disk manual jika diperlukan:
#     TARGET_DISK='/dev/sda' ./chr-install.sh
# ==============================================================================

set -euo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

# -------- 1. Pengecekan Hak Akses & Arsitektur --------
[[ $EUID -eq 0 ]] || { echo "[-] Kesalahan: Script harus dijalankan sebagai root."; exit 1; }

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
  echo "[-] Kesalahan: MikroTik CHR hanya mendukung arsitektur x86_64 (terdeteksi: $ARCH)."
  exit 1
fi

if [[ -d /sys/firmware/efi ]]; then
  echo "[!] PERINGATAN: Sistem VPS terdeteksi booting menggunakan UEFI (/sys/firmware/efi)."
  echo "    Image bawaan MikroTik CHR menggunakan format MBR/BIOS Legacy."
  echo "    Pastikan VPS/hypervisor Anda mendukung fallback boot BIOS/Legacy."
fi

# Aktifkan seluruh fungsi SysRq untuk memastikan reboot darurat berhasil
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true

# -------- 2. Pemasangan Dependensi yang Dibutuhkan --------
echo "[*] Memeriksa dependensi sistem..."
if command -v apt-get >/dev/null; then
  apt-get update -qq && apt-get install -qq -y wget unzip util-linux udev
elif command -v dnf >/dev/null; then
  dnf install -y wget unzip util-linux udev
elif command -v yum >/dev/null; then
  yum install -y wget unzip util-linux udev
fi

need_bins=(wget losetup mount umount awk ip dd lsblk findmnt)
for b in "${need_bins[@]}"; do
  command -v "$b" >/dev/null || { echo "[-] Aplikasi yang diperlukan tidak ditemukan: $b"; exit 1; }
done

# -------- 3. Konfigurasi Awal --------
if [[ -z "${ROS_VER:-}" ]]; then
  echo "[*] Mengambil versi RouterOS stable terbaru..."
  ROS_VER=$(wget -qO- https://upgrade.mikrotik.com/routeros/NEWESTa7.stable | awk '{print $1}')
  [[ -n "$ROS_VER" ]] || { echo "[-] Gagal mengambil versi terbaru."; exit 1; }
  echo "    -> Versi stable terbaru: ${ROS_VER}"
fi

ROS_ZIP_URL="https://download.mikrotik.com/routeros/${ROS_VER}/chr-${ROS_VER}.img.zip"

NEW_USER="${NEW_USER:-admin}"
NEW_PASSWORD="${NEW_PASSWORD:-GantiPasswordIni!}"
IDENTITY="${IDENTITY:-chr-${ROS_VER}}"
TARGET_DISK="${TARGET_DISK:-}"

# PENTING: Gunakan /dev/shm (tmpfs di RAM) agar saat disk ditimpa, image tidak korup
WORKDIR="/dev/shm/chr-inst"
MNT="/mnt/chr"

# -------- 4. Penyiapan Direktori & Trap Cleanup --------
mkdir -p "$WORKDIR" "$MNT"
cleanup() {
  set +e
  mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[*] Mengunduh image CHR ${ROS_VER} ke RAM (${WORKDIR})..."
cd "$WORKDIR"
wget -q --show-progress "$ROS_ZIP_URL" -O chr.img.zip

echo "[*] Mengekstrak file image..."
if command -v unzip >/dev/null; then
  unzip -p chr.img.zip > chr.img
elif command -v python3 >/dev/null; then
  python3 -c "import zipfile; zipfile.ZipFile('chr.img.zip').extractall('.')"
  EXTRACTED=$(ls chr-*.img 2>/dev/null | head -n1 || true)
  if [[ -n "$EXTRACTED" ]]; then
    mv "$EXTRACTED" chr.img
  fi
else
  echo "[-] Gagal mengekstrak image. Unzip atau Python3 dibutuhkan."
  exit 1
fi
rm -f chr.img.zip

[[ -f "$WORKDIR/chr.img" ]] || { echo "[-] chr.img tidak ditemukan setelah ekstraksi."; exit 1; }

echo "[*] Memasang loop device..."
LOOPDEV=$(losetup --show -Pf chr.img)
sleep 1
command -v partx >/dev/null && partx -u "$LOOPDEV" 2>/dev/null || true

echo "[*] Mencari partisi konfigurasi (direktori 'rw/')..."
found=""
for part in "${LOOPDEV}"p{1..8}; do
  [[ -e "$part" ]] || continue
  mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
  mount "$part" "$MNT" 2>/dev/null || continue
  if [[ -d "$MNT/rw" ]]; then
    found="$part"
    echo "    -> Partisi konfigurasi ditemukan pada: $part"
    break
  fi
done
[[ -n "$found" ]] || { echo "[-] Gagal menemukan direktori 'rw/' pada partisi image CHR."; exit 1; }

# -------- 5. Deteksi Jaringan VPS (IP & Gateway) --------
IFACE=$(ip -4 route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {print $5; exit}')
[[ -n "${IFACE:-}" ]] || IFACE=$(ip -4 route show 2>/dev/null | awk '/default/ {print $5; exit}')
[[ -n "${IFACE:-}" ]] || { echo "[-] Gagal mendeteksi interface default."; exit 1; }

ADDR="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | head -n1 || true)"
GW="$(ip -4 route show default | awk '/default/ {print $3; exit}' || true)"
[[ -n "$ADDR" && -n "$GW" ]] || {
  echo "[-] Alamat IPv4 ($ADDR) atau Gateway ($GW) tidak berhasil dideteksi.";
  exit 1;
}
echo "[*] Jaringan Terdeteksi: Interface=$IFACE, IP=$ADDR, Gateway=$GW"

# -------- 6. Menulis Skrip Konfigurasi Awal (autorun.scr) --------
echo "[*] Membuat autorun.scr (RouterOS v7 + RoMON + BCP)..."
cat > "$MNT/rw/autorun.scr" <<EOF
/ip address add address=${ADDR} interface=ether1
/ip route add dst-address=0.0.0.0/0 gateway=${GW}
/user set [find name="admin"] name="${NEW_USER}" password="${NEW_PASSWORD}"
/system identity set name="${IDENTITY}"
/tool bandwidth-server set enabled=no
/ip dns set servers=1.1.1.1,8.8.8.8
/ip service disable api
/ip service disable api-ssl
/ip service disable telnet
/ip service disable ftp
/ip dhcp-client remove [find]
/tool romon set enabled=yes
/interface bridge add name=bridge-romon protocol-mode=none
/ppp profile set default bridge=bridge-romon
/ppp profile set default-encryption bridge=bridge-romon
/interface pppoe-server server add service-name=PPPOE-CHR interface=bridge-romon default-profile=default-encryption disabled=no one-session-per-host=no
EOF

sync
umount "$MNT"
losetup -d "$LOOPDEV"
unset LOOPDEV

# -------- 7. Deteksi Target Disk yang Aman --------
if [[ -z "$TARGET_DISK" ]]; then
  ROOTSRC=$(findmnt -no SOURCE /)
  ROOT_TYPE=$(lsblk -no TYPE "$ROOTSRC" 2>/dev/null || true)
  if [[ "$ROOT_TYPE" == "disk" ]]; then
    TARGET_DISK="$ROOTSRC"
  else
    PARENT=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null || true)
    if [[ -n "$PARENT" ]]; then
      TARGET_DISK="/dev/$PARENT"
    else
      TARGET_DISK=$(echo "$ROOTSRC" | sed -E 's/p?[0-9]+$//')
    fi
  fi
fi

[[ -b "$TARGET_DISK" ]] || { echo "[-] Target disk bukan block device yang valid: $TARGET_DISK"; exit 1; }
echo "[*] Target disk instalasi: ${TARGET_DISK}"

# -------- 8. Penulisan Image ke Disk & Reboot --------
echo "[*] Mengosongkan buffer filesystem dan mengubah mode root ke read-only..."
echo u > /proc/sysrq-trigger 2>/dev/null || true
sleep 3

echo "[*] Menulis image CHR ke ${TARGET_DISK}..."
dd if="${WORKDIR}/chr.img" of="${TARGET_DISK}" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
sync

echo "[*] Penulisan selesai. Menyimpan buffer disk dan me-restart VPS..."
echo s > /proc/sysrq-trigger 2>/dev/null || true
sleep 1
echo b > /proc/sysrq-trigger 2>/dev/null || reboot -f
