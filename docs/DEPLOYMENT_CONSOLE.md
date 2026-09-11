# SITA Deployment Console

Konsol utama dijalankan dari root proyek pada host Docker atau server aaPanel:

```bash
bash deploy/sita.sh
```

Pilih satu environment untuk setiap tindakan. Konsol tidak pernah men-deploy Docker dan aaPanel dalam satu perintah karena keduanya adalah lingkungan uji yang terpisah.
Pilih `0` pada submenu untuk kembali ke pemilihan environment.

## Docker

Pilih menu Docker bila SITA berjalan dengan Docker Compose. Profile lokal dibuat sekali pada `deploy/docker-profile.env` dan hanya berisi URL healthcheck, URL publik, lokasi konfigurasi Nginx Docker, serta pilihan audit dependency. Profile tidak boleh berisi password database, `APP_KEY`, atau secret Reverb.

Urutan normal:

1. Buat profile Docker.
2. Jalankan `Check Docker` untuk Compose, container, health HTTP, storage, bundle frontend, WebSocket, dan Security Gate.
3. Jalankan `Release update Docker` saat kode perlu diperbarui.

Release Docker menjalankan preflight, build image, service `init`, update container, Integration Gate, dan Security Gate. Service `init` dapat menjalankan migration, sehingga migration harus ditinjau dan database penting harus dibackup sebelum release.

Perintah langsung:

```bash
bash deploy/sita.sh docker check
bash deploy/sita.sh docker release
```

## aaPanel

Pilih menu aaPanel bila Nginx, PHP-FPM, database, dan Website dikelola oleh aaPanel. Website, PHP extension, database/user, SSL, dan monitoring tetap disiapkan melalui GUI aaPanel. Sesudah itu, profile lokal `deploy/aapanel-profile.env` menyimpan domain, path aplikasi, runtime PHP, dan URL healthcheck tanpa secret.

Urutan normal:

1. Buat profile aaPanel.
2. Jalankan `Check kesiapan server`.
3. Pada server baru, pilih `Siapkan server baru` untuk deploy awal dan mengaktifkan service runtime.
4. Pada update rutin, pilih `Release update aplikasi`.

Perintah langsung:

```bash
bash deploy/sita.sh aapanel check
bash deploy/sita.sh aapanel release
```

Perintah lama berikut tetap berlaku dan diarahkan ke aaPanel:

```bash
bash deploy/sita.sh check
bash deploy/sita.sh release
```

## Log dan keputusan

Setiap aksi runner menyimpan transcript bertimestamp pada `storage/logs/deployment/`. Status `siap` berarti seluruh pemeriksaan wajib pada aksi tersebut lulus. Peringatan tetap harus dibaca melalui menu log sebelum keputusan production dibuat.
