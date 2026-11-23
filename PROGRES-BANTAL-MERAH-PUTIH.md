# Progres Proyek: Web Penjual "Bantal Merah Putih"

Terakhir diperbarui: 23 November 2026 (integrasi Supabase selesai)

> Tip untuk Claude Code: simpan file ini di root proyek sebagai `CLAUDE.md` agar otomatis dibaca sebagai konteks.

---

## 1. Ringkasan proyek

Usaha penjualan bantal bertema **Block Design Test (BDT) merah putih**. Rekan pemilik memiliki **aplikasi BDT berbasis Expo (React Native)**. Setiap pembelian bantal mendapat **kode aktivasi** untuk membuka aplikasi tersebut.

**Tugas saya (pemilik proyek ini):** membuat **web untuk penjual** yang dapat:

1. Generate kode aktivasi per transaksi.
2. Mencetak kode (beserta QR) di **nota printer thermal**.
3. Menyimpan dan menampilkan **riwayat penjualan**.

**Tugas rekan:** menambahkan **halaman input kode** (ketik atau scan QR) di aplikasi Expo, yang memanggil fungsi aktivasi di Supabase. Aplikasi membaca `jumlah_bantal` (minimal 4) dari hasil aktivasi untuk menentukan permainan.

---

## 2. Keputusan yang sudah final

| Topik | Keputusan |
|---|---|
| Nama brand di web | **Bantal Merah Putih** (tanpa subjudul) |
| Desain | Mengikuti referensi dosen (file `KubusCeria_Maretha.html`): warna merah `#cb3540`, sidebar, kartu statistik, tabel, pop-up |
| Struktur halaman | **Satu halaman utama** (statistik + form generate + riwayat), plus Login dan Pengaturan. Bantuan berupa pop-up "?" |
| Input penjualan | Dua pilihan: **Paket 4 bantal** atau **Satuan** (ketik jumlah 1–500). Paket 9 dihapus. Total = jumlah × harga per bantal |
| Syarat kode aktivasi | **Minimal 4 bantal** mendapat 1 kode. 1–3 bantal hanya mendapat nota, status "Tanpa kode". Dicek juga di database |
| Jumlah kode | **1 kode per transaksi** (untuk transaksi ≥ 4 bantal), berapa pun jumlah bantalnya |
| Format kode | `BDT-XXXX-XXXX`, 8 karakter acak, tanpa 0/O/1/I/L |
| Isi QR di nota | `bdt://aktivasi?kode=BDT-XXXX-XXXX` |
| Aturan kode | 1 kode = 1 perangkat. Perangkat yang sama boleh aktivasi ulang (misal install ulang) |
| Cetak | Printer thermal kelas 58 mm, **kertas rol 57 × 50 mm** (lebar 57 mm). Isi nota dicetak selebar **48 mm** (area cetak printer), di tengah kertas. Opsi 80 mm di Pengaturan. Cetak ulang bertanda **SALINAN KE-N**. Kode yang sudah aktif tidak dicetak ulang |
| Peran | **Admin**: semua data, pengaturan, kelola akun, ganti/cabut kode. **Penjual**: buat kode, cetak, lihat penjualan sendiri |
| Backend | **Supabase** (trial paket Free): database, login, fungsi aktivasi. Aplikasi Expo tidak punya server sendiri |
| Aplikasi rekan | **Expo (React Native)**, memakai `@supabase/supabase-js` (sebelumnya tertulis Flutter, sudah dikoreksi) |
| Hosting web | Web = 1 file HTML statis. Trial dan produksi: **Cloudflare Pages** (gratis, boleh komersial). Alternatif: Hostinger shared hosting. **Tidak perlu VPS** |
| Tidak dipakai dari referensi | Halaman aktivasi & permainan di web, label QR A4 terpisah, pilihan paket |
| Diambil dari referensi | Kode disamarkan di tabel, ganti/cabut kode dengan alasan, ID permintaan anti-dobel, ekspor CSV tanpa kode rahasia, tidak meminta data anak |

---

## 3. Arsitektur

```
[Web Penjual: index.html statis di Cloudflare Pages] ──┐
                                                       ├──► [SUPABASE: Postgres + Auth + fungsi RPC]
[Aplikasi BDT Expo di HP pembeli]   ──────────────────┘
```

- Web memakai `supabase-js` dari CDN dengan **Publishable key** (`sb_publishable_...`).
- Aplikasi Expo memakai Publishable key yang sama, hanya boleh memanggil `activate_code`.
- **Secret key tidak pernah** ditaruh di web atau aplikasi.

---

## 4. File proyek

| File | Isi | Status |
|---|---|---|
| `web-penjual-bdt.html` | Versi pratinjau dengan **data simulasi** (localStorage). Disimpan sebagai arsip/demo | Selesai |
| `deploy/index.html` | **Versi produksi** yang tersambung ke Supabase. File inilah yang diunggah ke Cloudflare Pages / Hostinger | Selesai, menunggu uji login di web asli |
| `supabase-schema.sql` | Skrip database Supabase: tabel, fungsi, RLS, hak akses | Selesai, diuji di PostgreSQL 16 lokal dengan tiruan auth Supabase |
| `KubusCeria_Maretha.html` | Referensi desain dari dosen | Hanya referensi |
| Dokumen perencanaan | https://claude.ai/artifact/FXBHDJLN7FDUFmi9AFamEh | Ada di claude.ai |
| Pratinjau web | https://claude.ai/artifact/NvCTDioJAC535jd9Z63A7A | Ada di claude.ai |

---

## 5. Web penjual (`web-penjual-bdt.html`)

Satu file HTML: CSS, JS, dan encoder QR (versi 6, diambil dari referensi dosen) semuanya inline. Tanpa framework.

### Struktur kode JavaScript
1. **Encoder QR**: `BdtQR.svg(text)`.
2. **LAPISAN DATA (SIMULASI)**: blok yang **harus diganti dengan Supabase**. Isinya:
   - `apiCreateSale(input)`: membuat penjualan + 1 kode, anti-dobel lewat `requestId`.
   - `apiReplaceCode(codeId, reason)`, `apiRevokeCode(codeId, reason)`: khusus admin.
   - `apiActivate(rawCode, deviceId)`: dipakai simulator "Uji aktivasi".
   - Data disimpan di `localStorage` (kunci `bdt-penjual-pratinjau-v1`), berisi data contoh (seed).
3. **TAMPILAN**: tidak perlu banyak diubah.
   - Login (akun simulasi: `admin@contoh.id`, `andi@contoh.id`, kata sandi bebas).
   - Halaman Penjualan: statistik, form, riwayat (cari, filter status/periode, paginasi 15, ekspor CSV).
   - Pop-up nota: pratinjau thermal, Salin kode, Cetak (`window.print` + `@page size: 58mm auto`).
   - Pop-up Kelola (admin): kode pengganti atau cabut, wajib alasan.
   - Pop-up "Uji aktivasi": meniru halaman input kode di aplikasi Expo.
   - Halaman Pengaturan (admin): info toko, harga, lebar kertas, awalan nota, teks penutup, akun penjual, reset data simulasi.
   - Routing lewat hash: `#penjualan`, `#pengaturan`.

### Responsif
- **Komputer (≥1100 px):** sidebar penuh, form 340 px di kiri dan riwayat di kanan.
- **Tablet (760–1099 px):** sidebar ikon saja, form di atas (2 kolom) dan riwayat di bawah.
- **HP (<760 px):** tanpa sidebar, **navigasi bawah**, tabel riwayat berubah menjadi kartu, pop-up muncul dari bawah.

### Catatan
- Di pratinjau claude.ai, `window.print` dan unduhan diblokir (sandbox). Di hosting asli keduanya berfungsi. Kode sudah mendeteksi `inFrame`.

---

## 6. Database Supabase (`supabase-schema.sql`)

### Tabel
| Tabel | Isi |
|---|---|
| `profiles` | id (= auth.users), name, email, role (`admin`/`penjual`), **active (default false)** |
| `settings` | 1 baris: shop_name, address, phone, price_per_pillow, paper_mm, invoice_prefix, footer |
| `sales` | invoice (unik, `INV-YYYYMMDD-0001` zona Asia/Jakarta), seller_id, qty, unit_price, total, buyer, pay_method, request_id (unik), print_count, last_print_at |
| `activation_codes` | sale_id, code (unik), status (`issued`/`active`/`revoked`), device_id, activated_at, reason. Kode lama tetap tersimpan saat diganti |
| `logs` | jejak: generate, cetak, cetak_ulang, aktivasi, ganti_kode, cabut |
| `activation_attempts` | catatan percobaan aktivasi untuk pembatasan (tertutup total) |

### Fungsi RPC
| Fungsi | Dipanggil oleh | Keterangan |
|---|---|---|
| `create_sale(p_qty, p_unit_price, p_buyer, p_pay_method, p_request_id)` | Web (login) | Membuat penjualan + kode. Mengembalikan `{sale_id, invoice, duplicate}` |
| `record_print(p_sale_id)` | Web (login) | Mengembalikan nomor salinan (0 = cetakan pertama) |
| `replace_code(p_code_id, p_reason)` | Web (admin) | Mencabut kode lama dan membuat kode baru |
| `revoke_code(p_code_id, p_reason)` | Web (admin) | Mencabut kode |
| `activate_code(p_code, p_device_id)` | Aplikasi Expo (anon) | Lihat kontrak di bagian 7 |
| `is_admin()`, `is_active_seller()` | Policy RLS | Fungsi bantu |
| `handle_new_user()` | Trigger auth.users | Otomatis membuat profil (belum aktif) |

### Keamanan
- RLS aktif di semua tabel. Penjual hanya melihat `sales` dan `activation_codes` miliknya; admin melihat semua.
- **Tidak ada INSERT/UPDATE/DELETE langsung** dari klien, kecuali update kolom tertentu di `profiles` dan `settings` (dibatasi policy admin). Semua penulisan lewat fungsi `security definer`.
- `revoke execute ... from public`, lalu grant per fungsi.

### Hasil uji lokal (sudah lolos)
- Penjual yang belum aktif ditolak membuat kode.
- Request ganda mengembalikan `duplicate: true`.
- Penjual hanya melihat penjualannya sendiri.
- Insert langsung ke `sales` ditolak.
- Penjual tidak bisa mencabut kode.
- Hitungan cetak benar (0, lalu 1).
- Aktivasi: dari isi QR berhasil; perangkat sama → `reactivated: true`; perangkat lain → `used`; kode karangan → `invalid`.
- Role `anon` tidak bisa membaca tabel `activation_codes`.

---

## 7. Kontrak API aktivasi (untuk rekan, Expo / React Native)

- Project URL: `https://clsrjirgrqsoyukarhve.supabase.co`
- Publishable key: `sb_publishable_zc879OKKuhQyGxEz2MJiPQ_BUVT3eIA`
- Aplikasi **tidak perlu login**. Cukup panggil satu fungsi: `activate_code`.

Pasang paket:
```bash
npx expo install @supabase/supabase-js @react-native-async-storage/async-storage react-native-url-polyfill expo-application expo-crypto
```

Contoh `aktivasi.js`:
```js
import 'react-native-url-polyfill/auto';
import { Platform } from 'react-native';
import { createClient } from '@supabase/supabase-js';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Application from 'expo-application';
import * as Crypto from 'expo-crypto';

const supabase = createClient(
  'https://clsrjirgrqsoyukarhve.supabase.co',
  'sb_publishable_zc879OKKuhQyGxEz2MJiPQ_BUVT3eIA',
  { auth: { persistSession: false, autoRefreshToken: false } } // aplikasi tidak login
);

// ID perangkat yang TETAP SAMA walau aplikasi di-install ulang,
// supaya pembeli yang install ulang tidak ditolak ("used").
async function getDeviceId() {
  let id = null;
  if (Platform.OS === 'android') id = Application.getAndroidId();
  else if (Platform.OS === 'ios') id = await Application.getIosIdForVendorAsync();
  if (id) return `${Platform.OS}-${id}`;
  // cadangan (misal di web/emulator): UUID acak yang disimpan
  id = await AsyncStorage.getItem('bdt_device_id');
  if (!id) { id = Crypto.randomUUID(); await AsyncStorage.setItem('bdt_device_id', id); }
  return id;
}

// kodeAtauIsiQR: "BDT-XXXX-XXXX", tanpa strip, atau isi QR utuh "bdt://aktivasi?kode=..."
export async function aktivasi(kodeAtauIsiQR) {
  const { data, error } = await supabase.rpc('activate_code', {
    p_code: kodeAtauIsiQR,
    p_device_id: await getDeviceId(),
  });
  if (error) throw error;                      // masalah jaringan / server
  if (data.status === 'ok') {
    await AsyncStorage.setItem('bdt_aktivasi', JSON.stringify(data)); // agar bisa main offline
  }
  return data;                                 // { status, kode, nota, jumlah_bantal, ... }
}
```

Catatan untuk aplikasi Expo:
- **`jumlah_bantal` selalu ≥ 4** (bisa 4, 5, 6, … karena ada pembelian Satuan). Aplikasi menentukan sendiri mode/level permainan dari nilai ini.
- **Scan QR**: pakai `expo-camera` (`CameraView` dengan `barcodeScannerSettings={{ barcodeTypes: ['qr'] }}`), lalu kirim isi QR apa adanya ke `aktivasi()`.
- **Opsional**: set `"scheme": "bdt"` di `app.json`. Dengan begitu, scan QR nota memakai kamera bawaan HP langsung membuka aplikasi (`bdt://aktivasi?kode=...`).
- **Di Android, ID perangkat** (`getAndroidId`) tetap sama walau aplikasi di-install ulang, selama kunci tanda tangan aplikasinya sama. Karena itu, **jangan ganti keystore/kunci build** setelah rilis.
- **Di iOS, ID perangkat** (`getIosIdForVendorAsync`) bisa berubah jika semua aplikasi dari developer yang sama dihapus. Jika pembeli kena `used`, admin menerbitkan kode pengganti lewat Kelola.

Setelah `ok`, aplikasi menyimpan status aktif secara lokal agar bisa dimainkan tanpa internet.

---

## 8. Status saat ini

- [x] Perencanaan dan keputusan desain
- [x] Web penjual versi pratinjau (data simulasi)
- [x] Skrip database Supabase
- [x] Proyek Supabase dibuat (nama "Bantal Merah Putih", region Asia-Pacific/Singapore)
- [x] Menjalankan `supabase-schema.sql` di SQL Editor
- [ ] Matikan "Allow new users to sign up" di Authentication
- [x] Akun admin `bintang@cemail.com` dan penjual uji `gibran@cemail.com` dibuat dan diaktifkan. Cara membuat akun:
      `update public.profiles set role='admin', active=true, name='Maretha' where email='...';`
- [x] Project URL `https://clsrjirgrqsoyukarhve.supabase.co` dan Publishable key sudah dipasang di `deploy/index.html`
- [x] Ganti lapisan simulasi di web dengan Supabase (hasilnya `deploy/index.html`)
- [x] Deploy ke Cloudflare (sebagai **Worker static assets**, bukan Pages): **https://bantal-merah-putih.oamp.workers.dev**. Update: Workers & Pages > bantal-merah-putih > upload ulang folder `deploy`
- [x] Site URL Supabase = https://bantal-merah-putih.oamp.workers.dev, Redirect URL = https://bantal-merah-putih.oamp.workers.dev/** (saat pindah ke Hostinger: ganti Site URL dan tambah domain baru)
- [ ] Jalankan `migrasi-02-paket-4-dan-satuan.sql` di SQL Editor (menggantikan migrasi-01), lalu unggah ulang `deploy/index.html` ke Cloudflare
- [ ] Rekan membuat halaman input kode di aplikasi Expo dan uji alur lengkap
- [ ] Uji cetak di printer thermal asli (58 mm)

---

## 9. Langkah berikutnya: integrasi web dengan Supabase

Tambahkan:
```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script>const sb = supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);</script>
```

| Fitur | Simulasi sekarang | Ganti dengan |
|---|---|---|
| Login / keluar | cek `db.users` | `sb.auth.signInWithPassword`, `sb.auth.signOut`, `sb.auth.getSession`, `onAuthStateChange` |
| Profil yang login | `me()` | `sb.from('profiles').select().eq('id', user.id).single()` |
| Buat penjualan | `apiCreateSale` | `sb.rpc('create_sale', {...})`, lalu ambil ulang penjualan + kodenya |
| Riwayat | `filteredSales()` | `sb.from('sales').select('*, activation_codes(*), profiles(name)').order('created_at', {ascending:false}).range(a,b)` + filter di server |
| Statistik | hitung lokal | query agregat (atau hitung dari data periode berjalan) |
| Cetak | `s.print_count++` | `sb.rpc('record_print', {p_sale_id})` → nomor salinan |
| Ganti / cabut | `apiReplaceCode` / `apiRevokeCode` | `sb.rpc('replace_code' / 'revoke_code', {p_code_id, p_reason})` |
| Pengaturan | `db.settings` | `sb.from('settings').select().single()` / `.update({...}).eq('id',1)` |
| Akun penjual | `db.users` | `sb.from('profiles').select()` / `.update({active}).eq('id', ...)` |
| Tambah penjual | form di web | Untuk sementara lewat dashboard Supabase (Add user). Dari web butuh **Edge Function** dengan secret key (tahap lanjut) |
| Uji aktivasi | `apiActivate` | `sb.rpc('activate_code', ...)`. Pertimbangkan hanya untuk admin atau dihapus di produksi |

Hal lain yang perlu dikerjakan saat integrasi:
- Status loading dan pesan error jaringan.
- Hapus banner "PRATINJAU" dan data seed.
- Nama kolom berubah: `qty`, `unit_price`, `buyer`, `pay_method`, `seller_id`, `print_count`; kode ada di relasi `activation_codes` (kode terkini = `created_at` terbaru).

---

## 10. Catatan penting

- Paket Free Supabase: proyek **dihentikan sementara setelah 1 minggu tidak aktif** (bisa dinyalakan lagi). Untuk jualan sungguhan, pertimbangkan Supabase Pro.
- Key `anon`/`service_role` lama akan dihentikan Supabase paling lambat akhir 2026. Pakai **publishable** dan **secret** key.
- Vercel Hobby hanya untuk non-komersial, jadi tidak dipakai.
- Akun baru otomatis `active = false`; admin mengaktifkan di halaman Pengaturan.
- Saat membuat proyek Supabase: "Grant API access to new tables automatically" sebaiknya **dimatikan**, dan "Enable RLS automatically" **dinyalakan**. Skrip sudah mengatur grant sendiri.

## 11. Pertanyaan yang masih terbuka

- Nama domain (kalau memakai domain sendiri).
- Merek/tipe printer thermal, dan dicetak dari perangkat apa (komputer atau HP Android). Ini menentukan perlu tidaknya cetak Bluetooth (Web Bluetooth/RawBT) di tahap lanjut.
- Cara aplikasi Expo membuat `device_id` (disarankan `getAndroidId` / `getIosIdForVendorAsync`, lihat bagian 7).
- Hosting produksi final: tetap Cloudflare Pages atau Hostinger.
