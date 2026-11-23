-- =====================================================================
--  Migrasi 02: Paket 4 bantal + pembelian Satuan
--  - Jumlah bantal per transaksi: 1 sampai 500.
--  - Kode aktivasi HANYA dibuat untuk pembelian minimal 4 bantal.
--    Pembelian 1–3 bantal tetap tercatat dan mendapat nota, tanpa kode.
--
--  Menggantikan migrasi-01 (aturan "hanya 4 atau 9"). Tidak masalah
--  apakah migrasi-01 sudah pernah dijalankan atau belum.
--  Cara pakai: Supabase > SQL Editor > New query > tempel seluruh isi
--  file ini > Run. Aman dijalankan ulang.
-- =====================================================================

-- 1. Hapus aturan lama "hanya 4 atau 9" (kalau ada).
--    Batas 1–500 dari pembuatan tabel awal (sales_qty_check) tetap berlaku.
alter table public.sales drop constraint if exists sales_qty_4_atau_9;

-- 2. Fungsi create_sale: kode hanya untuk >= 4 bantal.
--    (create or replace mempertahankan hak akses yang sudah ada)
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

  if p_qty >= 4 then
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
