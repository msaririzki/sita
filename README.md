# SITA

SITA adalah aplikasi manajemen bimbingan tugas akhir berbasis Laravel + Inertia + React.
Aplikasi ini mendukung alur kerja berbasis peran untuk mahasiswa, dosen, dan admin,
termasuk chat real-time, pembaruan jadwal, dan notifikasi dalam aplikasi.

## Tumpukan Teknologi

- Backend: Laravel 12, PHP 8.4, Pest 4
- Frontend: Inertia v2, React 19, TypeScript, Tailwind CSS v4
- Real-time: Laravel Echo + Laravel Reverb
- Tooling: Vite, ESLint, Prettier, Pint

## Prasyarat

- PHP 8.4+
- Composer
- Node.js 20+ dan npm
- MySQL/PostgreSQL (sesuai konfigurasi di `.env`)

## Menjalankan Dengan Docker Compose (Production-like)

Stack Docker sudah disiapkan agar langsung jalan dengan sekali perintah, termasuk:

- `db` (PostgreSQL)
- `init` (migrate + cache optimize)
- `app` (PHP-FPM)
- `web` (Nginx)
- `queue` (queue worker)
- `scheduler` (Laravel scheduler)
- `reverb` (WebSocket server)

Jalankan:

```bash
cp .env.docker .env
# isi APP_KEY di .env, misalnya dari: php artisan key:generate --show
docker compose up --build -d
```

Layanan utama:

- App HTTP: `http://localhost:8088`
- Reverb WS: `ws://localhost:8089`

Catatan penting:

- Konfigurasi container memakai `.env`.
- File `.env.docker` tersedia sebagai referensi/contoh konfigurasi khusus Docker lokal. Salin ke `.env`, isi `APP_KEY`, lalu jalankan build.
- Nilai `VITE_REVERB_*` di `.env` ikut dipakai saat image build, jadi frontend tidak kehilangan app key Pusher/Reverb.
- Seeder bisa diaktifkan tanpa mengubah `APP_ENV`: set `RUN_DB_SEED=true` di `.env` (akan dijalankan saat service `init`).
- Default `SEED_IF_EMPTY_ONLY=true` agar `docker compose up --build -d` tidak gagal saat data sudah ada; set `false` kalau memang ingin memaksa re-seed.
- Jika seeder memakai Faker/factory dev dependency, biarkan `INIT_INSTALL_DEV_DEPENDENCIES=true` agar hanya service `init` yang install dev dependency; service runtime tetap lean.
- Untuk environment server/CI, override nilai sensitif (`APP_KEY`, password DB, dsb) lewat secret/variable pipeline.
- Saat pertama kali naik, service `init` akan otomatis menjalankan migrasi dan cache (`config:cache`, `route:cache`, `view:cache`).

Validasi pascadeploy Docker:

```bash
HEALTHCHECK_URL=http://127.0.0.1:8088/up bash scripts/docker-integration-gate.sh
```

Gate memeriksa container, health HTTP, akses storage Laravel dan Nginx, bundle Reverb, serta WebSocket handshake. Untuk menjalankannya otomatis di akhir `scripts/deploy-via-compose.sh`, tambahkan `RUN_INTEGRATION_GATE=true`.

Matikan stack:

```bash
docker compose down
```

Hapus volume data DB + storage:

```bash
docker compose down -v
```

## Mulai Cepat

1. Install dependensi

```bash
composer install
npm install
```

2. Buat file environment dan app key

```bash
cp .env.example .env
php artisan key:generate
```

3. Konfigurasi database dan env real-time di `.env`

```env
BROADCAST_CONNECTION=reverb

REVERB_APP_ID=local-app
REVERB_APP_KEY=local-key
REVERB_APP_SECRET=local-secret
REVERB_HOST=localhost
REVERB_PORT=8080
REVERB_SCHEME=http
REVERB_SERVER_HOST=0.0.0.0
REVERB_SERVER_PORT=8080

VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST="${REVERB_HOST}"
VITE_REVERB_PORT="${REVERB_PORT}"
VITE_REVERB_SCHEME="${REVERB_SCHEME}"
```

4. Jalankan migrasi

```bash
php artisan migrate
```

5. Jalankan layanan development

```bash
composer run dev
```

## Perintah Umum

- Menjalankan stack dev: `composer run dev`
- Build frontend: `npm run build`
- Lint/format PHP: `composer run lint` atau `vendor/bin/pint --dirty`
- Lint JS/TS: `npm run lint`
- Type check: `npm run types`
- Menjalankan semua test: `composer run test`
- Menjalankan test spesifik: `php artisan test --compact tests/Feature/...`
- Menjalankan E2E Playwright: `npm run e2e`
- Menjalankan E2E dengan browser terlihat: `npm run e2e:headed`
- Menjalankan Playwright runner UI: `npm run e2e:ui`
- Verifikasi CI lokal: `composer run ci:verify`

## E2E Playwright

Playwright dipakai untuk pengujian integrasi UI multi-role, terutama alur tugas akhir, chat bimbingan, sempro, dan sidang. Pest tetap dipakai untuk logika backend, seeder, service, dan assertion berbasis PHP.

### Prasyarat E2E

- Dependensi npm sudah terpasang melalui `npm install`
- Browser Playwright sudah terinstal melalui `npx playwright install`
- PHP, Composer, dan dependensi Laravel sudah siap

### Cara Kerja E2E

- Konfigurasi ada di `playwright.config.ts`
- Spec berada di `tests/e2e/specs/`
- Global setup akan menyiapkan environment Playwright sendiri, termasuk:
    - memakai database SQLite terpisah di `database/playwright.sqlite`
    - menyimpan auth state di `storage/playwright`
    - menjalankan `php artisan migrate:fresh --seed --force`
    - menangkap session login untuk admin, dosen, dan mahasiswa uji
- Web server E2E dijalankan otomatis dari Playwright lewat `npm run build` dan `php artisan serve --host=127.0.0.1 --port=9010`

### Menjalankan E2E

Jalankan seluruh spec aktif:

```bash
npm run e2e
```

Jalankan satu spec:

```bash
npx playwright test tests/e2e/specs/session-isolation.spec.ts
```

Lihat browser saat test berjalan:

```bash
npm run e2e:headed
```

Gunakan Playwright UI untuk memilih/rerun test secara interaktif:

```bash
npm run e2e:ui
```

### Artefak dan Debugging

- Screenshot, video, dan trace disimpan hanya saat test gagal
- Folder output lokal seperti `test-results/` dan `playwright-report/` diabaikan oleh git
- Untuk membuka trace kegagalan:

```bash
npx playwright show-trace test-results/<folder>/trace.zip
```

### Catatan Penting

- E2E bergantung pada seed data yang konsisten, khususnya `UserSeeder` dan `ThesisWorkflowSeeder`
- Jika menambah alur thesis baru, perbarui seed data dan spec Playwright yang relevan
- Beberapa spec dapat sengaja ditandai `test.fixme(...)` sampai flow UI tersebut benar-benar diimplementasikan atau distabilkan

## Git Hook (Verifikasi CI sebelum Push)

Install pre-push hook lokal sekali saja:

```bash
npm run hooks:install
```

Perintah ini memasang `.githooks/pre-push` ke `.git/hooks/pre-push`
dan menjalankan `composer run ci:verify` sebelum setiap push.

## Notifikasi

- Preferensi notifikasi dikelola di `Settings > Notifikasi`.
- Notifikasi dalam aplikasi disimpan di database dan ditampilkan di panel header.
- Notifikasi browser membutuhkan izin browser dan opsi `browserNotifications` aktif.

## Struktur Proyek

- `app/` - kode utama Laravel (controller, model, service, notification)
- `routes/` - route HTTP dan channel broadcast
- `database/` - migration, seeder, factory
- `resources/js/` - halaman/komponen/type Inertia React
- `tests/` - test Feature/Unit berbasis Pest

## Troubleshooting

- Layar blank dengan error `You must pass your app key when you instantiate Pusher.`
    - Pastikan `VITE_REVERB_APP_KEY` dan variabel `VITE_REVERB_*` sudah terisi.
    - Bersihkan cache konfigurasi: `php artisan config:clear`.
    - Jalankan ulang proses frontend: `npm run dev` atau `npm run build`.

- Perubahan frontend tidak muncul
    - Jalankan ulang Vite dengan `npm run dev`.

## CI/CD (GitHub Actions + Tailscale)

Workflow deploy ada di `.github/workflows/deploy.yml` dengan alur:

1. Trigger setelah workflow `tests` sukses di branch `main` (atau manual `workflow_dispatch`)
2. Verify (`composer install`, `npm ci`, `npm run build`, `php artisan test`, `npm run types`)
3. Build + push image ke GHCR (`app` dan `web`)
4. Join Tailscale dari GitHub Actions
5. SSH ke server private, pull image terbaru, jalankan `scripts/deploy-via-compose.sh`

### File deploy penting

- `docker-compose.deploy.yml`: override agar service pakai image dari registry (bukan build lokal)
- `scripts/deploy-via-compose.sh`: pull image, jalankan init (migrate/cache), restart service, healthcheck

### GitHub Secrets yang wajib

- `TS_OAUTH_CLIENT_ID`
- `TS_OAUTH_SECRET`
- `DEPLOY_HOST` (gunakan Tailscale IP `100.x.y.z` atau full MagicDNS hostname)
- `DEPLOY_USER`
- `DEPLOY_PATH` (path repo di server)
- `DEPLOY_SSH_PRIVATE_KEY`
- `GHCR_USERNAME`
- `GHCR_READ_TOKEN` (token read:packages untuk pull di server)
- `VITE_REVERB_APP_KEY`

### GitHub Variables yang disarankan

- `FRONTEND_REVERB_HOST` (default workflow: kosong, fallback ke domain halaman)
- `FRONTEND_REVERB_PORT` (default: `443`)
- `VITE_REVERB_SCHEME` (default: `https`)
- `DEPLOY_SSH_PORT` (default: `22`)
- `DEPLOY_HEALTHCHECK_URL` (contoh: `http://localhost:8088/up`)

### Bootstrap server (sekali saja)

Di server homeserver:

1. Clone repo ke `DEPLOY_PATH`
2. Siapkan `.env.docker` production values
3. Login GHCR sekali untuk validasi (`docker login ghcr.io`)
4. Pastikan Docker + Compose plugin aktif

Setelah itu deploy feature cukup push ke `main` (tanpa SSH manual).

Jika deploy gagal di langkah `ssh-keyscan` / `Trust deploy host`, biasanya `DEPLOY_HOST` tidak bisa di-resolve di runner. Solusi paling stabil adalah isi `DEPLOY_HOST` dengan Tailscale IP langsung.

Jika host sudah berupa IP Tailscale tapi masih gagal di `Trust deploy host`, cek bahwa SSH port sesuai (`DEPLOY_SSH_PORT`) dan bisa diakses dari tailnet (ACL + firewall + sshd).

Jika gagal di step Tailscale dengan `backend error: invalid key: unable to validate API key`, artinya kredensial OAuth salah format/salah nilai. `TS_OAUTH_CLIENT_ID` + `TS_OAUTH_SECRET` harus pasangan dari OAuth Client yang sama (bukan `tskey-auth-*` / `tskey-api-*`), berada di tailnet yang sama, punya scope `auth_keys` writable, dan diizinkan request tag `tag:ci`.

Catatan format terbaru: `TS_OAUTH_CLIENT_ID` dari halaman Trust Credentials bisa berupa ID pendek alfanumerik (tidak harus prefix `tskey-client-`).

Untuk Tailscale ACL, pastikan node CI (`tag:ci`) diizinkan akses ke server deploy port 22. Contoh ACL legacy:

```json
{
    "tagOwners": {
        "tag:ci": ["autogroup:admin"]
    },
    "acls": [
        {
            "action": "accept",
            "src": ["tag:ci"],
            "dst": ["100.101.102.103:22"]
        }
    ]
}
```

Ganti `100.101.102.103` dengan Tailscale IP server kamu.
