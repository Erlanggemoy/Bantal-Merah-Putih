-- =====================================================================
--  Migrasi 04: Akun penjual dengan username + data invoice bersama
--  - Admin membuat akun dari web (Pengaturan > Akun penjual) cukup
--    dengan nama, username, dan kata sandi. Tanpa email: di belakang
--    layar Supabase memakai email bayangan  username@bdt.local
--  - Semua penjual aktif melihat SEMUA invoice (data sinkron).
--    Kelola (hapus/ganti/cabut) tetap hanya pemilik invoice atau admin.
--  - Perubahan invoice dikirim langsung (realtime) ke web lain yang terbuka.
--  Jalankan SETELAH migrasi-03. Aman dijalankan ulang.
-- =====================================================================

-- 1. Data bersama: semua penjual aktif boleh membaca semua invoice & kode.
drop policy if exists "penjualan: milik sendiri atau admin" on public.sales;
drop policy if exists "penjualan: semua penjual aktif" on public.sales;
create policy "penjualan: semua penjual aktif" on public.sales
  for select to authenticated using (public.is_active_seller());

drop policy if exists "kode: mengikuti penjualannya" on public.activation_codes;
drop policy if exists "kode: semua penjual aktif" on public.activation_codes;
create policy "kode: semua penjual aktif" on public.activation_codes
  for select to authenticated using (public.is_active_seller());

-- Nama kasir di riwayat: semua penjual aktif boleh melihat daftar profil.
drop policy if exists "profil: diri sendiri atau admin" on public.profiles;
drop policy if exists "profil: diri sendiri atau penjual aktif" on public.profiles;
create policy "profil: diri sendiri atau penjual aktif" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or public.is_active_seller());

-- 2. Buat akun penjual (khusus admin).
create or replace function public.admin_create_seller(
  p_username text, p_password text, p_name text, p_role text default 'penjual')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_user text; v_email text;
begin
  if not public.is_admin() then raise exception 'Hanya admin yang dapat menambah akun.'; end if;
  v_user := lower(trim(coalesce(p_username, '')));
  if v_user !~ '^[a-z0-9._]{3,20}$' then
    raise exception 'Username 3-20 karakter: huruf kecil, angka, titik, atau garis bawah.';
  end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'Kata sandi minimal 6 karakter.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Nama minimal 2 karakter.'; end if;
  if p_role not in ('admin', 'penjual') then raise exception 'Peran tidak valid.'; end if;
  v_email := v_user || '@bdt.local';
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'Username % sudah dipakai.', v_user;
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', trim(p_name)), now(), now(), '', '', '', '');

  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
    'email', now(), now(), now());

  -- Profil dibuat otomatis oleh trigger; langsung aktifkan.
  update public.profiles set name = trim(p_name), role = p_role, active = true where id = v_id;
  insert into public.logs (actor_id, action, detail) values (auth.uid(), 'tambah_akun', v_user || ' (' || p_role || ')');
  return v_id;
end;
$$;

-- 3. Aktifkan / nonaktifkan akun (khusus admin, tidak bisa diri sendiri).
create or replace function public.admin_set_seller_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya admin yang dapat mengubah akun.'; end if;
  if p_id = auth.uid() then raise exception 'Tidak bisa menonaktifkan akun sendiri.'; end if;
  update public.profiles set active = p_active where id = p_id;
  if not found then raise exception 'Akun tidak ditemukan.'; end if;
  insert into public.logs (actor_id, action, detail)
  values (auth.uid(), case when p_active then 'aktifkan_akun' else 'nonaktifkan_akun' end, p_id::text);
end;
$$;

-- 4. Ganti kata sandi akun (khusus admin).
create or replace function public.admin_set_seller_password(p_id uuid, p_password text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Hanya admin yang dapat mengganti kata sandi.'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'Kata sandi minimal 6 karakter.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
   where id = p_id;
  if not found then raise exception 'Akun tidak ditemukan.'; end if;
  insert into public.logs (actor_id, action, detail) values (auth.uid(), 'ganti_sandi_akun', p_id::text);
end;
$$;

revoke execute on function public.admin_create_seller(text, text, text, text) from public, anon;
revoke execute on function public.admin_set_seller_active(uuid, boolean)      from public, anon;
revoke execute on function public.admin_set_seller_password(uuid, text)       from public, anon;
grant  execute on function public.admin_create_seller(text, text, text, text) to authenticated;
grant  execute on function public.admin_set_seller_active(uuid, boolean)      to authenticated;
grant  execute on function public.admin_set_seller_password(uuid, text)       to authenticated;

-- 5. Realtime: web lain langsung menerima invoice baru / perubahan kode.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sales') then
    alter publication supabase_realtime add table public.sales;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'activation_codes') then
    alter publication supabase_realtime add table public.activation_codes;
  end if;
end $$;
