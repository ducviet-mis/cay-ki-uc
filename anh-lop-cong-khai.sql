begin;

-- The user confirmed that guests with a tree link may view the 14 shared class photos.

grant select (teacher_slug, slot, season, object_path, caption, photo_date)
  on public.cay_gallery to anon;

drop policy if exists cay_public_reads_shared_gallery on public.cay_gallery;
create policy cay_public_reads_shared_gallery on public.cay_gallery
  for select to anon using (teacher_slug is null and season = -1 and object_path like 'class/%');

drop policy if exists cay_public_signs_shared_class_files on storage.objects;
create policy cay_public_signs_shared_class_files on storage.objects
  for select to anon using (
    bucket_id = 'cay-ki-uc'
    and storage.allow_only_operation('storage.object.sign_many')
    and name like 'class/%'
    and exists (
      select 1
      from public.cay_gallery g
      where g.teacher_slug is null and g.season = -1 and g.object_path = objects.name
    )
  );

notify pgrst, 'reload schema';
commit;
