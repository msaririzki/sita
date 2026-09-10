# Catatan eksperimen Security Gate DevSecOps SITA

## Fokus skripsi

Judul kerja: **Implementasi Security Gate Berbasis DevSecOps untuk Meningkatkan Keamanan Deployment Sistem Informasi Tugas Akhir pada Lingkungan Docker dan aaPanel**.

Objek penelitian adalah pipeline deployment SITA yang telah dipakai tim. Docker dan aaPanel diperlakukan sebagai dua lingkungan uji yang setara, bukan sebagai dua aplikasi yang berbeda. Seluruh pengujian keamanan hanya dilakukan pada VM laboratorium privat, bukan pada `sita.ubg.ac.id`.

## Masalah dan baseline nyata

Sebelum Security Gate diterapkan, pemeriksaan HTTP pada kedua laboratorium menunjukkan bahwa `/.env`, `/.git/HEAD`, dan `/composer.lock` sudah tidak dapat diakses secara publik (masing-masing 403, 403, dan 404). Ini dicatat sebagai kontrol yang telah ada, bukan temuan baru.

Dua temuan baseline yang dapat direproduksi adalah:

1. `config/reverb.php` memakai `allowed_origins => ['*']`, sementara `REVERB_ALLOWED_ORIGINS` belum didefinisikan pada kedua lingkungan.
2. Respons HTTP belum memiliki `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, dan `Permissions-Policy`.

## Artefak implementasi

`scripts/security-gate.sh` dijalankan setelah deployment dan gagal bila kontrol wajib tidak terpenuhi. Pemeriksaannya mencakup:

- `APP_ENV=production`, `APP_DEBUG=false`, serta variabel Reverb wajib;
- origin Reverb eksplisit tanpa wildcard;
- permission `.env` tidak dapat diakses pengguna lain;
- pola rahasia server pada artefak frontend, termasuk artefak di container Docker;
- akses publik ke `/.env`, `/.git/HEAD`, dan `/composer.lock`;
- empat header keamanan HTTP;
- document root, deny dot-file, dan proxy Reverb Nginx;
- container non-root, tanpa `privileged: true`, dan database tanpa port host.

Gate dipanggil dengan `RUN_SECURITY_GATE=true` dari `scripts/deploy-via-compose.sh` dan `deploy/aapanel-deploy.sh`. Contoh parameter tidak memuat rahasia:

```bash
PUBLIC_BASE_URL=https://host-sita.example RUN_SECURITY_GATE=true \
bash scripts/deploy-via-compose.sh
```

## Lapisan audit dependency sebelum deployment

Security Gate dikembangkan menjadi dua tahap. Tahap sebelum deployment menjalankan `scripts/dependency-security-audit.sh`; tahap sesudah deployment menjalankan `scripts/security-gate.sh`. Audit dependency hanya memeriksa dependency production: `composer audit --locked --no-dev` untuk PHP dan `npm audit --omit=dev` untuk frontend. Audit tidak mengubah lockfile, memasang dependency, atau menjalankan `audit fix`.

aaPanel menjalankan audit dengan runtime host karena PHP, Composer, dan npm tersedia pada server panel. Host Docker laboratorium tidak membawa tool tersebut; mode `DEPENDENCY_AUDIT_RUNTIME=docker` menjalankan Composer dan npm dalam container sementara, dengan source project dipasang hanya-baca serta direktori laporan saja yang dapat ditulis. Perbedaan ini adalah bagian dari evaluasi portabilitas mekanisme, bukan alasan untuk melewati audit pada Docker.

Mode `report` menyimpan ringkasan JSON dan tidak menghentikan deployment. Mode `enforce` menghentikan deployment bila ditemukan advisory pada atau di atas ambang yang ditentukan. Pemisahan ini penting: temuan harus ditriase dan pembaruan versi harus diuji kompatibilitasnya sebelum dijadikan syarat blokir. Jalankan dengan:

```bash
RUN_DEPENDENCY_AUDIT=true \
DEPENDENCY_AUDIT_MODE=report \
DEPENDENCY_AUDIT_THRESHOLD=high \
bash scripts/deploy-via-compose.sh
```

Baseline lokal pada 10 September 2026 memakai ruang lingkup production. Pada eksekusi validasi terakhir, Composer melaporkan 53 advisory pada 17 paket dan npm melaporkan 14 advisory (2 critical, 8 high, 3 moderate, dan 1 low); 25 advisory berada pada ambang high atau critical. Basis data advisory dapat berubah, sehingga setiap eksekusi menyimpan ringkasan JSON bertimestamp dan hasil skripsi akan memakai snapshot yang dicantumkan pada bab pengujian. Temuan ini tidak langsung diklaim sebagai kerentanan yang dapat dieksploitasi pada SITA; setiap paket akan dikelompokkan menurut keterpaparan runtime, jalur pemanggilan aplikasi, ketersediaan versi perbaikan, serta hasil regresi setelah pembaruan.

Pada aaPanel, bila konfigurasi vhost dibaca oleh root, jalankan gate lewat sudo dan berikan lokasi vhost pada `NGINX_CONFIG`. Hal ini membuat pemeriksaan statis merepresentasikan konfigurasi aktif, bukan hanya template di repositori.

## Perbaikan yang diterapkan

Konfigurasi Reverb sekarang membaca `REVERB_ALLOWED_ORIGINS` berbentuk daftar hostname yang dipisahkan koma. Reverb membandingkan daftar tersebut dengan hostname hasil `parse_url` dari header `Origin`; karena itu nilai tidak boleh memakai `http://`, `https://`, atau wildcard. Nilai laboratorium berisi hostname antarmuka masing-masing. Template serta vhost aaPanel aktif dan konfigurasi Nginx Docker mengirim empat header keamanan. Pada aaPanel perubahan vhost diuji dengan `nginx -t` sebelum reload melalui service aaPanel.

## Rancangan evaluasi

Gunakan eksperimen before-after yang sama pada Docker dan aaPanel.

| Skenario gangguan terkontrol | Kondisi awal | Hasil Security Gate yang diharapkan |
| --- | --- | --- |
| Origin Reverb tidak valid | wildcard atau URL lengkap pada `REVERB_ALLOWED_ORIGINS` | gagal sebelum deployment dinyatakan selesai |
| Debug aktif | `APP_DEBUG=true` | gagal |
| Endpoint `.env` dapat diakses | aturan deny Nginx dihilangkan pada VM lab | gagal |
| Header keamanan dihilangkan | empat `add_header` dihilangkan pada VM lab | gagal |
| Permission `.env` longgar | mode memberi akses `other` | gagal |
| Konfigurasi aman | semua perbaikan diterapkan | lulus, HSTS hanya peringatan pada HTTP |

Setiap gangguan dibuat hanya di VM laboratorium, gate dijalankan, hasil dan waktu dicatat, lalu konfigurasi dipulihkan dan diverifikasi ulang. Metrik utama: jumlah konfigurasi berisiko yang terdeteksi, false negative, false positive, waktu deteksi, dan intervensi manual. Fungsi aplikasi tetap diverifikasi dengan integration gate dan uji real-time dua pengguna agar pengamanan tidak merusak chat Reverb.

Empat skenario yang tidak membutuhkan reload layanan dijalankan ulang melalui `scripts/run-security-gate-experiment.sh`. Runner membutuhkan konfirmasi eksplisit bahwa target adalah lab, menyimpan CSV dan log, lalu memulihkan `.env` dengan `trap`. Skenario header memakai salinan konfigurasi Nginx, sehingga tidak mengubah vhost aktif. Eksperimen endpoint publik dilakukan terpisah setelah tersedia vhost lab cadangan, karena memerlukan reload Nginx.

Gunakan `SECURITY_EXPERIMENT_RUNS=5` atau lebih untuk pengukuran skripsi. CSV memuat nomor replikasi dan waktu per skenario; laporkan median, rentang, serta tingkat deteksi. Waktu tersebut mengukur durasi Security Gate, bukan latensi aplikasi atau WebSocket.

Untuk memverifikasi header HTTP dari konfigurasi aktif, gunakan `scripts/run-live-nginx-header-experiment.sh` pada VM lab. Script ini membuat cadangan konfigurasi aktif, menghapus `X-Content-Type-Options` sementara, menguji sintaks dan reload Nginx, menjalankan gate, lalu memulihkan konfigurasi melalui `trap`. Pada aaPanel script dijalankan lewat sudo; pada Docker ia hanya mengubah konfigurasi di container `web` yang sedang berjalan.

## Bukti awal laboratorium

Pada 10 September 2026, konfigurasi aman lulus dengan nol kegagalan pada kedua VM. Keduanya menghasilkan satu peringatan HSTS karena URL laboratorium masih memakai HTTP. Sesudah itu, eksperimen `REVERB_ALLOWED_ORIGINS=*` dijalankan dengan mengubah `.env` sementara tanpa reload layanan, menjalankan gate, lalu memulihkan berkas secara otomatis. Gate menolak konfigurasi tersebut dalam 38 ms pada Docker dan 42 ms pada aaPanel. Setelah pemulihan, origin eksplisit, permission `.env`, endpoint `/up`, serta seluruh service yang relevan kembali tervalidasi.

### Replikasi awal lima kali

Setelah validasi format hostname Reverb ditambahkan, runner dijalankan lima kali pada setiap lingkungan. Semua keputusan yang diharapkan tercapai (5/5 per skenario). Median durasi gate adalah sebagai berikut.

| Skenario | Docker | aaPanel |
| --- | ---: | ---: |
| Baseline aman | 676 ms | 590 ms |
| Origin Reverb wildcard | 465 ms | 53 ms |
| URL lengkap pada origin Reverb | 479 ms | 55 ms |
| `APP_DEBUG=true` | 449 ms | 59 ms |
| Permission `.env` longgar | 495 ms | 56 ms |
| `Permissions-Policy` hilang pada konfigurasi salinan | 448 ms | 57 ms |

Angka tersebut adalah waktu eksekusi gate, bukan waktu respons aplikasi. Docker memeriksa artefak frontend di dalam container sehingga jalur pemeriksaannya lebih berat daripada aaPanel. Karena itu, hasil awal dipakai untuk menunjukkan konsistensi deteksi dalam tiap lingkungan, bukan untuk menyimpulkan aaPanel lebih cepat daripada Docker.

### Verifikasi header pada konfigurasi Nginx aktif

Eksperimen live menghapus `X-Content-Type-Options` dari Nginx aktif secara sementara pada VM lab, menjalankan `nginx -t` dan reload, lalu menjalankan Security Gate. Gate menolak kondisi tersebut dengan alasan header hilang dalam 235 ms pada Docker dan 490 ms pada aaPanel. Konfigurasi asli kemudian dipulihkan, Nginx direload kembali, dan `/up` kembali menghasilkan HTTP 200 dengan header `X-Content-Type-Options: nosniff` pada kedua lingkungan.

### Penyempurnaan kontrol origin Reverb

Uji dua pengguna menemukan regresi pada aaPanel saat daftar `REVERB_ALLOWED_ORIGINS` memakai URL lengkap. Dokumentasi dan kode Reverb menunjukkan bahwa server membandingkan hostname dari header `Origin`, sehingga nilai URL lengkap tidak cocok walaupun terlihat eksplisit. Security Gate kemudian diperbaiki untuk menolak wildcard dan nilai yang memuat `://`. Setelah nilai lab diubah menjadi hostname saja dan proses Reverb dimuat ulang, integration gate serta uji chat dua pengguna kembali lulus pada Docker dan aaPanel.
