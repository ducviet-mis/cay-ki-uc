begin;
alter table public.cay_gallery
  drop constraint cay_gallery_slot_check,
  add constraint cay_gallery_slot_check check (slot between 1 and 14);
commit;
