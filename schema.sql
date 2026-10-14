-- FMF Back Order Web App: database schema (Supabase / PostgreSQL)
--
-- Run in the Supabase SQL Editor. Creates the tables, functions, triggers, row level
-- security policies and grants the web app needs. Safe to re-run: existing data is kept.
--
-- Roles (profiles.role):
--   editor     Manager.  Edits, changes status, assigns sales reps, deletes, archives, manages users.
--   submitter  Sales Office.  Sees all lines, raises back orders, deletes own lines while TO BE ORDERED.
--   viewer     Sales rep.  Read only. Sees only back orders assigned to them.
--
-- The website talks to Supabase with the public key, so the policies and grants below are the
-- only thing protecting the data. Do not change them without re-testing every role.

begin;

-- ------------------------------------------------------------------ tables

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  role         text not null default 'viewer',
  created_at   timestamptz not null default now(),
  constraint profiles_display_name_check check (char_length(btrim(display_name)) between 1 and 100),
  constraint profiles_role_check         check (role in ('editor', 'submitter', 'viewer'))
);

create table if not exists public.back_orders (
  id           uuid primary key default gen_random_uuid(),
  account      text not null,
  account_name text,
  order_ref    text not null,
  notes        text,
  assigned_to  uuid references public.profiles (id) on delete set null,
  created_by   text not null,
  created_at   timestamptz not null default now(),
  constraint back_orders_account_check      check (char_length(btrim(account)) between 1 and 200),
  constraint back_orders_account_name_check check (char_length(account_name) <= 200),
  constraint back_orders_order_ref_check    check (char_length(btrim(order_ref)) between 1 and 100),
  constraint back_orders_notes_check        check (char_length(notes) <= 1000)
);

create table if not exists public.product_lines (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.back_orders (id) on delete cascade,
  line_no          integer not null default 1,
  part_number      text not null,
  description      text not null,
  qty              integer not null default 1,
  unit_cost        numeric not null default 0,
  unit_price       numeric not null default 0,
  status           text not null default 'TO BE ORDERED',
  status_note      text,
  notes            text,
  completed_at     timestamptz,
  created_at       timestamptz not null default now(),
  created_by_user  uuid default auth.uid() references auth.users (id) on delete set null,
  archived_at      timestamptz,
  archived_by_user uuid references auth.users (id) on delete set null,
  constraint product_lines_part_number_check        check (char_length(btrim(part_number)) between 1 and 100),
  constraint product_lines_description_check        check (char_length(btrim(description)) between 1 and 300),
  constraint product_lines_qty_check                check (qty > 0),
  constraint product_lines_unit_cost_check          check (unit_cost >= 0),
  constraint product_lines_unit_price_check         check (unit_price >= 0),
  constraint product_lines_status_check             check (status in ('TO BE ORDERED', 'ORDERED', 'COMPLETED')),
  constraint product_lines_status_note_check        check (char_length(status_note) <= 200),
  constraint product_lines_notes_check              check (char_length(notes) <= 1000),
  constraint product_lines_archived_completed_check check (archived_at is null or status = 'COMPLETED')
);

create index if not exists back_orders_created_idx     on public.back_orders (created_at desc);
create index if not exists back_orders_assigned_to_idx on public.back_orders (assigned_to);
create index if not exists product_lines_order_idx     on public.product_lines (order_id);
create index if not exists product_lines_status_idx    on public.product_lines (status);
create index if not exists product_lines_owner_idx     on public.product_lines (created_by_user);
create index if not exists product_lines_archived_idx  on public.product_lines (archived_at);

-- ------------------------------------------------------------------ role helpers

-- Any profile (any role).
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid());
$$;

-- Manager.
create or replace function public.is_editor()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'editor');
$$;

-- Manager or Submitter: people who may see everything and raise back orders.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('editor', 'submitter'));
$$;

-- ------------------------------------------------------------------ trigger functions

create or replace function public.uppercase_order()
returns trigger language plpgsql as $$
begin
  new.account := upper(new.account);
  new.account_name := upper(new.account_name);
  new.order_ref := upper(new.order_ref);
  new.notes := upper(new.notes);
  return new;
end;
$$;

create or replace function public.uppercase_line()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.archived_at is not null and new.archived_at is not null then
    return new;
  end if;
  new.part_number := upper(new.part_number);
  new.description := upper(new.description);
  new.notes       := upper(new.notes);
  new.status_note := upper(new.status_note);
  return new;
end;
$$;

create or replace function public.set_completed_at()
returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status then
    new.completed_at := case when new.status = 'COMPLETED' then now() else null end;
  end if;
  return new;
end;
$$;

create or replace function public.clear_status_note()
returns trigger language plpgsql as $$
begin
  if new.status is distinct from 'ORDERED' and new.archived_at is null then   -- archived lines are left untouched
    new.status_note := null;
  end if;
  return new;
end;
$$;

create or replace function public.archive_guard()
returns trigger language plpgsql as $$
begin
  if old.archived_at is not null and new.archived_at is not null then
    -- Deleting a user makes the database blank created_by_user / archived_by_user on their lines.
    -- That must not be blocked, or a user who has exported lines could never be deleted.
    -- (The browser has no permission to change those two columns, so this cannot be used to edit a line.)
    if (to_jsonb(new) - 'created_by_user' - 'archived_by_user') = (to_jsonb(old) - 'created_by_user' - 'archived_by_user') then
      return new;
    end if;
    raise exception 'Archived lines cannot be edited. Restore the line first.';
  end if;
  if old.archived_at is null and new.archived_at is not null then
    new.archived_at      := now();
    new.archived_by_user := auth.uid();
  elsif new.archived_at is null then
    new.archived_by_user := null;
  end if;
  return new;
end;
$$;

-- When the last line of a back order is deleted, delete the back order too.
create or replace function public.cleanup_empty_order()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  delete from public.back_orders b
  where b.id = old.order_id
    and not exists (select 1 from public.product_lines l where l.order_id = old.order_id);
  return null;
end;
$$;

-- A back order can only be assigned to a sales rep (role 'viewer'), whatever route the change comes through.
create or replace function public.check_assignee()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.assigned_to is not null
     and not exists (select 1 from public.profiles where id = new.assigned_to and role = 'viewer') then
    raise exception 'Orders can only be assigned to a sales rep (Viewer)';
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------ triggers

drop trigger if exists back_orders_uppercase on public.back_orders;
create trigger back_orders_uppercase
  before insert or update on public.back_orders
  for each row execute function public.uppercase_order();

drop trigger if exists back_orders_check_assignee on public.back_orders;
create trigger back_orders_check_assignee
  before insert or update of assigned_to on public.back_orders
  for each row execute function public.check_assignee();

drop trigger if exists product_lines_uppercase on public.product_lines;
create trigger product_lines_uppercase
  before insert or update on public.product_lines
  for each row execute function public.uppercase_line();

drop trigger if exists product_lines_completed_at on public.product_lines;
create trigger product_lines_completed_at
  before update on public.product_lines
  for each row execute function public.set_completed_at();

drop trigger if exists product_lines_clear_status_note on public.product_lines;
create trigger product_lines_clear_status_note
  before update on public.product_lines
  for each row execute function public.clear_status_note();

drop trigger if exists product_lines_archive_guard on public.product_lines;
create trigger product_lines_archive_guard
  before update on public.product_lines
  for each row execute function public.archive_guard();

drop trigger if exists product_lines_cleanup on public.product_lines;
create trigger product_lines_cleanup
  after delete on public.product_lines
  for each row execute function public.cleanup_empty_order();

-- ------------------------------------------------------------------ RPC functions called by the page

-- Raise a back order with its lines in one call. Staff only: sales reps (viewers) can never raise back orders.
create or replace function public.create_back_order(
  p_account text, p_order_ref text, p_notes text, p_lines jsonb,
  p_account_name text default null, p_assigned_to uuid default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare
  v_id uuid;
  v_name text;
  v_n integer;
begin
  if not public.is_staff() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Lines must be a list';
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 100 then
    raise exception 'Add between 1 and 100 product lines';
  end if;

  select display_name into v_name from public.profiles where id = auth.uid();

  insert into public.back_orders (account, account_name, order_ref, notes, assigned_to, created_by)
  values (btrim(p_account), nullif(btrim(coalesce(p_account_name, '')), ''), btrim(p_order_ref),
          nullif(btrim(coalesce(p_notes, '')), ''), p_assigned_to, v_name)
  returning id into v_id;

  insert into public.product_lines
    (order_id, line_no, part_number, description, qty, unit_cost, unit_price, notes, created_by_user)
  select v_id,
         t.ord::integer,
         btrim(t.l->>'part_number'),
         btrim(coalesce(t.l->>'description', '')),
         (t.l->>'qty')::integer,
         coalesce((t.l->>'unit_cost')::numeric, 0),
         coalesce((t.l->>'unit_price')::numeric, 0),
         nullif(btrim(coalesce(t.l->>'notes', '')), ''),
         auth.uid()
  from jsonb_array_elements(p_lines) with ordinality as t(l, ord);

  return v_id;
end;
$$;

-- Source of the Sales rep drop-down. Staff only.
create or replace function public.list_sales_reps()
returns table (id uuid, display_name text)
language sql stable security definer set search_path to 'public' as $$
  select p.id, p.display_name from public.profiles p
  where p.role = 'viewer' and public.is_staff()
  order by p.display_name;
$$;

-- ------------------------------------------------------------------ row level security

alter table public.profiles       enable row level security;
alter table public.back_orders    enable row level security;
alter table public.product_lines  enable row level security;

drop policy if exists profiles_read_own on public.profiles;
create policy profiles_read_own on public.profiles for select to authenticated
  using (id = auth.uid());

-- Staff see everything. A sales rep sees only back orders assigned to them, and only their lines.
drop policy if exists orders_read on public.back_orders;
create policy orders_read on public.back_orders for select to authenticated
  using (public.is_staff() or (public.is_member() and assigned_to = auth.uid()));

drop policy if exists orders_update on public.back_orders;
create policy orders_update on public.back_orders for update to authenticated
  using (public.is_editor()) with check (public.is_editor());

drop policy if exists orders_delete on public.back_orders;
create policy orders_delete on public.back_orders for delete to authenticated
  using (public.is_editor());

drop policy if exists lines_read on public.product_lines;
create policy lines_read on public.product_lines for select to authenticated
  using (
    public.is_staff()
    or exists (select 1 from public.back_orders b where b.id = product_lines.order_id and b.assigned_to = auth.uid())
  );

drop policy if exists lines_insert on public.product_lines;
create policy lines_insert on public.product_lines for insert to authenticated
  with check (public.is_editor());

drop policy if exists lines_update on public.product_lines;
create policy lines_update on public.product_lines for update to authenticated
  using (public.is_editor()) with check (public.is_editor());

drop policy if exists lines_delete on public.product_lines;
create policy lines_delete on public.product_lines for delete to authenticated
  using (public.is_editor() or (public.is_staff() and created_by_user = auth.uid() and status = 'TO BE ORDERED'));

-- ------------------------------------------------------------------ grants

-- Start from nothing, then grant only what the page needs. Signed-out visitors (anon) get nothing.
revoke all on public.profiles, public.back_orders, public.product_lines from anon, authenticated;

grant select on public.profiles, public.back_orders, public.product_lines to authenticated;
grant delete on public.back_orders, public.product_lines to authenticated;

-- Back orders are created through create_back_order(); the page may only edit these columns (Managers, via RLS).
grant update (account, account_name, order_ref, notes, assigned_to) on public.back_orders to authenticated;

grant insert (order_id, line_no, part_number, description, qty, unit_cost, unit_price, notes)
  on public.product_lines to authenticated;
grant update (part_number, description, qty, unit_cost, unit_price, notes, status, status_note, archived_at)
  on public.product_lines to authenticated;

revoke all on function public.is_member()  from public, anon;
revoke all on function public.is_editor()  from public, anon;
revoke all on function public.is_staff()   from public, anon;
revoke all on function public.create_back_order(text, text, text, jsonb, text, uuid) from public, anon;
revoke all on function public.list_sales_reps() from public, anon;
grant execute on function public.is_member()  to authenticated;
grant execute on function public.is_editor()  to authenticated;
grant execute on function public.is_staff()   to authenticated;
grant execute on function public.create_back_order(text, text, text, jsonb, text, uuid) to authenticated;
grant execute on function public.list_sales_reps() to authenticated;

commit;

-- First Manager: create the login in Authentication > Users, then run (with that user's id):
--   insert into public.profiles (id, display_name, role) values ('<user id>', '<Name>', 'editor');
-- After that, Managers add everyone else from the Users screen in the app.
