# Protokol Eksperimen Deployment SITA

## Tujuan

Mengevaluasi apakah Security and Integration Gate dapat mencegah deployment
SITA dinyatakan siap ketika masih terdapat gangguan keamanan, konfigurasi, atau
integrasi runtime pada Docker dan aaPanel.

## Rumusan masalah kerja

1. Bagaimana merancang Security and Integration Gate yang memverifikasi
   konfigurasi, runtime, layanan latar belakang, keamanan dasar, dan alur chat
   realtime SITA pada Docker dan aaPanel?
2. Seberapa efektif gate mendeteksi gangguan terkontrol dibanding pemeriksaan
   deployment manual yang dipakai sebelumnya?
3. Seberapa cepat release dapat dipulihkan ke kondisi siap setelah gate
   mendeteksi kegagalan?

## Batas penelitian

- Objeknya adalah proses deployment SITA, bukan benchmark kapasitas Reverb,
  Redis, throughput pesan, atau latency P99.
- Chat dua akun digunakan sebagai bukti fungsi pascadeploy, bukan pengukuran
  performa jaringan.
- Rollback otomatis hanya mencakup release source dan konfigurasi Nginx yang
  dicadangkan oleh runner. Migration database tetap memerlukan backup dan
  persetujuan operator; rollback skema database tidak diklaim otomatis.
- Semua gangguan dijalankan hanya pada VM lab `sita-docker` dan
  `sita-aapanel`, tidak pernah pada SITA kampus.

## Kondisi pembanding

| Kode | Kondisi | Definisi hasil siap |
|---|---|---|
| B0 | Pemeriksaan manual sebelumnya | Deploy selesai dan operator memeriksa halaman, service, atau chat secara terpisah. Tidak ada keputusan gabungan yang menolak release. |
| T1 | Deployment Console dengan gate | Release hanya siap jika synchronization check, Integration Gate, dan Security Gate lulus. Bila post-deployment gagal, release source kembali ke release baik sebelumnya sesuai kemampuan rollback. |

## Metrik

| Metrik | Definisi | Satuan |
|---|---|---|
| Deteksi benar | Gate menolak release ketika gangguan memang ada | jumlah dan persentase |
| False negative | Gangguan ada tetapi release/gate dinyatakan siap | jumlah |
| False positive | Kondisi normal tetapi gate menolak release | jumlah |
| Waktu deteksi | Dari gangguan selesai dipasang hingga hasil gagal tersedia | detik atau milidetik |
| Waktu pemulihan | Dari tindakan pemulihan dimulai hingga gate kembali lulus | detik |
| Intervensi manual | Jumlah tindakan operator selain menjalankan aksi standar console | langkah |
| Keberhasilan rollback | Release sebelumnya tetap/menjadi aktif dan healthcheck serta gate lulus | berhasil atau gagal |

## Matriks skenario

| ID | Gangguan | Lingkungan | Bukti kegagalan yang diharapkan | Pemulihan |
|---|---|---|---|---|
| G-01 | Service Reverb dihentikan | Docker dan aaPanel | Service tidak aktif dan WebSocket gagal; HTTP dapat tetap sehat | Jalankan kembali Reverb lalu gate lulus |
| G-02 | Proxy WebSocket Nginx salah atau tidak menuju Reverb | Docker dan aaPanel | WebSocket upgrade gagal, meskipun service Reverb aktif | Pulihkan konfigurasi Nginx dari backup, uji sintaks, reload |
| G-03 | `storage` atau `bootstrap/cache` tidak dapat ditulis user runtime | Docker dan aaPanel | Gate permission gagal | Pulihkan owner/group dan mode runtime |
| G-04 | Socket atau handler PHP-FPM pada vhost tidak sesuai | aaPanel | Synchronization check atau health aplikasi gagal | Pulihkan socket/include PHP yang benar |
| G-05 | Bundle frontend memuat konfigurasi Reverb yang salah | Docker dan aaPanel | Inspeksi artefak atau uji browser realtime gagal | Bangun ulang asset dengan `.env` benar |
| G-06 | Endpoint sensitif seperti `.env` atau `.git/HEAD` dapat dijangkau | Docker dan aaPanel bila aman disimulasikan | Security Gate gagal | Pulihkan aturan deny Nginx |
| G-07 | Kondisi normal tanpa gangguan | Docker dan aaPanel | Semua gate lulus; dipakai menghitung false positive | Tidak ada pemulihan |

## Urutan pelaksanaan

1. Catat baseline B0 pada satu lingkungan tanpa mengubah konfigurasi.
2. Jalankan kondisi normal G-07 lima kali untuk setiap lingkungan.
3. Jalankan satu gangguan, mulai dengan G-01 Reverb.
4. Catat output gate, waktu, release aktif, dan tindakan manual pada lembar data.
5. Pulihkan sistem sesuai prosedur skenario.
6. Jalankan gate, healthcheck, dan uji chat dua akun untuk mengonfirmasi baseline
   kembali siap.
7. Ulangi skenario yang sama hingga lima kali sebelum berpindah ke gangguan
   berikutnya.
8. Jangan melanjutkan eksperimen bila pemulihan tidak lulus; diagnosis dan
   stabilkan baseline lebih dahulu.

## Aturan validitas data

- Catatan eksperimen hanya memakai hasil dari skrip yang memuat profile server
  dengan benar. Percobaan yang berhenti sebelum pemeriksaan dimulai diberi
  status invalid dan tidak dihitung.
- Versi commit, spesifikasi VM efektif, domain/probe mode, dan timestamp UTC
  dicatat pada setiap pengulangan.
- Gunakan snapshot Proxmox atau backup konfigurasi sebelum kelompok gangguan
  yang berisiko mengubah vhost atau runtime.
- Bandingkan efektivitas pemeriksaan, bukan kecepatan web Docker versus
  aaPanel, karena resource kedua VM tidak identik.

## Status saat ini

- G-01 aaPanel sudah memiliki satu hasil valid: Reverb dihentikan, gate gagal,
  service dipulihkan, gate lulus, lalu chat dua akun kembali diterima tanpa
  refresh.
- Hasil G-01 belum cukup untuk statistik; empat pengulangan aaPanel serta
  lima pengulangan Docker masih diperlukan.
- Gateway SSH menuju VM lab sedang timeout. Eksperimen aktif ditunda sampai
  konektivitas lab kembali, tanpa mengganti baseline atau memaksa akses ke
  server kampus.
