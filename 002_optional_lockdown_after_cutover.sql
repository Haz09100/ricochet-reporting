-- OPTIONAL SECURITY HARDENING — DO NOT RUN DURING PARALLEL TESTING.
--
-- Run this only after:
--   1. the GitHub dashboard is fully verified;
--   2. the old browser dashboard no longer queries reporting/AI tables directly; and
--   3. you have a current Supabase backup.
--
-- This does not affect a Hyperdrive/Postgres synchronization role, but it can stop old
-- browser applications that depend on the Supabase anon/authenticated roles from reading
-- the synchronized tables directly.

begin;

revoke usage on schema reporting, ai from anon, authenticated;
revoke all on all tables in schema reporting from anon, authenticated;
revoke all on all tables in schema ai from anon, authenticated;

commit;
