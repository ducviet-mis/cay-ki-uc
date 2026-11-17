alter policy cay_public_reads_shared_gallery on public.cay_gallery
using (teacher_slug is null and object_path like 'class/%');

alter policy cay_public_signs_shared_class_files on storage.objects
using (
  bucket_id = 'cay-ki-uc' and name like 'class/%'
  and storage.allow_only_operation('storage.object.sign_many')
  and exists (
    select 1 from public.cay_gallery g
    where g.teacher_slug is null and g.object_path = objects.name
  )
);

create function public.cay_export_current_wishes()
returns table(id uuid, teacher_slug text, student_number integer, student_name text,
              wish text, submitted_at timestamptz, note_date text, revision text)
language sql stable security invoker set search_path = '' as $$
  select r.id, r.teacher_slug, r.student_number, r.student_name, r.wish, r.submitted_at,
         m.note_date, md5(jsonb_build_array(m.wish, m.note_date)::text)
  from public.cay_export_submissions() r
  join public.cay_messages m on m.teacher_slug = r.teacher_slug and m.student_number = r.student_number
  order by r.teacher_slug, r.student_number
$$;

revoke all on function public.cay_export_current_wishes() from public, anon, authenticated;
grant execute on function public.cay_export_current_wishes() to authenticated;

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
  current_revision text;
begin
  if not cay_private.is_admin() then
    raise insufficient_privilege using message = 'Cần quyền quản lý để đưa lời chúc lên cây.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Chọn từ 1 đến 500 lời chúc trong mỗi lần nhập.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cay_publish_submissions',137952));
  for item in select * from jsonb_to_recordset(p_rows) as input(
    submission_id uuid,teacher_slug text,student_number integer,wish text,note_date text,revision text
  ) loop
    select * into original from cay_private.submissions s
      where s.id = item.submission_id and s.submitted_at is not null and s.wish <> '' and s.wish_deleted_at is null;
    if not found or original.teacher_slug is distinct from item.teacher_slug
        or original.student_number is distinct from item.student_number then
      raise exception using errcode = '22023', message = 'Mã lời chúc cần khớp với cô nhận và số thứ tự đã xuất.';
    end if;
    if cay_private.active_student_wish(original.teacher_slug, original.student_number) is distinct from original.id then
      raise sqlstate 'PT409' using message = 'Có lời chúc mới hơn hoặc bài đã bị xóa. Hãy xuất Excel mới rồi nhập lại.';
    end if;
    if item.revision is not null then
      select md5(jsonb_build_array(m.wish, m.note_date)::text) into current_revision
      from public.cay_messages m
      where m.teacher_slug = original.teacher_slug and m.student_number = original.student_number
      for update;
      if current_revision is distinct from item.revision then
        raise sqlstate 'PT409' using message = 'Lời chúc đã thay đổi sau khi xuất Excel. Hãy xuất bản mới trước khi sửa.';
      end if;
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
  end loop;
  return cardinality(seen);
end;
$function$;

notify pgrst, 'reload schema';
