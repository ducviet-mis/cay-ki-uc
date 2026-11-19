begin;

create or replace function cay_private.roster_name_key(p_name text)
returns text language sql immutable security invoker set search_path = ''
as $$
  select upper(regexp_replace(btrim(pg_catalog.normalize(p_name, 'NFC')), '[[:space:]]+', ' ', 'g'))
$$;
revoke all on function cay_private.roster_name_key(text) from public, anon, authenticated;

create or replace function cay_private.save_student_roster(p_rows jsonb, p_expected_rows jsonb)
returns table (number integer, name text)
language plpgsql security definer set search_path = ''
as $$
declare
  current_rows jsonb;
  changes jsonb;
  highest_number integer;
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Bạn cần quyền quản lý để lưu danh sách lớp.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_typeof(p_expected_rows) is distinct from 'array' then
    raise exception using errcode='22023', message='Danh sách lớp không hợp lệ.';
  end if;
  if jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 10000 then
    raise exception using errcode='22023', message='Danh sách cần có từ 1 đến 10.000 học sinh.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_rows) as item(value)
    where jsonb_typeof(value) is distinct from 'object'
       or jsonb_typeof(value->'number') is distinct from 'number'
       or coalesce(value->>'number','') !~ '^[0-9]{1,5}$'
       or jsonb_typeof(value->'name') is distinct from 'string'
       or length(btrim(value->>'name')) not between 1 and 100
       or (value ? 'class_roster' and jsonb_typeof(value->'class_roster') is distinct from 'boolean')
  ) then
    raise exception using errcode='22023', message='Mỗi dòng cần mã số và tên học sinh hợp lệ.';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_rows) as r(number integer)
    where r.number not between 1 and 10000
  ) or exists (
    select r.number from jsonb_to_recordset(p_rows) as r(number integer)
    group by r.number having count(*) > 1
  ) then
    raise exception using errcode='22023', message='Mã học sinh phải từ 1 đến 10.000 và không được trùng.';
  end if;

  -- Serialize roster writes and reject edits based on an older admin screen.
  lock table public.cay_students in share row exclusive mode;
  select coalesce(jsonb_agg(jsonb_build_object('number',s.number,'name',s.name) order by s.number),'[]'::jsonb)
  into current_rows from public.cay_students s;
  if current_rows is distinct from (
    select coalesce(jsonb_agg(jsonb_build_object('number',r.number,'name',r.name) order by r.number),'[]'::jsonb)
    from jsonb_to_recordset(p_expected_rows) as r(number integer,name text)
  ) then
    raise exception using errcode='PT409', message='Danh sách lớp vừa được thay đổi. Hãy tải lại trang quản lý rồi thử lại.';
  end if;

  -- Equal names keep their stored IDs. Equal names at different IDs need an exact ID match.
  if exists (
    select 1 from jsonb_to_recordset(p_rows) as r(number integer,name text)
    where (select count(*) from public.cay_students s
           where cay_private.roster_name_key(s.name)=cay_private.roster_name_key(r.name)) > 1
      and not exists (select 1 from public.cay_students s where s.number=r.number
          and cay_private.roster_name_key(s.name)=cay_private.roster_name_key(r.name))
  ) then
    raise exception using errcode='22023', message='Có học sinh trùng họ tên. Hãy giữ mã hiện tại cho những tên này.';
  end if;

  with incoming as (
    select r.number as input_number,btrim(r.name) as name,
           coalesce(r.class_roster,true) as class_roster, r.ordinality,
           (select s.number from public.cay_students s
            where cay_private.roster_name_key(s.name)=cay_private.roster_name_key(r.name)
            order by (s.number=r.number) desc,s.number limit 1) as matched_number
    from rows from (jsonb_to_recordset(p_rows) as (number integer,name text,class_roster boolean))
         with ordinality as r(number,name,class_roster,ordinality)
  ), mapped as (
    select i.*,
      case when matched_number is not null then matched_number
        when not exists (select 1 from public.cay_students s where s.number=i.input_number) then input_number
        when not exists (select 1 from incoming other where other.matched_number=i.input_number) then input_number
      end as number
    from incoming i
  )
  select jsonb_agg(jsonb_build_object('number',m.number,'name',m.name,'class_roster',m.class_roster)
                   order by m.ordinality) into changes from mapped m;

  if exists (
    select r.number from jsonb_to_recordset(changes) as r(number integer)
    where r.number is not null group by r.number having count(*)>1
  ) then
    raise exception using errcode='22023', message='Danh sách đang ghép nhiều dòng vào cùng học sinh. Hãy kiểm tra lại tên và mã.';
  end if;
  select greatest(coalesce((select max(s.number) from public.cay_students s),0),
                  coalesce((select max(r.number) from jsonb_to_recordset(changes) as r(number integer)),0))
  into highest_number;

  -- Allocate new IDs above all reserved IDs, so inserted students cannot inherit a classmate's account.
  with numbered as (
    select r.*, count(*) filter (where r.number is null) over (order by r.ordinality) as new_offset
    from rows from (jsonb_to_recordset(changes) as (number integer,name text,class_roster boolean))
         with ordinality as r(number,name,class_roster,ordinality)
  )
  select jsonb_agg(jsonb_build_object('number',coalesce(r.number,highest_number+r.new_offset),
      'name',r.name,'class_roster',r.class_roster) order by r.ordinality)
  into changes from numbered r;
  if exists (select 1 from jsonb_to_recordset(changes) as r(number integer) where r.number > 10000) then
    raise exception using errcode='22023', message='Danh sách đã vượt quá 10.000 mã học sinh.';
  end if;

  insert into public.cay_students as target(number,name,class_roster)
    select r.number,r.name,r.class_roster from jsonb_to_recordset(changes) as r(number integer,name text,class_roster boolean)
  on conflict on constraint cay_students_pkey do update set name=excluded.name,class_roster=excluded.class_roster;

  return query select s.number,s.name from public.cay_students s order by s.number;
end;
$$;
revoke all on function cay_private.save_student_roster(jsonb,jsonb) from public, anon, authenticated;
grant execute on function cay_private.save_student_roster(jsonb,jsonb) to authenticated;

create or replace function public.cay_save_student_roster(p_rows jsonb,p_expected_rows jsonb)
returns table (number integer,name text)
language sql security invoker set search_path = ''
begin atomic
  select r.number,r.name from cay_private.save_student_roster(p_rows,p_expected_rows) as r;
end;
revoke all on function public.cay_save_student_roster(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.cay_save_student_roster(jsonb,jsonb) to authenticated;
notify pgrst, 'reload schema';

commit;
