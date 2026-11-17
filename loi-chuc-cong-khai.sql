begin;

create table if not exists public.cay_public_wishes (
  teacher_slug text not null,
  student_number integer not null,
  wish text not null,
  primary key (teacher_slug, student_number),
  foreign key (teacher_slug, student_number)
    references public.cay_messages (teacher_slug, student_number)
    on update cascade on delete cascade
);

alter table public.cay_public_wishes enable row level security;
revoke all on public.cay_public_wishes from public, anon, authenticated;
grant select (teacher_slug, wish) on public.cay_public_wishes to anon, authenticated;

drop policy if exists cay_public_wishes_read on public.cay_public_wishes;
create policy cay_public_wishes_read on public.cay_public_wishes
  for select to anon, authenticated using (true);

-- The trigger copies only the wish and its internal key. Clients cannot call it or write the public table.
create or replace function cay_private.sync_public_wishes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.wish ~ '[^[:space:]]' then
    insert into public.cay_public_wishes (teacher_slug, student_number, wish)
    values (new.teacher_slug, new.student_number, new.wish)
    on conflict (teacher_slug, student_number) do update set wish = excluded.wish;
  else
    delete from public.cay_public_wishes
    where teacher_slug = new.teacher_slug and student_number = new.student_number;
  end if;
  return new;
end;
$$;

revoke all on function cay_private.sync_public_wishes() from public, anon, authenticated;

drop trigger if exists cay_sync_public_wishes on public.cay_messages;
create trigger cay_sync_public_wishes
  after insert or update of wish on public.cay_messages
  for each row execute function cay_private.sync_public_wishes();

insert into public.cay_public_wishes (teacher_slug, student_number, wish)
select teacher_slug, student_number, wish from public.cay_messages
where wish ~ '[^[:space:]]'
on conflict (teacher_slug, student_number) do update set wish = excluded.wish;

-- Publish just the opening letter for each public tree. Teacher rows and private messages keep their own access policies.
create or replace function cay_private.public_tree_intro(p_teacher_slug text)
returns table (name text, letter jsonb)
language sql stable security definer set search_path = ''
as $
  select t.name, jsonb_strip_nulls(jsonb_build_object(
    'greeting', t.letter->'greeting',
    'paragraphs', t.letter->'paragraphs',
    'closing', t.letter->'closing',
    'signature', t.letter->'signature',
    'date', t.letter->'date'
  ))
  from public.cay_teachers t
  where t.slug = p_teacher_slug and t.slug in ('co-1', 'co-2', 'co-3', 'co-4')
$;
revoke all on function cay_private.public_tree_intro(text) from public, anon, authenticated;
grant execute on function cay_private.public_tree_intro(text) to anon, authenticated;

create or replace function public.cay_public_tree_intro(p_teacher_slug text)
returns table (name text, letter jsonb)
language sql stable security invoker set search_path = ''
begin atomic
  select intro.name, intro.letter
  from cay_private.public_tree_intro(p_teacher_slug) as intro;
end;
revoke all on function public.cay_public_tree_intro(text) from public, anon, authenticated;
grant execute on function public.cay_public_tree_intro(text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;
