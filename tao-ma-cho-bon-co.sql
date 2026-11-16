-- Run only in SQL Editor as project owner. Copy the displayed codes and share each with its teacher.
-- Existing codes are preserved. The result contains codes generated on this run.
with new_codes as materialized (
  select t.slug, t.name, upper(encode(extensions.gen_random_bytes(10), 'hex')) as code
  from public.cay_teachers t
  where t.slug in ('co-1', 'co-2', 'co-3', 'co-4')
    and not exists (select 1 from cay_private.teacher_passcodes c where c.teacher_slug = t.slug)
), saved as (
  insert into cay_private.teacher_passcodes (teacher_slug, code_hash)
  select n.slug, extensions.digest(n.code, 'sha256') from new_codes n
  on conflict (teacher_slug) do nothing
  returning teacher_slug
)
select n.slug, n.name, regexp_replace(n.code, '(.{5})(?=.)', '\1-', 'g') as passcode
from new_codes n join saved s on s.teacher_slug = n.slug
order by n.slug;
