-- ============================================================================
-- Kebab · Atomic entry move (2026-08-18 hardening pass, PASS 11)
--
-- Today the client moves an entry between collections with two independent
-- server calls: remove_entry_from_collection then add_entry_to_collection
-- (CollectionRepository.swift / FeedViewModel.moveEntry). A failure BETWEEN
-- them leaves the entry unfiled server-side until the next revalidation
-- reconciles it. This replaces the pair with one transactional function that
-- either fully moves the entry or changes nothing.
--
-- Security: SECURITY DEFINER, so ownership is enforced INSIDE the function
-- (it runs as the table owner and bypasses RLS). It derives identity solely
-- from auth.uid() and verifies that:
--   * the entry belongs to the caller, and
--   * the destination collection (when given) belongs to the caller,
-- so a malicious client cannot move another user's entry, nor file an entry
-- into another user's collection, by substituting UUIDs. p_collection_id NULL
-- means "All / unfiled" (remove from any collection).
--
-- Schema confirmed 2026-08-18 via live introspection:
--   collection_entries(collection_id uuid NN, entry_id uuid NN,
--                      added_at timestamptz NN default now(),
--                      added_by uuid NN)  PK (collection_id, entry_id)
-- so the INSERT supplies added_by and conflict-guards on the composite PK.
-- Single-collection-per-entry is maintained procedurally (delete-then-insert),
-- exactly as the existing add_entry_to_collection does — there is no unique
-- constraint on entry_id alone.
--
-- Idempotent. Run order: Section 1 → 2.
-- ============================================================================


-- ============================================================================
-- SECTION 1 · move_entry_to_collection(entry, destination|null)
-- ============================================================================

create or replace function public.move_entry_to_collection(
  p_entry_id uuid,
  p_collection_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_uid          uuid := (select auth.uid());
  v_entry_owner  uuid;
  v_entry_parent uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Entry must exist, belong to the caller, and be a top-level entry (only
  -- roots are filed into collections — same rule the insert trigger enforces).
  select user_id, parent_id into v_entry_owner, v_entry_parent
  from public.entries where id = p_entry_id;
  if v_entry_owner is null then
    raise exception 'Entry not found' using errcode = 'P0002';
  end if;
  if v_entry_owner <> v_uid then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if v_entry_parent is not null then
    raise exception 'Only top-level entries can be filed into collections' using errcode = '42501';
  end if;

  -- Destination (when given) must be a collection the caller can edit. Uses
  -- the same collection_members owner/editor check as add_entry_to_collection,
  -- so a client cannot file its entry into another user's collection by
  -- passing that collection's UUID.
  if p_collection_id is not null then
    if not exists (
      select 1 from public.collection_members cm
      where cm.collection_id = p_collection_id
        and cm.user_id = v_uid
        and cm.role in ('owner', 'editor')
    ) then
      raise exception 'Not authorized to modify this collection' using errcode = '42501';
    end if;
  end if;

  -- The move itself, in one transaction (the whole function is atomic): drop
  -- the entry's current membership, then attach to the destination if there is
  -- one. collection_entries has PK (collection_id, entry_id) and added_by is
  -- NOT NULL, so the insert supplies added_by and conflict-guards on the PK.
  delete from public.collection_entries where entry_id = p_entry_id;

  if p_collection_id is not null then
    insert into public.collection_entries (collection_id, entry_id, added_by)
    values (p_collection_id, p_entry_id, v_uid)
    on conflict (collection_id, entry_id) do nothing;
  end if;
end;
$function$;


-- ============================================================================
-- SECTION 2 · Execute grants: authenticated only (no unauthenticated surface)
-- ============================================================================

revoke execute on function public.move_entry_to_collection(uuid, uuid) from public;
revoke execute on function public.move_entry_to_collection(uuid, uuid) from anon;
grant  execute on function public.move_entry_to_collection(uuid, uuid) to authenticated, service_role;


-- ============================================================================
-- Verification (read-only, after applying):
--   select proname, prosecdef, proconfig from pg_proc
--     where proname = 'move_entry_to_collection';
--   -- Positive: move your own entry to your own collection, then to NULL.
--   -- Negative (expect 'Not authorized'): as user A, call with another
--   --   user's entry id, or with your entry id and another user's collection.
-- ============================================================================
