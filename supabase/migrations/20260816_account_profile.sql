-- ============================================================================
-- Kebab · Account + optional profile (V1)
-- Drafted 2026-08-16 against the live schema (introspected same day).
--
-- What exists today (verified):
--   profiles(id uuid PK → auth.users ON DELETE CASCADE, email text,
--            created_at timestamptz) — currently EMPTY (no signup trigger;
--            the client upserts on first profile edit).
--   RLS on profiles: SELECT own + INSERT own only — no UPDATE policy yet.
--   entries.user_id → auth.users has NO delete action (blocks deleting the
--            auth user until entries are removed first).
--   collections.created_by identifies ownership; collections cascade to
--            sub-collections, collection_entries, collection_members.
--   Storage: public buckets entry-images (folder-scoped INSERT/DELETE own)
--            and link-preview-images (owner-scoped policies). Avatars reuse
--            entry-images under {userId}/avatar-{uuid}.jpg — no new bucket,
--            the existing folder policies already cover upload/replace/remove.
--
-- Run order: Section 1 → 2 → 3. All statements are idempotent.
-- ============================================================================


-- ============================================================================
-- SECTION 1 · profiles: optional display name + avatar URL
-- ============================================================================

alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_url  text;

-- 50-char cap matches the client-side limit (free-form display name, V1).
alter table public.profiles drop constraint if exists profiles_display_name_length;
alter table public.profiles add  constraint profiles_display_name_length
  check (display_name is null or char_length(display_name) <= 50);

-- The client persists edits with an upsert; INSERT own already exists,
-- UPDATE own is the missing half. (select auth.uid()) per the initplan rule.
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile" on public.profiles
  for update
  using      ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);


-- ============================================================================
-- SECTION 2 · delete_account(): full, ordered removal of a user's data
--
-- Order matters:
--   1. entries first — entries.user_id → auth.users has NO cascade, so the
--      auth row cannot be deleted while entries exist. Deleting roots
--      cascades comments (parent_id) and collection_entries (entry_id).
--   2. collections the user created — cascades sub-collections, remaining
--      collection_entries, and collection_members rows.
--   3. leftover collection_members rows (memberships in collections the
--      user didn't create — none in V1, but safe and cheap).
--   4. storage object records for the user's folders/objects. NOTE: this
--      removes the DB records (URLs 404 immediately); the physical files
--      are orphaned in the storage backend — acceptable V1 cost, same
--      caveat as any SQL-side storage cleanup.
--   5. auth.users last — cascades profiles, sessions, identities, tokens.
--
-- SECURITY DEFINER (owner: postgres) because auth.users and storage.objects
-- are outside the authenticated role's reach. The only row selector is
-- auth.uid() — a caller can only ever delete themselves.
-- ============================================================================

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.entries
  where user_id = v_user_id;

  delete from public.collections
  where created_by = v_user_id;

  delete from public.collection_members
  where user_id = v_user_id;

  delete from storage.objects
  where (bucket_id = 'entry-images'
         and (storage.foldername(name))[1] = v_user_id::text)
     or (bucket_id = 'link-preview-images'
         and owner_id = v_user_id::text);

  delete from auth.users
  where id = v_user_id;
end;
$function$;


-- ============================================================================
-- SECTION 3 · Execute grants: authenticated only (no unauthenticated surface)
-- ============================================================================

revoke execute on function public.delete_account() from public;
revoke execute on function public.delete_account() from anon;
grant  execute on function public.delete_account() to authenticated, service_role;


-- ============================================================================
-- Verification (read-only, after applying):
-- select column_name from information_schema.columns
--   where table_schema='public' and table_name='profiles';
-- select policyname, cmd from pg_policies
--   where schemaname='public' and tablename='profiles';
-- select proname, prosecdef from pg_proc
--   where proname='delete_account' and pronamespace='public'::regnamespace;
-- ============================================================================
