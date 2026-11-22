-- السوق العام — أنواع الخدمات (شغّله مرة وحدة في Supabase ← SQL Editor، بعد general.sql)
alter table public.ar_ads drop constraint if exists ar_ads_cat_check;
alter table public.ar_ads add constraint ar_ads_cat_check check (cat in (
  'cars','realestate','phones','furniture','appliances','fashion','kids','sports','animals','equipment','services','jobs','other',
  'svc_maint','svc_ac','svc_elec','svc_clean','svc_move','svc_build','svc_car','svc_teach','svc_design','svc_events','svc_beauty','svc_tech',
  'khanjar','silver','gems','coins','brass','wood','vintage','books','misc'));

create or replace function public.ar_list(p_cat text, p_gov text, p_area text, p_q text, p_sort text, p_limit int, p_offset int)
returns table(id uuid, created_at timestamptz, title text, cat text, price numeric, cond text, gov text, area text, descr text, photos text[], status text, seller text, phone text, wa text, email text)
language sql stable security definer set search_path = public as $$
  select a.id, a.created_at, a.title, a.cat, a.price, a.cond, a.gov, a.area, a.descr, a.photos, a.status, s.name, s.phone, s.wa, s.email
  from ar_ads a join ar_sellers s on s.id = a.seller_id
  where a.status in ('active','sold') and a.expires_at > now() and s.status = 'ok'
    and (coalesce(p_cat,'') in ('','all')
         or (p_cat = 'heritage' and a.cat in ('khanjar','silver','gems','coins','brass','wood','vintage','books','misc'))
         or (p_cat = 'services' and (a.cat = 'services' or a.cat like 'svc\_%'))
         or a.cat = p_cat)
    and (coalesce(p_gov,'') = '' or a.gov = p_gov)
    and (coalesce(p_area,'') = '' or a.area = p_area)
    and (coalesce(p_q,'') = '' or a.title ilike '%' || p_q || '%' or a.descr ilike '%' || p_q || '%')
  order by (a.status = 'sold'),
    case when p_sort = 'low'  then a.price end asc,
    case when p_sort = 'high' then a.price end desc,
    a.created_at desc
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
$$;
grant execute on function public.ar_list(text, text, text, text, text, int, int) to anon, authenticated;
