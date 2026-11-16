begin;

create table if not exists cay_private.submissions (
  id uuid primary key,
  author_id uuid not null,
  teacher_slug text not null references public.cay_teachers(slug) on delete cascade,
  student_number integer not null check (student_number between 1 and 10000),
  student_name text not null check (char_length(student_name) between 2 and 100),
  wish text not null check (char_length(wish) <= 3000),
  story text not null check (char_length(story) <= 12000),
  photo_paths text[] not null default '{}' check (cardinality(photo_paths) <= 3),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  published_at timestamptz,
  check (wish <> '' or story <> '')
);

alter table cay_private.submissions enable row level security;
revoke all on cay_private.submissions from public, anon, authenticated;
create index if not exists cay_submissions_author_created
  on cay_private.submissions (author_id, created_at desc);
create index if not exists cay_submissions_recent_per_student
  on cay_private.submissions (teacher_slug, student_number, submitted_at desc, id desc)
  where submitted_at is not null;

create or replace function public.cay_begin_submission(
  p_id uuid, p_teacher_slug text, p_student_number integer,
  p_student_name text, p_wish text, p_story text
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  author uuid := auth.uid();
  existing cay_private.submissions%rowtype;
  student_name text := btrim(coalesce(p_student_name, ''));
  wish text := btrim(coalesce(p_wish, ''));
  story text := btrim(coalesce(p_story, ''));
begin
  if author is null then
    raise insufficient_privilege using message = 'Phiên gửi bài đã hết hạn.';
  end if;
  if p_id is null or p_student_number is null or p_student_number not between 1 and 10000
      or char_length(student_name) not between 2 and 100 or char_length(wish) > 3000 or char_length(story) > 12000
      or (wish = '' and story = '')
      or not exists (select 1 from public.cay_teachers t where t.slug = p_teacher_slug) then
    raise exception using errcode = '22023', message = 'Kiểm tra lại họ tên, số thứ tự, cô nhận và nội dung.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(author::text, 137952));
  select * into existing from cay_private.submissions s
    where s.id = p_id and s.author_id = author;
  if found then
    if existing.teacher_slug <> p_teacher_slug or existing.student_number <> p_student_number
      or existing.student_name <> student_name or existing.wish <> wish or existing.story <> story then
      raise exception using errcode = '22023', message = 'Thông tin bài gửi đã thay đổi. Vui lòng thử lại.';
    end if;
    if existing.submitted_at is null and existing.created_at < now() - interval '2 hours' then
      raise exception using errcode = 'PT410', message = 'Bài gửi nháp đã hết hạn. Bấm Gửi bài để thử lại.';
    end if;
    return existing.submitted_at is not null;
  end if;

  if (select count(*) from cay_private.submissions s
      where s.author_id = author and s.created_at >= now() - interval '1 hour') >= 16 then
    raise exception using errcode = 'PT429', message = 'Bạn đã gửi nhiều bài liên tiếp. Hãy quay lại sau ít phút.';
  end if;
  insert into cay_private.submissions (id, author_id, teacher_slug, student_number, student_name, wish, story)
    values (p_id, author, p_teacher_slug, p_student_number, student_name, wish, story);
  return false;
end;
$$;

create or replace function cay_private.accept_submission_upload(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from cay_private.submissions s
    where s.author_id = (select auth.uid()) and s.submitted_at is null
      and s.created_at >= now() - interval '2 hours'
      and p_path = any(array['submission/' || s.id::text || '/1',
                             'submission/' || s.id::text || '/2',
                             'submission/' || s.id::text || '/3'])
  )
$$;

drop policy if exists cay_submission_photo_upload on storage.objects;
create policy cay_submission_photo_upload on storage.objects
  for insert to authenticated with check (
    bucket_id = 'cay-ki-uc' and name like 'submission/%'
    and cay_private.accept_submission_upload(name)
  );

create or replace function public.cay_finish_submission(p_id uuid, p_photo_count integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  draft cay_private.submissions%rowtype;
  paths text[];
begin
  if p_photo_count is null or p_photo_count not between 0 and 3 then
    raise exception using errcode = '22023', message = 'Mỗi bài gửi có tối đa 3 ảnh.';
  end if;
  select * into draft from cay_private.submissions s
    where s.id = p_id and s.author_id = (select auth.uid()) for update;
  if not found then
    raise insufficient_privilege using message = 'Không tìm thấy bài gửi của phiên này.';
  end if;
  if draft.submitted_at is not null then return; end if;
  if draft.created_at < now() - interval '2 hours' then
    raise exception using errcode = 'PT410', message = 'Bài gửi nháp đã hết hạn. Bấm Gửi bài để thử lại.';
  end if;
  select array(select 'submission/' || p_id::text || '/' || slot::text
               from generate_series(1, p_photo_count) slot order by slot) into paths;
  if (select count(*) from storage.objects o
      where o.bucket_id = 'cay-ki-uc' and o.name = any(paths)
        and o.metadata->>'mimetype' in ('image/jpeg', 'image/png', 'image/webp')) <> p_photo_count then
    raise exception using errcode = '22023', message = 'Ảnh đính kèm chưa tải đủ. Hãy thử gửi lại.';
  end if;
  update cay_private.submissions set submitted_at = now(), photo_paths = paths where id = p_id;
end;
$$;

create or replace function public.cay_export_submissions()
returns table (
  id uuid, teacher_slug text, student_number integer, student_name text,
  wish text, story text, submitted_at timestamptz, photo_count integer
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Cần mã quản lý để xuất bài gửi.';
  end if;
  return query
    select s.id, s.teacher_slug, s.student_number, s.student_name,
      s.wish, s.story, s.submitted_at, cardinality(s.photo_paths)
    from (
      select distinct on (item.teacher_slug, item.student_number) item.*
      from cay_private.submissions item
      where item.submitted_at is not null
      order by item.teacher_slug, item.student_number, item.submitted_at desc, item.id desc
    ) s
    where s.published_at is null
    order by s.teacher_slug, s.student_number;
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
    raise insufficient_privilege using message = 'Cần mã quản lý để đưa bài gửi lên cây.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Tệp bài gửi không hợp lệ.';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Chọn từ 1 đến 500 bài gửi trong một lượt nhập.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cay_publish_submissions', 137952));
  for item in select * from jsonb_to_recordset(p_rows) as input(
    submission_id uuid, teacher_slug text, student_number integer, student_name text,
    wish text, story text, note_date text
  ) loop
    select * into original from cay_private.submissions s
      where s.id = item.submission_id and s.submitted_at is not null;
    if not found or original.teacher_slug is distinct from item.teacher_slug
        or original.student_number is distinct from item.student_number then
      raise exception using errcode = '22023', message = 'Mã bài gửi cần khớp với cô nhận và số thứ tự đã xuất.';
    end if;
    item_key := item.teacher_slug || '/' || item.student_number;
    if item_key = any(seen) then
      raise exception using errcode = '22023', message = 'Tệp có nhiều bài của cùng một bạn gửi cho cùng một cô.';
    end if;
    seen := array_append(seen, item_key);
    if char_length(btrim(coalesce(item.student_name, ''))) not between 2 and 100
        or char_length(coalesce(item.wish, '')) > 3000 or char_length(coalesce(item.story, '')) > 12000
        or char_length(coalesce(item.note_date, '')) > 80 then
      raise exception using errcode = '22023', message = 'Kiểm tra lại độ dài họ tên, lời chúc, tâm sự và ngày gửi.';
    end if;
    if (select count(*) from storage.objects o where o.bucket_id = 'cay-ki-uc'
        and o.name = any(original.photo_paths)) <> cardinality(original.photo_paths) then
      raise exception using errcode = '22023', message = 'Một bài gửi thiếu ảnh trong kho. Chưa cập nhật cây.';
    end if;

    insert into public.cay_students (number, name) values (item.student_number, btrim(item.student_name))
      on conflict (number) do update set name = excluded.name
        where cay_students.name = 'Học sinh ' || cay_students.number::text;
    insert into public.cay_messages (teacher_slug, student_number, wish, story, note_date, photo_paths)
      values (item.teacher_slug, item.student_number, coalesce(item.wish, ''), coalesce(item.story, ''),
        coalesce(item.note_date, ''), original.photo_paths)
      on conflict (teacher_slug, student_number) do update
        set wish = excluded.wish, story = excluded.story, note_date = excluded.note_date, photo_paths = excluded.photo_paths;
    update cay_private.submissions set published_at = now() where id = original.id;
  end loop;
  return cardinality(seen);
end;
$$;

revoke all on function public.cay_begin_submission(uuid,text,integer,text,text,text),
  public.cay_finish_submission(uuid,integer), public.cay_export_submissions(), public.cay_publish_submissions(jsonb),
  cay_private.accept_submission_upload(text) from public, anon, authenticated;
grant execute on function public.cay_begin_submission(uuid,text,integer,text,text,text),
  public.cay_finish_submission(uuid,integer), public.cay_export_submissions(), public.cay_publish_submissions(jsonb),
  cay_private.accept_submission_upload(text) to authenticated;

notify pgrst, 'reload schema';
commit;
