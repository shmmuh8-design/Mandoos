-- العرصة: قاعدة بيانات الإعلانات + تخزين الصور — انسخ الملف كامل والصقه في SQL Editor (Database مو Logs) واضغط Run
-- نفس مشروع سُقيا وخدماتي، ونفس رمز المدير. تقدر تشغّله أكثر من مرة.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.ar_sellers (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name       text not null check (char_length(name) between 2 and 40),
  phone      text not null unique check (phone ~ '^[0-9]{10,15}$'),
  status     text not null default 'ok' check (status in ('ok','blocked')),
  code_hash  text not null
);
create table if not exists public.ar_ads (
  id         uuid primary key default gen_random_uuid(),
  seller_id  uuid not null references public.ar_sellers(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days',
  title      text not null check (char_length(title) between 3 and 70),
  cat        text not null check (cat in ('furn','home','elec','cars','old','misc')),
  price      numeric(10,3) not null check (price >= 0 and price < 10000000),
  cond       text not null check (cond in ('new','excellent','good','used','antique')),
  gov        text not null check (char_length(gov) <= 40),
  area       text not null check (char_length(area) <= 40),
  descr      text not null default '' check (char_length(descr) <= 1000),
  photos     text[] not null check (cardinality(photos) between 1 and 6),
  status     text not null default 'active' check (status in ('active','sold','hidden','blocked'))
);
create index if not exists ar_ads_list on public.ar_ads (status, created_at desc);
create table if not exists public.ar_reports (
  id         bigserial primary key,
  ad_id      uuid references public.ar_ads(id) on delete cascade,
  reason     text not null default '',
  created_at timestamptz not null default now()
);
alter table public.ar_sellers enable row level security;
alter table public.ar_ads     enable row level security;
alter table public.ar_reports enable row level security;
revoke all on public.ar_sellers, public.ar_ads, public.ar_reports from anon, authenticated;

-- الصور: مخزن عام للقراءة، والرفع للصور بس وبحجم صغير، داخل مجلد ads/
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('arsa', 'arsa', true, 1572864, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 1572864, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists "arsa upload" on storage.objects;
create policy "arsa upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'arsa' and (storage.foldername(name))[1] = 'ads' and name ~ '^ads/[0-9a-z-]{8,60}\.(jpg|png|webp)$');

-- helpers --------------------------------------------------------------
create or replace function public._ar_seller(p_phone text, p_code text) returns public.ar_sellers
language plpgsql security definer set search_path = public, extensions as $$
declare s ar_sellers;
begin
  select * into s from ar_sellers where phone = p_phone;
  if s.id is null or s.code_hash <> crypt(upper(coalesce(p_code,'')), s.code_hash) then
    perform pg_sleep(1);
    raise exception 'الرقم أو رمز الدخول غلط';
  end if;
  if s.status = 'blocked' then raise exception 'حسابك موقوف. للمراجعة راسل الإدارة'; end if;
  return s;
end $$;

create or replace function public._ar_photos(p text[]) returns text[]
language plpgsql immutable as $$
declare x text;
begin
  if p is null or cardinality(p) < 1 then raise exception 'أضف صورة وحدة على الأقل'; end if;
  if cardinality(p) > 6 then raise exception 'الحد 6 صور'; end if;
  foreach x in array p loop
    if x !~ '^ads/[0-9a-z-]{8,60}\.(jpg|png|webp)$' then raise exception 'صورة غير صحيحة'; end if;
  end loop;
  return p;
end $$;

-- public: list / one ad / report ----------------------------------------
drop function if exists public.ar_list(text, text, text, text, text, int, int);
create function public.ar_list(p_cat text, p_gov text, p_area text, p_q text, p_sort text, p_limit int, p_offset int)
returns table(id uuid, created_at timestamptz, title text, cat text, price numeric, cond text, gov text, area text, descr text, photos text[], status text, seller text, phone text)
language sql stable security definer set search_path = public as $$
  select a.id, a.created_at, a.title, a.cat, a.price, a.cond, a.gov, a.area, a.descr, a.photos, a.status, s.name, s.phone
  from ar_ads a join ar_sellers s on s.id = a.seller_id
  where a.status in ('active','sold') and a.expires_at > now() and s.status = 'ok'
    and (coalesce(p_cat,'') in ('','all') or a.cat = p_cat)
    and (coalesce(p_gov,'') = '' or a.gov = p_gov)
    and (coalesce(p_area,'') = '' or a.area = p_area)
    and (coalesce(p_q,'') = '' or a.title ilike '%' || p_q || '%' or a.descr ilike '%' || p_q || '%')
  order by (a.status = 'sold'),
    case when p_sort = 'low'  then a.price end asc,
    case when p_sort = 'high' then a.price end desc,
    a.created_at desc
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
$$;

create or replace function public.ar_report(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into ar_reports(ad_id, reason) values (p_id, left(coalesce(p_reason, ''), 300));
  -- 3 بلاغات = يختفي لين تراجعه الإدارة
  if (select count(*) from ar_reports where ad_id = p_id) >= 3 then
    update ar_ads set status = 'hidden' where id = p_id and status = 'active';
  end if;
end $$;

-- seller ------------------------------------------------------------------
create or replace function public.ar_register(p_name text, p_phone text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_code text;
begin
  if exists (select 1 from ar_sellers where phone = p_phone) then
    raise exception 'هذا الرقم مسجّل من قبل — ادخل برمز الدخول حقك';
  end if;
  if (select count(*) from ar_sellers where created_at > now() - interval '1 hour') > 60 then
    raise exception 'ضغط تسجيلات كثير، حاول بعد شوي';
  end if;
  v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
  insert into ar_sellers(name, phone, code_hash) values (trim(p_name), p_phone, crypt(v_code, gen_salt('bf')));
  return json_build_object('code', v_code);
end $$;

create or replace function public.ar_me(p_phone text, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare s ar_sellers := _ar_seller(p_phone, p_code);
begin
  return json_build_object('name', s.name, 'phone', s.phone, 'ads', coalesce((
    select json_agg(json_build_object('id', a.id, 'created_at', a.created_at, 'expires_at', a.expires_at, 'title', a.title, 'cat', a.cat,
      'price', a.price, 'cond', a.cond, 'gov', a.gov, 'area', a.area, 'descr', a.descr, 'photos', a.photos, 'status', a.status) order by a.created_at desc)
    from ar_ads a where a.seller_id = s.id), '[]'::json));
end $$;

drop function if exists public.ar_post(text, text, uuid, text, text, numeric, text, text, text, text, text[]);
create function public.ar_post(p_phone text, p_code text, p_id uuid, p_title text, p_cat text, p_price numeric, p_cond text, p_gov text, p_area text, p_descr text, p_photos text[])
returns json language plpgsql security definer set search_path = public as $$
declare s ar_sellers := _ar_seller(p_phone, p_code); v_id uuid;
begin
  perform _ar_photos(p_photos);
  if p_id is null then
    if (select count(*) from ar_ads where seller_id = s.id and created_at > now() - interval '1 day') >= 10 then
      raise exception 'الحد 10 إعلانات باليوم';
    end if;
    if (select count(*) from ar_ads where seller_id = s.id and status = 'active') >= 30 then
      raise exception 'عندك 30 إعلان شغّال. احذف أو علّم «انباع» على القديم أول';
    end if;
    insert into ar_ads(seller_id, title, cat, price, cond, gov, area, descr, photos)
    values (s.id, trim(p_title), p_cat, p_price, p_cond, p_gov, p_area, trim(coalesce(p_descr,'')), p_photos)
    returning id into v_id;
  else
    update ar_ads set title = trim(p_title), cat = p_cat, price = p_price, cond = p_cond, gov = p_gov, area = p_area,
      descr = trim(coalesce(p_descr,'')), photos = p_photos, updated_at = now()
    where id = p_id and seller_id = s.id and status <> 'blocked' returning id into v_id;
    if v_id is null then raise exception 'الإعلان مو موجود'; end if;
  end if;
  return json_build_object('id', v_id);
end $$;

create or replace function public.ar_set_status(p_phone text, p_code text, p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare s ar_sellers := _ar_seller(p_phone, p_code);
begin
  if p_status = 'deleted' then delete from ar_ads where id = p_id and seller_id = s.id; return; end if;
  if p_status not in ('active','sold') then raise exception 'حالة غير صحيحة'; end if;
  update ar_ads set status = p_status, updated_at = now(),
    expires_at = case when p_status = 'active' then greatest(expires_at, now() + interval '60 days') else expires_at end
  where id = p_id and seller_id = s.id and status in ('active','sold');
end $$;

create or replace function public.ar_delete_account(p_phone text, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare s ar_sellers := _ar_seller(p_phone, p_code);
begin
  delete from ar_sellers where id = s.id;
  return json_build_object('ok', true);
end $$;

-- admin (نفس رمز مدير سُقيا) --------------------------------------------------
create or replace function public.ar_admin_ads(p_pass text, p_status text)
returns table(id uuid, created_at timestamptz, title text, cat text, price numeric, gov text, area text, descr text, photos text[], status text, seller text, phone text, reports int)
language plpgsql security definer set search_path = public as $$
begin
  perform _check_admin(p_pass);
  return query select a.id, a.created_at, a.title, a.cat, a.price, a.gov, a.area, a.descr, a.photos, a.status, s.name, s.phone,
    (select count(*)::int from ar_reports r where r.ad_id = a.id)
  from ar_ads a join ar_sellers s on s.id = a.seller_id
  where coalesce(p_status,'') = '' or a.status = p_status
  order by (select count(*) from ar_reports r where r.ad_id = a.id) desc, a.created_at desc limit 300;
end $$;

create or replace function public.ar_admin_set(p_pass text, p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _check_admin(p_pass);
  if p_status = 'deleted' then delete from ar_ads where id = p_id; return; end if;
  if p_status not in ('active','hidden','blocked') then raise exception 'حالة غير صحيحة'; end if;
  update ar_ads set status = p_status, updated_at = now() where id = p_id;
  if p_status = 'active' then delete from ar_reports where ad_id = p_id; end if;
end $$;

create or replace function public.ar_admin_block_seller(p_pass text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _check_admin(p_pass);
  update ar_sellers set status = 'blocked' where phone = p_phone;
  update ar_ads set status = 'blocked' where seller_id = (select id from ar_sellers where phone = p_phone);
end $$;

create or replace function public.ar_admin_reports(p_pass text)
returns table(id bigint, created_at timestamptz, ad_id uuid, title text, reason text)
language plpgsql security definer set search_path = public as $$
begin
  perform _check_admin(p_pass);
  return query select r.id, r.created_at, r.ad_id, a.title, r.reason from ar_reports r left join ar_ads a on a.id = r.ad_id order by r.created_at desc limit 200;
end $$;

-- who may call what ---------------------------------------------------------
revoke all on function public._ar_seller(text, text), public._ar_photos(text[]) from public, anon, authenticated;
grant execute on function
  public.ar_list(text, text, text, text, text, int, int), public.ar_report(uuid, text),
  public.ar_register(text, text), public.ar_me(text, text),
  public.ar_post(text, text, uuid, text, text, numeric, text, text, text, text, text[]),
  public.ar_set_status(text, text, uuid, text), public.ar_delete_account(text, text),
  public.ar_admin_ads(text, text), public.ar_admin_set(text, uuid, text), public.ar_admin_block_seller(text, text), public.ar_admin_reports(text)
to anon, authenticated;
