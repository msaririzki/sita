# Panduan Operator Manual SITA di aaPanel

Dokumen ini adalah prosedur yang dapat dijalankan administrator server tanpa bantuan AI, dari VM aaPanel yang bersih sampai SITA siap dipakai dan dapat diperbarui. Prosedur memakai repository `msaririzki/sita` dan branch yang berisi Deployment Console saat ini, `codex/dependency-audit-p1`.

Dokumen ini untuk VM laboratorium. Jangan menjalankan eksperimen atau perubahan layanan pada `sita.ubg.ac.id` tanpa persetujuan administrator kampus.

## 1. Batas tanggung jawab

| Dikerjakan di aaPanel GUI | Dikerjakan di terminal server |
| --- | --- |
| Pasang Nginx, PHP, database, extension PHP, website, database/user, log, dan monitoring. | Clone source, `.env`, build, migration terkontrol, service Reverb/queue/scheduler, release, rollback, dan gate. |

Jangan membuat website atau user database dengan memanipulasi database internal aaPanel. Jangan menjalankan `chmod -R 777`, `migrate:fresh`, `db:seed`, atau `truncate` pada data SITA yang dipakai.

## 2. Topologi laboratorium ini

- Panel aaPanel: akses melalui jaringan privat/Tailscale.
- Domain aplikasi: `sita-aapanel.ikydev.com`.
- HTTPS publik: Cloudflare Tunnel.
- Origin lokal Tunnel: `http://127.0.0.1:80`.
- Nginx aaPanel tidak perlu sertifikat TLS ketika hanya menjadi origin Tunnel. Jangan membuka panel aaPanel ke domain publik.
- Database yang telah dipasang pada VM lab adalah MariaDB 10.11. Laravel menggunakan driver `mysql`, sehingga MariaDB 10.11 dapat dipakai. Untuk replikasi server kampus, catat versi database kampus sebelum membandingkan hasil.

## 3. Persiapan sekali di aaPanel GUI

### 3.1 Pasang komponen server

Di **App Store**, pasang satu web server saja:

- Nginx 1.30;
- PHP 8.4;
- satu database: MySQL 8.0 **atau** MariaDB 10.11;
- Node.js Version Manager dan Node.js 22 LTS;
- phpMyAdmin hanya bila administrator memang membutuhkan antarmuka SQL tambahan.

Jangan memasang Apache, OpenLiteSpeed, DNS Server, Mail Server, atau Pure-FTPd untuk SITA. Bila Pure-FTPd telanjur terpasang di lab, nonaktifkan setelah tahap ini; SITA tidak memakainya.

### 3.2 Aktifkan extension PHP 8.4

Masuk ke **App Store > PHP 8.4 > Install extensions**. Pastikan extension berikut aktif:

```text
bcmath, ctype, dom, fileinfo, filter, intl, mbstring, openssl,
pcntl, pcre, pdo, pdo_mysql, session, tokenizer, xml, zip
```

Setelah memasang extension, gunakan tombol restart PHP-FPM dari aaPanel atau jalankan pemeriksaan pada bagian 6. Extension berlaku untuk seluruh situs yang memakai PHP 8.4. Pada server multi-situs, lakukan pada maintenance window dan uji situs lain yang memakai runtime yang sama.

### 3.3 Buat website

Di **Website > Add site**:

- Domain: `sita-aapanel.ikydev.com`;
- PHP version: PHP 8.4;
- Database: jangan dibuat otomatis dari form ini, karena dibuat pada langkah berikut;
- SSL aaPanel: jangan diaktifkan untuk topologi Tunnel ini.

Buat direktori source terpisah dari document root bawaan agar source dan konfigurasi aaPanel tetap mudah ditelusuri. Pada lab ini gunakan:

```text
APP_DIR=/www/wwwroot/sita-aapanel.ikydev.com/sita
```

Setelah source sudah di-clone pada langkah 4, buka **Website > sita-aapanel.ikydev.com > Config** dan ubah **hanya** baris root menjadi:

```nginx
root /www/wwwroot/sita-aapanel.ikydev.com/sita/public;
```

Pertahankan `server_name`, `include enable-php-84.conf`, log, dan baris lain yang dibuat aaPanel. Simpan konfigurasi dan jalankan uji Nginx melalui tombol aaPanel atau:

```bash
sudo /www/server/nginx/sbin/nginx -t
sudo /etc/init.d/nginx reload
```

Saat atomic release pertama, console akan meminta persetujuan untuk mengubah root ini lagi ke symlink release `current/public`. Ia membuat backup vhost lebih dahulu di `/var/backups/sita/nginx/`.

### 3.4 Buat database

Di **Database > Add database**, isi:

```text
Database: sita_aapanel
Username: sita_aapanel
Password: buat kuat, simpan pada password manager administrator
Access: Local server (127.0.0.1)
```

Password hanya ditulis ke `.env` di server. Jangan menyimpannya di Git, profile deployment, screenshot, chat, atau dokumen skripsi.

### 3.5 Pastikan Node.js tersedia untuk akun deploy

Buka terminal aaPanel sebagai akun deploy lalu jalankan:

```bash
node --version
npm --version
```

Node harus minimal `20.19` atau `22.12`; gunakan Node 22 LTS. Bila Node dari aaPanel belum masuk `PATH`, tambahkan path Node version manager ke `PATH` akun deploy sebelum menjalankan console. Verifikasi ulang sampai dua perintah di atas menghasilkan versi.

## 4. Clone source dan buat `.env`

Login terminal sebagai pengguna deploy, lalu jalankan perintah berikut. Ganti `BRANCH` hanya setelah branch tersebut sudah disetujui sebagai branch rilis.

```bash
export APP_DIR=/www/wwwroot/sita-aapanel.ikydev.com/sita
export BRANCH=codex/dependency-audit-p1
sudo install -d -m 750 -o "$USER" -g www "$APP_DIR"
git clone --branch "$BRANCH" https://github.com/msaririzki/sita.git "$APP_DIR"
cd "$APP_DIR"
cp .env.example .env
chmod 640 .env
chgrp www .env
```

Jika `git clone` menolak karena direktori sudah berisi file, jangan hapus isi secara massal. Periksa path dengan `pwd` dan clone ke folder `sita` seperti contoh di atas, bukan ke document root bawaan aaPanel.

Edit `.env` memakai editor lokal server, misalnya `nano .env`. Nilai penting untuk lab Tunnel adalah berikut. Isi placeholder database dan mail sendiri.

```dotenv
APP_NAME=SITA
APP_ENV=production
APP_DEBUG=false
APP_URL=https://sita-aapanel.ikydev.com
APP_TIMEZONE=Asia/Makassar
APP_KEY=base64:ISI_DENGAN_KUNCI_32_BYTE
LOG_LEVEL=info

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=sita_aapanel
DB_USERNAME=sita_aapanel
DB_PASSWORD=ISI_PASSWORD_DATABASE

SESSION_DRIVER=database
SESSION_SECURE_COOKIE=true
SESSION_SAME_SITE=lax
CACHE_STORE=database
QUEUE_CONNECTION=database
BROADCAST_CONNECTION=reverb

REVERB_APP_ID=sita-aapanel
REVERB_APP_KEY=ISI_KUNCI_REVERB
REVERB_APP_SECRET=ISI_SECRET_REVERB
REVERB_HOST=sita-aapanel.ikydev.com
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_INTERNAL_HOST=127.0.0.1
REVERB_INTERNAL_PORT=8080
REVERB_INTERNAL_SCHEME=http
REVERB_SERVER_HOST=127.0.0.1
REVERB_SERVER_PORT=8080
REVERB_ALLOWED_ORIGINS=sita-aapanel.ikydev.com

VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST=sita-aapanel.ikydev.com
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https
```

Untuk menghasilkan nilai rahasia tanpa menyalinnya ke chat:

```bash
openssl rand -base64 32       # untuk APP_KEY, tambahkan awalan base64:
openssl rand -hex 16          # untuk REVERB_APP_KEY
openssl rand -hex 32          # untuk REVERB_APP_SECRET
```

Tetap isi `MAIL_*` dengan layanan SMTP yang disetujui bila fitur email SITA akan diuji. Jangan menggunakan nilai production kampus pada lab.

## 5. Buat profile Deployment Console

Dari `APP_DIR`, jalankan:

```bash
bash deploy/sita.sh
```

Pilih **aaPanel**, lalu pilih **Buat profile server**. Isi:

```text
Domain: sita-aapanel.ikydev.com
URL publik: https://sita-aapanel.ikydev.com
```

Console membuat `deploy/aapanel-profile.env` dengan mode file `600`, tanpa password. Buka file tersebut dan pastikan nilai berikut ada atau diubah:

```dotenv
HTTP_PROBE_MODE=auto
ORIGIN_PROBE_ADDRESS=127.0.0.1
ORIGIN_PROBE_HTTP_PORT=80
CHECK_EDGE_HTTP=true
MIGRATION_MODE=prompt
DB_BACKUP_DIR=/var/backups/sita
DEPLOYMENT_STRATEGY=atomic
RELEASE_ROOT=/www/wwwroot/sita-aapanel.ikydev.com/sita/.sita-release
CURRENT_LINK=/www/wwwroot/sita-aapanel.ikydev.com/sita/.sita-release/current
MANAGE_NGINX_ROOT=prompt
RELEASE_KEEP=3
```

Profile boleh menyimpan domain dan path, tetapi tidak boleh memuat `DB_PASSWORD`, `APP_KEY`, token Cloudflare, atau secret Reverb.

## 6. Pasang Cloudflare Tunnel

Di Cloudflare Zero Trust:

1. Buka **Networks > Tunnels** dan buat atau pilih Tunnel khusus `sita-lab-aapanel`.
2. Buat public hostname `sita-aapanel.ikydev.com`.
3. Atur service type `HTTP` menuju `http://127.0.0.1:80`.
4. Di VM, gunakan perintah instal connector Linux yang ditampilkan Cloudflare. Perintah itu memuat token rahasia, sehingga jangan disalin ke Git atau dokumen ini.
5. Pastikan service connector aktif dan domain dapat mencapai Nginx setelah bootstrap.

Tunnel sehat hanya membuktikan connector terhubung ke Cloudflare. Ia tidak membuktikan Nginx, PHP, database, Reverb, atau SITA siap. Itu tugas Deployment Console dan gate.

## 7. Deploy awal

Sebelum deploy, cek tanpa perubahan:

```bash
cd /www/wwwroot/sita-aapanel.ikydev.com/sita
bash deploy/sita.sh aapanel check
```

Perbaiki setiap `[FAIL]`. Pada VM lab saat prosedur ini ditulis, dua item yang harus diperhatikan adalah Node.js yang belum tersedia dan extension `fileinfo` yang belum aktif.

Jika Check siap, jalankan deploy awal:

```bash
bash deploy/sita.sh aapanel bootstrap
```

Saat daftar migration muncul pada database baru, baca daftar tersebut. Jawab `Y` hanya bila setuju. Console akan membuat backup database, memeriksa gzip/checksum backup, lalu menjalankan migration. Backup tersimpan di `/var/backups/sita`.

Pada aktivasi atomic pertama, console meminta konfirmasi untuk mengubah document root dari `APP_DIR/public` menjadi `CURRENT_LINK/public`. Jawab `Y` setelah memastikan domain, path, dan vhost benar. Jika kandidat gagal pada build, integration gate, atau security gate pascaaktivasi, release kode sebelumnya dipulihkan otomatis. Migration baru sengaja diblokir pada atomic release karena rollback kode tidak dapat membatalkan struktur database.

## 8. Pemeriksaan setelah deploy

Cek di terminal:

```bash
bash deploy/sita.sh aapanel check
bash deploy/sita.sh aapanel release
```

Cek di browser:

```text
https://sita-aapanel.ikydev.com/up
https://sita-aapanel.ikydev.com
```

Lakukan uji dua akun SITA untuk login, perpindahan halaman, dan chat realtime. Keberhasilan release belum menggantikan uji pengguna tersebut.

Di aaPanel, pantau access log, error log, penggunaan CPU/RAM, status database, dan status Nginx/PHP. Reverb, queue, dan scheduler dikelola sebagai service host oleh console, bukan sebagai aplikasi Node aaPanel.

## 9. Update rutin

Untuk update kode yang sudah ada di branch aktif:

```bash
cd /www/wwwroot/sita-aapanel.ikydev.com/sita
bash deploy/sita.sh aapanel release
```

Alur release:

1. sinkronisasi GUI aaPanel dan runtime;
2. precheck source, `.env`, extension, Node, database, dan service;
3. build kandidat release;
4. pemeriksaan integration dan security;
5. aktivasi symlink atomic;
6. rollback kode otomatis bila validasi pascaaktivasi gagal.

Jika migration terdeteksi, console menampilkan jumlah dan nama migration, meminta `Y`, membuat backup otomatis beserta checksum, lalu menerapkan migration. Jangan menganggap perubahan file biasa membutuhkan migration; migration hanya diperlukan bila code update membawa file baru pada `database/migrations/`.

## 10. Log, rollback, dan respons kegagalan

- Pilih menu **Lihat log terakhir** atau buka `storage/logs/deployment/` pada control checkout.
- Backup database: `/var/backups/sita`.
- Backup vhost sebelum root atomic diubah: `/var/backups/sita/nginx/`.
- Release aktif: `.sita-release/current`.
- Tiga release terakhir dipertahankan sesuai `RELEASE_KEEP=3`.

Jika release tanpa migration gagal setelah aktivasi, console mengembalikan `current` ke release sebelumnya. Jangan melakukan `git reset --hard` sebagai respons pertama. Baca log dan identifikasi fase yang gagal.

Jika release membawa migration, selesaikan melalui migration gate dan gunakan backup database untuk pemulihan yang telah ditinjau. Jangan mencoba rollback schema hanya dengan mengalihkan symlink kode.

## 11. Validasi operator sebelum menyatakan siap

- [ ] Nginx, PHP 8.4, database, dan Node 22 LTS tersedia.
- [ ] Semua extension PHP pada bagian 3.2 aktif.
- [ ] Website memakai PHP 8.4 dan root awal mengarah ke `APP_DIR/public`.
- [ ] `.env` production ada, mode `640`, dan tidak tercatat Git.
- [ ] Database/user dapat diakses Laravel.
- [ ] Tunnel mengarah ke `127.0.0.1:80`; panel aaPanel tetap privat.
- [ ] `bash deploy/sita.sh aapanel check` tidak memiliki `[FAIL]`.
- [ ] Bootstrap atau release menyatakan siap.
- [ ] `/up`, login, navigasi, dan chat dua akun berhasil.
- [ ] Log release, backup migration, dan hasil uji dicatat pada `docs/lab-skripsi-deployment.md`.
