-- =====================================================================
--  Database Web Penjual "Bantal Merah Putih" untuk Supabase
--  Cara pakai: Supabase Dashboard > SQL Editor > New query >
--  tempel seluruh isi file ini > Run. Cukup dijalankan SATU kali.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. TABEL
-- ---------------------------------------------------------------------

-- Profil penjual. Satu baris per akun login (Supabase Auth).
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null default '',
  email       text not null,
  role        text not null default 'penjual' check (role in ('admin','penjual')),
  active      boolean not null default false,   -- akun baru harus diaktifkan admin
  created_at  timestamptz not null default now()
);

-- Pengaturan toko & nota (hanya 1 baris).
create table public.settings (
  id               int primary key default 1 check (id = 1),
  shop_name        text not null default 'Mitra UMKM Sidoarjo',
  address          text not null default 'Sidoarjo, Jawa Timur',
  phone            text not null default '',
  price_per_pillow integer not null default 65000 check (price_per_pillow >= 0),
  paper_mm         integer not null default 58 check (paper_mm in (58, 80)),
  invoice_prefix   text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9]{1,6}$'),
  footer           text not null default 'Terima kasih. Selamat bermain bersama keluarga!',
  updated_at       timestamptz not null default now()
);
insert into public.settings (id) values (1);

-- Penjualan. 1 transaksi = 1 baris.
create table public.sales (
  id            uuid primary key default gen_random_uuid(),
  invoice       text not null unique,
  seller_id     uuid not null references public.profiles(id),
  qty           integer not null check (qty between 1 and 500),   -- kode hanya untuk >= 4 bantal
  unit_price    integer not null check (unit_price >= 0),
  total         bigint not null,
  buyer         text not null default '',
  pay_method    text not null default 'Tunai' check (pay_method in ('Tunai','QRIS','Transfer')),
  request_id    uuid not null unique,              -- anti-dobel saat tombol ditekan 2x
  print_count   integer not null default 0,
  last_print_at timestamptz,
  created_at    timestamptz not null default now()
);
create index sales_created_idx on public.sales (created_at desc);
create index sales_seller_idx  on public.sales (seller_id);

-- Kode aktivasi. Satu penjualan punya 1 kode aktif; kode lama tetap
-- tersimpan (status revoked) bila diganti.
create table public.activation_codes (
  id            uuid primary key default gen_random_uuid(),
  sale_id       uuid not null references public.sales(id) on delete cascade,
  code          text not null unique,
  status        text not null default 'issued' check (status in ('issued','active','revoked')),
  device_id     text,
  activated_at  timestamptz,
  reason        text,
  created_at    timestamptz not null default now()
);
create index activation_codes_sale_idx on public.activation_codes (sale_id);

-- Jejak aktivitas (generate, cetak, aktivasi, ganti, cabut).
create table public.logs (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  actor_id    uuid,
  action      text not null,
  sale_id     uuid,
  detail      text
);

-- Catatan percobaan aktivasi, untuk membatasi tebak-tebakan kode.
create table public.activation_attempts (
  id          bigint generated always as identity primary key,
  device_id   text,
  ip          text,
  success     boolean not null,
  created_at  timestamptz not null default now()
);
create index activation_attempts_idx on public.activation_attempts (created_at, device_id);

-- ---------------------------------------------------------------------
-- 2. FUNGSI BANTU
-- ---------------------------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and active);
$$;

create or replace function public.is_active_seller() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active);
$$;

-- Saat akun dibuat di Authentication, otomatis buat profilnya (belum aktif).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Kode acak BDT-XXXX-XXXX tanpa karakter mirip (0/O, 1/I/L).
create or replace function public.new_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  b bytea;
  s text;
begin
  loop
    b := extensions.gen_random_bytes(8);
    s := '';
    for i in 0..7 loop
      s := s || substr(alphabet, (get_byte(b, i) % 31) + 1, 1);
    end loop;
    s := 'BDT-' || substr(s, 1, 4) || '-' || substr(s, 5, 4);
    exit when not exists (select 1 from public.activation_codes where code = s);
  end loop;
  return s;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. FUNGSI YANG DIPANGGIL WEB PENJUAL (supabase.rpc)
-- ---------------------------------------------------------------------

-- Buat penjualan + 1 kode aktivasi.
create or replace function public.create_sale(
  p_qty int, p_unit_price int, p_buyer text, p_pay_method text, p_request_id uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_sale   public.sales;
  v_day    text;
  v_prefix text;
  v_n      int;
  v_code   text;
begin
  if not public.is_active_seller() then
    raise exception 'Akun belum login atau belum diaktifkan admin.';
  end if;

  select * into v_sale from public.sales where request_id = p_request_id;
  if found then
    return json_build_object('sale_id', v_sale.id, 'invoice', v_sale.invoice, 'duplicate', true);
  end if;

  if p_qty is null or p_qty < 1 or p_qty > 500 then
    raise exception 'Jumlah bantal harus 1 sampai 500.';
  end if;
  if p_unit_price is null or p_unit_price < 0 then
    raise exception 'Harga per bantal tidak valid.';
  end if;

  v_day := to_char(now() at time zone 'Asia/Jakarta', 'YYYYMMDD');
  perform pg_advisory_xact_lock(hashtext('invoice-' || v_day));   -- nomor nota tidak bentrok
  select invoice_prefix into v_prefix from public.settings where id = 1;
  select count(*) + 1 into v_n from public.sales
   where to_char(created_at at time zone 'Asia/Jakarta', 'YYYYMMDD') = v_day;

  insert into public.sales (invoice, seller_id, qty, unit_price, total, buyer, pay_method, request_id)
  values (v_prefix || '-' || v_day || '-' || lpad(v_n::text, 4, '0'),
          auth.uid(), p_qty, p_unit_price, p_qty::bigint * p_unit_price,
          left(coalesce(trim(p_buyer), ''), 80), coalesce(p_pay_method, 'Tunai'), p_request_id)
  returning * into v_sale;

  if p_qty >= 4 then                          -- kode aktivasi hanya untuk minimal 4 bantal
    v_code := public.new_code();
    insert into public.activation_codes (sale_id, code) values (v_sale.id, v_code);
    insert into public.logs (actor_id, action, sale_id, detail)
    values (auth.uid(), 'generate', v_sale.id, right(v_code, 4));
  else
    insert into public.logs (actor_id, action, sale_id, detail)
    values (auth.uid(), 'penjualan_tanpa_kode', v_sale.id, p_qty || ' bantal');
  end if;

  return json_build_object('sale_id', v_sale.id, 'invoice', v_sale.invoice, 'duplicate', false,
                           'has_code', v_code is not null);
end;
$$;

-- Catat cetak nota. Mengembalikan nomor salinan (0 = cetakan pertama).
create or replace function public.record_print(p_sale_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare v_copy int;
begin
  if not public.is_active_seller() then raise exception 'Akun tidak aktif.'; end if;
  update public.sales
     set print_count = print_count + 1, last_print_at = now()
   where id = p_sale_id and (seller_id = auth.uid() or public.is_admin())
  returning print_count - 1 into v_copy;
  if v_copy is null then raise exception 'Nota tidak ditemukan.'; end if;
  insert into public.logs (actor_id, action, sale_id, detail)
  values (auth.uid(), case when v_copy = 0 then 'cetak' else 'cetak_ulang' end, p_sale_id, 'salinan ' || v_copy);
  return v_copy;
end;
$$;

-- Admin: terbitkan kode pengganti (misal pembeli ganti HP).
create or replace function public.replace_code(p_code_id uuid, p_reason text) returns json
language plpgsql security definer set search_path = '' as $$
declare v_sale_id uuid; v_code text;
begin
  if not public.is_admin() then raise exception 'Hanya admin yang dapat mengganti kode.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Tulis alasan minimal 5 karakter.'; end if;
  update public.activation_codes
     set status = 'revoked', reason = 'Diganti: ' || trim(p_reason)
   where id = p_code_id and status <> 'revoked'
  returning sale_id into v_sale_id;
  if v_sale_id is null then raise exception 'Kode tidak ditemukan atau sudah dicabut.'; end if;
  v_code := public.new_code();
  insert into public.activation_codes (sale_id, code) values (v_sale_id, v_code);
  insert into public.logs (actor_id, action, sale_id, detail) values (auth.uid(), 'ganti_kode', v_sale_id, trim(p_reason));
  return json_build_object('sale_id', v_sale_id);
end;
$$;

-- Admin: cabut kode (retur atau kode bocor).
create or replace function public.revoke_code(p_code_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_sale_id uuid;
begin
  if not public.is_admin() then raise exception 'Hanya admin yang dapat mencabut kode.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Tulis alasan minimal 5 karakter.'; end if;
  update public.activation_codes set status = 'revoked', reason = trim(p_reason)
   where id = p_code_id and status <> 'revoked'
  returning sale_id into v_sale_id;
  if v_sale_id is null then raise exception 'Kode tidak ditemukan atau sudah dicabut.'; end if;
  insert into public.logs (actor_id, action, sale_id, detail) values (auth.uid(), 'cabut', v_sale_id, trim(p_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. FUNGSI YANG DIPANGGIL APLIKASI BDT (Flutter) — tanpa login
--    supabase.rpc('activate_code', params: {'p_code': ..., 'p_device_id': ...})
-- ---------------------------------------------------------------------
create or replace function public.activate_code(p_code text, p_device_id text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_ip   text;
  v_fail int;
  v_raw  text;
  v_code text;
  v_re   boolean := false;
  c      public.activation_codes;
  s      public.sales;
begin
  v_ip := trim(split_part(coalesce(
            current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1));

  if p_device_id is null or length(p_device_id) not between 3 and 100 then
    return json_build_object('status', 'invalid_device');
  end if;

  -- Maksimal 10 percobaan gagal per menit per perangkat / IP.
  select count(*) into v_fail from public.activation_attempts
   where not success and created_at > now() - interval '1 minute'
     and (device_id = p_device_id or (v_ip <> '' and ip = v_ip));
  if v_fail >= 10 then
    return json_build_object('status', 'rate_limited');
  end if;

  -- Terima "BDT-XXXX-XXXX", "bdtxxxxxxxx", atau isi QR "bdt://aktivasi?kode=BDT-XXXX-XXXX".
  v_raw := upper(coalesce(p_code, ''));
  if position('KODE=' in v_raw) > 0 then
    v_raw := substr(v_raw, position('KODE=' in v_raw) + 5);
  end if;
  v_raw := regexp_replace(v_raw, '[^A-Z0-9]', '', 'g');
  if left(v_raw, 3) = 'BDT' then v_raw := substr(v_raw, 4); end if;
  if length(v_raw) = 8 then
    v_code := 'BDT-' || substr(v_raw, 1, 4) || '-' || substr(v_raw, 5, 4);
  end if;

  select * into c from public.activation_codes where code = v_code for update;
  if not found or c.status = 'revoked' then
    insert into public.activation_attempts (device_id, ip, success) values (p_device_id, v_ip, false);
    return json_build_object('status', 'invalid');
  end if;

  if c.status = 'active' then
    if c.device_id is distinct from p_device_id then
      return json_build_object('status', 'used');
    end if;
    v_re := true;                                   -- perangkat sama, misal install ulang
  else
    update public.activation_codes
       set status = 'active', device_id = p_device_id, activated_at = now()
     where id = c.id
    returning * into c;
    insert into public.logs (actor_id, action, sale_id, detail) values (null, 'aktivasi', c.sale_id, p_device_id);
  end if;

  insert into public.activation_attempts (device_id, ip, success) values (p_device_id, v_ip, true);
  select * into s from public.sales where id = c.sale_id;

  return json_build_object(
    'status', 'ok', 'reactivated', v_re, 'kode', c.code, 'nota', s.invoice,
    'jumlah_bantal', s.qty, 'activated_at', c.activated_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. KEAMANAN: ROW LEVEL SECURITY + HAK AKSES
-- ---------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.settings            enable row level security;
alter table public.sales               enable row level security;
alter table public.activation_codes    enable row level security;
alter table public.logs                enable row level security;
alter table public.activation_attempts enable row level security;   -- tanpa policy = tertutup

create policy "profil: diri sendiri atau admin" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or public.is_admin());
create policy "profil: hanya admin yang mengubah" on public.profiles
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "pengaturan: dibaca semua yang login" on public.settings
  for select to authenticated using (true);
create policy "pengaturan: hanya admin yang mengubah" on public.settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "penjualan: milik sendiri atau admin" on public.sales
  for select to authenticated using (seller_id = (select auth.uid()) or public.is_admin());

create policy "kode: mengikuti penjualannya" on public.activation_codes
  for select to authenticated using (exists (
    select 1 from public.sales s
     where s.id = sale_id and (s.seller_id = (select auth.uid()) or public.is_admin())));

create policy "log: hanya admin" on public.logs
  for select to authenticated using (public.is_admin());

-- Tabel tidak bisa diubah langsung dari web; semua perubahan lewat fungsi di atas.
revoke all on all tables in schema public from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.settings, public.sales,
                public.activation_codes, public.logs to authenticated;
grant update (name, role, active) on public.profiles to authenticated;
grant update (shop_name, address, phone, price_per_pillow, paper_mm,
              invoice_prefix, footer, updated_at) on public.settings to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin(), public.is_active_seller() to authenticated;
grant execute on function public.create_sale(int, int, text, text, uuid) to authenticated;
grant execute on function public.record_print(uuid)               to authenticated;
grant execute on function public.replace_code(uuid, text)         to authenticated;
grant execute on function public.revoke_code(uuid, text)          to authenticated;
grant execute on function public.activate_code(text, text)        to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. SETELAH MEMBUAT AKUN ADMIN PERTAMA (Authentication > Users > Add user),
--    jalankan baris ini dengan email Anda:
--
--    update public.profiles set role = 'admin', active = true, name = 'Maretha'
--     where email = 'email-anda@contoh.com';
-- ---------------------------------------------------------------------
