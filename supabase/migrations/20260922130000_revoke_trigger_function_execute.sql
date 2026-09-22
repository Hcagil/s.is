-- handle_new_user() kept the default PUBLIC execute grant that every other
-- function in this schema revokes. It is not exploitable -- Postgres refuses
-- to run a trigger function outside a trigger ("trigger functions can only be
-- called as triggers") -- but it raises a standing security advisory, and a
-- standing advisory is where a real one goes unnoticed.
--
-- Safe to revoke: EXECUTE on a trigger function is checked at CREATE TRIGGER
-- time, not when the trigger fires. access_test.sql proves the signup trigger
-- still creates a profile.
revoke all on function public.handle_new_user() from public, anon, authenticated;
