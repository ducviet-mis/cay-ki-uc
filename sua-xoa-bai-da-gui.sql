alter table cay_private.submissions
  add column wish_deleted_at timestamptz,
  add column note_deleted_at timestamptz;

-- Consider deleted versions here so removing the latest wish does not restore an older one.
create function cay_private.active_student_wish(p_teacher_slug text, p_student_number integer)
returns uuid language sql stable set search_path = '' as $$
  select s.id
  from cay_private.submissions s
  where s.teacher_slug = p_teacher_slug and s.student_number = p_student_number
    and s.wish <> '' and s.published_at is not null
  order by s.published_at desc, s.submitted_at desc, s.id desc
  limit 1
$$;

create function cay_private.student_history()
returns table(id uuid, teacher_slug text, kind text, body text, submitted_at timestamptz,
              photo_count integer, on_tree boolean)
language sql stable security definer set search_path = '' as $$
  with own as (
    select s.*, cay_private.active_student_wish(s.teacher_slug, s.student_number) as active_wish
    from cay_private.submissions s
    where s.author_id = (select cay_private.google_student_user()) and s.submitted_at is not null
  )
  select history.* from (
    select s.id, s.teacher_slug, 'chuc'::text as kind,
           case when s.id = s.active_wish then coalesce(nullif(m.wish, ''), s.wish) else s.wish end as body,
           s.submitted_at, 0 as photo_count,
           coalesce(s.id = s.active_wish and m.wish ~ '[^[:space:]]', false) as on_tree
    from own s
    left join public.cay_messages m using (teacher_slug, student_number)
    where s.wish <> '' and s.wish_deleted_at is null
    union all
    select s.id, s.teacher_slug, 'nhan', s.story, s.submitted_at, cardinality(s.photo_paths),
           not exists (
             select 1 from own newer
             where newer.teacher_slug = s.teacher_slug and newer.student_number = s.student_number
               and (newer.story <> '' or cardinality(newer.photo_paths) > 0)
               and (newer.submitted_at, newer.id) > (s.submitted_at, s.id)
           )
    from own s
    where (s.story <> '' or cardinality(s.photo_paths) > 0) and s.note_deleted_at is null
  ) history
  order by history.submitted_at desc, history.id desc, history.kind
$$;

create function cay_private.change_own_submission(p_id uuid, p_kind text, p_body text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  author uuid := cay_private.google_student_user();
  content text := regexp_replace(p_body, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  sent cay_private.submissions%rowtype;
begin
  if p_kind is null or p_kind not in ('chuc', 'nhan') then
    raise exception using errcode = '22023', message = 'Loại bài gửi không hợp lệ.';
  end if;

  -- Use the same lock as sending wishes and importing the admin spreadsheet.
  perform pg_advisory_xact_lock(hashtextextended('cay_publish_submissions', 137952));
  select s.* into sent
  from cay_private.submissions s
  where s.id = p_id and s.author_id = author and s.submitted_at is not null
    and ((p_kind = 'chuc' and s.wish <> '')
      or (p_kind = 'nhan' and (s.story <> '' or cardinality(s.photo_paths) > 0)))
  for update;

  if not found then
    raise exception using errcode = 'PT404', message = 'Không tìm thấy bài đã gửi.';
  end if;

  if (p_kind = 'chuc' and sent.wish_deleted_at is not null)
      or (p_kind = 'nhan' and sent.note_deleted_at is not null) then
    if p_body is null then
      return;
    end if;
    raise exception using errcode = 'PT404', message = 'Không tìm thấy bài đã gửi.';
  end if;

  if p_kind = 'chuc' then
    if content = '' or char_length(content) > 3000 then
      raise exception using errcode = '22023', message = 'Lời chúc cần có nội dung và tối đa 3.000 ký tự.';
    end if;
    update cay_private.submissions
    set wish = coalesce(content, wish), wish_deleted_at = case when content is null then now() end
    where id = sent.id;
    if sent.id = cay_private.active_student_wish(sent.teacher_slug, sent.student_number) then
      update public.cay_messages set wish = coalesce(content, '')
      where teacher_slug = sent.teacher_slug and student_number = sent.student_number;
    end if;
  else
    if content = '' or char_length(content) > 12000 then
      raise exception using errcode = '22023', message = 'Lời nhắn cần có nội dung và tối đa 12.000 ký tự.';
    end if;
    update cay_private.submissions
    set story = coalesce(content, story), note_deleted_at = case when content is null then now() end
    where id = sent.id;
  end if;
end
$$;

create function public.cay_student_history()
returns table(id uuid, teacher_slug text, kind text, body text, submitted_at timestamptz,
              photo_count integer, on_tree boolean)
language sql stable set search_path = '' as $$
  select * from cay_private.student_history()
$$;

create function public.cay_change_own_submission(p_id uuid, p_kind text, p_body text)
returns void language sql set search_path = '' as $$
  select cay_private.change_own_submission(p_id, p_kind, p_body)
$$;

revoke all on function cay_private.active_student_wish(text, integer) from public, anon, authenticated;
revoke all on function cay_private.student_history(), public.cay_student_history(),
  cay_private.change_own_submission(uuid, text, text), public.cay_change_own_submission(uuid, text, text)
  from public, anon, authenticated;
grant execute on function cay_private.student_history(), public.cay_student_history(),
  cay_private.change_own_submission(uuid, text, text), public.cay_change_own_submission(uuid, text, text)
  to authenticated;

create or replace function cay_private.tree_notes(p_teacher_slug text)
returns table(student_number integer, story text, submitted_at timestamptz, photo_paths text[])
language sql stable security definer set search_path = '' as $$
  select latest.student_number, latest.story, latest.submitted_at, latest.photo_paths
  from (
    select distinct on (s.student_number) s.student_number, s.story, s.submitted_at, s.photo_paths, s.note_deleted_at
    from cay_private.submissions s
    where s.teacher_slug = p_teacher_slug and s.submitted_at is not null
      and (s.story <> '' or cardinality(s.photo_paths) > 0)
      and (s.author_id = (select auth.uid()) or (select cay_private.can_read_received_note(p_teacher_slug)))
    order by s.student_number, s.submitted_at desc, s.id desc
  ) latest
  where latest.note_deleted_at is null
$$;

create or replace function cay_private.owns_submitted_photo(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from cay_private.submissions s
    where (s.author_id = (select auth.uid()) or cay_private.can_read_received_note(s.teacher_slug))
      and s.submitted_at is not null and s.note_deleted_at is null and s.photo_paths @> array[p_path]
  )
$$;

create or replace function public.cay_read_own_submission(p_id uuid default null)
returns table(teacher_slug text, student_name text, wish text, story text, submitted_at timestamptz, photo_paths text[])
language sql stable security definer set search_path = '' as $$
  select s.teacher_slug, s.student_name,
         case when s.wish_deleted_at is not null then ''
              when s.wish <> '' and s.id = cay_private.active_student_wish(s.teacher_slug, s.student_number)
                then coalesce(nullif(m.wish, ''), s.wish)
              else s.wish end,
         case when s.note_deleted_at is null then s.story else '' end,
         s.submitted_at, case when s.note_deleted_at is null then s.photo_paths else '{}'::text[] end
  from cay_private.submissions s
  left join public.cay_messages m using (teacher_slug, student_number)
  where s.author_id = (select auth.uid()) and s.submitted_at is not null
    and (p_id is null or s.id = p_id)
    and ((s.wish <> '' and s.wish_deleted_at is null)
      or ((s.story <> '' or cardinality(s.photo_paths) > 0) and s.note_deleted_at is null))
  order by s.submitted_at desc, s.id desc
  limit 1
$$;

create or replace function cay_private.student_submissions()
returns table(id uuid, teacher_slug text, submitted_at timestamptz, published_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select s.id, s.teacher_slug, s.submitted_at,
         case when s.wish = '' or s.wish_deleted_at is not null then s.submitted_at else s.published_at end
  from cay_private.submissions s
  where s.author_id = (select cay_private.google_student_user()) and s.submitted_at is not null
    and ((s.wish <> '' and s.wish_deleted_at is null)
      or ((s.story <> '' or cardinality(s.photo_paths) > 0) and s.note_deleted_at is null))
  order by s.submitted_at desc,s.id desc
$$;

CREATE OR REPLACE FUNCTION public.cay_export_submissions()
 RETURNS TABLE(id uuid, teacher_slug text, student_number integer, student_name text, wish text, story text, submitted_at timestamp with time zone, photo_count integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Cần quyền quản lý để xuất lời chúc.';
  end if;
  return query
    select s.id,s.teacher_slug,s.student_number,s.student_name,m.wish,''::text,s.submitted_at,0
    from (
      select distinct on (item.teacher_slug,item.student_number) item.*
      from cay_private.submissions item
      where item.published_at is not null and item.wish <> ''
      order by item.teacher_slug,item.student_number,item.published_at desc,item.submitted_at desc,item.id desc
    ) s
    join public.cay_messages m on m.teacher_slug=s.teacher_slug and m.student_number=s.student_number
    where s.wish_deleted_at is null
    order by s.teacher_slug,s.student_number;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cay_publish_submissions(p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  item record;
  original cay_private.submissions%rowtype;
  seen text[] := '{}';
  item_key text;
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Cần quyền quản lý để đưa lời chúc lên cây.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Chọn từ 1 đến 500 lời chúc trong mỗi lần nhập.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cay_publish_submissions',137952));
  for item in select * from jsonb_to_recordset(p_rows) as input(
    submission_id uuid,teacher_slug text,student_number integer,wish text,note_date text
  ) loop
    select * into original from cay_private.submissions s
      where s.id = item.submission_id and s.submitted_at is not null and s.wish <> '' and s.wish_deleted_at is null;
    if not found or original.teacher_slug is distinct from item.teacher_slug
        or original.student_number is distinct from item.student_number then
      raise exception using errcode = '22023', message = 'Mã lời chúc cần khớp với cô nhận và số thứ tự đã xuất.';
    end if;
    item_key := item.teacher_slug || '/' || item.student_number::text;
    if item_key = any(seen) then
      raise exception using errcode = '22023', message = 'Tệp có nhiều lời chúc của cùng một bạn gửi cho cùng một cô.';
    end if;
    seen := array_append(seen,item_key);
    if char_length(coalesce(item.wish,'')) > 3000 or char_length(coalesce(item.note_date,'')) > 80 then
      raise exception using errcode = '22023', message = 'Kiểm tra lại độ dài lời chúc và ngày gửi.';
    end if;
    insert into public.cay_students(number,name) values (original.student_number,original.student_name)
      on conflict (number) do nothing;
    insert into public.cay_messages(teacher_slug,student_number,wish,story,note_date,photo_paths)
      values (original.teacher_slug,original.student_number,coalesce(item.wish,''),'',coalesce(item.note_date,''),'{}')
      on conflict (teacher_slug,student_number) do update
        set wish=excluded.wish,note_date=excluded.note_date;
    update cay_private.submissions set published_at=now() where id=original.id;
  end loop;
  return cardinality(seen);
end;
$function$;
