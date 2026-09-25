# Absensi Guru — Face Recognition On-Device

Sistem absensi guru SDN Gubrih 1 berbasis pengenalan wajah dan validasi lokasi GPS.
Deteksi dan verifikasi wajah berjalan sepenuhnya di HP (on-device), tanpa mengirim
foto ke server.

## Fitur

- Deteksi wajah (MTCNN) + pengenalan (MobileFaceNet) on-device via TensorFlow Lite
- Validasi lokasi dengan GPS Geofencing (Haversine Formula, radius 50m)
- Mode offline fallback (SQLite) dengan sync otomatis saat internet tersedia
- Anti-fraud: monotonic clock (SystemClock.elapsedRealtime) + audit trail
- Foreground service untuk menjaga GPS tetap hidup saat aplikasi di background
- Sync watchdog dengan exponential backoff (0s / 30s / 60s / 150s / 300s)
- Cek koneksi berdasarkan ping ke server (bukan hanya status WiFi/data)

## Teknologi

- **Mobile:** Flutter 3.x (Dart)
- **Model runtime:** tflite_flutter
- **Paket utama:** camera, geolocator, sqflite, wakelock_plus, light
- **Cloud:** Supabase (Auth, PostgreSQL, Storage)
- **Native Android:** Kotlin (monotonic clock, network monitor, GPS foreground service)

## Model

- **MTCNN** — deteksi wajah dan 5 facial landmarks.
  Sumber: [ipazc/mtcnn](https://github.com/ipazc/mtcnn).
  Dikonversi ke TFLite dengan custom PReLU layer.
- **MobileFaceNet** — ekstraksi embedding wajah 128-D.
  Sumber: [Xiaoccer/MobileFaceNet_Pytorch](https://github.com/Xiaoccer/MobileFaceNet_Pytorch).
  Konversi ke TFLite int8 (kuantisasi).
  Referensi paper: Chen et al. (2018), [arXiv:1804.07573](https://arxiv.org/abs/1804.07573).

**Threshold pengenalan:**
- Strict 0.75 — dataset non-kacamata
- Loose 0.80 — dataset kacamata

## Cara Menjalankan

1. Clone repository ini.
2. `flutter pub get`
3. Siapkan proyek Supabase dengan tabel: `profiles`, `sekolah`, `attendance`,
   `face_embeddings`, `session_logs`, `face_attempts`, `gps_attempts`,
   `trusted_time_anchor`. Bucket storage: `face_photos` (private).
4. Isi kredensial di `lib/config/supabase_config.dart`.
5. `flutter run`

## Struktur Proyek

lib/
├── main.dart
├── config/ # konfigurasi (threshold, Supabase)
├── screens/ # UI (login, absen, riwayat, registrasi)
├── services/ # logika (GPS, model, database, sync)
└── utils/ # helper

## Cara Kerja Singkat

1. Guru buka aplikasi → GPS warmup jalan di background.
2. Kamera depan aktif. MTCNN deteksi wajah, MobileFaceNet ekstraksi embedding.
3. Wajah dicocokkan dengan database lokal (Euclidean Distance).
4. Jika cocok → cek lokasi GPS (radius 50m dari sekolah).
5. Jika dalam radius → absen tercatat, sync ke server (jika internet tersedia).
6. Jika internet mati → data tersimpan lokal, sync otomatis saat internet kembali
   (via alarm koneksi dan sync watchdog).

## Status

Penelitian skripsi — Program Studi Teknik Informatika,
Universitas Muhammadiyah Jember.

**Penulis:** Riko Putra Dwi Susanto (2010651111)
