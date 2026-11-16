begin;

create table if not exists cay_private.pin_secret (
  singleton boolean primary key default true check (singleton),
  secret bytea not null
);
insert into cay_private.pin_secret (secret) values (extensions.gen_random_bytes(32))
on conflict (singleton) do nothing;

create table if not exists cay_private.pin_limits (
  scope text primary key check (scope in ('admin', 'teacher')),
  window_until timestamptz not null,
  attempts integer not null
);

alter table cay_private.pin_secret enable row level security;
alter table cay_private.pin_limits enable row level security;
revoke all on cay_private.pin_secret, cay_private.pin_limits from public, anon, authenticated, service_role;

create or replace function cay_private.pin_hash(code text)
returns bytea
language sql
stable
strict
set search_path = ''
as $$
  select extensions.hmac(convert_to(code, 'UTF8'), secret, 'sha256') from cay_private.pin_secret
$$;

create or replace function cay_private.consume_pin_attempt(p_scope text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  attempted_at timestamptz := clock_timestamp();
  max_attempts integer := case p_scope when 'admin' then 6 else 12 end;
begin
  insert into cay_private.pin_limits as current (scope, window_until, attempts)
  values (p_scope, attempted_at + interval '10 minutes', 1)
  on conflict (scope) do update set
    window_until = case when current.window_until <= attempted_at then excluded.window_until else current.window_until end,
    attempts = case when current.window_until <= attempted_at then 1 else current.attempts + 1 end
  where current.window_until <= attempted_at or current.attempts < max_attempts;
  if not found then
    raise sqlstate 'PT429' using message = 'Too many code attempts';
  end if;
end;
$$;

revoke all on function cay_private.pin_hash(text), cay_private.consume_pin_attempt(text)
  from public, anon, authenticated, service_role;

create or replace function cay_private.redeem_passcode(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  viewer_id uuid := auth.uid();
  code text := upper(regexp_replace(p_code, '[[:space:]-]', '', 'g'));
  candidate bytea;
  tree text;
begin
  if viewer_id is null or (auth.jwt() ->> 'is_anonymous') is distinct from 'true'
    or code is null then
    return null;
  end if;
  if code ~ '^[0-9]{6}$' then
    perform cay_private.consume_pin_attempt('teacher');
    candidate := cay_private.pin_hash(code);
  elsif code ~ '^[0-9A-F]{20}$' then
    candidate := extensions.digest(code, 'sha256');
  else
    return null;
  end if;

  with granted as (
    insert into cay_private.guest_access (user_id, code_hash, expires_at)
    select viewer_id, c.code_hash, now() + interval '12 hours'
    from cay_private.teacher_passcodes c
    where c.code_hash = candidate
    on conflict (user_id) do update
    set code_hash = excluded.code_hash, expires_at = excluded.expires_at
    returning code_hash
  )
  select c.teacher_slug into tree
  from granted g join cay_private.teacher_passcodes c using (code_hash);

  return tree;
end;
$$;

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
  candidate bytea;
begin
  if viewer_id is null or viewer_session is null
    or (auth.jwt() ->> 'is_anonymous') is distinct from 'true'
    or code is null then
    return false;
  end if;
  if code ~ '^[0-9]{7}$' then
    perform cay_private.consume_pin_attempt('admin');
    candidate := cay_private.pin_hash(code);
  elsif code ~ '^[0-9A-F]{32}$' then
    candidate := extensions.digest(code, 'sha256');
  else
    return false;
  end if;

  insert into cay_private.admin_guest_access (user_id, session_id, code_hash, expires_at)
  select viewer_id, s.id, c.code_hash, now() + interval '2 hours'
  from cay_private.admin_passcode c
  join auth.sessions s on s.id = viewer_session::uuid and s.user_id = viewer_id
  where c.singleton and c.code_hash = candidate
  on conflict (user_id) do update set
    session_id = excluded.session_id,
    code_hash = excluded.code_hash,
    expires_at = excluded.expires_at;
  return found;
end;
$$;

commit;
