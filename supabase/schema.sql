-- Project Atlas — rent & cash board for small landlords.
-- Multi-tenant: every row belongs to an org; a user sees only the orgs they are a member of.

create extension if not exists pgcrypto;

create table public.orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  currency    text not null default 'MXN',
  created_by  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table public.org_members (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'owner' check (role in ('owner','member')),
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);

create table public.properties (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  name        text not null,
  address     text not null default '',
  created_at  timestamptz not null default now()
);

create table public.units (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id) on delete cascade,
  property_id   uuid not null references public.properties(id) on delete cascade,
  name          text not null,                         -- "Depto 4B"
  rent          numeric(12,2) not null default 0,      -- monthly rent
  due_day       int not null default 1 check (due_day between 1 and 31),
  tenant_name   text not null default '',
  tenant_phone  text not null default '',
  status        text not null default 'occupied' check (status in ('occupied','vacant')),
  notes         text not null default '',
  created_at    timestamptz not null default now()
);

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  unit_id     uuid not null references public.units(id) on delete cascade,
  period      text not null check (period ~ '^\d{4}-\d{2}$'),   -- rent month "2026-11"
  amount      numeric(12,2) not null,
  paid_on     date not null default current_date,
  method      text not null default 'transfer' check (method in ('transfer','cash','card','other')),
  note        text not null default '',
  created_at  timestamptz not null default now()
);

create table public.expenses (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id) on delete cascade,
  property_id   uuid references public.properties(id) on delete set null,
  unit_id       uuid references public.units(id) on delete set null,
  date          date not null default current_date,
  amount        numeric(12,2) not null,
  category      text not null default 'other'
                check (category in ('maintenance','utilities','taxes','admin','insurance','other')),
  note          text not null default '',
  created_at    timestamptz not null default now()
);

create index on public.org_members (user_id);
create index on public.properties (org_id);
create index on public.units (org_id, property_id);
create index on public.payments (org_id, period);
create index on public.payments (unit_id, period);
create index on public.expenses (org_id, date);

-- ---------- row-level security ----------
-- Which orgs does the caller belong to? security definer so the policy on org_members
-- can use it without recursing into itself.
create or replace function public.my_org_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select org_id from public.org_members where user_id = auth.uid()
$$;

alter table public.orgs         enable row level security;
alter table public.org_members  enable row level security;
alter table public.properties   enable row level security;
alter table public.units        enable row level security;
alter table public.payments     enable row level security;
alter table public.expenses     enable row level security;

create policy "members read org"   on public.orgs for select using (id in (select public.my_org_ids()));
create policy "owner updates org"  on public.orgs for update using (id in (select public.my_org_ids()));

create policy "members read members" on public.org_members for select using (org_id in (select public.my_org_ids()));

create policy "org rw properties" on public.properties for all
  using (org_id in (select public.my_org_ids())) with check (org_id in (select public.my_org_ids()));
create policy "org rw units" on public.units for all
  using (org_id in (select public.my_org_ids())) with check (org_id in (select public.my_org_ids()));
create policy "org rw payments" on public.payments for all
  using (org_id in (select public.my_org_ids())) with check (org_id in (select public.my_org_ids()));
create policy "org rw expenses" on public.expenses for all
  using (org_id in (select public.my_org_ids())) with check (org_id in (select public.my_org_ids()));

-- ---------- creating an org (first login) ----------
-- Inserts the org and makes the caller its owner in one step, so no insert policy
-- on orgs/org_members is needed.
create or replace function public.create_org(p_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.orgs (name, created_by) values (trim(p_name), auth.uid()) returning id into v_id;
  insert into public.org_members (org_id, user_id, role) values (v_id, auth.uid(), 'owner');
  return v_id;
end $$;

-- Invite a teammate by email (they must already have signed up).
create or replace function public.add_member(p_org uuid, p_email text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if not exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid() and role = 'owner') then
    raise exception 'only owners can invite';
  end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'no account with that email yet'; end if;
  insert into public.org_members (org_id, user_id, role) values (p_org, v_user, 'member')
  on conflict do nothing;
end $$;

grant execute on function public.my_org_ids() to authenticated;
grant execute on function public.create_org(text) to authenticated;
grant execute on function public.add_member(uuid, text) to authenticated;

-- ---------- v0.2: contracts, bank matching, receipts ----------
alter table public.units add column contract_end date;            -- when the lease ends
alter table public.units add column match text not null default ''; -- words that identify this tenant on a bank alert
alter table public.payments add column source text not null default 'manual' check (source in ('manual','bank'));
alter table public.payments add column bank_ref text not null default ''; -- fingerprint of the bank alert, so one alert is never imported twice
create unique index payments_bank_ref_uniq on public.payments (org_id, bank_ref) where bank_ref <> '';
