# Authentication Experiment Workflow

`auth-experiment.yml` adalah kontrak eksekusi antara SITA Workload Identity
Observatory dan repositori SITA. Implementasi dilakukan bertahap agar setiap
profil dapat divalidasi secara terpisah.

## Status Profil

| Profil            | Status            | Credential jangka panjang pada workflow |
| ----------------- | ----------------- | --------------------------------------- |
| WIF dasar         | Pilot diterapkan  | 0                                       |
| OAuth statis      | Belum diaktifkan  | 1 OAuth Client Secret                   |
| WIF multi-klaim   | Belum diaktifkan  | 0                                       |

Pilot pertama menerima `profile=wif_basic` dan `scenario=valid`. Input lain
ditolak secara eksplisit agar tidak menghasilkan data yang tampak sah tetapi
sebenarnya belum menerapkan gangguan terkontrol.

Workflow memeriksa ID eksperimen, ID trial, target logis, nomor pengulangan,
expected decision, serta commit SHA opsional. Bukti selalu diunggah sebagai
artifact, termasuk saat autentikasi gagal. Token OIDC mentah, OAuth secret,
auth key, dan header otorisasi tidak ditulis ke artifact.

Satu eksperimen memakai concurrency group berdasarkan `experiment_id` sehingga
pengulangan dari batch yang sama tidak berjalan paralel.
