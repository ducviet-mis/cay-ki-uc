-- Run as project owner in SQL Editor. Copy and retain the returned code privately.
-- With an existing code this statement makes no change and returns no rows.
with new_code as materialized (
  select upper(encode(extensions.gen_random_bytes(16), 'hex')) as code
), saved as (
  insert into cay_private.admin_passcode (code_hash)
  select extensions.digest(code, 'sha256') from new_code
  on conflict (singleton) do nothing
  returning code_hash
)
select regexp_replace(code, '(.{4})(?=.)', '\1-', 'g') as passcode
from new_code cross join saved;
