-- =============================================================================
-- diagnose_login.sql — why can somebody not sign in?
--
-- Run in the Supabase SQL editor. Read-only: it changes nothing. The repair is
-- the commented block at the foot, to be run only after reading the answer.
--
-- The address appears literally in each section. To check somebody else,
-- replace every 'chauhanvedant34@gmail.com' below with theirs — the four
-- sections each stand alone and can be run one at a time.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Does a login exist, and can it be used?
--
-- A login that is missing, unconfirmed or deleted produces three different
-- messages in the app, and only one of them is about the password.
-- -----------------------------------------------------------------------------
select
  '1. The login' as section,
  u.id::text    as auth_user_id,
  u.email,
  case
    when u.email_confirmed_at is null
      then 'NOT CONFIRMED — the app says "This account has not been confirmed '
           'yet". Confirm it under Authentication -> Users.'
    else 'confirmed ' || to_char(u.email_confirmed_at, 'DD Mon YYYY')
  end as state,
  coalesce(to_char(u.last_sign_in_at, 'DD Mon YYYY HH24:MI'), 'never')
    as last_signed_in
from auth.users u
where lower(u.email) = lower('chauhanvedant34@gmail.com');
-- No rows here means there is no such login at all. Create it under
-- Authentication -> Users, then run the repair at the foot of this file.

-- -----------------------------------------------------------------------------
-- 2. Is that login attached to a staff profile?
--
-- This is the usual answer. A login with no profile signs in to Supabase and
-- is then turned away by the app with "This login is not linked to a staff
-- profile yet", because every screen needs to know who you are on the floor.
-- -----------------------------------------------------------------------------
select
  '2. The profile behind it' as section,
  p.employee_code,
  p.name,
  p.role::text,
  p.active,
  t.name as employee_role
from auth.users u
left join public.profiles p on p.auth_user_id = u.id
left join public.employee_types t on t.id = p.employee_type_id
where lower(u.email) = lower('chauhanvedant34@gmail.com');
-- employee_code null  -> the login is NOT linked. Use the repair below.
-- active false        -> the app says "This account has been deactivated".
-- role not ADMIN      -> it signs in, but to the operator side of the app.

-- -----------------------------------------------------------------------------
-- 3. What does the Factory Admin profile say?
--
-- Read this beside section 2. If EMP-001 shows a different auth_user_id, the
-- login was linked to somebody else — moving it is the repair below.
-- -----------------------------------------------------------------------------
select
  '3. Factory Admin (EMP-001)' as section,
  p.employee_code,
  p.name,
  p.role::text,
  p.active,
  coalesce(p.auth_user_id::text, 'NO LOGIN LINKED') as auth_user_id,
  coalesce(u.email, '—') as linked_email
from public.profiles p
left join auth.users u on u.id = p.auth_user_id
where p.employee_code = 'EMP-001';

-- -----------------------------------------------------------------------------
-- 4. Everybody who can sign in
--
-- Useful when the question is "has anybody got in at all". An administrator
-- with no login here is why nobody can administer anything.
-- -----------------------------------------------------------------------------
select
  '4. Linked logins' as section,
  p.employee_code,
  p.name,
  p.role::text,
  p.active,
  u.email
from public.profiles p
join auth.users u on u.id = p.auth_user_id
order by p.role::text, p.employee_code;

-- =============================================================================
-- THE REPAIR — read the answers above first, then uncomment ONE of these
--
-- link_profile_to_auth_user() is the usual way to do this, but it calls
-- app.require_admin() and the SQL editor has no signed-in user, so it refuses.
-- That is exactly the situation you are in if no administrator can sign in, so
-- the repair here is a direct UPDATE, which runs as the table owner.
-- =============================================================================

-- (a) Link the login to Factory Admin.
--     Use when section 2 showed no profile, or section 3 showed no login.
--
-- update public.profiles
-- set auth_user_id = (select id from auth.users
--                     where lower(email) = lower('chauhanvedant34@gmail.com'))
-- where employee_code = 'EMP-001';

-- (b) Take the login off whoever currently holds it, then link it.
--     Use when section 2 showed a DIFFERENT person. One login belongs to one
--     person; leaving it on two would let either of them act as the other.
--
-- update public.profiles
-- set auth_user_id = null
-- where auth_user_id = (select id from auth.users
--                       where lower(email) = lower('chauhanvedant34@gmail.com'))
--   and employee_code <> 'EMP-001';
--
-- update public.profiles
-- set auth_user_id = (select id from auth.users
--                     where lower(email) = lower('chauhanvedant34@gmail.com'))
-- where employee_code = 'EMP-001';

-- (c) Put Factory Admin back on the roll.
--     Use when section 3 showed active = false.
--
-- update public.profiles set active = true where employee_code = 'EMP-001';

-- (d) Make them an administrator.
--     Use when section 2 showed a role other than ADMIN. An administrator is
--     office staff, never a machine operator — the two must not disagree.
--
-- update public.profiles
-- set role = 'ADMIN',
--     employee_type_id = (select id from public.employee_types
--                         where code = 'OFFICE')
-- where employee_code = 'EMP-001';

-- After any repair, run section 3 again. It should show the email beside
-- EMP-001, role ADMIN, active true.
