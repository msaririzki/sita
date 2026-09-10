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

Pada aaPanel, bila konfigurasi vhost dibaca oleh root, jalankan gate lewat sudo dan berikan lokasi vhost pada `NGINX_CONFIG`. Hal ini membuat pemeriksaan statis merepresentasikan konfigurasi aktif, bukan hanya template di repositori.

## Perbaikan yang diterapkan

Konfigurasi Reverb sekarang membaca `REVERB_ALLOWED_ORIGINS` berbentuk daftar origin yang dipisahkan koma. Nilai laboratorium berisi satu origin antarmuka masing-masing dan tidak menggunakan wildcard. Template serta vhost aaPanel aktif dan konfigurasi Nginx Docker mengirim empat header keamanan. Pada aaPanel perubahan vhost diuji dengan `nginx -t` sebelum reload melalui service aaPanel.

## Rancangan evaluasi

Gunakan eksperimen before-after yang sama pada Docker dan aaPanel.

| Skenario gangguan terkontrol | Kondisi awal | Hasil Security Gate yang diharapkan |
| --- | --- | --- |
| Origin Reverb wildcard | `REVERB_ALLOWED_ORIGINS=*` | gagal sebelum deployment dinyatakan selesai |
| Debug aktif | `APP_DEBUG=true` | gagal |
| Endpoint `.env` dapat diakses | aturan deny Nginx dihilangkan pada VM lab | gagal |
| Header keamanan dihilangkan | empat `add_header` dihilangkan pada VM lab | gagal |
| Permission `.env` longgar | mode memberi akses `other` | gagal |
| Konfigurasi aman | semua perbaikan diterapkan | lulus, HSTS hanya peringatan pada HTTP |

Setiap gangguan dibuat hanya di VM laboratorium, gate dijalankan, hasil dan waktu dicatat, lalu konfigurasi dipulihkan dan diverifikasi ulang. Metrik utama: jumlah konfigurasi berisiko yang terdeteksi, false negative, false positive, waktu deteksi, dan intervensi manual. Fungsi aplikasi tetap diverifikasi dengan integration gate dan uji real-time dua pengguna agar pengamanan tidak merusak chat Reverb.

Empat skenario yang tidak membutuhkan reload layanan dijalankan ulang melalui `scripts/run-security-gate-experiment.sh`. Runner membutuhkan konfirmasi eksplisit bahwa target adalah lab, menyimpan CSV dan log, lalu memulihkan `.env` dengan `trap`. Skenario header memakai salinan konfigurasi Nginx, sehingga tidak mengubah vhost aktif. Eksperimen endpoint publik dilakukan terpisah setelah tersedia vhost lab cadangan, karena memerlukan reload Nginx.

Gunakan `SECURITY_EXPERIMENT_RUNS=5` atau lebih untuk pengukuran skripsi. CSV memuat nomor replikasi dan waktu per skenario; laporkan median, rentang, serta tingkat deteksi. Waktu tersebut mengukur durasi Security Gate, bukan latensi aplikasi atau WebSocket.

## Bukti awal laboratorium

Pada 10 September 2026, konfigurasi aman lulus dengan nol kegagalan pada kedua VM. Keduanya menghasilkan satu peringatan HSTS karena URL laboratorium masih memakai HTTP. Sesudah itu, eksperimen `REVERB_ALLOWED_ORIGINS=*` dijalankan dengan mengubah `.env` sementara tanpa reload layanan, menjalankan gate, lalu memulihkan berkas secara otomatis. Gate menolak konfigurasi tersebut dalam 38 ms pada Docker dan 42 ms pada aaPanel. Setelah pemulihan, origin eksplisit, permission `.env`, endpoint `/up`, serta seluruh service yang relevan kembali tervalidasi.
