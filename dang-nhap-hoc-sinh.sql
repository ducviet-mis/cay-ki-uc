begin;

alter table public.cay_students add column if not exists class_roster boolean not null default false;

create table if not exists cay_private.student_accounts (
  user_id uuid primary key references auth.users(id) on delete restrict,
  student_number integer not null unique references public.cay_students(number) on delete restrict,
  claimed_at timestamptz not null default now()
);
alter table cay_private.student_accounts enable row level security;
revoke all on cay_private.student_accounts from public, anon, authenticated;

create or replace function cay_private.google_student_user()
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null or not exists (
    select 1 from auth.identities i
    where i.user_id = current_user_id and i.provider = 'google'
  ) then
    raise insufficient_privilege using message = 'Bạn cần đăng nhập bằng Google.';
  end if;
  return current_user_id;
end;
$$;

create or replace function cay_private.student_account()
returns table (student_number integer, student_name text)
language sql stable security definer set search_path = ''
as $$
  select r.number, r.name
  from cay_private.student_accounts a
  join public.cay_students r on r.number = a.student_number
  where a.user_id = (select cay_private.google_student_user())
$$;

create or replace function cay_private.available_students()
returns table (student_number integer, student_name text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  current_user_id uuid := cay_private.google_student_user();
begin
  if exists (select 1 from cay_private.student_accounts a where a.user_id = current_user_id) then
    return;
  end if;
  return query
    select r.number, r.name
    from public.cay_students r
    where r.class_roster and not exists (
      select 1 from cay_private.student_accounts a where a.student_number = r.number
    )
    order by r.number;
end;
$$;

create or replace function cay_private.claim_student_account(p_student_number integer)
returns table (student_number integer, student_name text)
language plpgsql security definer set search_path = ''
as $$
declare
  current_user_id uuid := cay_private.google_student_user();
  current_number integer;
begin
  if not exists (select 1 from public.cay_students r where r.number = p_student_number and r.class_roster) then
    raise exception using errcode = '22023', message = 'Tên đã chọn không nằm trong danh sách lớp.';
  end if;

  insert into cay_private.student_accounts (user_id, student_number)
    values (current_user_id, p_student_number) on conflict do nothing;

  select a.student_number into current_number from cay_private.student_accounts a
    where a.user_id = current_user_id;
  if current_number is null then
    raise exception using errcode = 'PT409', message = 'Tên này đã được chọn. Bạn kiểm tra lại danh sách nhé.';
  elsif current_number <> p_student_number then
    raise exception using errcode = 'PT409', message = 'Tài khoản này đã xác nhận tên trong lớp.';
  end if;

  return query select r.number, r.name from public.cay_students r where r.number = current_number;
end;
$$;

create or replace function cay_private.student_submissions()
returns table (id uuid, teacher_slug text, submitted_at timestamptz, published_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select s.id, s.teacher_slug, s.submitted_at, s.published_at
  from cay_private.submissions s
  where s.author_id = (select cay_private.google_student_user()) and s.submitted_at is not null
  order by s.submitted_at desc, s.id desc
$$;

create or replace function public.cay_get_student_account()
returns table (student_number integer, student_name text)
language sql stable set search_path = ''
as $$ select * from cay_private.student_account() $$;

create or replace function public.cay_list_available_students()
returns table (student_number integer, student_name text)
language sql stable set search_path = ''
as $$ select * from cay_private.available_students() $$;

create or replace function public.cay_claim_student_account(p_student_number integer)
returns table (student_number integer, student_name text)
language sql set search_path = ''
as $$ select * from cay_private.claim_student_account(p_student_number) $$;

create or replace function public.cay_list_student_submissions()
returns table (id uuid, teacher_slug text, submitted_at timestamptz, published_at timestamptz)
language sql stable set search_path = ''
as $$ select * from cay_private.student_submissions() $$;

create or replace function public.cay_class_size()
returns integer
language sql stable security definer set search_path = ''
as $$
  select coalesce(nullif(count(*) filter (where class_roster), 0), count(*))::integer
  from public.cay_students
$$;

create or replace function cay_private.begin_student_submission(
  p_id uuid, p_teacher_slug text, p_wish text, p_story text
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
  return public.cay_begin_submission(p_id, p_teacher_slug, account.student_number, account.student_name, p_wish, p_story);
end;
$$;

create or replace function public.cay_begin_student_submission(
  p_id uuid, p_teacher_slug text, p_wish text, p_story text
)
returns boolean
language sql set search_path = ''
as $$ select cay_private.begin_student_submission(p_id, p_teacher_slug, p_wish, p_story) $$;

create or replace function cay_private.finish_student_submission(p_id uuid, p_photo_count integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from cay_private.student_account()) then
    raise insufficient_privilege using message = 'Bạn cần xác nhận tên trong danh sách lớp trước khi gửi bài.';
  end if;
  perform public.cay_finish_submission(p_id, p_photo_count);
end;
$$;

create or replace function public.cay_finish_student_submission(p_id uuid, p_photo_count integer)
returns void
language sql set search_path = ''
as $$ select cay_private.finish_student_submission(p_id, p_photo_count) $$;

revoke all on function cay_private.google_student_user(), cay_private.student_account(),
  cay_private.available_students(), cay_private.claim_student_account(integer), cay_private.student_submissions(),
  cay_private.begin_student_submission(uuid,text,text,text), cay_private.finish_student_submission(uuid,integer),
  public.cay_get_student_account(), public.cay_list_available_students(),
  public.cay_claim_student_account(integer), public.cay_list_student_submissions(),
  public.cay_begin_student_submission(uuid,text,text,text),
  public.cay_finish_student_submission(uuid,integer) from public, anon, authenticated;
grant execute on function cay_private.student_account(), cay_private.available_students(),
  cay_private.claim_student_account(integer), cay_private.student_submissions(),
  cay_private.begin_student_submission(uuid,text,text,text), cay_private.finish_student_submission(uuid,integer),
  public.cay_get_student_account(), public.cay_list_available_students(),
  public.cay_claim_student_account(integer), public.cay_list_student_submissions(),
  public.cay_begin_student_submission(uuid,text,text,text),
  public.cay_finish_student_submission(uuid,integer) to authenticated;
revoke all on function public.cay_class_size() from public, anon, authenticated;
grant execute on function public.cay_class_size() to anon, authenticated;

-- Keep the official roster available only to teachers, administrators and Google students who have not claimed a name.
drop policy if exists cay_guest_reads_roster on public.cay_students;

-- Student submissions now enter through cay_begin_student_submission, which derives the name and number from the account.
revoke execute on function public.cay_begin_submission(uuid,text,integer,text,text,text),
  public.cay_finish_submission(uuid,integer) from public, anon, authenticated;

drop policy if exists cay_submission_photo_upload on storage.objects;
create policy cay_submission_photo_upload on storage.objects for insert to authenticated with check (
  bucket_id = 'cay-ki-uc' and name like 'submission/%'
  and exists (select 1 from cay_private.student_account())
  and cay_private.accept_submission_upload(name)
);

notify pgrst, 'reload schema';
commit;
