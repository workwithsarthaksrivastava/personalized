-- ============================================================
-- CREATE ADMIN ACCOUNT — Personalized Gift Shop
-- Run in: Supabase Dashboard → SQL Editor → New Query
-- ============================================================

-- ── STEP 1: Create user directly via Supabase auth admin ────
-- Supabase requires email format for username.
-- We'll use "Rajesh@pgs.local" so the login stays as "Rajesh@pgs"
-- (just append .local — it never sends any real email)

insert into auth.users (
  id,
  instance_id,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data,
  is_super_admin,
  role
)
values (
  gen_random_uuid(),
  '00000000-0000-0000-0000-000000000000',
  'Rajesh@pgs.local',
  crypt('Rajesh@123', gen_salt('bf')),
  now(),              -- auto-confirmed, no email verification needed
  now(),
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Rajesh"}',
  false,
  'authenticated'
);

-- ── STEP 2: Set role = admin in profiles ────────────────────
-- The trigger auto-created the profile row. Now make it admin.
update public.profiles
set
  full_name = 'Rajesh',
  role      = 'admin'
where email = 'Rajesh@pgs.local';

-- ── STEP 3: Verify ──────────────────────────────────────────
select p.id, p.full_name, p.email, p.role, u.email_confirmed_at
from public.profiles p
join auth.users u on u.id = p.id
where p.role = 'admin';

-- ============================================================
-- LOGIN CREDENTIALS FOR ADMIN PANEL:
--   URL:      yoursite.com/admin.html
--   Email:    Rajesh@pgs.local
--   Password: Rajesh@123
-- ============================================================
