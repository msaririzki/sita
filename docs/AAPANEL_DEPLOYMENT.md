# Deployment SITA di aaPanel

Dokumen ini menjelaskan deployment SITA untuk aaPanel Free, Nginx, PHP-FPM, MariaDB/MySQL, dan Node.js untuk build asset.

## Ringkasan Audit

- Backend: Laravel 12, PHP minimal 8.4 untuk lock dependency saat ini, Fortify untuk auth, Inertia Laravel, Filament untuk admin.
- Frontend: React 19, Inertia React, Vite 7, Tailwind CSS v4.
- Build frontend: `npm ci` lalu `npm run build`.
- Runtime backend: Nginx mengarah ke folder `public/`, PHP-FPM menjalankan `public/index.php`.
- Database lokal saat audit: SQLite. Production direkomendasikan MariaDB/MySQL dari aaPanel.
- Queue/cache/session: default repo memakai driver `database`, sehingga tabel `jobs`, `cache`, dan `sessions` harus dimigrasikan.
- Storage: `storage/` dan `bootstrap/cache/` wajib writable oleh user PHP-FPM. Jalankan `php artisan storage:link`.
- Realtime chat/notifikasi: project memakai Laravel Reverb. Di aaPanel perlu proses Reverb terpisah jika ingin chat realtime seperti Docker.
- Scheduler: project punya command reminder. Cron scheduler perlu diaktifkan.
- Email: Fortify reset password dan verifikasi email butuh SMTP production.
- SSR: repo punya entry SSR, tetapi production aaPanel dibuat default `INERTIA_SSR_ENABLED=false` agar tidak membutuhkan proses Node runtime.
- Dependency eksternal: font dari `fonts.bunny.net`. Aplikasi tetap punya fallback system font jika akses internet server/client dibatasi.

## Arsitektur yang Direkomendasikan

Gunakan satu subdomain, misalnya:

```text
https://sita.kampus.ac.id
```

Struktur folder:

```text
/www/wwwroot/sita.kampus.ac.id
├── app
├── bootstrap
├── config
├── database
├── deploy
├── docs
├── public
├── resources
├── routes
├── storage
├── vendor
├── .env
├── artisan
├── composer.json
├── package.json
└── package-lock.json
```

Document root aaPanel harus diarahkan ke:

```text
/www/wwwroot/sita.kampus.ac.id/public
```

Frontend dan backend tidak perlu dipisah subdomain karena Inertia menyajikan React dari Laravel yang sama.

## Requirement Server

- aaPanel Free dengan Nginx.
- PHP 8.4 atau lebih baru. Samakan PHP CLI, Composer, PHP-FPM site, dan PATH build Vite ke PHP 8.4.
- Extension PHP: `bcmath`, `ctype`, `dom`, `fileinfo`, `filter`, `intl`, `json`, `mbstring`, `openssl`, `pcntl`, `pcre`, `pdo`, `pdo_mysql`, `session`, `tokenizer`, `xml`, `zip`.
- Composer 2.
- Node.js 20.19 atau 22.12 lebih baru untuk build Vite 7. Node 22 tetap direkomendasikan karena CI/CD homeserver memakai Node 22.
- MariaDB/MySQL.
- Git dan Bash.

## Setup Pertama

1. Buat website di aaPanel dengan domain `sita.kampus.ac.id`.
2. Set document root ke `/www/wwwroot/sita.kampus.ac.id/public`.
3. Clone repo ke `/www/wwwroot/sita.kampus.ac.id`.
4. Buat database dan user MySQL/MariaDB dari aaPanel.
5. Salin env production:

```bash
cp .env.production.example .env
php -r "echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;"
```

Isi `APP_KEY` dengan output command tersebut, lalu sesuaikan minimal:

```dotenv
APP_ENV=production
APP_DEBUG=false
APP_URL=https://sita.kampus.ac.id
APP_BASE_PATH=
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=sita
DB_USERNAME=sita_user
DB_PASSWORD=isi_password_database
MAIL_MAILER=smtp
MAIL_HOST=smtp.kampus.ac.id
MAIL_SCHEME=null
MAIL_PORT=587
MAIL_USERNAME=isi_user_smtp
MAIL_PASSWORD=isi_password_smtp
MAIL_FROM_ADDRESS=noreply@sita.kampus.ac.id

BROADCAST_CONNECTION=reverb
REVERB_APP_ID=sita-production
REVERB_APP_KEY=isi_key_panjang
REVERB_APP_SECRET=isi_secret_panjang
REVERB_HOST=sita.kampus.ac.id
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_INTERNAL_HOST=127.0.0.1
REVERB_INTERNAL_PORT=8080
REVERB_INTERNAL_SCHEME=http
REVERB_SERVER_HOST=127.0.0.1
REVERB_SERVER_PORT=8080
VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST="${REVERB_HOST}"
VITE_REVERB_PORT="${REVERB_PORT}"
VITE_REVERB_SCHEME="${REVERB_SCHEME}"
```

Jangan commit `.env`.

## Precheck Server

Jalankan:

```bash
bash deploy/aapanel-doctor.sh
```

Jika ingin sekaligus cek kecocokan domain:

```bash
DOMAIN=sita.kampus.ac.id PHP_BIN=/www/server/php/84/bin/php bash deploy/aapanel-doctor.sh
```

Semua item `[FAIL]` harus diperbaiki sebelum deploy.

Jika ingin cek healthcheck dan nama service PHP-FPM yang akan direstart saat deploy:

```bash
DOMAIN=sita.kampus.ac.id \
PHP_BIN=/www/server/php/84/bin/php \
PHP_FPM_SERVICE=php-fpm-84 \
HEALTHCHECK_URL=https://sita.kampus.ac.id/up \
bash deploy/aapanel-doctor.sh
```

## Deploy

Deploy normal:

```bash
DOMAIN=sita.kampus.ac.id PHP_BIN=/www/server/php/84/bin/php bash deploy/aapanel-deploy.sh
```

Script akan:

- validasi `.env` production;
- `git pull --ff-only` jika folder adalah git checkout;
- reload script deploy satu kali setelah `git pull` agar aaPanel memakai versi script terbaru dari repo;
- validasi PHP 8.4, Node 20.19/22.12, Composer, NPM, dan extension PHP production;
- masuk maintenance mode;
- install Composer production dependency;
- cek Composer platform requirement;
- install dependency Node dan build asset Vite;
- menghapus `public/hot` agar production tidak menunjuk Vite dev server;
- menyiapkan permission storage;
- menjalankan `storage:link`;
- menjalankan migration;
- membuat cache config, route, view, dan event;
- restart queue worker Laravel;
- restart/reload PHP-FPM aaPanel agar opcache/runtime setara dengan container homeserver yang diganti;
- keluar dari maintenance mode.

Script tidak menjalankan `migrate:fresh`, `db:seed`, `truncate`, atau penghapusan tabel. Namun `php artisan migrate --force` dapat mengubah struktur database dan dapat mengubah data bila migration yang akan diterapkan memang berisi migrasi data. Buat backup database sebelum menjalankan deployment pada server kampus.

Deploy dengan healthcheck seperti CI/CD homeserver:

```bash
DOMAIN=sita.kampus.ac.id \
PHP_BIN=/www/server/php/84/bin/php \
PHP_FPM_SERVICE=php-fpm-84 \
HEALTHCHECK_URL=https://sita.kampus.ac.id/up \
bash deploy/aapanel-deploy.sh
```

Jika nama service PHP-FPM aaPanel berbeda, isi `PHP_FPM_SERVICE`. Jika restart PHP-FPM dikelola manual oleh panel, pakai `RESTART_PHP_FPM=false`.

Jika PHP-FPM memakai group selain `www`, isi `PHP_FPM_RUNTIME_GROUP` agar `storage/` dan `bootstrap/cache/` dapat ditulis oleh proses PHP-FPM:

```bash
PHP_FPM_RUNTIME_GROUP=www DOMAIN=sita.kampus.ac.id bash deploy/aapanel-deploy.sh
```

## Integration Gate Pascadeploy

Gunakan gate ini setelah setiap update untuk membuktikan aplikasi siap dipakai, bukan hanya script deploy sudah selesai. Gate memeriksa permission user PHP-FPM, health endpoint HTTP, status service, konfigurasi host Reverb pada bundle frontend, dan WebSocket handshake melalui Nginx.

```bash
DOMAIN=sita.kampus.ac.id \
PHP_BIN=/www/server/php/84/bin/php \
PHP_FPM_SERVICE=php-fpm-84 \
PHP_FPM_RUNTIME_USER=www \
HEALTHCHECK_URL=https://sita.kampus.ac.id/up \
bash deploy/aapanel-integration-gate.sh
```

Untuk menjalankannya otomatis di akhir deploy, tambahkan `RUN_INTEGRATION_GATE=true`. `CHECK_SERVICES` bernilai `true` secara default, sehingga status PHP-FPM, Reverb, queue, dan scheduler tetap diperiksa pada setiap update. `INSTALL_SERVICES=true` hanya dipakai ketika service Reverb, queue, dan scheduler pertama kali dibuat atau unit service diubah.

## Security Gate Sebelum dan Sesudah Deploy

Gunakan preflight untuk menghentikan rilis sebelum source, dependency, atau migration diubah bila konfigurasi production tidak aman. Security Gate pascadeploy kemudian memeriksa endpoint publik dan header dari aplikasi yang sudah aktif.

```bash
DOMAIN=sita.kampus.ac.id \
PHP_BIN=/www/server/php/84/bin/php \
PHP_FPM_SERVICE=php-fpm-84 \
PHP_FPM_RUNTIME_USER=www \
HEALTHCHECK_URL=https://sita.kampus.ac.id/up \
PUBLIC_BASE_URL=https://sita.kampus.ac.id \
NGINX_CONFIG=/path/ke/vhost-sita.conf \
RUN_DEPENDENCY_AUDIT=true \
DEPENDENCY_AUDIT_MODE=enforce \
DEPENDENCY_AUDIT_THRESHOLD=high \
RUN_SECURITY_PREFLIGHT=true \
RUN_INTEGRATION_GATE=true \
RUN_SECURITY_GATE=true \
bash deploy/aapanel-deploy.sh
```

Preflight tidak mengubah vhost aaPanel. Ia membaca konfigurasi yang diberikan lewat `NGINX_CONFIG`; jalankan dengan akses yang dapat membaca vhost tersebut. Skrip eksperimen `scripts/run-*-experiment.sh` hanya untuk VM laboratorium dan tidak boleh dijalankan pada server kampus.

Deploy lengkap sekaligus memasang service Reverb, queue worker, dan scheduler systemd:

```bash
DOMAIN=sita.kampus.ac.id \
PHP_BIN=/www/server/php/84/bin/php \
COMPOSER_BIN=/tmp/composer84 \
INSTALL_SERVICES=true \
bash deploy/aapanel-deploy.sh
```

Mode ini membutuhkan `sudo` karena membuat file service di `/etc/systemd/system`. Jika server kampus tidak mengizinkan systemd service dari SSH, pakai aaPanel Process Manager/Supervisor dengan command di bagian "Reverb, Queue, dan Cron".

Untuk deploy tanpa pull:

```bash
GIT_PULL=false DOMAIN=sita.kampus.ac.id bash deploy/aapanel-deploy.sh
```

Untuk deploy tanpa migration:

```bash
RUN_MIGRATIONS=false DOMAIN=sita.kampus.ac.id bash deploy/aapanel-deploy.sh
```

## Nginx aaPanel

Gunakan template `deploy/aapanel-nginx.conf`. Ganti:

- `DOMAIN` menjadi domain production.
- `PROJECT_ROOT` menjadi folder checkout production yang sebenarnya, misalnya `/www/wwwroot/sita.kampus.ac.id`. Jangan menyamakan nama folder dengan domain bila keduanya berbeda.

Untuk panel admin Filament, pastikan request `/livewire/*` diteruskan ke Laravel. Jika aaPanel masih memakai rule static bawaan untuk `.js`/`.css`, tambahkan blok ini sebelum rule static asset:

```nginx
location ^~ /livewire {
    try_files $uri $uri/ /index.php?$query_string;
}
```

Simpan aturan eksplisit `/storage/` pada template. Laravel menerbitkan unggahan publik pada jalur ini; aturan penolakan direktori internal tidak boleh ikut memblokirnya.

Untuk Reverb realtime, proxy websocket ke proses lokal Reverb:

```nginx
location ~ ^/(app|apps) {
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 60;
    proxy_send_timeout 60;
    proxy_pass http://127.0.0.1:8080;
}
```
- `fastcgi_pass unix:/tmp/php-cgi-84.sock;` sesuai socket PHP aaPanel. Pada beberapa server aaPanel, include bawaan `enable-php-84.conf` bisa dipakai menggantikan blok PHP manual.

Contoh root wajib tetap ke `public/`, bukan folder project utama.

## Reverb, Queue, dan Cron

Chat realtime membutuhkan Laravel Reverb. Jika Reverb tidak jalan, halaman chat masih bisa terbuka tetapi update realtime antar user tidak akan masuk sampai fallback/request berikutnya.

Cara otomatis yang direkomendasikan:

```bash
DOMAIN=sita.kampus.ac.id PHP_BIN=/www/server/php/84/bin/php bash deploy/aapanel-services.sh
```

Script ini membuat dan menyalakan:

- `sita-DOMAIN-reverb.service`
- `sita-DOMAIN-queue.service`
- `sita-DOMAIN-schedule.timer`

Cek status:

```bash
systemctl list-units 'sita-*'
systemctl status sita-sita-kampus-ac-id-reverb.service
systemctl status sita-sita-kampus-ac-id-queue.service
systemctl status sita-sita-kampus-ac-id-schedule.timer
```

Jika memakai aaPanel Process Manager/Supervisor manual, gunakan command Reverb:

```bash
/www/server/php/84/bin/php /www/wwwroot/sita.kampus.ac.id/artisan reverb:start --host=127.0.0.1 --port=8080
```

Command queue:

```bash
/www/server/php/84/bin/php /www/wwwroot/sita.kampus.ac.id/artisan queue:work database --sleep=1 --tries=3 --timeout=90
```

Tambahkan cron scheduler Laravel agar fitur schedule masa depan langsung aktif:

```cron
* * * * * cd /www/wwwroot/sita.kampus.ac.id && /www/server/php/84/bin/php artisan schedule:run >> /dev/null 2>&1
```

## Deploy di Subpath

Subdomain tetap opsi paling aman. Jika kampus mewajibkan subpath seperti `https://domain-kampus.ac.id/admin`, isi:

```dotenv
APP_URL=https://domain-kampus.ac.id/admin
APP_BASE_PATH=admin
ASSET_URL=https://domain-kampus.ac.id/admin
SESSION_PATH=/admin
```

Lalu jalankan ulang:

```bash
DOMAIN=domain-kampus.ac.id bash deploy/aapanel-deploy.sh
```

Catatan: Nginx subpath Laravel butuh konfigurasi rewrite yang lebih teliti dibanding subdomain. Gunakan subdomain jika masih bisa dipilih.

## Troubleshooting

- 404 semua halaman: document root belum mengarah ke `public/` atau `try_files` Nginx belum benar.
- Blank page setelah deploy: cek `storage/logs/laravel.log`, lalu jalankan `php artisan optimize:clear`.
- Asset CSS/JS 404: pastikan `npm run build` sukses dan `public/build` ada. Untuk subpath, pastikan `ASSET_URL` sesuai `APP_URL`.
- Admin login tidak merespons dan console menampilkan `livewire.min.js 404`: tambahkan rule Nginx `/livewire` seperti bagian Nginx di atas, lalu reload Nginx.
- Chat terkirim tetapi harus refresh: Reverb belum aktif, service Reverb mati, atau Nginx belum punya proxy `location ~ ^/(app|apps)`.
- Chat 500 tetapi pesan muncul setelah refresh: Laravel gagal broadcast ke Reverb. Cek `.env` agar `REVERB_INTERNAL_HOST=127.0.0.1`, `REVERB_INTERNAL_PORT=8080`, dan `REVERB_INTERNAL_SCHEME=http`.
- Login/reset password email tidak terkirim: cek konfigurasi SMTP dan firewall kampus.
- Migration gagal: cek kredensial DB, permission user DB, dan extension `pdo_mysql`.
