begin;

create table if not exists cay_private.admin_passcode (
  singleton boolean primary key default true check (singleton),
  code_hash bytea not null unique check (octet_length(code_hash) = 32)
);

create table if not exists cay_private.admin_guest_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  session_id uuid not null,
  code_hash bytea not null references cay_private.admin_passcode(code_hash) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists admin_guest_access_code_hash_idx
  on cay_private.admin_guest_access(code_hash);

alter table cay_private.admin_passcode enable row level security;
alter table cay_private.admin_guest_access enable row level security;
revoke all on cay_private.admin_passcode, cay_private.admin_guest_access
  from public, anon, authenticated, service_role;

create or replace function cay_private.redeem_admin_passcode(p_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  viewer_id uuid := auth.uid();
  viewer_session text := auth.jwt() ->> 'session_id';
  code text := upper(regexp_replace(p_code, '[[:space:]-]', '', 'g'));
begin
  if viewer_id is null or viewer_session is null
    or (auth.jwt() ->> 'is_anonymous') is distinct from 'true'
    or code is null or code !~ '^[0-9A-F]{32}$' then
    return false;
  end if;

  insert into cay_private.admin_guest_access (user_id, session_id, code_hash, expires_at)
  select viewer_id, s.id, c.code_hash, now() + interval '2 hours'
  from cay_private.admin_passcode c
  join auth.sessions s on s.id = viewer_session::uuid and s.user_id = viewer_id
  where c.singleton and c.code_hash = extensions.digest(code, 'sha256')
  on conflict (user_id) do update set
    session_id = excluded.session_id,
    code_hash = excluded.code_hash,
    expires_at = excluded.expires_at;
  return found;
end;
$$;

create or replace function public.cay_unlock_admin(p_code text)
returns boolean
language sql
security invoker
set search_path = ''
as $$ select cay_private.redeem_admin_passcode(p_code) $$;

revoke all on function cay_private.redeem_admin_passcode(text), public.cay_unlock_admin(text)
  from public, anon;
grant execute on function cay_private.redeem_admin_passcode(text), public.cay_unlock_admin(text)
  to authenticated;

create or replace function cay_private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case when (auth.jwt() ->> 'is_anonymous') = 'true' then exists (
    select 1
    from cay_private.admin_guest_access a
    join auth.sessions s on s.id = a.session_id and s.user_id = a.user_id
    where a.user_id = (select auth.uid())
      and a.session_id = (auth.jwt() ->> 'session_id')::uuid
      and a.expires_at > now()
  ) else exists (
    select 1 from cay_private.admins where user_id = (select auth.uid())
  ) end
$$;

notify pgrst, 'reload schema';
commit;
