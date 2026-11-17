begin;

-- The public tree and Excel feed contain wishes. Private notes stay with the original submission.
alter table public.cay_messages add constraint cay_public_messages_text_only
  check (story = '' and cardinality(photo_paths) = 0);

create or replace function cay_private.can_read_received_note(p_teacher_slug text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is not null and (
    p_teacher_slug = (select cay_private.guest_tree())
    or exists (select 1 from public.cay_teachers t
               where t.slug = p_teacher_slug and t.user_id = (select auth.uid()))
  )
$$;

create or replace function cay_private.tree_notes(p_teacher_slug text)
returns table (student_number integer, story text, submitted_at timestamptz, photo_paths text[])
language sql stable security definer set search_path = ''
as $$
  select distinct on (s.student_number) s.student_number, s.story, s.submitted_at, s.photo_paths
  from cay_private.submissions s
  where s.teacher_slug = p_teacher_slug and s.submitted_at is not null
    and (s.story <> '' or cardinality(s.photo_paths) > 0)
    and (s.author_id = (select auth.uid()) or (select cay_private.can_read_received_note(p_teacher_slug)))
  order by s.student_number,s.submitted_at desc,s.id desc
$$;

create or replace function public.cay_tree_notes(p_teacher_slug text)
returns table (student_number integer, story text, submitted_at timestamptz, photo_paths text[])
language sql stable set search_path = ''
as $$ select * from cay_private.tree_notes(p_teacher_slug) $$;

revoke all on function cay_private.can_read_received_note(text), cay_private.tree_notes(text),
  public.cay_tree_notes(text) from public,anon,authenticated;
grant execute on function cay_private.tree_notes(text),public.cay_tree_notes(text) to authenticated;

create or replace function cay_private.owns_submitted_photo(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from cay_private.submissions s
    where (s.author_id = (select auth.uid()) or cay_private.can_read_received_note(s.teacher_slug))
      and s.submitted_at is not null and s.photo_paths @> array[p_path]
  )
$$;

-- Old class and story assets still follow the existing gallery rules.
-- A submitted private photo can only be downloaded through the author/recipient policy.
alter policy cay_photo_read on storage.objects using (
  bucket_id = 'cay-ki-uc' and name not like 'submission/%'
  and ((select cay_private.is_admin())
    or exists (select 1 from public.cay_gallery g where g.object_path = objects.name)
    or exists (select 1 from public.cay_messages m where m.photo_paths @> array[objects.name]))
);
alter policy cay_photo_remove on storage.objects using (
  bucket_id = 'cay-ki-uc' and name not like 'submission/%' and (select cay_private.is_admin())
  and not exists (select 1 from public.cay_gallery g where g.object_path = objects.name)
  and not exists (select 1 from public.cay_messages m where m.photo_paths @> array[objects.name])
);

create or replace function cay_private.accept_submission_upload(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from cay_private.submissions s
    where s.author_id = (select auth.uid()) and s.submitted_at is null and s.story <> ''
      and s.created_at >= now() - interval '2 hours'
      and p_path = any(array['submission/' || s.id::text || '/1',
                             'submission/' || s.id::text || '/2',
                             'submission/' || s.id::text || '/3'])
  )
$$;

create or replace function cay_private.begin_student_submission(
  p_id uuid,p_teacher_slug text,p_wish text,p_story text
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  account record;
begin
  select * into account from cay_private.student_account();
  if not found then
    raise insufficient_privilege using message = 'Bạn cần xác nhận tên trong danh sách lớp trước khi gửi bài.';
  end if;
  if (btrim(coalesce(p_wish,'')) = '') = (btrim(coalesce(p_story,'')) = '') then
    raise exception using errcode = '22023', message = 'Bạn gửi lời chúc và lời nhắn riêng bằng hai biểu mẫu riêng nhé.';
  end if;
  return public.cay_begin_submission(p_id,p_teacher_slug,account.student_number,account.student_name,p_wish,p_story);
end;
$$;

create or replace function cay_private.finish_student_submission(p_id uuid,p_photo_count integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from cay_private.student_account()) then
    raise insufficient_privilege using message = 'Bạn cần xác nhận tên trong danh sách lớp trước khi gửi bài.';
  end if;
  if p_photo_count > 0 and not exists (
    select 1 from cay_private.submissions s
    where s.id = p_id and s.author_id = (select auth.uid()) and s.story <> ''
  ) then
    raise exception using errcode = '22023', message = 'Chỉ lời nhắn riêng mới có thể đính kèm ảnh.';
  end if;
  perform public.cay_finish_submission(p_id,p_photo_count);
end;
$$;

create or replace function cay_private.student_submissions()
returns table (id uuid,teacher_slug text,submitted_at timestamptz,published_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select s.id,s.teacher_slug,s.submitted_at,
         case when s.wish = '' then s.submitted_at else s.published_at end
  from cay_private.submissions s
  where s.author_id = (select cay_private.google_student_user()) and s.submitted_at is not null
  order by s.submitted_at desc,s.id desc
$$;

create or replace function public.cay_export_submissions()
returns table (
  id uuid,teacher_slug text,student_number integer,student_name text,
  wish text,story text,submitted_at timestamptz,photo_count integer
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Cần quyền quản lý để xuất lời chúc.';
  end if;
  return query
    select s.id,s.teacher_slug,s.student_number,s.student_name,s.wish,''::text,s.submitted_at,0
    from (
      select distinct on (item.teacher_slug,item.student_number) item.*
      from cay_private.submissions item
      where item.submitted_at is not null and item.wish <> ''
      order by item.teacher_slug,item.student_number,item.submitted_at desc,item.id desc
    ) s where s.published_at is null
    order by s.teacher_slug,s.student_number;
end;
$$;

create or replace function public.cay_publish_submissions(p_rows jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
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
      where s.id = item.submission_id and s.submitted_at is not null and s.wish <> '';
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
$$;

notify pgrst, 'reload schema';
commit;
