-- JuanGo 課文書架 (textbook shelf): books › lessons › pages, synced across devices, plus the private
-- Storage bucket for the page photos. Pro feature; a free account may keep 1 lesson of up to 3 pages.
-- Run once in Supabase → SQL Editor → New query → Run. Safe to run again.

-- ------------------------------------------------------------------ subscriptions (same as battle_ranked.sql)

create table if not exists public.entitlements (
  user_id     uuid not null references auth.users on delete cascade,
  entitlement text not null,
  primary key (user_id, entitlement),
  source      text not null check (source in ('app_store', 'play_store', 'promo')),
  product_id  text,
  status      text not null check (status in ('active', 'grace', 'canceled', 'expired')),
  expires_at  timestamptz not null,
  updated_at  timestamptz not null default now()
);
alter table public.entitlements enable row level security;
drop policy if exists "read own entitlement" on public.entitlements;
create policy "read own entitlement" on public.entitlements for select using (auth.uid() = user_id);

create or replace function public.has_pro(p_user uuid, p_app text default 'juango_pro') returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from entitlements e where e.user_id = p_user and e.entitlement = p_app
                 and e.status in ('active', 'grace', 'canceled') and e.expires_at > now())
$$;

-- ------------------------------------------------------------------ tables
-- Ids are made by the apps (UUIDs), so a book made offline keeps its id when it syncs.
-- deleted_at is a tombstone, as in the word sync: a deletion has to reach the other devices too.

create table if not exists public.books (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade default auth.uid(),
  title      text not null check (char_length(title) between 1 and 80),
  subject    text check (char_length(subject) <= 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists books_user on public.books (user_id, updated_at);

create table if not exists public.lessons (
  id             uuid primary key default gen_random_uuid(),
  book_id        uuid not null references public.books on delete cascade,
  title          text not null check (char_length(title) between 1 and 80),
  sort           int not null,
  last_read_page int not null default 0,
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index if not exists lessons_book on public.lessons (book_id);
create index if not exists lessons_updated on public.lessons (updated_at);

-- content:     {"v":1,"paragraphs":[{"sentences":[{"words":[{"t":"modem,","box":[x,y,w,h],"conf":0.42}]}]}]}
--              box is normalised to the photo, top-left origin; t keeps the punctuation printed with the word.
-- corrections: [{"p":0,"s":1,"w":3,"original":"modem","suggestion":"modern","source":"ai|dictionary|manual",
--                "status":"pending|accepted|rejected"}]   p/s/w point at paragraph › sentence › word.
create table if not exists public.pages (
  id          uuid primary key default gen_random_uuid(),
  lesson_id   uuid not null references public.lessons on delete cascade,
  sort        int not null,
  image_path  text,
  content     jsonb not null,
  corrections jsonb not null default '[]',
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  constraint page_size check (pg_column_size(content) + pg_column_size(corrections) < 400000)
);
create index if not exists pages_lesson on public.pages (lesson_id);
create index if not exists pages_updated on public.pages (updated_at);

-- ------------------------------------------------------------------ who owns what

create or replace function public.textbook_book_owner(p_book uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from books where id = p_book
$$;
create or replace function public.textbook_lesson_owner(p_lesson uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select b.user_id from lessons l join books b on b.id = l.book_id where l.id = p_lesson
$$;

alter table public.books   enable row level security;
alter table public.lessons enable row level security;
alter table public.pages   enable row level security;

drop policy if exists "own books" on public.books;
create policy "own books" on public.books for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own lessons" on public.lessons;
create policy "own lessons" on public.lessons for all to authenticated
  using (public.textbook_book_owner(book_id) = auth.uid())
  with check (public.textbook_book_owner(book_id) = auth.uid());

drop policy if exists "own pages" on public.pages;
create policy "own pages" on public.pages for all to authenticated
  using (public.textbook_lesson_owner(lesson_id) = auth.uid())
  with check (public.textbook_lesson_owner(lesson_id) = auth.uid());

-- ------------------------------------------------------------------ the Pro check (server side)
-- Done in BEFORE triggers rather than in the insert policies: a policy's sub-query can't see the other rows of
-- the same request, so a single upload of 10 pages would all pass a "fewer than 3" policy. A volatile trigger
-- does see the rows inserted before it in the same statement.
-- Upserts (insert … on conflict do update) also fire the insert trigger, so a row that already exists is let
-- through: re-sending old pages after Pro ends only updates them (reading position, accepted fixes).
-- Bringing a deleted row back counts as adding it.

create or replace function public.textbook_limits() returns trigger
language plpgsql volatile security definer set search_path = public as $$
declare
  v_owner uuid;
  v_pro boolean;
  v_count int;
begin
  if new.deleted_at is not null then return new; end if;
  if tg_op = 'INSERT' then
    if tg_table_name = 'books' then
      if exists (select 1 from books where id = new.id) then return new; end if;
    elsif tg_table_name = 'lessons' then
      if exists (select 1 from lessons where id = new.id) then return new; end if;
    else
      if exists (select 1 from pages where id = new.id) then return new; end if;
    end if;
  elsif old.deleted_at is null then
    -- an ordinary update; moving a lesson or page somewhere else isn't something the apps do
    return new;
  end if;

  if tg_table_name = 'books' then
    v_owner := new.user_id;
  elsif tg_table_name = 'lessons' then
    v_owner := textbook_book_owner(new.book_id);
  else
    v_owner := textbook_lesson_owner(new.lesson_id);
  end if;
  v_pro := has_pro(v_owner);

  if tg_table_name = 'books' then
    if not v_pro then
      select count(*) into v_count from books where user_id = v_owner and deleted_at is null and id <> new.id;
      if v_count >= 1 then raise exception 'textbook_free_limit: free accounts keep 1 book' using errcode = 'P0001'; end if;
    end if;
  elsif tg_table_name = 'lessons' then
    if not v_pro then
      select count(*) into v_count from lessons l join books b on b.id = l.book_id
        where b.user_id = v_owner and l.deleted_at is null and l.id <> new.id;
      if v_count >= 1 then raise exception 'textbook_free_limit: free accounts keep 1 lesson' using errcode = 'P0001'; end if;
    end if;
  else
    select count(*) into v_count from pages p join lessons l on l.id = p.lesson_id join books b on b.id = l.book_id
      where b.user_id = v_owner and p.deleted_at is null and l.deleted_at is null and p.id <> new.id;
    if not v_pro and v_count >= 3 then
      raise exception 'textbook_free_limit: free accounts keep 3 pages' using errcode = 'P0001';
    end if;
    if v_count >= 1000 then
      raise exception 'textbook_page_limit: 1000 pages per account' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists textbook_limits on public.books;
create trigger textbook_limits before insert or update on public.books
  for each row execute function public.textbook_limits();
drop trigger if exists textbook_limits on public.lessons;
create trigger textbook_limits before insert or update on public.lessons
  for each row execute function public.textbook_limits();
drop trigger if exists textbook_limits on public.pages;
create trigger textbook_limits before insert or update on public.pages
  for each row execute function public.textbook_limits();

-- updated_at is the server's clock, so every device can pull "what changed since the newest row I've seen"
-- even when a phone's clock is off. (Runs after textbook_limits: triggers fire in name order.)
create or replace function public.textbook_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists textbook_touch on public.books;
create trigger textbook_touch before insert or update on public.books
  for each row execute function public.textbook_touch();
drop trigger if exists textbook_touch on public.lessons;
create trigger textbook_touch before insert or update on public.lessons
  for each row execute function public.textbook_touch();
drop trigger if exists textbook_touch on public.pages;
create trigger textbook_touch before insert or update on public.pages
  for each row execute function public.textbook_touch();

grant select, insert, update, delete on public.books, public.lessons, public.pages to authenticated;

-- ------------------------------------------------------------------ page photos
-- Private bucket; each account writes only inside its own folder "<user id>/<page id>.jpg", and only for a page
-- it owns (so the photo count can't go past the page limit). The apps send JPEGs of about 300 KB.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('textbook-pages', 'textbook-pages', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

create or replace function public.textbook_owns_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = auth.uid()::text
     and exists (select 1 from pages p
                 where p.id::text = split_part(storage.filename(p_name), '.', 1)
                   and textbook_lesson_owner(p.lesson_id) = auth.uid())
$$;

drop policy if exists "textbook photos read" on storage.objects;
create policy "textbook photos read" on storage.objects for select to authenticated
  using (bucket_id = 'textbook-pages' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "textbook photos add" on storage.objects;
create policy "textbook photos add" on storage.objects for insert to authenticated
  with check (bucket_id = 'textbook-pages' and public.textbook_owns_photo(name));
drop policy if exists "textbook photos replace" on storage.objects;
create policy "textbook photos replace" on storage.objects for update to authenticated
  using (bucket_id = 'textbook-pages' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'textbook-pages' and public.textbook_owns_photo(name));
drop policy if exists "textbook photos delete" on storage.objects;
create policy "textbook photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'textbook-pages' and (storage.foldername(name))[1] = auth.uid()::text);

-- Not here yet (needs an Edge Function with the service role, because Storage files can't be removed from SQL):
-- deleting the photos 90 days after Pro ends, with the e-mail 7 days before (spec 3.5.2 「Pro 到期後」).
