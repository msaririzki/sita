# Triase Snapshot Dependency Audit SITA

## Tujuan dan aturan keputusan

Dokumen ini mencatat snapshot audit dependency production pada 10 September UTC atau 11 September 2026 WITA. Tujuannya adalah menentukan urutan investigasi sebelum `DEPENDENCY_AUDIT_MODE=enforce` dijadikan kebijakan deployment reguler.

Advisory bukan bukti otomatis bahwa SITA dapat dieksploitasi. Sebelum pembaruan, setiap temuan harus dicek berdasarkan jalur pemanggilan aplikasi, exposure runtime, versi perbaikan yang kompatibel, dan hasil regresi. Tidak ada `composer update`, `npm update`, atau `audit fix` yang dijalankan dalam tahap ini.

Kategori prioritas:

- **P1:** direct dependency atau severity critical/high yang berpotensi berada pada build atau runtime production.
- **P2:** transitive dependency severity high yang harus ditelusuri melalui dependency tree.
- **P3:** medium, low, atau severity tidak diketahui; dicatat dan ditriase setelah P1/P2.

## Ringkasan snapshot baseline

| Ekosistem | Paket terdampak | Advisory | High/Critical | Catatan |
| --- | ---: | ---: | ---: | --- |
| Composer production (`--no-dev`) | 17 | 53 | 15 | Tiga paket direct: Filament, Laravel Framework, dan dependensi terkait UI/admin |
| npm production (`--omit=dev`) | 14 | 14 | 10 | `concurrently` dan Vite tercatat sebagai direct dependency pada `package.json` |

Total keputusan mode `enforce` pada ambang `high` adalah 25 advisory. Nilai ini dapat berubah ketika basis data advisory berubah; JSON bertimestamp menjadi bukti primer eksperimen.

## Composer

| Paket | Versi lock | Jalur | Advisory | Maks. severity | Prioritas | Tindakan sebelum update |
| --- | --- | --- | ---: | --- | --- | --- |
| `filament/filament` | v5.2.4 | Direct | 6 | high | P1 | Telaah changelog versi perbaikan dan uji panel admin |
| `laravel/framework` | v12.53.0 | Direct | 3 | high | P1 | Telaah release security Laravel dan jalankan suite fitur |
| `filament/tables` | v5.2.4 | Transitive | 2 | high | P2 | Akan diperbarui bersama ekosistem Filament bila kompatibel |
| `guzzlehttp/guzzle` | 7.10.0 | Transitive | 9 | high | P2 | Telusuri paket induk serta penggunaan HTTP client SITA |
| `league/commonmark` | 2.8.0 | Transitive | 12 | high | P2 | Telusuri penggunaan Markdown dan input pengguna |
| `symfony/http-kernel` | v7.4.5 | Transitive | 1 | high | P2 | Ikuti constraint Laravel Framework saat evaluasi update |
| `symfony/mime` | v7.4.5 | Transitive | 2 | high | P2 | Telusuri alur email/attachment yang memakai package ini |
| `filament/actions` | v5.2.4 | Transitive | 1 | medium | P3 | Ikuti evaluasi ekosistem Filament |
| `filament/infolists` | v5.2.4 | Transitive | 1 | medium | P3 | Ikuti evaluasi ekosistem Filament |
| `guzzlehttp/psr7` | 2.8.0 | Transitive | 4 | medium | P3 | Ikuti evaluasi dependency tree Guzzle |
| `livewire/livewire` | v4.2.1 | Transitive | 1 | medium | P3 | Uji regresi panel bila diperbarui |
| `paragonie/sodium_compat` | v2.5.0 | Transitive | 1 | unknown | P3 | Identifikasi severity dari advisory upstream sebelum keputusan |
| `symfony/html-sanitizer` | v8.0.0 | Transitive | 5 | low | P3 | Telaah jika fitur sanitasi dipakai oleh SITA |
| `symfony/http-foundation` | v7.4.5 | Transitive | 1 | medium | P3 | Ikuti constraint Laravel Framework |
| `symfony/mailer` | v7.4.4 | Transitive | 1 | medium | P3 | Telusuri fitur pengiriman email SITA |
| `symfony/polyfill-intl-idn` | v1.33.0 | Transitive | 1 | low | P3 | Pantau melalui update dependency induk |
| `symfony/routing` | v7.4.4 | Transitive | 2 | medium | P3 | Ikuti constraint Laravel Framework |

## npm

| Paket | Versi lock | Jalur | Advisory | Maks. severity | Prioritas | Tindakan sebelum update |
| --- | --- | --- | ---: | --- | --- | --- |
| `concurrently` | 9.2.1 | Direct | 1 | critical | P1 | Verifikasi bahwa tool hanya dipakai skrip development; evaluasi pemindahan ke `devDependencies` tanpa mengubah perilaku deploy |
| `vite` | 7.3.2 | Direct | 2 | high | P1 | Telaah release perbaikan serta uji build frontend dan E2E setelah update |
| `axios` | 1.16.0 | Transitive | 10 | high | P2 | Telusuri apakah bundle production membawa jalur rentan dan package induk yang menguncinya |
| `browserslist` | 4.28.1 | Transitive | 2 | high | P2 | Telaah sebagai dependency toolchain/build |
| `form-data` | 4.0.5 | Transitive | 1 | high | P2 | Telusuri paket induk dan apakah dipakai pada runtime server/browser |
| `nanoid` | 3.3.11 | Transitive | 3 | high | P2 | Telusuri dependency tree serta penggunaan bundel produksi |
| `postcss` | 8.5.14 | Transitive | 2 | high | P2 | Telaah sebagai toolchain CSS/build |
| `shell-quote` | 1.8.3 | Transitive | 2 | critical | P2 | Telusuri rantai dari `concurrently`; prioritas tinggi karena source critical |
| `socket.io-parser` | 4.2.6 | Transitive | 1 | high | P2 | Pastikan hubungan dengan dependency real-time frontend |
| `ws` | 8.18.3 | Transitive | 2 | high | P2 | Telusuri penggunaan WebSocket dan package induk |
| `@babel/core` | 7.28.6 | Transitive | 1 | low | P3 | Telaah sebagai toolchain build |
| `baseline-browser-mapping` | 2.9.16 | Transitive | 1 | moderate | P3 | Telaah sebagai toolchain build |
| `engine.io-client` | 6.6.4 | Transitive | 1 | moderate | P3 | Telusuri dependency real-time frontend |
| `qs` | 6.15.0 | Transitive | 3 | moderate | P3 | Telusuri package induk dan data input terkait |

## Rencana pengujian perbaikan

1. Buat branch per kelompok dependency, dimulai dari P1 Composer dan P1 npm; jangan memperbarui seluruh lockfile sekaligus.
2. Catat version range advisory dan versi perbaikan pada tabel eksperimen.
3. Jalankan unit/feature test, `npm run types`, build frontend, Security Gate, dan E2E chat dua pengguna setelah setiap pembaruan.
4. Bandingkan advisory sebelum dan sesudah pembaruan menggunakan snapshot baru. Laporkan advisory yang tersisa serta alasannya.
5. Ubah mode audit menjadi `enforce` hanya setelah kebijakan pengecualian dan bukti regresi disetujui pada lingkungan lab.

## Hasil tindakan P1 Composer (11 September 2026 WITA)

Pembaruan dilakukan pada branch terpisah dengan constraint yang sudah ada di `composer.json`; tidak ada perubahan dependency manifest. Perintah yang digunakan adalah `composer update laravel/framework filament/filament --with-all-dependencies --no-scripts --no-interaction`, lalu `composer update paragonie/sodium_compat --with-all-dependencies --no-scripts --no-interaction`. Aset publik Filament dibangkitkan ulang melalui `composer dump-autoload` dan `filament:upgrade`.

| Komponen | Sebelum | Sesudah |
| --- | --- | --- |
| `laravel/framework` | v12.53.0 | v12.69.2 |
| `filament/filament` | v5.2.4 | v5.8.1 |
| `paragonie/sodium_compat` | v2.5.0 | v2.5.2 |
| Composer production advisory | 53 | 0 |

Verifikasi lokal: `composer audit --locked --no-dev --format=summary` tidak menemukan advisory; `php artisan test --compact` lulus 255 tes dan 1.946 assertion; `npm run types` dan `npm run build` juga lulus. Perubahan konfigurasi menetapkan `Asia/Makassar` sebagai default dan contoh `APP_TIMEZONE` agar kontrol jadwal Filament tidak berubah delapan jam apabila variabel lingkungan belum ditetapkan.

Audit npm belum ditangani pada tindakan ini: baseline masih 14 advisory, dengan 10 high/critical. Karena itu mode `enforce` untuk audit dependency belum boleh dipakai sebagai syarat deployment sampai paket npm dan klasifikasi `dependencies`/`devDependencies` selesai dievaluasi dan diuji.
