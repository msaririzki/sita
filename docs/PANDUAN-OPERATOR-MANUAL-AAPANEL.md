# Panduan Operator Manual SITA di aaPanel

Dokumen ini adalah prosedur yang dapat dijalankan administrator server tanpa bantuan AI, dari VM aaPanel yang bersih sampai SITA siap dipakai dan dapat diperbarui. Prosedur memakai repository `msaririzki/sita` dan branch yang berisi Deployment Console saat ini, `codex/dependency-audit-p1`.

Dokumen ini untuk VM laboratorium. Jangan menjalankan eksperimen atau perubahan layanan pada `sita.ubg.ac.id` tanpa persetujuan administrator kampus.

## 1. Batas tanggung jawab

| Dikerjakan di aaPanel GUI | Dikerjakan di terminal server |
| --- | --- |
| Pasang Nginx, PHP, database, extension PHP, website, database/user, log, dan monitoring. | Clone source, `.env`, build, migration terkontrol, service Reverb/queue/scheduler, release, rollback, dan gate. |

Jangan membuat website atau user database dengan memanipulasi database internal aaPanel. Jangan menjalankan `chmod -R 777`, `migrate:fresh`, `db:seed`, atau `truncate` pada data SITA yang dipakai.

Console dapat dijalankan oleh akun deploy yang memiliki `sudo` atau langsung sebagai `root`, seperti pola server kampus. Hak root hanya digunakan untuk vhost, PHP-FPM, permission, dan unit systemd. Reverb, queue, dan scheduler tetap dijalankan sebagai user PHP-FPM (`www` secara default), bukan sebagai root.

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

Console `bootstrap` otomatis memeriksa dan memperbaiki `fileinfo` bila extension itu tidak tersedia, termasuk pada build aaPanel yang memasang PHP dengan `--disable-fileinfo`. Ia membangun modul yang cocok dengan PHP aktif, menyimpan backup `php.ini` dan modul lama di `/var/backups/sita/php-extensions/`, reload PHP-FPM, lalu memverifikasinya. Proses otomatis hanya berjalan jika runtime PHP dipakai satu vhost. Pada server multi-situs, ia berhenti sebelum mengubah runtime bersama sampai administrator menyetujui perubahan pada maintenance window.

Extension lain tetap diperiksa oleh console. Jika ada yang tidak tersedia, perbaiki melalui aaPanel sesuai versi PHP aktif lalu jalankan Check ulang. Jangan memasang paket `apt install php-*` karena itu tidak memperbaiki runtime PHP aaPanel.

### 3.3 Buat website

Di **Website > Add site**:

- Domain: `sita-aapanel.ikydev.com`;
- PHP version: PHP 8.4;
- Database: jangan dibuat otomatis dari form ini, karena dibuat pada langkah berikut;
- SSL aaPanel: jangan diaktifkan untuk topologi Tunnel ini.

Gunakan path bawaan aaPanel sebagai control checkout. Ini adalah pola paling mudah dikenali oleh administrator kampus:

```text
APP_DIR=/www/wwwroot/sita-aapanel.ikydev.com
```

Jangan mengubah baris `root` dari GUI pada tahap ini. Situs baru aaPanel akan memakai root awal `/www/wwwroot/sita-aapanel.ikydev.com;`. Saat atomic release pertama, console mengenali root bawaan tersebut, meminta persetujuan, membuat backup vhost di `/var/backups/sita/nginx/`, menguji sintaks Nginx, lalu menggantinya menjadi symlink release `current/public`.

Path tetap fleksibel. Bila administrator menentukan path lain, misalnya `/www/wwwroot/webkampus/sita`, clone source di path itu dan pastikan root vhost awal sama dengan `APP_DIR` atau `APP_DIR/public`. Console mengenali kedua bentuk tersebut sebelum mengalihkan ke `current/public`.

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

Node harus minimal `20.19` atau `22.12`; gunakan Node 22 LTS. Bila Check menemukan Node/npm belum tersedia, menu `[2]` menawarkan pemasangan Node 22 khusus SITA di `/opt/sita/node`. Arsip berasal dari nodejs.org dan checksum resmi diverifikasi; Node global aaPanel maupun website lain tidak diubah. Verifikasi ulang sampai dua perintah di atas menghasilkan versi.

## 4. Clone source lalu jalankan console

Setelah komponen GUI tersedia, operator cukup clone source yang telah disetujui lalu membuka console dari source tersebut. Pola ini tidak memakai skrip unduhan terpisah.

```bash
cd /www/wwwroot/sita-aapanel.ikydev.com
sudo git clone -b codex/dependency-audit-p1 --depth=1 https://github.com/msaririzki/sita.git sita
sudo chown -R "$(id -un)":www sita
sudo find sita -type d -exec chmod 750 {} +
cd sita
bash deploy/sita.sh
```

aaPanel umumnya membuat folder Website dengan pemilik `www`, sehingga `git clone` langsung oleh akun SSH non-root dapat ditolak. Perintah di atas memakai hak administrator hanya untuk membuat checkout, lalu memberikan kepemilikan kepada akun operator dan grup `www` agar console dapat membuat profile/log serta PHP-FPM tetap dapat membaca source. Permission file bawaan Git dipertahankan agar control checkout tidak tampak berubah hanya karena mode executable skrip. Source berada pada subfolder `sita`, sedangkan folder parent tetap menjadi root Website bawaan aaPanel. File panel seperti `.user.ini`, `.htaccess`, serta halaman error tetap berada pada folder parent dan tidak disentuh Git. Pada atomic release pertama, console mengenali root parent tersebut, mencadangkan vhost, menguji konfigurasi Nginx, lalu mengarahkannya ke `current/public` secara terkontrol.

Bila administrator memilih nama atau lokasi source lain, clone ke lokasi tersebut. Saat menu inisialisasi meminta **Folder root Website aaPanel**, masukkan folder parent yang benar. Contoh: source `/www/wwwroot/webkampus/sita` memiliki root Website `/www/wwwroot/webkampus`.

## 5. Inisialisasi aplikasi dari console

Pilih environment **aaPanel**, lalu pilih menu **[1] Inisialisasi aplikasi**. Menu ini menanyakan domain, URL publik, folder root Website aaPanel, dan kredensial database. Password database diketik tersembunyi.

Menu [1] otomatis membuat:

- `.env` production dengan permission `640` dan grup runtime `www`;
- `APP_KEY`, `REVERB_APP_KEY`, dan `REVERB_APP_SECRET` secara acak tanpa menampilkannya;
- `deploy/aapanel-profile.env` dengan permission `600`;
- konfigurasi domain, path, vhost, PHP-FPM, healthcheck, backup, dan atomic release.

Profile adalah kartu konfigurasi operasional server yang dipakai console pada setiap check, release, backup, dan rollback. Ia tidak menyimpan `DB_PASSWORD`, `APP_KEY`, token Cloudflare, atau secret Reverb. Semua rahasia hanya tersimpan di `.env` lokal.

Untuk email, menu membuat `MAIL_MAILER=log` sebagai nilai aman pada lab. Sebelum fitur email diuji, isi `MAIL_*` dengan layanan SMTP yang disetujui di `.env` lokal.

Setelah menu [1], urutan normal adalah [2] Check kesiapan server, kemudian [3] Siapkan server baru. Update selanjutnya hanya memakai [4] Atomic Release.
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

Check tidak menulis aplikasi. Pada server benar-benar baru, `[FAIL]` permission `storage` dan `bootstrap/cache` masih wajar sebelum Bootstrap karena source baru belum menyiapkan direktori runtime. Tinjau hasilnya untuk memastikan domain, vhost, PHP, dan `.env` benar. Menu Check dapat menawarkan perbaikan terisolasi untuk `fileinfo` dan Node.js; Bootstrap juga memastikan ulang keduanya serta menyiapkan permission runtime sebelum deploy.

Sesudah Bootstrap atau setelah service SITA pernah dipasang, Check juga menjalankan Integration Gate read-only. Karena itu Reverb, queue, scheduler, health endpoint, public storage, dan WebSocket harus lulus; service yang mati tidak lagi hanya dicatat sebagai peringatan. Pada server yang benar-benar belum memiliki release maupun unit service, tahap integrasi dilewati dan akan dijalankan oleh Bootstrap.

Setelah hasil Check ditinjau, jalankan deploy awal:

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
- [ ] Website memakai PHP 8.4 dan root awal masih root bawaan aaPanel atau `APP_DIR/public`; console akan memvalidasi lalu mengalihkan root pada atomic release pertama.
- [ ] `.env` production ada, mode `640`, dan tidak tercatat Git.
- [ ] Database/user dapat diakses Laravel.
- [ ] Tunnel mengarah ke `127.0.0.1:80`; panel aaPanel tetap privat.
- [ ] `bash deploy/sita.sh aapanel check` tidak memiliki `[FAIL]`.
- [ ] Bootstrap atau release menyatakan siap.
- [ ] `/up`, login, navigasi, dan chat dua akun berhasil.
- [ ] Log release, backup migration, dan hasil uji dicatat pada `docs/lab-skripsi-deployment.md`.
