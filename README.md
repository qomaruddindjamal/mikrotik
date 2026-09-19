# mikrotik

Script instalasi otomatis MikroTik Cloud Hosted Router (CHR) pada VPS Linux.

## Fitur & Keunggulan
- **RouterOS v7 Ready:** Otomatis mendeteksi versi *stable* terbaru dari MikroTik atau menggunakan versi yang ditentukan.
- **Konfigurasi Jaringan Otomatis:** Otomatis mendeteksi interface default, alamat IPv4 publik, dan default gateway VPS, lalu menerapkannya pada `ether1`.
- **Eksekusi Aman dari RAM (`/dev/shm`):** File image diunduh dan diekstrak ke RAM *tmpfs* agar penulisan raw disk via `dd` tidak mengalami I/O error atau kernel panic.
- **Dukungan Deteksi Disk Lengkap:** Mendukung VirtIO (`/dev/vda`), SCSI/SATA (`/dev/sda`), dan NVMe (`/dev/nvme0n1`).
- **Validasi Arsitektur & Bootloader:** Memeriksa arsitektur `x86_64` dan mendeteksi apakah sistem menggunakan UEFI.

## Cara Penggunaan

Jalankan perintah berikut pada VPS Linux baru Anda dengan hak akses `root`:

### 1. Eksekusi Langsung via Curl
```bash
curl -fsSL https://raw.githubusercontent.com/qomaruddindjamal/mikrotik/main/chr-install.sh | NEW_PASSWORD='PasswordKuat123!' bash
```

### 2. Atau Unduh Script Terlebih Dahulu
```bash
wget -O chr-install.sh https://raw.githubusercontent.com/qomaruddindjamal/mikrotik/main/chr-install.sh
chmod +x chr-install.sh

# Eksekusi dengan password kustom
NEW_PASSWORD='PasswordKuat123!' ./chr-install.sh

# Eksekusi dengan parameter lengkap (Identity, Versi, Password)
IDENTITY='MikroTik-Cloud' ROS_VER='7.18.1' NEW_PASSWORD='PasswordKuat123!' ./chr-install.sh
```

## Peringatan
> **PENTING:** Script ini akan **MENIMPA DAN MENGHAPUS SELURUH DISK SISTEM** pada VPS Anda tanpa konfirmasi interaktif. Pastikan Anda hanya menjalankannya pada VPS baru atau VPS yang sudah di-backup.
