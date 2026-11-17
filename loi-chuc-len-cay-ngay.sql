begin;

-- Keep the transition and new submissions from publishing out of order.
lock table cay_private.submissions in share row exclusive mode;

create or replace function cay_private.finish_student_submission(p_id uuid,p_photo_count integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  sent cay_private.submissions%rowtype;
begin
  if not exists (select 1 from cay_private.student_account()) then
    raise insufficient_privilege using message = 'Bạn cần xác nhận tên trong danh sách lớp trước khi gửi bài.';
  end if;
  select * into sent from cay_private.submissions s
  where s.id = p_id and s.author_id = (select auth.uid());
  if p_photo_count > 0 and coalesce(sent.story,'') = '' then
    raise exception using errcode = '22023', message = 'Chỉ lời nhắn riêng mới có thể đính kèm ảnh.';
  end if;
  if sent.wish <> '' then
    perform pg_advisory_xact_lock(hashtextextended('cay_publish_submissions',137952));
  end if;
  perform public.cay_finish_submission(p_id,p_photo_count);
  if coalesce(sent.wish,'') = '' then return; end if;

  select * into strict sent from cay_private.submissions s
  where s.id = p_id and s.author_id = (select auth.uid());
  if sent.published_at is not null or exists (
    select 1 from cay_private.submissions s
    where s.teacher_slug = sent.teacher_slug and s.student_number = sent.student_number
      and s.wish <> '' and (s.submitted_at,s.id) > (sent.submitted_at,sent.id)
  ) then
    return;
  end if;

  insert into public.cay_messages(teacher_slug,student_number,wish,note_date)
  values (sent.teacher_slug,sent.student_number,sent.wish,to_char(sent.submitted_at at time zone 'Asia/Ho_Chi_Minh','DD/MM/YYYY'))
  on conflict (teacher_slug,student_number) do update
  set wish=excluded.wish,note_date=excluded.note_date;
  update cay_private.submissions set published_at=now() where id=sent.id;
end;
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
    select s.id,s.teacher_slug,s.student_number,s.student_name,m.wish,''::text,s.submitted_at,0
    from (
      select distinct on (item.teacher_slug,item.student_number) item.*
      from cay_private.submissions item
      where item.published_at is not null and item.wish <> ''
      order by item.teacher_slug,item.student_number,item.published_at desc,item.submitted_at desc,item.id desc
    ) s
    join public.cay_messages m on m.teacher_slug=s.teacher_slug and m.student_number=s.student_number
    order by s.teacher_slug,s.student_number;
end;
$$;

-- Publish the newest submitted wish for each recipient and student.
with latest as (
  select distinct on (s.teacher_slug,s.student_number) s.*
  from cay_private.submissions s
  where s.submitted_at is not null and s.wish <> ''
  order by s.teacher_slug,s.student_number,s.submitted_at desc,s.id desc
), live as (
  insert into public.cay_messages(teacher_slug,student_number,wish,note_date)
  select s.teacher_slug,s.student_number,s.wish,to_char(s.submitted_at at time zone 'Asia/Ho_Chi_Minh','DD/MM/YYYY')
  from latest s where s.published_at is null
  on conflict (teacher_slug,student_number) do update set wish=excluded.wish,note_date=excluded.note_date
  returning teacher_slug,student_number
)
update cay_private.submissions s set published_at=now()
from latest l join live m using (teacher_slug,student_number)
where s.id=l.id;

notify pgrst, 'reload schema';
commit;
