begin;

create or replace function public.cay_read_own_submission(p_id uuid default null)
returns table (
  teacher_slug text, student_name text, wish text, story text,
  submitted_at timestamptz, photo_paths text[]
)
language sql stable security definer set search_path = ''
as $$
  select s.teacher_slug, s.student_name, s.wish, s.story, s.submitted_at, s.photo_paths
  from cay_private.submissions s
  where s.author_id = (select auth.uid())
    and s.submitted_at is not null
    and (p_id is null or s.id = p_id)
  order by s.submitted_at desc, s.id desc
  limit 1
$$;

create or replace function cay_private.owns_submitted_photo(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from cay_private.submissions s
    where s.author_id = (select auth.uid())
      and s.submitted_at is not null
      and s.photo_paths @> array[p_path]
  )
$$;

revoke all on function public.cay_read_own_submission(uuid),
  cay_private.owns_submitted_photo(text) from public, anon, authenticated;
grant execute on function public.cay_read_own_submission(uuid),
  cay_private.owns_submitted_photo(text) to authenticated;

drop policy if exists cay_submission_photo_read_owner on storage.objects;
create policy cay_submission_photo_read_owner on storage.objects
  for select to authenticated using (
    bucket_id = 'cay-ki-uc'
    and name like 'submission/%'
    and storage.allow_only_operation('storage.object.get_authenticated')
    and cay_private.owns_submitted_photo(name)
  );

notify pgrst, 'reload schema';
commit;
