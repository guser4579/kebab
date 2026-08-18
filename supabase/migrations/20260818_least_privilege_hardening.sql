-- ============================================================================
-- Kebab · Least-privilege hardening (2026-08-18 hardening pass)
--
-- Live introspection showed the pre-login `anon` role holds GRANT ALL
-- (SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER) on every core
-- table, and EXECUTE on nearly every RPC. RLS currently blocks all of it
-- (an anon caller has a null auth.uid(), so every own-scoped policy yields
-- zero rows, and the SECURITY DEFINER RPCs raise 'Not authenticated') — this
-- was verified live: anon reads of entries / the view / get_feed_entries all
-- returned []. So nothing here fixes an ACTIVE breach; it removes the standing
-- over-grant so a future table without RLS, or an accidental permissive
-- policy, cannot silently expose data to the public anon key shipped in the
-- app binary.
--
-- The Kebab client only ever touches these tables AFTER login (role
-- `authenticated`); it never operates as `anon` except for auth (OTP). So
-- revoking anon here changes no app behavior. Verified against the shipped
-- client's data layer (EntryRepository / CollectionRepository / ProfileStore).
--
-- Sections 1–2 are the recommended core (safe, no behavior change). Sections
-- 3–5 are optional defense-in-depth, each labeled with its rationale.
-- Idempotent. Run order: 1 → 2 → (optional 3 → 4 → 5).
-- ============================================================================


-- ============================================================================
-- SECTION 1 · Strip all table privileges from `anon`
--
-- anon needs zero access to application data. After this, an unauthenticated
-- REST call to any of these returns 401 (as public.feedback already does).
-- ============================================================================

revoke all on public.entries                     from anon;
revoke all on public.collections                 from anon;
revoke all on public.collection_members          from anon;
revoke all on public.collection_entries          from anon;
revoke all on public.profiles                    from anon;
revoke all on public.entries_with_comment_counts from anon;


-- ============================================================================
-- SECTION 2 · Remove EXECUTE from anon / PUBLIC on app RPCs
--
-- Every one of these already derives identity from auth.uid() and either
-- raises 'Not authenticated' or returns no rows for an anon caller, so this
-- is belt-and-suspenders. `authenticated` and `service_role` keep EXECUTE.
-- (delete_account and get_feed_page were already authenticated-only.)
-- ============================================================================

do $$
declare
  fn text;
  fns text[] := array[
    'public.add_entry_to_collection(uuid, uuid)',
    'public.remove_entry_from_collection(uuid, uuid)',
    'public.create_collection(text)',
    'public.create_subcollection(uuid, text)',
    'public.rename_collection(uuid, text)',
    'public.delete_collection(uuid)',
    'public.get_collection_entries(uuid)',
    'public.get_my_collections()',
    'public.fire_entry(uuid)',
    'public.resurface_entry(uuid)'
  ];
begin
  foreach fn in array fns loop
    execute format('revoke execute on function %s from anon, public;', fn);
    execute format('grant  execute on function %s to authenticated, service_role;', fn);
  end loop;
end $$;


-- ============================================================================
-- SECTION 3 (OPTIONAL) · Drop the dead, unfiltered get_feed_entries()
--
-- The shipped client uses get_feed_page (keyset, and it filters
-- user_id = auth.uid() against the base entries table). get_feed_entries()
-- is unused and is the ONLY function that returns rows with no in-function
-- ownership filter — it leans entirely on the view's RLS/invoker behavior.
-- Dropping it removes that dependency and shrinks the callable surface.
-- Safe only once no shipped build calls it (get_feed_page has been live since
-- the pagination work; confirm no ≤ build-54 clients remain, same caveat as
-- the legacy-search drop).
-- ============================================================================

-- drop function if exists public.get_feed_entries();


-- ============================================================================
-- SECTION 4 (OPTIONAL) · Remove direct write grants from `authenticated` on
-- the collection join tables.
--
-- All writes to these go through SECURITY DEFINER RPCs (create/rename/delete/
-- add/remove/subcollection), which run as postgres and are unaffected. The
-- client only SELECTs these tables (get_feed_page / get_collection_entries run
-- SECURITY INVOKER and need SELECT). RLS already denies direct writes (no
-- INSERT/UPDATE/DELETE policy exists), so this just makes the grant match.
-- ============================================================================

-- revoke insert, update, delete, truncate, references, trigger
--   on public.collections        from authenticated;
-- revoke insert, update, delete, truncate, references, trigger
--   on public.collection_members from authenticated;
-- revoke insert, update, delete, truncate, references, trigger
--   on public.collection_entries from authenticated;


-- ============================================================================
-- SECTION 5 (OPTIONAL) · Cap the link-preview-images bucket.
--
-- entry-images has a 10 MB limit and an image-only mime allowlist;
-- link-preview-images has NEITHER (file_size_limit null, allowed_mime any),
-- so an authenticated user can upload arbitrary large files of any type into
-- their own folder. Match entry-images to bound storage abuse.
-- ============================================================================

-- update storage.buckets
--   set file_size_limit = 10485760,
--       allowed_mime_types = array['image/jpeg','image/png','image/heic','image/webp','image/gif']
--   where id = 'link-preview-images';


-- ============================================================================
-- Verification (read-only, after applying 1–2):
--   -- anon should now get 401, not []:
--   --   curl "$URL/rest/v1/entries?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
--   select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='public' and table_name='entries' and grantee='anon';  -- expect 0 rows
-- ============================================================================
