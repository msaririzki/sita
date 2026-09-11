# Log Eksperimen Skripsi: Deployment SITA

> Status: catatan kerja. Dokumen ini tidak memuat password, API key, atau nilai `.env`.
> Fokus calon penelitian: validasi deployment dan integrasi SITA pada Docker dan aaPanel.

## Identitas Lingkungan

| Lingkungan | VM | IP LAN | Spesifikasi efektif saat dicatat | Peran |
|---|---:|---|---|---|
| Docker | `sita-docker` (901) | `192.168.1.31` | 2 vCPU, sekitar 1.8 GiB RAM, tanpa swap | Baseline container Compose |
| aaPanel | `sita-aapanel` (902) | `192.168.1.32` | 2 vCPU, sekitar 3 GiB RAM, swap 1 GiB | Baseline deployment aaPanel |

- Source awal kedua lingkungan: commit `76454fbca8016cc7961d21f19d0c7bfc27188cb6` pada branch `codex/fix-compose-reverb-build-env`.
- Source setelah pengembangan gate: commit `fe17275` pada branch `codex/aapanel-deployment-gate`.
- Remote fork kerja: `msaririzki/sita`; sumber upstream tetap `RikiSanjayaa/sita`.
- Snapshot Proxmox yang tersedia:
  - Kedua VM: `baseline-clean-ubuntu-2404`, `runtime-ready-20260910`.
  - Docker: `docker-baseline-deployed-20260910` setelah SITA lulus pengujian pascadeploy, lalu `docker-gate-validated-20260910` setelah integration gate otomatis lulus.
  - aaPanel: `aapanel-pre-stack-20260910` sebelum pemasangan runtime web, `aapanel-baseline-deployed-20260910` setelah HTTP, service, dan WebSocket handshake lulus, lalu `aapanel-gate-validated-20260910` setelah integration gate dan dua eksperimen gangguan dipulihkan.
- Catatan hypervisor: Proxmox memberi peringatan thin-pool mempunyai kapasitas logis teralokasi melebihi kapasitas fisik. Ini bukan kegagalan snapshot, tetapi kapasitas storage harus dipantau sebelum eksperimen menambah snapshot atau disk.

## Tujuan Pengamatan

Membuktikan bahwa deployment tidak cukup dinyatakan berhasil hanya karena script selesai. Sistem harus memverifikasi bahwa runtime, konfigurasi, layanan latar belakang, endpoint HTTP, dan koneksi realtime yang dipakai browser benar-benar selaras.

## Kronologi dan Bukti Awal

### E-01 - Build aset Reverb dapat salah walaupun Docker Compose berjalan

- **Kondisi:** `scripts/deploy-via-compose.sh` meneruskan `VITE_REVERB_*` sebagai build argument dari environment shell.
- **Masalah:** shell pemanggil tidak otomatis memuat `.env`. Nilai kosong lalu menimpa substitusi `.env` Compose sehingga bundle frontend berisiko tidak memiliki konfigurasi Reverb yang benar.
- **Perbaikan:** hapus penerusan build argument manual; Compose membangun image dengan nilai dari `.env`.
- **Bukti setelah perbaikan:** build Vite selesai, layanan Reverb membuka port `8089`, dan satu aset di `public/build` terbukti memuat host Reverb lab.
- **Makna skripsi:** pemeriksaan `.env` backend saja tidak cukup; gate harus memeriksa artefak frontend hasil build.

### E-02 - RAM konfigurasi VM berbeda dengan RAM efektif ketika build

- **Kondisi:** VM Docker tampak memiliki maksimum 4 GiB RAM pada Proxmox, tetapi balloon memory awal `512 MiB` membuat guest hanya melihat sekitar `985 MiB`.
- **Dampak:** build Vite pernah tersendat dan koneksi SSH menjadi tidak responsif.
- **Perbaikan:** minimum balloon dinaikkan menjadi `2048 MiB`; guest kemudian memiliki sekitar `1.8 GiB` RAM dan build Vite selesai dalam sekitar 29 detik.
- **Makna skripsi:** gate perlu mencatat resource aktual guest, bukan hanya konfigurasi maksimum hypervisor.

### E-03 - Baseline Docker berhasil setelah pengujian pascadeploy

- **Layanan terverifikasi:** `web`, `app`, `db`, `queue`, `scheduler`, dan `reverb`.
- **Bukti:** endpoint `http://127.0.0.1:8088/up` berhasil, aplikasi sehat, dan port Reverb `8089` terbuka.
- **Keterbatasan saat ini:** pengujian browser dua akun untuk chat realtime belum dijalankan; itu menjadi skenario integrasi berikutnya.

### E-04 - Perintah instalasi CLI aaPanel tidak dapat dipakai sebagaimana dokumentasinya

- **Kondisi:** format `bt install/1/nginx/1.28` dicoba pada aaPanel.
- **Masalah:** CLI menampilkan `Unsupported command` lalu `Cancelled`. Hasil inspeksi source lokal menunjukkan pemeriksaan prefix membandingkan enam karakter `instal` dengan string `install`, sehingga cabang instalasi tidak pernah dijalankan.
- **Makna skripsi:** otomatisasi tidak boleh bergantung pada asumsi bahwa CLI control panel akan memberi sinyal sukses/gagal yang benar.

### E-05 - Installer aaPanel dapat mengembalikan status sukses palsu

- **Kondisi:** pemanggilan langsung installer dengan urutan parameter keliru meminta URL `.../install/install/...` yang menghasilkan HTTP 404.
- **Masalah:** script tetap mencetak pesan sukses dan mengembalikan exit code `0`.
- **Perbaikan:** urutan parameter dikoreksi berdasarkan source lokal menjadi `install_soft.sh 1 install nginx 1.28`.
- **Bukti akhir:** Nginx selesai dipasang dan layanan memulai dengan status `done`.
- **Makna skripsi:** exit code saja tidak cukup. Gate perlu memvalidasi file binary, proses layanan, konfigurasi, dan endpoint yang relevan.

### E-06 - Dependency aaPanel pada Ubuntu 24.04 tidak seluruhnya kompatibel

- **Kondisi:** pemasangan Nginx aaPanel menarik dependency build dari source.
- **Temuan:** beberapa nama paket lama tidak tersedia, termasuk `rcconf`, `libncurses5`, `zlibc`, `libpng3`, dan `libpng12-dev`.
- **Hasil:** installer melanjutkan proses dan akhirnya Nginx `1.28.3` aktif. Verifikasi `nginx -t` juga berhasil, tetapi log menunjukkan provisioning tidak bersih dan waktunya panjang karena kompilasi dependency seperti OpenSSL.
- **Makna skripsi:** gate perlu mengklasifikasikan error dependency, memeriksa hasil akhir yang nyata, dan menyimpan log agar diagnosis dapat diulang.

### E-07 - Pemasangan PHP 8.4 aaPanel sedang divalidasi

- **Kondisi:** pemasangan dimulai setelah Nginx terverifikasi aktif.
- **Temuan awal:** script meminta `icu-config`, yang tidak tersedia pada Ubuntu 24.04, kemudian mengambil paket kompatibilitas ICU dan OpenSSL dari repository aaPanel.
- **Hasil:** PHP `8.4.24` terpasang. Extension Laravel yang diverifikasi aktif: `bcmath`, `intl`, `mbstring`, `pcntl`, `pdo_mysql`, dan `zip`.
- **Runtime:** PHP-FPM aktif sebagai `php-fpm-84` dan memakai socket `/tmp/php-cgi-84.sock`.
- **Makna skripsi:** template Nginx yang masih memakai `/tmp/php-cgi-82.sock` memang tidak sesuai dengan runtime hasil instalasi; pemeriksaan socket perlu menjadi gate wajib.

### E-08 - Konfigurasi PHP hasil installer memuat ZIP dua kali

- **Kondisi:** saat PHP-FPM pertama dijalankan, log menampilkan peringatan `Module "zip" is already loaded`.
- **Penyebab:** terdapat dua directive `extension = zip.so` di `php.ini`.
- **Perbaikan:** konfigurasi asli disalin ke `php.ini.bak-lab-20260910`, directive duplikat dihapus, lalu PHP-FPM direstart.
- **Bukti:** PHP-FPM tetap aktif, `zip` tetap ada pada daftar modul, dan `php -v` tidak lagi menampilkan peringatan.
- **Makna skripsi:** gate runtime harus menangkap konfigurasi modul ganda walaupun layanan masih dapat menyala.

### E-09 - Pemasangan MySQL 8.0 aaPanel sedang dijalankan

- **Kondisi:** runtime web dan PHP-FPM telah lulus pemeriksaan dasar.
- **Pengamanan pencatatan:** log installer disimpan di VM dan hanya status hasil serta pemeriksaan service yang akan dimasukkan ke catatan; password database tidak ditulis di dokumen maupun output kerja.
- **Hasil:** MySQL `8.0.45` terpasang dan service `mysqld` aktif.
- **Runtime:** MySQL membuka port `3306` dengan socket `/tmp/mysql.sock`; konsumsi awal service sekitar `396 MiB`.
- **Status lanjutan:** koneksi Laravel akan divalidasi setelah database dan `.env` lab dibuat.

### E-10 - Node.js untuk build asset aaPanel

- **Kondisi:** aaPanel tidak memasang Node.js secara otomatis bersama Nginx/PHP.
- **Tindakan:** Node.js dipasang dari repository NodeSource resmi setelah script setup diunduh dan diperiksa.
- **Hasil:** `node v22.23.2` dan `npm 10.9.8` tersedia; versi ini memenuhi requirement build Vite 7.
- **Makna skripsi:** pemeriksaan runtime frontend harus termasuk dalam precheck aaPanel, walaupun Node tidak menjadi proses aplikasi production.

### E-11 - Precheck menemukan fileinfo tidak ada pada PHP aaPanel

- **Kondisi:** `aapanel-doctor.sh` gagal pada pemeriksaan extension `fileinfo`.
- **Verifikasi:** daftar modul PHP dan pemeriksaan fungsi mengonfirmasi `fileinfo` memang belum tersedia, bukan kesalahan pelaporan doctor.
- **Perbaikan:** extension dibangun dari source PHP resmi dengan versi yang sama, `8.4.24`, memakai satu proses kompilasi agar sesuai kapasitas VM. Konfigurasi PHP-FPM dan PHP CLI dibackup sebelum extension diaktifkan.
- **Bukti:** modul `fileinfo` aktif dan fungsi `finfo_open` tersedia setelah PHP-FPM direstart. Log kompilasi disimpan di VM pada `/var/log/sita-fileinfo-build-8.4.24.log`.
- **Makna skripsi:** validasi harus memeriksa extension yang benar-benar aktif, bukan hanya versi PHP atau status pemasangan aaPanel.

### E-12 - Composer bawaan aaPanel tidak cocok dengan lock file SITA

- **Kondisi:** deployment berhenti sebelum dependency PHP dipasang.
- **Penyebab:** Composer bawaan aaPanel menyediakan `composer-runtime-api 2.0`, sedangkan Laravel `12.53.0` dan `laravel/prompts` pada `composer.lock` mensyaratkan `^2.2`.
- **Perbaikan:** installer Composer resmi diunduh dengan pemeriksaan SHA-384 terhadap signature yang dipublikasikan Composer, lalu Composer `2.10.3` dipasang sebagai `/usr/local/bin/composer2`. Composer bawaan aaPanel tidak diubah.
- **Makna skripsi:** gate perlu memeriksa kompatibilitas Composer platform requirement, bukan sekadar keberadaan executable `composer`.

### E-13 - Restart PHP-FPM dapat gagal meskipun konfigurasi dan proses lama masih berjalan

- **Kondisi:** setelah build aset, migrasi database, dan cache produksi berhasil, deployment menjalankan `systemctl restart php-fpm-84`.
- **Masalah:** restart gagal karena proses PHP-FPM lama masih mendengarkan socket `/tmp/php-cgi-84.sock`; systemd kemudian menandai layanan gagal walaupun worker lama masih melayani socket tersebut.
- **Verifikasi:** `php-fpm configtest` berhasil. Setelah proses lama dihentikan melalui init script lalu layanan dimulai ulang melalui systemd, `php-fpm-84` menjadi `active (running)` dan master process tercatat dalam cgroup systemd.
- **Makna skripsi:** pemeriksaan pascadeployment tidak cukup berhenti pada exit code restart. Gate harus memastikan status service dikelola systemd, socket hanya dimiliki satu master process, dan request PHP benar-benar dapat diproses.

### E-14 - Template virtual host tidak dapat mengasumsikan nama domain sama dengan folder proyek

- **Kondisi:** template Nginx mengganti `DOMAIN` menjadi alamat Tailscale lab `100.118.75.14`.
- **Masalah:** penggantian itu juga membentuk `root /www/wwwroot/100.118.75.14/public`, padahal checkout proyek berada di `/www/wwwroot/sita`. Nginx lulus `nginx -t`, server block cocok, tetapi semua request menghasilkan `404` dari Nginx.
- **Perbaikan:** root virtual host diarahkan secara eksplisit ke `/www/wwwroot/sita/public`; socket PHP-FPM juga disesuaikan ke `/tmp/php-cgi-84.sock`.
- **Makna skripsi:** gate konfigurasi perlu menerima parameter `PROJECT_ROOT` yang terpisah dari `DOMAIN`, lalu memeriksa keberadaan `public/index.php` dan menjalankan request HTTP nyata. Lolos sintaks Nginx bukan bukti aplikasi dapat dijangkau.

### E-15 - Permission Laravel gagal ketika group deploy berbeda dengan user PHP-FPM

- **Kondisi:** build, migrasi, cache produksi, dan service sudah berhasil; endpoint `/up` kemudian merespons `500`.
- **Penyebab:** PHP-FPM aaPanel berjalan sebagai `www`, sedangkan `storage` dan `bootstrap/cache` bergroup `ServerDeploy`. Perintah deployment hanya menjalankan `chmod -R ug+rw`, sehingga user `www` tetap tidak dapat menulis log/cache.
- **Perbaikan:** ownership diubah menjadi `ServerDeploy:www` dan permission `ug+rwX` diterapkan pada kedua direktori.
- **Bukti:** user `www` dapat membuat file uji pada `storage/logs`; endpoint `/up` dan root aplikasi sama-sama merespons `200`.
- **Makna skripsi:** gate harus memverifikasi tulis-baca memakai user runtime PHP-FPM, bukan hanya memeriksa mode permission dari akun deployment.

### Verifikasi deployment aaPanel setelah perbaikan

- Commit yang dideploy: `76454fb` pada branch `codex/fix-compose-reverb-build-env`.
- HTTP health endpoint: `200`.
- PHP-FPM: `active` dan socket `/tmp/php-cgi-84.sock` aktif.
- Reverb, queue worker, dan scheduler timer: masing-masing `active` sebagai service systemd.
- Reverb hanya mendengarkan `127.0.0.1:8080`; Nginx melakukan proxy dari port HTTP.
- Uji WebSocket upgrade melalui Nginx mengembalikan HTTP `101`. Client curl kemudian timeout karena koneksi WebSocket sengaja tetap terbuka; ini mengonfirmasi handshake, bukan kegagalan.
- Sedikitnya satu berkas bundle frontend produksi memuat alamat host Reverb lingkungan aaPanel.

### E-16 - Integration gate pascadeploy berhasil diterapkan

- **Implementasi:** branch `codex/aapanel-deployment-gate` menambahkan `deploy/aapanel-integration-gate.sh`, perbaikan permission group PHP-FPM pada deploy, pemeriksaan Composer runtime API di doctor, serta placeholder `PROJECT_ROOT` yang terpisah dari `DOMAIN` pada template Nginx.
- **Pemeriksaan gate:** tulis-baca sebagai user PHP-FPM, HTTP `/up`, status PHP-FPM/Reverb/queue/scheduler, host Reverb pada bundle Vite, dan WebSocket upgrade melalui Nginx.
- **Verifikasi:** deployment penuh dengan `RUN_INTEGRATION_GATE=true` berhasil dari build hingga gate pada commit `00246f0`.
- **Makna skripsi:** artefak penelitian kini bukan sekadar script deploy; ia memberi keputusan eksplisit lulus/gagal berdasarkan integrasi komponen yang pernah gagal di lingkungan aaPanel.

### E-17 - Gangguan Reverb terkontrol berhasil dideteksi dan dipulihkan

- **Gangguan:** service Reverb dihentikan sementara.
- **Hasil gate:** gagal dengan dua bukti independen: service Reverb tidak aktif dan WebSocket upgrade melalui Nginx mengembalikan HTTP `502`.
- **Waktu deteksi:** sekitar `331 ms` untuk satu eksekusi gate pada kondisi lab ini.
- **Pemulihan:** service dinyalakan kembali; gate berikutnya lulus penuh termasuk WebSocket upgrade `101`.
- **Makna skripsi:** skenario ini secara langsung merepresentasikan keluhan chat yang tidak diperbarui sampai refresh, tanpa mengambil ruang penelitian skalabilitas Reverb/Redis milik anggota tim lain.

### E-18 - Gangguan permission PHP-FPM terkontrol berhasil dideteksi

- **Gangguan:** group `storage` dan `bootstrap/cache` sementara diganti dari `www` ke group akun deployment.
- **Hasil gate:** gagal karena user PHP-FPM `www` tidak dapat menulis pada kedua direktori, sedangkan health HTTP dan seluruh service masih tampak aktif.
- **Waktu deteksi:** sekitar `5.329 ms` karena gate tetap menyelesaikan pengecekan HTTP dan WebSocket.
- **Pemulihan:** group dikembalikan menjadi `www` dengan mode `ug+rwX`; akses tulis user runtime diverifikasi kembali.
- **Makna skripsi:** skenario ini menunjukkan nilai gate dibanding health check tunggal, karena aplikasi dapat terlihat `200` padahal operasi yang membutuhkan cache/log/upload akan gagal.

### E-19 - Docker web tidak menyajikan storage runtime sebelum perbaikan

- **Kondisi:** pada baseline Docker, Laravel `app` dapat menulis volume `storage`, tetapi container Nginx `web` tidak memiliki symlink `public/storage` maupun mount volume storage.
- **Risiko terdeteksi:** file public baru seperti avatar dapat tersimpan oleh aplikasi tetapi tidak tersedia melalui URL `/storage/...`, sementara HTTP `/up` tetap sehat.
- **Perbaikan:** image `web` kini membuat symlink ke `storage/app/public`, dan Compose memasang volume storage sebagai read-only pada Nginx.
- **Bukti:** Docker integration gate mengonfirmasi symlink dan target storage tersedia dari container web.

### E-20 - Healthcheck sukses dapat melewati gate bila kontrol alur salah

- **Kondisi:** implementasi awal `RUN_INTEGRATION_GATE=true` pada skrip Docker ditempatkan setelah blok healthcheck.
- **Masalah:** healthcheck sukses memanggil `exit 0`, sehingga baris gate setelahnya tidak pernah dieksekusi.
- **Perbaikan:** alur diganti memakai status `healthcheck_passed`; setelah healthcheck lulus, eksekusi meneruskan ke integration gate dan hanya gagal bila seluruh percobaan benar-benar habis.
- **Makna skripsi:** validasi harus menguji bahwa mekanisme benar-benar dijalankan, bukan hanya bahwa kode pemeriksa tersedia di repository.

### E-21 - Docker integration gate lulus pada alur deployment otomatis

- **Pemeriksaan:** status enam container (`db`, `app`, `web`, `queue`, `scheduler`, `reverb`), health database dan app, akses tulis storage Laravel, HTTP `/up`, storage publik Nginx, bundle Reverb, dan WebSocket upgrade.
- **Hasil:** seluruh pemeriksaan lulus setelah `RUN_INTEGRATION_GATE=true` dipanggil melalui `scripts/deploy-via-compose.sh`.
- **Kesetaraan:** kriteria inti kini sama dengan aaPanel: readiness HTTP, runtime/background service, artefak bundle, akses berkas publik, dan konektivitas realtime. Perbedaan database dan cara pengelolaan proses tetap dicatat sebagai karakteristik lingkungan, bukan sebagai uji performa panel versus container.

### E-22 - Gangguan Reverb Docker terkontrol berhasil dideteksi dan dipulihkan

- **Gangguan:** container Reverb Docker dihentikan sementara.
- **Hasil gate:** container Reverb tidak ditemukan sebagai container aktif dan uji WebSocket gagal dengan HTTP `000` serta curl exit `7`; HTTP aplikasi tetap `200`.
- **Waktu deteksi:** sekitar `1.598 ms` pada kondisi lab ini.
- **Pemulihan:** Compose menyalakan kembali Reverb; gate berikutnya lulus penuh termasuk WebSocket upgrade `101`.
- **Makna skripsi:** pada Docker maupun aaPanel, health HTTP tunggal tidak cukup untuk menangkap gangguan realtime. Hasil ini dapat dibandingkan dengan X-01 tanpa menyimpulkan kedua lingkungan mempunyai performa yang sama.

### E-23 - Aturan proteksi Nginx aaPanel memblokir public storage Laravel

- **Kondisi:** gate membuat marker melalui user PHP-FPM pada `storage/app/public`, lalu mengaksesnya melalui `/storage/...`.
- **Masalah:** request mendapat HTTP `403`. Penyebabnya adalah aturan Nginx yang menolak direktori internal memasukkan `storage` tanpa membedakan `public/storage` yang memang merupakan jalur publik Laravel.
- **Perbaikan:** template Nginx menambahkan `location ^~ /storage/` dengan `try_files`, ditempatkan sebelum aturan deny direktori internal. Konfigurasi lab dibackup, dirender ulang memakai `PROJECT_ROOT`, diuji dengan `nginx -t`, lalu direload.
- **Bukti:** marker yang dibuat user runtime berhasil dikembalikan Nginx; integration gate aaPanel lulus penuh setelah perbaikan.
- **Makna skripsi:** hardening konfigurasi tidak boleh mengorbankan jalur file publik aplikasi. Pemeriksaan end-to-end storage menangkap konflik yang tidak terdeteksi oleh syntax test maupun HTTP `/up`.

### E-24 - Gangguan proxy WebSocket Nginx terkontrol berhasil dideteksi

- **Gangguan:** aturan sementara `location ^~ /app/ { return 404; }` dipasang untuk menimpa proxy Reverb, kemudian Nginx diuji dan direload.
- **Hasil gate:** seluruh service, HTTP health, storage, dan bundle frontend tetap lulus, tetapi WebSocket upgrade gagal dengan HTTP `404`.
- **Waktu deteksi:** sekitar `525 ms`.
- **Pemulihan:** konfigurasi asli dipulihkan dari backup, Nginx diuji dan direload. Gate berikutnya kembali lulus dengan WebSocket `101`.
- **Makna skripsi:** ini adalah rekonstruksi gangguan konfigurasi yang sejalan dengan chat yang membutuhkan refresh; gate membedakan kegagalan proxy dari kegagalan service Reverb.

## Kandidat Skenario Pengujian Berikutnya

| ID | Gangguan atau kondisi | Pemeriksaan yang diharapkan | Metrik |
|---|---|---|---|
| T-01 | `VITE_REVERB_HOST` kosong atau salah ketika build | inspeksi bundle frontend harus gagal | deteksi, false negative |
| T-02 | Reverb berhenti | health proses dan uji websocket harus gagal | waktu deteksi |
| T-03 | Nginx tidak mem-proxy `/app` dan `/apps` | uji handshake WebSocket harus gagal | deteksi konfigurasi |
| T-04 | Socket PHP-FPM di template tidak sesuai versi terpasang | `nginx -t` dan request PHP harus gagal | deteksi konfigurasi |
| T-05 | RAM efektif di bawah ambang build | precheck resource memberi peringatan sebelum build | kegagalan yang dicegah |
| T-06 | CLI aaPanel atau installer memberi sukses palsu | validasi binary, service, dan endpoint tetap menggagalkan gate | false positive deployment |
| T-07 | Chat dua pengguna | pesan harus muncul tanpa refresh | keberhasilan integrasi realtime |
| T-08 | PHP-FPM lama masih memiliki socket ketika restart | status systemd, kepemilikan socket, dan request PHP harus divalidasi | false positive deployment, waktu pemulihan |
| T-09 | `DOMAIN` dan folder proyek berbeda | root virtual host, `public/index.php`, dan HTTP health request harus divalidasi | deteksi konfigurasi |
| T-10 | User PHP-FPM tidak dapat menulis storage/cache | tulis-baca dijalankan sebagai user runtime | deteksi permission, false positive deployment |
| T-11 | Nginx Docker tidak mempunyai akses public storage | symlink dan volume read-only pada container web | deteksi akses berkas public |
| T-12 | Nginx aaPanel memblokir `/storage/*` | marker dibuat runtime lalu diambil melalui HTTP | deteksi konflik hardening dan fungsi file publik |

## Hasil Eksperimen Terkendali Awal

| ID | Gangguan | Hasil baseline/gate | Waktu deteksi | Pemulihan |
|---|---|---|---:|---|
| X-01 | Reverb dihentikan | Gate gagal: service inactive dan WebSocket `502` | 331 ms | Reverb dinyalakan; gate lulus `101` |
| X-02 | Group runtime storage/cache salah | Gate gagal: user `www` tidak bisa menulis, meski HTTP `200` | 5.329 ms | Group kembali `www`, tulis-baca terverifikasi |
| X-03 | Reverb Docker dihentikan | Gate gagal: container tidak aktif dan WebSocket `000` | 1.598 ms | Compose menyalakan kembali Reverb; gate lulus `101` |
| X-04 | Proxy WebSocket aaPanel ditimpa `return 404` | Gate gagal: WebSocket `404`, pemeriksaan lain lulus | 525 ms | Konfigurasi asli direload; gate lulus `101` |

## Data yang Harus Dicatat pada Setiap Percobaan

1. ID eksperimen, tanggal, commit, dan branch.
2. Lingkungan, versi OS, versi runtime, RAM efektif, dan ruang disk.
3. Konfigurasi atau gangguan yang disengaja, tanpa menyimpan secret.
4. Hasil setiap pemeriksaan dan log ringkas kegagalan.
5. Waktu mulai, waktu selesai, waktu deteksi, serta intervensi manual.
6. Status akhir layanan: HTTP, database, PHP-FPM, queue, scheduler, Reverb, dan chat browser.

### E-25 - Validasi browser dua pengguna membedakan koneksi dari subscription

- **Tujuan:** memeriksa gejala paling dekat dengan kasus historis: pesan tersimpan, tetapi penerima baru melihatnya setelah refresh.
- **Penyempurnaan uji:** skenario browser membuka ruang bimbingan mahasiswa dan dosen pada dua konteks terpisah. Sebelum mengirim pesan, uji menunggu koneksi Echo berstatus `connected` dan seluruh kanal `private-mentorship.thread.*` yang dirender telah `subscribed`. Dengan demikian pesan tidak dikirim ketika otorisasi kanal masih berlangsung.
- **Temuan awal:** pemeriksaan yang hanya menunggu `connected` menghasilkan kegagalan semu pada aaPanel; subscription privat belum selalu siap. Hal ini membuktikan HTTP `200` dan WebSocket handshake `101` belum cukup untuk menyatakan fungsi chat siap.
- **Hasil akhir:** pesan baru terlihat pada penerima tanpa navigasi atau refresh di Docker (`12,1 s` total eksekusi) dan aaPanel (`10,7 s` total eksekusi). Waktu tersebut adalah durasi keseluruhan skenario browser, bukan latensi pesan dan tidak boleh dipakai sebagai klaim performa.
- **Kondisi lab:** aaPanel sebelumnya belum memiliki data uji; `db:seed --force` dijalankan pada VM lab agar akun mahasiswa, dosen, dan thread bimbingan tersedia. Tidak ada server kampus produksi yang diubah.
- **Perbaikan regresi E2E:** judul halaman dosen dan placeholder pencarian berubah menjadi `Pesan Dosen` dan `Cari grup...`; selektor E2E dibuat kompatibel terhadap bentuk lama maupun baru. Skenario chat lama juga diperketat supaya tidak me-refresh atau menavigasi ulang halaman penerima sebelum memeriksa pesan.
- **Makna skripsi:** gate deployment perlu tingkat bertahap: service aktif -> upgrade WebSocket -> koneksi browser -> subscription kanal privat -> pertukaran pesan dua pengguna. Tingkat terakhir memberikan bukti fungsi yang tidak dapat digantikan oleh pengecekan port atau health endpoint.

### E-26 - Preflight dan pemeriksaan service rutin dipisahkan

- **Masalah rancangan:** pemasangan unit service aaPanel adalah kebutuhan instalasi awal, sedangkan pemeriksaan status PHP-FPM, Reverb, queue, dan scheduler diperlukan pada setiap pembaruan. Ketika keduanya memakai satu parameter, update rutin berisiko melewati pemeriksaan service.
- **Perbaikan:** `INSTALL_SERVICES` tetap khusus pemasangan atau perubahan unit systemd. Parameter baru `CHECK_SERVICES` bernilai `true` secara default untuk Integration Gate. Security Gate juga dapat dipanggil sebagai `RUN_SECURITY_PREFLIGHT=true` sebelum langkah perubahan deployment dan sebagai `RUN_SECURITY_GATE=true` setelah aplikasi aktif.
- **Validasi lab pada commit `5a8b626`:** preflight aaPanel lulus tanpa kegagalan; Integration Gate aaPanel memverifikasi empat service aktif dan WebSocket `101`; Docker menjalankan preflight, deployment, Integration Gate, dan Security Gate tanpa kegagalan. Kedua endpoint lab menggunakan HTTP sehingga HSTS tercatat sebagai peringatan, bukan kegagalan.
- **Pengamanan data contoh:** nilai default `RUN_DB_SEED` pada template Docker diubah menjadi `false`. Seeder harus diaktifkan eksplisit pada VM lab yang database-nya kosong; tidak ada `db:seed`, `migrate:fresh`, atau penghapusan tabel pada deployment aaPanel rutin.

### E-27 - Sinkronisasi aman antara GUI aaPanel dan skrip deployment

- **Kasus:** vhost SITA pada awalnya dibuat langsung oleh skrip sehingga aplikasi dapat diakses, tetapi situs tidak muncul pada daftar **Website** aaPanel. Ketika situs didaftarkan lewat GUI, konfigurasi bawaan panel sempat memakai root direktori proyek, bukan `public`, dan menghasilkan 403/404 Laravel sampai konfigurasi yang benar dipulihkan.
- **Rancangan:** registrasi website, versi PHP, extension, database, SSL, log, dan monitoring tetap menjadi tanggung jawab GUI aaPanel. Repository menambahkan `deploy/aapanel-sync.sh` sebagai pemeriksaan baca-saja terhadap entri website aaPanel, vhost aktif, root Laravel, socket PHP-FPM, proxy Reverb, extension PHP, izin `.env`, direktori runtime, dan service. Skrip tidak menulis database internal aaPanel dan tidak menimpa konfigurasi SSL.
- **Perbaikan template:** `deploy/aapanel-nginx.conf` tidak lagi mengunci socket `php-cgi-82.sock`; operator harus mengisi `PHP_FPM_SOCKET` sesuai versi PHP, yaitu `/tmp/php-cgi-84.sock` pada VM lab. Ini mencegah vhost baru diam-diam memakai socket PHP yang salah.
- **Validasi lab pada commit `e12ebdf`:** pemeriksaan lulus pada situs `100.118.75.14` yang terdaftar di aaPanel, memakai root `/www/wwwroot/sita/public`, socket PHP 8.4, extension wajib aktif, izin `.env` `640`, dan tiga service aktif. Salinan vhost dengan root sengaja dibuat salah menghasilkan exit code `1` dan pesan kegagalan root, tanpa mengubah vhost aktif.
- **Keamanan multiwebsite:** pemeriksaan sinkronisasi juga menghitung seluruh vhost yang memakai socket PHP-FPM SITA. Bila runtime dipakai bersama, instalasi atau penghapusan extension tidak boleh diautomasi karena extension serta reload berlaku pada seluruh situs yang memakai versi PHP tersebut. Pada VM lab socket `/tmp/php-cgi-84.sock` hanya ditemukan pada vhost SITA.
- **Makna skripsi:** otomatisasi yang aman tidak harus mengambil alih GUI panel. Nilai mekanisme ini terletak pada pendeteksian drift antara konfigurasi yang dikelola operator melalui aaPanel dan asumsi deployment aplikasi sebelum perubahan dinyatakan berhasil.

### E-28 - Runner rilis mendeteksi artefak runtime yang dimiliki root

- **Gangguan yang ditemukan saat validasi release satu-perintah:** build Composer dan Vite berhasil, tetapi normalisasi permission gagal pada sejumlah laporan eksperimen lama di `storage/` yang dibuat sebagai `root`. Deployment berjalan sebagai `ServerDeploy`, sehingga `chmod` tanpa privilese tidak dapat mengubah file tersebut.
- **Dampak terukur:** runner menghentikan fase deployment dan tidak menampilkan status rilis siap. Trap deployment mematikan maintenance mode; verifikasi segera setelah kegagalan menunjukkan root dan `/up` kembali HTTP `200`.
- **Perbaikan:** `prepare_runtime_permissions()` kini menjalankan `chgrp` dan `chmod` rekursif melalui `sudo` bila tersedia. Dengan demikian, seluruh storage dan cache dapat diseragamkan ke group PHP-FPM tanpa bergantung pada pemilik lama setiap berkas.
- **Makna skripsi:** pemeriksaan permission tidak cukup hanya menguji akses tulis PHP-FPM saat kondisi normal. Proses deployment juga harus tahan terhadap artefak administratif yang sebelumnya dibuat oleh root.

### E-29 - Restart queue normal sempat terbaca sebagai service tidak aktif

- **Gangguan yang ditemukan:** setelah `artisan queue:restart`, worker lama keluar sesuai sinyal restart. Systemd menjalankan worker baru sekitar tiga detik kemudian, tetapi Integration Gate memeriksa status hanya sekali dan langsung menolak release.
- **Bukti:** log systemd menunjukkan worker baru aktif setelah jeda restart; root aplikasi dan `/up` tetap HTTP `200`, Reverb, scheduler, storage publik, dan WebSocket juga lulus.
- **Perbaikan:** pemeriksaan service kini menunggu secara terbatas, default maksimal sepuluh kali dengan interval satu detik. Service baru dinyatakan gagal bila tetap tidak aktif setelah seluruh percobaan. Batas waktu ini menghindari false positive tanpa menyembunyikan kegagalan yang menetap.
- **Makna skripsi:** validasi pascadeploy perlu membedakan transisi service yang diharapkan dari kegagalan runtime. Metrik evaluasi harus mencatat waktu readiness service, bukan hanya status pada satu titik waktu.

### E-30 - Validasi akhir runner rilis satu-perintah

- **Eksekusi:** `bash deploy/aapanel-release.sh release` dijalankan dari VM aaPanel menggunakan profile lokal tanpa rahasia. Nilai `RUN_MIGRATIONS=false`, sehingga validasi tidak mengubah struktur database.
- **Urutan lulus:** sinkronisasi GUI/runtime, doctor, update source, Composer sementara terverifikasi, `npm ci`, build Vite, cache Laravel, restart runtime, healthcheck, Integration Gate, sinkronisasi pascadeploy, dan Security Gate.
- **Hasil akhir:** semua pemeriksaan integrasi lulus, termasuk PHP-FPM, Reverb, queue setelah readiness wait, scheduler, storage publik, dan WebSocket upgrade. Security Gate menghasilkan nol kegagalan dan satu peringatan HSTS karena endpoint lab masih HTTP. Halaman utama, login, dan `/up` dikonfirmasi HTTP `200` setelah release.
- **Artefak:** runner menyimpan transcript bertimestamp di `storage/logs/deployment/`; profile server dipisahkan dari repository dan tidak berisi rahasia aplikasi.

### E-31 - Konsol terminal interaktif untuk operator aaPanel

- **Rancangan:** `deploy/sita.sh` menjadi satu perintah yang mudah diingat. Konsol menyediakan pembuatan profile lokal tanpa secret, deploy awal server baru, check, release rutin, dan pembacaan log terakhir. Implementasi deployment tetap dipisah dalam skrip fokus agar dapat diaudit dan diuji.
- **Portabilitas path:** root proyek dihitung dari lokasi `deploy/sita.sh`, bukan dipasang tetap pada `/www/wwwroot/sita`. Profile menyimpan `APP_DIR` yang harus sama dengan lokasi clone, sehingga instalasi seperti `/www/wwwroot/webkampus/sita` tetap memakai path yang benar untuk service, log, vhost, dan deployment.
- **Validasi lab pada commit `8b4e2ef`:** mode noninteraktif `bash deploy/sita.sh check` lulus. Menu interaktif menampilkan tindakan operator dan membaca profile lab tanpa mengekspos `.env` atau kredensial database.
- **Makna skripsi:** usability bukan hanya tampilan aplikasi. Konsol berfase, profile lokal, dan log bertimestamp mengurangi ketergantungan pada hafalan command tanpa menghilangkan keputusan eksplisit untuk migrasi database atau perubahan infrastruktur.

### E-32 - Panduan berfase tersedia di dalam konsol terminal

- **Masalah penggunaan:** operator aaPanel yang baru pertama kali memakai otomasi perlu mengetahui batas antara konfigurasi yang tetap dilakukan melalui GUI panel dan tahap yang dapat dijalankan oleh skrip. Tanpa panduan, deploy awal server dapat disalahartikan sebagai pemasangan seluruh infrastruktur dari nol.
- **Perbaikan:** menu `Panduan dan alur penggunaan` ditambahkan ke `deploy/sita.sh`. Panduan menjelaskan prasyarat GUI aaPanel, penyusunan kode dan `.env`, urutan profile -> check -> deploy awal -> release, fungsi setiap menu, pengamanan migration serta extension PHP, dan lokasi log eksperimen.
- **Umpan balik status:** halaman awal konsol menampilkan status profile lokal, keberadaan `.env`, dan repository untuk membantu operator mengenali kesiapan dasar tanpa membaca secret.
- **Validasi lab pada commit `edb6039`:** syntax Bash lulus dan menu panduan diuji melalui sesi noninteraktif. Tampilan warna dipakai hanya ketika terminal mendukung TTY; output tetap terbaca pada terminal tanpa warna atau saat dicatat ke log.
- **Makna skripsi:** desain interaksi terminal dapat menjadi bagian dari artefak rancang bangun. Konsol menjembatani pengelolaan GUI aaPanel dan gate berbasis CLI, sambil mempertahankan langkah yang perlu keputusan operator.

### E-33 - Konsol kembali ke menu setelah pemeriksaan berhasil

- **Masalah penggunaan:** implementasi awal menjalankan runner dengan `exec`. Setelah menu `Check` selesai, proses konsol berakhir dan operator harus menjalankan `bash deploy/sita.sh` lagi untuk memilih `Release`.
- **Perbaikan:** runner sekarang dipanggil sebagai proses anak. Setelah aksi berhasil, konsol menampilkan langkah lanjutan yang sesuai dan kembali ke menu. Aksi `Check` mengarahkan operator ke `Release` untuk update rutin atau `Siapkan server baru` untuk server baru.
- **Validasi lab pada commit `d0f8811`:** siklus menu `Check` dijalankan pada VM aaPanel. Sinkronisasi GUI/runtime dan doctor lulus; konsol menampilkan status siap, arahan `Release`, lalu kembali memperlihatkan menu tanpa perlu menjalankan ulang perintah.
- **Makna skripsi:** temuan ini menunjukkan bahwa hasil pemeriksaan harus dihubungkan dengan keputusan operasi berikutnya. Konsol tidak hanya menghasilkan status teknis, tetapi menjaga alur deployment agar operator tidak kehilangan konteks.

### E-34 - Status operasi ringkas dan pemisahan file lokal aaPanel

- **Masalah penggunaan:** hasil gate lengkap tersimpan di log, tetapi operator tidak memiliki layar ringkas untuk melihat endpoint, service, dan hasil tindakan terakhir. Selain itu, `git status` pada VM membaca `.htaccess` serta `.user.ini` yang dibuat aaPanel sebagai perubahan lokal sehingga tampak seperti perubahan kode aplikasi.
- **Perbaikan:** menu `Status aplikasi dan runtime` membaca HTTP health endpoint, status PHP-FPM/Reverb/queue/scheduler, dan kesimpulan log deployment terbaru tanpa melakukan perubahan. Halaman awal juga menampilkan branch Git serta membedakan perubahan tracked, file lokal yang belum dikenal, dan dua file lokal standar aaPanel.
- **Validasi lab pada commit `fea4443`:** endpoint `/up` menghasilkan HTTP `200`; PHP-FPM, Reverb, queue, dan scheduler aktif. Dua file lokal aaPanel terdeteksi dan ditampilkan sebagai `HANYA FILE PANEL LOKAL`, bukan perubahan kode. File tersebut tidak dihapus atau diubah.
- **Makna skripsi:** observabilitas deployment tidak cukup dengan log panjang. Ringkasan status mempercepat keputusan operator, sementara klasifikasi perubahan lokal menghindari tindakan korektif yang salah terhadap konfigurasi panel.

### E-35 - Status siap dibedakan dari status tanpa peringatan

- **Masalah penggunaan:** hasil `PEMERIKSAAN DINYATAKAN SIAP` pada log dapat tetap memiliki peringatan nonblokir. Tanpa ringkasan peringatan, operator berisiko menganggap server tidak mempunyai catatan lanjutan.
- **Perbaikan:** menu status menghitung baris peringatan pada log tindakan terbaru dan menampilkannya secara eksplisit dengan arahan ke menu log lengkap.
- **Validasi lab pada commit `285b663`:** status VM menampilkan dua peringatan dari pemeriksaan terakhir: Composer global belum memenuhi runtime API sehingga runner memakai Composer sementara terverifikasi, dan port Reverb `80` sesuai lab HTTP tetapi perlu disesuaikan menjadi `443` saat reverse proxy HTTPS dipakai. Health endpoint dan seluruh service tetap aktif.
- **Makna skripsi:** hasil evaluasi perlu mengklasifikasikan gagal, lulus, dan lulus dengan peringatan. Klasifikasi ini membantu pengukuran false positive serta keputusan perbaikan tanpa mengubah peringatan menjadi kegagalan semu.

### E-36 - Istilah operasi disederhanakan untuk operator aaPanel

- **Masalah penggunaan:** istilah teknis `Bootstrap server baru` tidak langsung menjelaskan tindakan yang akan dilakukan kepada operator nonpengembang.
- **Perbaikan:** antarmuka konsol memakai istilah `Siapkan server baru (deploy awal)` dan hasilnya memakai `DEPLOY AWAL DINYATAKAN SIAP`. Nama perintah internal `bootstrap` tetap dipertahankan untuk kompatibilitas skrip noninteraktif.
- **Makna skripsi:** istilah antarmuka perlu menyatakan tujuan kerja pengguna, sedangkan detail implementasi dapat tetap berada pada lapisan teknis.

### E-37 - Konsol deployment lintas-environment tervalidasi

- **Rancangan:** `deploy/sita.sh` menjadi titik masuk utama yang meminta operator memilih Docker atau aaPanel. Konsol meneruskan tindakan ke modul environment yang terpisah: Docker memakai Compose, container, dan `docker-integration-gate.sh`; aaPanel memakai sinkronisasi GUI, PHP-FPM, serta service systemd. Perintah lama `bash deploy/sita.sh check` tetap diarahkan ke aaPanel.
- **Profile lokal:** Docker menggunakan `deploy/docker-profile.env` yang hanya memuat URL health/public, konfigurasi Nginx Docker, serta pilihan audit dependency. Profile ini diabaikan Git dan tidak menyimpan secret Laravel. aaPanel tetap memakai profile terpisah yang sudah ada.
- **Validasi Docker pada commit `d295357`:** profile Docker dibuat pada VM tanpa secret. Check lintas-environment lulus: konfigurasi Compose valid; enam container berjalan; db/app sehat; runtime storage, public storage, bundle Reverb, dan WebSocket `101` lulus; Security Gate menghasilkan nol kegagalan dan satu peringatan HSTS karena lab HTTP.
- **Validasi aaPanel pada commit `d295357`:** `bash deploy/sita.sh aapanel check` meneruskan aksi ke runner aaPanel dan lulus untuk sinkronisasi GUI/runtime serta doctor. Peringatan Composer sementara dan port Reverb HTTP tetap tercatat sebagai peringatan nonblokir lab.
- **Navigasi:** submenu dapat kembali ke pemilihan environment tanpa menutup konsol. Tidak ada release, perubahan container, vhost, database, atau server produksi selama validasi ini; Check hanya menjalankan pemeriksaan dan marker storage sementara yang dibersihkan oleh gate.
- **Makna skripsi:** artefak yang sama memberi alur operator konsisten di dua lingkungan tanpa menyamakan implementasi infrastrukturnya. Hal ini mendukung evaluasi DevSecOps yang membandingkan keputusan gate, waktu, dan intervensi manual secara fair pada Docker maupun aaPanel.

### E-38 - False positive extension PHP setelah Release aaPanel diperbaiki

- **Gejala:** Release aaPanel pada 11 September 2026 sempat berhenti pada validasi sinkronisasi pascadeploy dengan laporan `bcmath`, `dom`, `filter`, dan `openssl` tidak aktif. Pemeriksaan awal sebelum deploy sebelumnya menyatakan extension yang sama aktif.
- **Investigasi:** pembacaan langsung `/www/server/php/84/bin/php -m` menunjukkan seluruh extension benar-benar aktif. Lima kali `aapanel-sync.sh` berikutnya juga lulus. Endpoint `/up` tetap HTTP `200`, sementara PHP-FPM, Reverb, queue, dan scheduler tetap aktif. Jadi kejadian tersebut adalah false positive gate, bukan perubahan extension aaPanel.
- **Akar masalah:** `aapanel-sync.sh` dan sebagian pemeriksaan aaPanel memakai pipeline `php -m | grep -q` saat `pipefail` aktif. Untuk extension yang ditemukan lebih awal, `grep -q` dapat menutup pipe terlebih dahulu dan membuat proses `php -m` menerima SIGPIPE. Status pipeline lalu terbaca gagal meskipun extension tersedia.
- **Perbaikan:** daftar module PHP sekarang dibaca satu kali, dinormalisasi ke huruf kecil, lalu dicocokkan di memori tanpa pipeline `grep -q`. Pola yang sama diterapkan pada sync, doctor, dan validasi deployment agar keputusan sebelum dan sesudah deploy konsisten.
- **Validasi pada commit `3660fc9`:** Check aaPanel lulus dengan seluruh extension aktif. Release penuh pada VM lab kemudian lulus sampai pascadeploy: sinkronisasi, doctor, Composer sementara terverifikasi, build Vite, restart service, Integration Gate, Security Gate, serta endpoint `/up` HTTP `200`. Security Gate menghasilkan nol kegagalan dan satu peringatan HSTS karena lab masih HTTP.
- **Makna skripsi:** gate yang hanya memberi status gagal belum tentu benar. Pengukuran false positive dan verifikasi pascakegagalan memperkuat evaluasi mekanisme DevSecOps, karena otomatisasi yang baik harus mendeteksi gangguan nyata tanpa menolak release sehat.

### E-39 - Migration terdeteksi, dibackup, dan diterapkan melalui Release

- **Kasus uji terkontrol:** migration probe `2099_01_01_000000_sita_deploy_gate_probe` dibuat hanya di VM aaPanel. Migration tersebut membuat satu tabel probe agar jalur backup dan penerapan migration dapat diuji tanpa menyentuh tabel SITA.
- **Temuan awal:** lokasi backup `/www/backup/database/sita` tidak dapat dipakai akun `ServerDeploy`, walaupun direktori anak berhasil dibuat, karena induk `/www/backup` dan `/www/backup/database` memiliki mode `700` milik root. Release berhenti sebelum `php artisan migrate --force`; maintenance mode dipulihkan dan endpoint `/up` kembali HTTP `200`. Ini adalah kegagalan aman: tidak ada perubahan skema dari migration probe.
- **Perbaikan:** lokasi default diubah menjadi `/var/backups/sita`. Jika belum ada, skrip membuat direktori khusus ini melalui `sudo install` dengan mode `700` dan kepemilikan akun deploy. Dump dan checksum memiliki mode `600`. Kredensial dump ditempatkan sementara dalam defaults file dengan mode `600` lalu dibersihkan melalui trap pada setiap keluaran proses.
- **Validasi pada commit `988cc15`:** Release interaktif menampilkan migration tertunda; persetujuan `Y` memicu backup `sita-100-118-75-14-20260911T074852Z.sql.gz` dan checksum `.sha256` pada `/var/backups/sita`. Arsip berukuran 32.191 byte lulus `gzip -t` dan `sha256sum -c`. Migration probe selesai dalam 83,97 ms; healthcheck `200`, Integration Gate termasuk WebSocket, sinkronisasi pascadeploy, dan Security Gate lulus dengan nol kegagalan dan satu peringatan HSTS karena lab HTTP.
- **Pembersihan eksperimen:** Laravel production pada lab melarang `migrate:rollback`, sehingga tabel probe dan satu catatan migration yang namanya sudah diverifikasi dibersihkan secara terarah melalui Laravel database facade. Verifikasi akhir menunjukkan tabel dan catatan probe tidak ada, backup tetap valid, dan `/up` HTTP `200`.
- **Makna skripsi:** keputusan database menjadi terlihat dan dapat diaudit: daftar migration, persetujuan operator, artefak backup, checksum, hasil migration, serta log release. Kasus ini dapat diukur sebagai pencegahan deployment yang mengaktifkan kode baru ketika backup database tidak tersedia.

### E-40 - Atomic release dan rollback kode pada aaPanel

- **Rancangan:** control checkout tetap berada pada `/www/wwwroot/sita`. Candidate dibangun dari `git archive` di `.sita-release/releases/<waktu>-<commit>`, sehingga source aktif tidak memiliki direktori `.git`. File `.env` dan `storage` dipindahkan ke `.sita-release/shared`; Nginx, PHP-FPM, Reverb, queue, dan scheduler memakai symlink `.sita-release/current`.
- **Perubahan vhost terkendali:** pada aktivasi pertama, skrip menyimpan salinan vhost aaPanel di `/var/backups/sita/nginx/`, mengganti hanya root dari control checkout menjadi `current/public`, menjalankan `nginx -t`, lalu reload. SSL, domain, socket PHP-FPM, log, dan aturan lain tidak diubah.
- **Kegagalan dan rollback nyata:** aktivasi pertama gagal karena artefak storage lama milik root tidak dapat disalin oleh akun deploy. Aktivasi kedua berhasil sampai Integration Gate, tetapi gate menolak candidate karena user `www` belum dapat menelusuri folder release. Pada kedua kasus, symlink candidate dihapus, vhost awal dipulihkan, service diarahkan ke control checkout, dan `/up` kembali HTTP `200`. Temuan ini menghasilkan perbaikan penyalinan storage berprivilege terbatas dan permission traversal group runtime.
- **False positive tambahan:** Security Gate sempat membaca mode symlink `.env` sebagai `777`, padahal file target shared memiliki mode `640`. Pemeriksaan diperbaiki memakai `stat -L` agar menilai target; rollback otomatis kembali dijalankan sebelum candidate dinyatakan siap.
- **Validasi sukses pada commit `0ea0b5c`:** release `20260911T081139Z-0ea0b5c4c4df` aktif melalui symlink `current`. Candidate tidak memiliki migration tertunda; Integration Gate lulus untuk storage, healthcheck, PHP-FPM, Reverb, queue, scheduler, bundle frontend, dan WebSocket `101`. Sync pascadeploy juga lulus; Security Gate menghasilkan nol kegagalan dan satu peringatan HSTS karena lab HTTP. Endpoint `/up` menghasilkan HTTP `200` setelah release.
- **Batas keamanan database:** atomic rollback hanya diizinkan tanpa migration tertunda. Jika candidate membawa migration, release diblokir sebelum aktivasi karena pengembalian kode tidak otomatis membuat skema database lama aman. Migration tetap memakai migration gate, backup, checksum, dan tinjauan operator.
- **Makna skripsi:** eksperimen menunjukkan rollback bukan hanya perintah Git. Artefak rancang bangun mencakup build terisolasi, aktivasi atomik, shared runtime, validasi pascadeploy, dan pemulihan otomatis yang dibuktikan oleh kegagalan terkendali maupun kegagalan nyata pada lab.

### E-41 - Seluruh gate pascadeploy menjadi bagian transaksi atomic

- **Temuan:** implementasi awal menjalankan sinkronisasi aaPanel dan Security Gate kedua pada runner setelah atomic script selesai. Kegagalan di lapisan itu tidak lagi berada dalam trap rollback candidate.
- **Perbaikan:** integration gate, sinkronisasi aaPanel, dan Security Gate dipindahkan ke `verify_candidate()` sebelum atomic release ditandai selesai. Runner atomic kini hanya memiliki tiga fase: pre-sync, doctor, lalu atomic release beserta seluruh gate dan rollback.
- **Validasi pada commit `487c1d2`:** release `20260911T082956Z-487c1d231781` lulus seluruh gate internal, `/up` HTTP `200`, service aktif, WebSocket `101`, Security Gate nol kegagalan dengan satu peringatan HSTS HTTP. Release lama yang tidak lagi diperlukan dibersihkan setelah kandidat dinyatakan siap.
- **Makna skripsi:** batas transaksi deployment harus mencakup seluruh kondisi yang dipakai untuk menyatakan release siap. Jika tidak, mekanisme rollback hanya melindungi sebagian dari keputusan pascadeploy.

### E-42 - Audit penguatan atomic runner sebelum pengujian ulang

- **Temuan audit:** runtime `.sita-release/` sebelumnya terbaca sebagai file lokal tak dikenal oleh Git, sehingga status konsol dapat menimbulkan kesan ada perubahan source. Selain itu, runner belum memvalidasi nilai retensi release, bentuk domain, dan bentuk symlink aktif secara eksplisit. Jalur pembersihan release juga memisahkan timestamp dan path berdasarkan spasi.
- **Perbaikan:** runtime release diabaikan Git. Runner sekarang menolak domain tidak valid, nilai `RELEASE_KEEP` selain bilangan positif, serta `CURRENT_LINK` yang sudah ada tetapi bukan symlink. Pembersihan release memakai pemisah NUL agar tetap benar bila path memuat spasi. Jika `git pull` membawa perubahan pada skrip atomic atau gate yang dipakainya, runner melakukan re-exec satu kali dan melanjutkan dengan versi skrip terbaru sebelum candidate dibuat.
- **Artefak uji lama:** migration probe yang tersisa di control checkout diverifikasi berstatus `Pending`, sehingga belum mengubah skema database. File probe dapat dihapus secara terarah tanpa melakukan rollback atau mengubah tabel SITA. File lokal aaPanel `.htaccess` dan `.user.ini` dipertahankan.
- **Makna skripsi:** pengujian deployment tidak hanya memeriksa apakah aplikasi hidup. Audit juga perlu menilai ketahanan tooling terhadap konfigurasi operator dan artefak eksperimen agar status yang disajikan tidak menyesatkan.

### E-43 - Validasi regresi akhir pada Docker dan aaPanel

- **aaPanel:** release penuh pada commit `a1dc97a` membentuk candidate `20260911T084052Z-a1dc97abc97f`. Candidate lolos build Composer dan Vite, tidak memiliki migration tertunda, diaktifkan melalui symlink `current`, lalu melewati Integration Gate, synchronization check, dan Security Gate. Health endpoint menghasilkan HTTP `200`; PHP-FPM, Reverb, queue, dan scheduler aktif; Integration Gate mengonfirmasi WebSocket upgrade `101`.
- **Kondisi akhir aaPanel:** Nginx tetap menunjuk ke `current/public`, profile lokal memiliki mode `600`, tiga release tersimpan sesuai `RELEASE_KEEP=3`, dan migration probe sudah tidak ada. Status Git hanya menampilkan `.htaccess` serta `.user.ini` lokal aaPanel; runtime `.sita-release/` sudah tidak dilaporkan sebagai perubahan source.
- **Docker:** `bash deploy/sita.sh docker check` pada commit yang sama lulus untuk Compose, enam container, healthcheck, storage publik, bundle Reverb, dan WebSocket. Security Gate Docker menghasilkan nol kegagalan dan satu peringatan HSTS karena URL lab memakai HTTP.
- **Validasi statis:** seluruh skrip pada `deploy/` dan `scripts/` lulus `bash -n`; pemeriksaan `git diff --check` juga lulus. ShellCheck tidak tersedia pada workstation sehingga tidak dijadikan klaim hasil uji.
- **Makna skripsi:** hasil ini menjadi baseline stabil untuk eksperimen gangguan berikutnya. Reset VM tidak dilakukan karena baseline ini adalah bukti uji yang aktif; pengujian reset harus memakai snapshot atau VM bersih terpisah agar bukti dan konfigurasi pembanding tidak hilang.

## Catatan untuk Sinopsis

Kasus nyata yang sudah tersedia adalah chat SITA yang pernah menyimpan pesan tetapi pembaruan baru terlihat setelah refresh ketika perpindahan Docker ke aaPanel. Bukti E-01 sampai E-06 menunjukkan akar masalah deployment dapat muncul pada build frontend, runtime, resource VM, CLI panel, maupun reverse proxy. Karena itu objek rancang bangun yang tepat adalah gate validasi deployment berbasis pemeriksaan integrasi, bukan hanya script copy/build biasa.
