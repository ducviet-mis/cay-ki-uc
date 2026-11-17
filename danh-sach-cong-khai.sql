create function cay_private.public_tree_roster(p_teacher_slug text)
returns table(student_number integer, student_name text, wish text)
language sql stable security definer set search_path = '' as $$
  select s.number, s.name, coalesce(w.wish, '')
  from public.cay_students s
  left join public.cay_public_wishes w
    on w.student_number = s.number and w.teacher_slug = p_teacher_slug
  where s.class_roster
    and exists (select 1 from public.cay_teachers t where t.slug = p_teacher_slug)
  order by s.number
$$;

create function public.cay_public_tree_roster(p_teacher_slug text)
returns table(student_number integer, student_name text, wish text)
language sql stable security invoker set search_path = ''
begin atomic
  select * from cay_private.public_tree_roster(p_teacher_slug);
end;

revoke all on function cay_private.public_tree_roster(text),
  public.cay_public_tree_roster(text) from public, anon, authenticated;
grant execute on function cay_private.public_tree_roster(text),
  public.cay_public_tree_roster(text) to anon, authenticated;

notify pgrst, 'reload schema';
