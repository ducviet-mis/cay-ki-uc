begin;

create schema if not exists cay_private;
revoke all on schema cay_private from public;
grant usage on schema cay_private to authenticated;

create table if not exists cay_private.admins (
  singleton boolean primary key default true check (singleton),
  user_id uuid not null references auth.users(id) on delete cascade
);
alter table cay_private.admins enable row level security;
revoke all on cay_private.admins from public, anon, authenticated;
drop policy if exists cay_admins_deny_direct_access on cay_private.admins;
create policy cay_admins_deny_direct_access on cay_private.admins as restrictive
  for all to anon, authenticated using (false) with check (false);

create or replace function cay_private.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from cay_private.admins where user_id = (select auth.uid()))
$$;
revoke all on function cay_private.is_admin() from public;
grant execute on function cay_private.is_admin() to authenticated;

create or replace function public.cay_is_admin()
returns boolean language sql stable security invoker set search_path = ''
as $$ select cay_private.is_admin() $$;
revoke all on function public.cay_is_admin() from public, anon;
grant execute on function public.cay_is_admin() to authenticated;

create table if not exists public.cay_teachers (
  slug text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  user_id uuid unique references auth.users(id) on delete set null,
  name text not null check (length(btrim(name)) > 0),
  class_name text not null default '',
  letter jsonb not null default '{}'::jsonb check (jsonb_typeof(letter) = 'object')
);

create table if not exists public.cay_students (
  number integer primary key check (number > 0),
  name text not null check (length(btrim(name)) > 0)
);

create table if not exists public.cay_messages (
  teacher_slug text not null references public.cay_teachers(slug) on delete cascade,
  student_number integer not null references public.cay_students(number) on delete cascade,
  wish text not null default '',
  story text not null default '',
  note_date text not null default '',
  photo_paths text[] not null default '{}',
  primary key (teacher_slug, student_number),
  check (cardinality(photo_paths) <= 3 and array_position(photo_paths, null) is null)
);
create index if not exists cay_messages_student_number_idx on public.cay_messages(student_number);
create index if not exists cay_messages_photo_paths_idx on public.cay_messages using gin(photo_paths);

create table if not exists public.cay_gallery (
  id uuid primary key default gen_random_uuid(),
  teacher_slug text references public.cay_teachers(slug) on delete cascade,
  slot integer not null check (slot between 1 and 14),
  season integer not null default -1 check (season between -1 and 3),
  object_path text not null check (object_path like 'class/%'),
  caption text not null default '',
  photo_date text not null default '',
  unique nulls not distinct (teacher_slug, slot, season)
);
create index if not exists cay_gallery_path_idx on public.cay_gallery(object_path);

alter table public.cay_teachers enable row level security;
alter table public.cay_students enable row level security;
alter table public.cay_messages enable row level security;
alter table public.cay_gallery enable row level security;

revoke all on public.cay_teachers, public.cay_students, public.cay_messages, public.cay_gallery from public, anon, authenticated;
grant select, insert, update, delete on public.cay_teachers, public.cay_students, public.cay_messages, public.cay_gallery to authenticated;

-- Chỉ tài khoản do người quản lý gán mới đọc được cây tương ứng.
drop policy if exists cay_teacher_reads_own on public.cay_teachers;
create policy cay_teacher_reads_own on public.cay_teachers for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists cay_teacher_reads_roster on public.cay_students;
create policy cay_teacher_reads_roster on public.cay_students for select to authenticated
  using (exists (select 1 from public.cay_teachers where user_id = (select auth.uid())));

drop policy if exists cay_teacher_reads_messages on public.cay_messages;
create policy cay_teacher_reads_messages on public.cay_messages for select to authenticated
  using (exists (
    select 1 from public.cay_teachers t where t.slug = cay_messages.teacher_slug and t.user_id = (select auth.uid())
  ));

drop policy if exists cay_teacher_reads_gallery on public.cay_gallery;
create policy cay_teacher_reads_gallery on public.cay_gallery for select to authenticated
  using (exists (
    select 1 from public.cay_teachers t
    where t.user_id = (select auth.uid()) and (cay_gallery.teacher_slug is null or t.slug = cay_gallery.teacher_slug)
  ));

do $$
declare table_name text;
begin
  foreach table_name in array array['cay_teachers','cay_students','cay_messages','cay_gallery'] loop
    execute format('drop policy if exists cay_admin_manages on public.%I', table_name);
    execute format(
      'create policy cay_admin_manages on public.%I for all to authenticated
       using ((select cay_private.is_admin())) with check ((select cay_private.is_admin()))', table_name
    );
  end loop;
end
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cay-ki-uc', 'cay-ki-uc', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists cay_photo_read on storage.objects;
create policy cay_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'cay-ki-uc' and (
    (select cay_private.is_admin())
    or exists (select 1 from public.cay_gallery g where g.object_path = objects.name)
    or exists (select 1 from public.cay_messages m where m.photo_paths @> array[objects.name])
  ));

drop policy if exists cay_photo_upload on storage.objects;
create policy cay_photo_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'cay-ki-uc' and (select cay_private.is_admin()) and
    (name like 'class/%' or name like 'story/%'));

-- Chỉ xoá tệp khi ảnh đã rời tất cả giá và thẻ tâm sự.
drop policy if exists cay_photo_remove on storage.objects;
create policy cay_photo_remove on storage.objects for delete to authenticated
  using (bucket_id = 'cay-ki-uc' and (select cay_private.is_admin())
    and not exists (select 1 from public.cay_gallery g where g.object_path = objects.name)
    and not exists (select 1 from public.cay_messages m where m.photo_paths @> array[objects.name]));

insert into public.cay_teachers (slug, name) values
  ('co-1', 'Cô Phùng Thị Việt Hà'),
  ('co-2', 'Cô Ngô Thị Thùy Giang'),
  ('co-3', 'Cô Ngô Thị Phượng'),
  ('co-4', 'Cô Nguyễn Thị Cẩm Nhung')
on conflict (slug) do nothing;

insert into public.cay_students (number, name)
select n, 'Học sinh ' || n from generate_series(1,30) n
on conflict (number) do nothing;

-- Giữ hàm tự bật RLS của Supabase cho event trigger nội bộ.
do $$
begin
  if exists (
    select 1 from pg_event_trigger e
    where e.evtfoid = to_regprocedure('public.rls_auto_enable()') and e.evtname = 'ensure_rls'
  ) then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end
$$;

notify pgrst, 'reload schema';
commit;
