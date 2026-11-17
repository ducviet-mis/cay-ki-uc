CREATE OR REPLACE FUNCTION cay_private.redeem_passcode(p_code text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if code ~ '^[0-9A-F]{20}$' then
    candidate := extensions.digest(code, 'sha256');
  elsif code ~ '^[0-9]{6}$' or code ~ '^[A-Z]{2,60}$' then
    perform cay_private.consume_pin_attempt('teacher');
    candidate := cay_private.pin_hash(code);
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
$function$;
