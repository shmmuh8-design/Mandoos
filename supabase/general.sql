-- السوق العام — ترقية «سوق التراث» لسوق عام (شغّله مرة وحدة في Supabase ← SQL Editor)
-- ما يحذف أي إعلان: يوسّع الأقسام بس، والتراث يصير «ركن التراث».

-- ١) الأقسام الجديدة (والأقسام التراثية القديمة تبقى)
alter table public.ar_ads drop constraint if exists ar_ads_cat_check;
alter table public.ar_ads add constraint ar_ads_cat_check check (cat in (
  'cars','realestate','phones','furniture','appliances','fashion','kids','sports','animals','equipment','services','jobs','other',
  'khanjar','silver','gems','coins','brass','wood','vintage','books','misc'));

-- ٢) قسم «ركن التراث» يعرض كل الأقسام التراثية مع بعض
create or replace function public.ar_list(p_cat text, p_gov text, p_area text, p_q text, p_sort text, p_limit int, p_offset int)
returns table(id uuid, created_at timestamptz, title text, cat text, price numeric, cond text, gov text, area text, descr text, photos text[], status text, seller text, phone text, wa text, email text)
language sql stable security definer set search_path = public as $$
  select a.id, a.created_at, a.title, a.cat, a.price, a.cond, a.gov, a.area, a.descr, a.photos, a.status, s.name, s.phone, s.wa, s.email
  from ar_ads a join ar_sellers s on s.id = a.seller_id
  where a.status in ('active','sold') and a.expires_at > now() and s.status = 'ok'
    and (coalesce(p_cat,'') in ('','all')
         or (p_cat = 'heritage' and a.cat in ('khanjar','silver','gems','coins','brass','wood','vintage','books','misc'))
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

-- ٣) حالة «جديد» للأغراض الجديدة
alter table public.ar_ads drop constraint if exists ar_ads_cond_check;
alter table public.ar_ads add constraint ar_ads_cond_check check (cond in ('new','excellent','good','worn','restored','needs'));
