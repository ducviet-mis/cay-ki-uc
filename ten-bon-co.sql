begin;

update public.cay_teachers t
set name = labels.name
from (values
  ('co-1', 'Cô Phùng Thị Việt Hà'),
  ('co-2', 'Cô Ngô Thị Thùy Giang'),
  ('co-3', 'Cô Ngô Thị Phượng'),
  ('co-4', 'Cô Nguyễn Thị Cẩm Nhung')
) as labels(slug, name)
where t.slug = labels.slug;

create or replace function public.cay_public_teacher_names()
returns table (slug text, name text)
language sql stable security definer set search_path = ''
as $$
  select t.slug, t.name from public.cay_teachers t
  where t.slug in ('co-1', 'co-2', 'co-3', 'co-4')
  order by t.slug
$$;

revoke all on function public.cay_public_teacher_names() from public, anon, authenticated;
grant execute on function public.cay_public_teacher_names() to anon, authenticated;
notify pgrst, 'reload schema';

commit;
