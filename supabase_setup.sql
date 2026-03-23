-- ============================================================
-- PERSONALIZED GIFT SHOP — Supabase Schema
-- Run this entire file in Supabase > SQL Editor > New Query
-- ============================================================

-- ── EXTENSIONS ──────────────────────────────────────────────
create extension if not exists "uuid-ossp";

-- ── ENUM TYPES ───────────────────────────────────────────────
create type order_status as enum (
  'pending',
  'design_review',
  'printing',
  'packed',
  'out_for_delivery',
  'delivered',
  'cancelled'
);

create type product_category as enum (
  'album',
  'frame',
  'uv_print',
  'sublimation'
);

-- ── PROFILES ─────────────────────────────────────────────────
-- Extends Supabase auth.users with extra fields
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text,
  phone         text unique,
  email         text,
  role          text not null default 'customer' check (role in ('customer', 'admin')),
  avatar_url    text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, full_name, email, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', new.phone)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ── PRODUCTS ─────────────────────────────────────────────────
create table public.products (
  id            uuid primary key default uuid_generate_v4(),
  name          text not null,
  description   text,
  category      product_category not null,
  icon          text default '🎁',
  base_price    numeric(10,2) not null,
  images        text[] default '{}',
  variants      jsonb default '[]',   -- [{label, price_delta, stock}]
  is_active     boolean default true,
  stock         int default 100,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- ── ORDERS ───────────────────────────────────────────────────
create table public.orders (
  id              uuid primary key default uuid_generate_v4(),
  order_number    text unique not null,
  customer_id     uuid references public.profiles(id),
  -- snapshot of customer info at time of order
  customer_name   text not null,
  customer_phone  text not null,
  customer_email  text,
  -- delivery
  address_line1   text not null,
  address_city    text not null,
  address_state   text not null,
  address_pin     text not null,
  -- financials
  subtotal        numeric(10,2) not null,
  shipping        numeric(10,2) default 0,
  tax             numeric(10,2) default 0,
  total           numeric(10,2) not null,
  -- status
  status          order_status default 'pending',
  status_note     text,
  -- meta
  payment_method  text default 'cod',
  payment_id      text,           -- Razorpay payment id
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- ── ORDER ITEMS ───────────────────────────────────────────────
create table public.order_items (
  id            uuid primary key default uuid_generate_v4(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  product_id    uuid references public.products(id),
  product_name  text not null,    -- snapshot
  product_icon  text,
  variant       text,             -- eg: "12×18, 3MM"
  quantity      int not null default 1,
  unit_price    numeric(10,2) not null,
  total_price   numeric(10,2) generated always as (quantity * unit_price) stored
);

-- ── ORDER STATUS HISTORY ─────────────────────────────────────
create table public.order_status_history (
  id         uuid primary key default uuid_generate_v4(),
  order_id   uuid not null references public.orders(id) on delete cascade,
  status     order_status not null,
  note       text,
  changed_by uuid references public.profiles(id),
  changed_at timestamptz default now()
);

-- Auto-log status changes
create or replace function log_order_status()
returns trigger language plpgsql as $$
begin
  if old.status is distinct from new.status then
    insert into public.order_status_history (order_id, status, note, changed_by)
    values (new.id, new.status, new.status_note, auth.uid());
  end if;
  return new;
end;
$$;

create trigger order_status_changed
  after update on public.orders
  for each row execute procedure log_order_status();

-- Auto-update updated_at
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger orders_updated_at before update on public.orders
  for each row execute procedure update_updated_at();
create trigger products_updated_at before update on public.products
  for each row execute procedure update_updated_at();
create trigger profiles_updated_at before update on public.profiles
  for each row execute procedure update_updated_at();

-- ── ORDER NUMBER GENERATOR ───────────────────────────────────
create or replace function generate_order_number()
returns text language plpgsql as $$
declare
  dt   text := to_char(now(), 'YYYYMMDD');
  seq  int;
  num  text;
begin
  select count(*) + 1 into seq
  from public.orders
  where created_at::date = current_date;
  num := 'PGS-' || dt || '-' || lpad(seq::text, 4, '0');
  return num;
end;
$$;

-- ── CONTACT MESSAGES ─────────────────────────────────────────
create table public.contact_messages (
  id         uuid primary key default uuid_generate_v4(),
  name       text not null,
  phone      text not null,
  email      text,
  service    text,
  message    text not null,
  is_read    boolean default false,
  created_at timestamptz default now()
);

-- ══════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ══════════════════════════════════════════════════════════════

alter table public.profiles             enable row level security;
alter table public.products             enable row level security;
alter table public.orders               enable row level security;
alter table public.order_items          enable row level security;
alter table public.order_status_history enable row level security;
alter table public.contact_messages     enable row level security;

-- Helper: is the current user an admin?
create or replace function is_admin()
returns boolean language sql security definer as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ── profiles policies ────────────────────────────────────────
create policy "Users can view own profile"
  on public.profiles for select using (auth.uid() = id);

create policy "Users can update own profile"
  on public.profiles for update using (auth.uid() = id);

create policy "Admins can view all profiles"
  on public.profiles for select using (is_admin());

-- ── products policies ────────────────────────────────────────
create policy "Anyone can view active products"
  on public.products for select using (is_active = true);

create policy "Admins can do anything with products"
  on public.products for all using (is_admin());

-- ── orders policies ──────────────────────────────────────────
create policy "Customers can view own orders"
  on public.orders for select
  using (customer_id = auth.uid());

create policy "Customers can create orders"
  on public.orders for insert
  with check (customer_id = auth.uid() or customer_id is null);

create policy "Admins can view all orders"
  on public.orders for select using (is_admin());

create policy "Admins can update orders"
  on public.orders for update using (is_admin());

-- ── order_items policies ─────────────────────────────────────
create policy "Customers can view own order items"
  on public.order_items for select
  using (exists (
    select 1 from public.orders
    where orders.id = order_items.order_id
    and orders.customer_id = auth.uid()
  ));

create policy "Customers can insert order items"
  on public.order_items for insert
  with check (exists (
    select 1 from public.orders
    where orders.id = order_items.order_id
    and (orders.customer_id = auth.uid() or orders.customer_id is null)
  ));

create policy "Admins can do anything with order items"
  on public.order_items for all using (is_admin());

-- ── order_status_history policies ───────────────────────────
create policy "Customers can view own order history"
  on public.order_status_history for select
  using (exists (
    select 1 from public.orders
    where orders.id = order_status_history.order_id
    and orders.customer_id = auth.uid()
  ));

create policy "Admins can do anything with status history"
  on public.order_status_history for all using (is_admin());

-- ── contact_messages policies ────────────────────────────────
create policy "Anyone can insert contact messages"
  on public.contact_messages for insert with check (true);

create policy "Admins can view contact messages"
  on public.contact_messages for all using (is_admin());

-- ══════════════════════════════════════════════════════════════
-- ANALYTICS VIEW (used by admin dashboard)
-- ══════════════════════════════════════════════════════════════

create or replace view public.admin_revenue_summary as
select
  date_trunc('day', created_at)::date as day,
  count(*)                            as order_count,
  sum(total)                          as revenue,
  avg(total)                          as avg_order_value
from public.orders
where status != 'cancelled'
group by 1
order by 1 desc;

-- Grant view access to authenticated users (admin check done in app)
grant select on public.admin_revenue_summary to authenticated;

-- ══════════════════════════════════════════════════════════════
-- SEED PRODUCTS
-- ══════════════════════════════════════════════════════════════

insert into public.products (name, description, category, icon, base_price, variants, stock) values
('2MM Acrylic Frame',     'Crystal-clear 2MM acrylic, UV-resistant glossy finish.',           'frame',       '🖼', 525,  '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":600},{"label":"16×20","price_delta":975}]', 50),
('3MM Acrylic Frame',     'Premium 3MM acrylic for extra durability and depth.',               'frame',       '🖼', 700,  '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":800},{"label":"16×20","price_delta":1300},{"label":"20×30","price_delta":2800}]', 50),
('5MM Acrylic Frame',     'Luxury 5MM thick acrylic — museum-grade presentation.',             'frame',       '🖼', 1000, '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":1000},{"label":"16×20","price_delta":1800},{"label":"20×30","price_delta":3500}]', 30),
('Slim LED Frame',        'Backlit LED frame for a glowing, dramatic display.',                'frame',       '💡', 1650, '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":450},{"label":"16×24","price_delta":1650},{"label":"23×35","price_delta":5700}]', 30),
('Molding LED Frame',     'Ornate molding with integrated LED backlight.',                     'frame',       '✨', 700,  '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":500},{"label":"16×20","price_delta":1100}]', 25),
('Wooden Print Frame',    'Natural wood finish — rustic, warm, and long-lasting.',             'frame',       '🪵', 1200, '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":800},{"label":"16×20","price_delta":2300},{"label":"23×35","price_delta":8300}]', 20),
('Matt Lamination Frame', 'Soft matte finish — elegant, non-reflective, premium feel.',        'frame',       '🎞', 450,  '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":350},{"label":"16×20","price_delta":800},{"label":"20×30","price_delta":1350}]', 40),
('Classic Wedding Album', 'Hardcover wedding album — timeless design, glossy pages.',          'album',       '💍', 2499, '[{"label":"20 pages","price_delta":0},{"label":"32 pages","price_delta":500},{"label":"50 pages","price_delta":1000}]', 999),
('Birthday Album',        'Fun, colourful birthday album — perfect keepsake.',                 'album',       '🎂', 1299, '[{"label":"16 pages","price_delta":0},{"label":"24 pages","price_delta":300}]', 999),
('Corporate Event Album', 'Professional corporate event album with branded cover.',            'album',       '🏢', 1999, '[{"label":"24 pages","price_delta":0},{"label":"40 pages","price_delta":600}]', 999),
('Acrylic Sheet Print',   'UV print on clear/frosted acrylic — vivid, scratch-proof.',         'uv_print',    '✨', 599,  '[{"label":"A4","price_delta":0},{"label":"A3","price_delta":400},{"label":"Custom","price_delta":0}]', 999),
('Wooden Board Print',    'UV print on natural wood board — rustic wall art.',                 'uv_print',    '🪵', 899,  '[{"label":"8×12","price_delta":0},{"label":"12×18","price_delta":500}]', 999),
('Mobile Cover Print',    'Full custom UV print on mobile covers — all models.',               'uv_print',    '📱', 299,  '[{"label":"Standard","price_delta":0}]', 999),
('Custom T-Shirt',        'Sublimation printed tee — vibrant, wash-safe, all sizes.',          'sublimation', '👕', 499,  '[{"label":"S","price_delta":0},{"label":"M","price_delta":0},{"label":"L","price_delta":0},{"label":"XL","price_delta":50},{"label":"XXL","price_delta":100}]', 999),
('Custom Mug',            'Photo/design on 11oz, 15oz, or magic colour-changing mug.',         'sublimation', '☕', 399,  '[{"label":"11oz Standard","price_delta":0},{"label":"15oz Travel","price_delta":100},{"label":"Magic Mug","price_delta":150}]', 999),
('Custom Keychain',       'Acrylic/metal keychain — any shape, your photo + text.',            'sublimation', '🔑', 149,  '[{"label":"Rectangle","price_delta":0},{"label":"Round","price_delta":0},{"label":"Heart","price_delta":10},{"label":"Star","price_delta":10}]', 999),
('Custom Hoodie',         'Pullover/zip hoodie with front or back sublimation print.',         'sublimation', '🧥', 899,  '[{"label":"S","price_delta":0},{"label":"M","price_delta":0},{"label":"L","price_delta":0},{"label":"XL","price_delta":100}]', 999);

-- ══════════════════════════════════════════════════════════════
-- FIRST ADMIN USER SETUP
-- ══════════════════════════════════════════════════════════════
-- After signing up with your admin email, run:
--
--   update public.profiles
--   set role = 'admin'
--   where email = 'your-admin@email.com';
--
-- ══════════════════════════════════════════════════════════════
-- STORAGE BUCKET (run in Supabase Dashboard > Storage > New Bucket)
-- ══════════════════════════════════════════════════════════════
-- Bucket name: product-images   (public)
-- Bucket name: order-uploads    (private)
--
-- Or via SQL:
insert into storage.buckets (id, name, public) values
  ('product-images', 'product-images', true),
  ('order-uploads',  'order-uploads',  false)
on conflict do nothing;

create policy "Public read product images"
  on storage.objects for select
  using (bucket_id = 'product-images');

create policy "Admins can upload product images"
  on storage.objects for insert
  using (bucket_id = 'product-images' and is_admin());

create policy "Customers can upload order files"
  on storage.objects for insert
  using (bucket_id = 'order-uploads' and auth.role() = 'authenticated');

-- ══════════════════════════════════════════════════════════════
-- DONE. Replace SUPABASE_URL and SUPABASE_ANON_KEY in both
-- personalizedgiftshop.html and admin.html before deploying.
-- ══════════════════════════════════════════════════════════════
