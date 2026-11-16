begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists cay_private.teacher_passcodes (
  teacher_slug text primary key references public.cay_teachers(slug) on delete cascade,
  code_hash bytea not null unique check (octet_length(code_hash) = 32)
);

create table if not exists cay_private.guest_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code_hash bytea not null references cay_private.teacher_passcodes(code_hash) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists guest_access_code_hash_idx on cay_private.guest_access(code_hash);

alter table cay_private.teacher_passcodes enable row level security;
alter table cay_private.guest_access enable row level security;
revoke all on cay_private.teacher_passcodes, cay_private.guest_access from public, anon, authenticated, service_role;

create or replace function cay_private.redeem_passcode(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  viewer_id uuid := auth.uid();
  code text := upper(regexp_replace(p_code, '[[:space:]-]', '', 'g'));
  tree text;
begin
  if viewer_id is null or (auth.jwt() ->> 'is_anonymous') is distinct from 'true'
    or code is null or code !~ '^[0-9A-F]{20}$' then
    return null;
  end if;

  with granted as (
    insert into cay_private.guest_access (user_id, code_hash, expires_at)
    select viewer_id, c.code_hash, now() + interval '12 hours'
    from cay_private.teacher_passcodes c
    where c.code_hash = extensions.digest(code, 'sha256')
    on conflict (user_id) do update
    set code_hash = excluded.code_hash, expires_at = excluded.expires_at
    returning code_hash
  )
  select c.teacher_slug into tree
  from granted g join cay_private.teacher_passcodes c using (code_hash);

  return tree;
end;
$$;

create or replace function cay_private.guest_tree()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.teacher_slug
  from cay_private.guest_access g
  join cay_private.teacher_passcodes c using (code_hash)
  where g.user_id = (select auth.uid())
    and (auth.jwt() ->> 'is_anonymous') = 'true'
    and g.expires_at > now()
$$;

create or replace function public.cay_unlock_tree(p_code text)
returns text
language sql
security invoker
set search_path = ''
as $$ select cay_private.redeem_passcode(p_code) $$;

revoke all on function cay_private.redeem_passcode(text), cay_private.guest_tree(),
  public.cay_unlock_tree(text) from public, anon;
grant execute on function cay_private.redeem_passcode(text), cay_private.guest_tree(),
  public.cay_unlock_tree(text) to authenticated;
grant usage on schema cay_private to authenticated;

drop policy if exists cay_guest_reads_tree on public.cay_teachers;
create policy cay_guest_reads_tree on public.cay_teachers for select to authenticated
  using (slug = (select cay_private.guest_tree()));

drop policy if exists cay_guest_reads_roster on public.cay_students;
create policy cay_guest_reads_roster on public.cay_students for select to authenticated
  using ((select cay_private.guest_tree()) is not null);

drop policy if exists cay_guest_reads_wishes on public.cay_messages;
create policy cay_guest_reads_wishes on public.cay_messages for select to authenticated
  using (teacher_slug = (select cay_private.guest_tree()));

drop policy if exists cay_guest_reads_gallery on public.cay_gallery;
create policy cay_guest_reads_gallery on public.cay_gallery for select to authenticated
  using ((select cay_private.guest_tree()) is not null
    and (teacher_slug is null or teacher_slug = (select cay_private.guest_tree())));

-- The existing Storage policy already checks the caller's visible gallery and message rows.
-- Retire the unused service-role lookup from the earlier migration where present.
drop function if exists public.cay_tree_by_passcode(text);

notify pgrst, 'reload schema';
commit;
