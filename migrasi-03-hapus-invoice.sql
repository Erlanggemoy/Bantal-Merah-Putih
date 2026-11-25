-- =====================================================================
--  Migrasi 03: Hapus invoice (diarsipkan) + aksi Kelola untuk penjual
--  - Invoice yang dihapus TIDAK dibuang dari database: ditandai
--    deleted_at/deleted_by/delete_reason, kodenya otomatis dicabut,
--    dan tidak tampil lagi di web. Nomor nota tidak bentrok.
--  - Penjual boleh menghapus, mengganti kode, dan mencabut kode untuk
--    invoice MILIKNYA SENDIRI. Admin boleh untuk semua invoice.
--  Jalankan SETELAH migrasi-02. Aman dijalankan ulang.
-- =====================================================================

alter table public.sales add column if not exists deleted_at    timestamptz;
alter table public.sales add column if not exists deleted_by    uuid;
alter table public.sales add column if not exists delete_reason text;

-- Boleh mengelola penjualan ini? (admin, atau penjual aktif pemiliknya)
create or replace function public.can_manage_sale(p_sale_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_active_seller() and exists (
    select 1 from public.sales s
     where s.id = p_sale_id and s.deleted_at is null
       and (s.seller_id = auth.uid() or public.is_admin()));
$$;

-- Hapus (arsipkan) invoice.
create or replace function public.delete_sale(p_sale_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_manage_sale(p_sale_id) then
    raise exception 'Invoice tidak ditemukan, sudah dihapus, atau bukan milik Anda.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Tulis alasan minimal 5 karakter.'; end if;
  update public.sales
     set deleted_at = now(), deleted_by = auth.uid(), delete_reason = trim(p_reason)
   where id = p_sale_id;
  update public.activation_codes
     set status = 'revoked', reason = 'Invoice dihapus: ' || trim(p_reason)
   where sale_id = p_sale_id and status <> 'revoked';
  insert into public.logs (actor_id, action, sale_id, detail)
  values (auth.uid(), 'hapus_invoice', p_sale_id, trim(p_reason));
end;
$$;

-- Ganti kode: sekarang juga untuk penjual pemilik invoice.
create or replace function public.replace_code(p_code_id uuid, p_reason text) returns json
language plpgsql security definer set search_path = '' as $$
declare v_sale_id uuid; v_code text;
begin
  select sale_id into v_sale_id from public.activation_codes where id = p_code_id;
  if v_sale_id is null or not public.can_manage_sale(v_sale_id) then
    raise exception 'Kode tidak ditemukan atau bukan milik Anda.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Tulis alasan minimal 5 karakter.'; end if;
  update public.activation_codes
     set status = 'revoked', reason = 'Diganti: ' || trim(p_reason)
   where id = p_code_id and status <> 'revoked';
  if not found then raise exception 'Kode sudah dicabut.'; end if;
  v_code := public.new_code();
  insert into public.activation_codes (sale_id, code) values (v_sale_id, v_code);
  insert into public.logs (actor_id, action, sale_id, detail) values (auth.uid(), 'ganti_kode', v_sale_id, trim(p_reason));
  return json_build_object('sale_id', v_sale_id);
end;
$$;

-- Cabut kode: sekarang juga untuk penjual pemilik invoice.
create or replace function public.revoke_code(p_code_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_sale_id uuid;
begin
  select sale_id into v_sale_id from public.activation_codes where id = p_code_id;
  if v_sale_id is null or not public.can_manage_sale(v_sale_id) then
    raise exception 'Kode tidak ditemukan atau bukan milik Anda.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Tulis alasan minimal 5 karakter.'; end if;
  update public.activation_codes set status = 'revoked', reason = trim(p_reason)
   where id = p_code_id and status <> 'revoked';
  if not found then raise exception 'Kode sudah dicabut.'; end if;
  insert into public.logs (actor_id, action, sale_id, detail) values (auth.uid(), 'cabut', v_sale_id, trim(p_reason));
end;
$$;

-- Hak akses fungsi baru (fungsi lama mempertahankan hak aksesnya).
revoke execute on function public.can_manage_sale(uuid)  from public, anon;
revoke execute on function public.delete_sale(uuid, text) from public, anon;
grant  execute on function public.can_manage_sale(uuid)  to authenticated;
grant  execute on function public.delete_sale(uuid, text) to authenticated;
