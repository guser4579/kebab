-- ============================================================================
-- Kebab · Step 2 (FINAL) : keyset-paginated feed RPC + index + grants + RLS
-- Drafted 2026-08-15 against the live schema; validated same day with
-- EXPLAIN (ANALYZE, BUFFERS) on production data for all three scopes
-- (All keyset page: 75 rows / 3.0 ms over 337 candidates; parent aggregate
-- "KEBAB MASTER COLLECTION": 50 rows / 3.3 ms over exactly its 81 members;
-- sub "Feature/Enhancement Ideas": 32 rows / 0.47 ms via Index Only Scan on
-- collection_entries_pkey with Index Cond (collection_id = ...)).
-- Run order: Section 1 → 2 → 3 → 4. Section 5 is verification (read-only).
-- Nothing here drops or modifies existing RPCs, tables, or data.
-- ============================================================================


-- ============================================================================
-- SECTION 1 · Feed-order index
--
-- The feed's ordering key is coalesce(last_resurfaced_at, created_at) — it is
-- NOT a stored column, it is computed (today inside entries_with_comment_counts
-- as "feed_order_at"). No existing index matches it; the closest is
-- idx_entries_user_created (user_id, created_at DESC), which resurfaced
-- entries fall out of. This expression index serves the paged query's
-- WHERE + ORDER BY + keyset cursor exactly, for root entries only.
-- ============================================================================

create index if not exists entries_feed_order_idx
  on public.entries (
    user_id,
    (coalesce(last_resurfaced_at, created_at)) desc,
    id desc
  )
  where parent_id is null;

-- Optional cleanup (safe, not required): idx_collection_entries_entry_id is
-- fully redundant with the unique index uq_collection_entries_entry_id
-- (both plain btrees on entry_id). Uncomment to drop the duplicate:
-- drop index if exists public.idx_collection_entries_entry_id;


-- ============================================================================
-- SECTION 2 · Paged feed RPC — one function, all three scopes
--
-- Scope mapping (client CollectionFilter → params):
--   All                      → p_collection_id = null   (p_include_subs ignored)
--   .all(parentId) aggregate → p_collection_id = parent, p_include_subs = true
--   .single(subId)           → p_collection_id = sub,    p_include_subs = false
--
-- Ordering: feed_order_at DESC, id DESC (newest first — matches the inverted
-- list's array order; older pages append at the end client-side). The id
-- tiebreaker makes the sort total, so the cursor never skips or repeats rows
-- that share a timestamp.
--
-- Cursor: keyset, not offset. First page: leave both p_before_* null. Next
-- (older) page: pass feed_order_at and id OF THE LAST ROW RECEIVED. The
-- row-value comparison (feed_order_at, id) < (p_before_order_at, p_before_id)
-- resumes exactly after that row.
--
-- has_more (deliberate contract decision): inferred from a short page —
-- rows_returned < p_limit means history is exhausted. This inference is
-- CONSERVATIVELY CORRECT, not merely probabilistic: feed_order_at only ever
-- moves forward (resurface sets last_resurfaced_at = now()), so rows can
-- LEAVE the below-cursor region but can never ENTER it. A short page at
-- snapshot time is therefore a true end-of-history. The only cost is one
-- possible empty round trip when the total happens to be an exact multiple
-- of the page size. A limit+1 envelope was evaluated and rejected: it either
-- denormalizes a per-row flag or wraps rows in a JSON envelope that breaks
-- the shared Entry decoding path — and a client wanting a strict flag can
-- always request pageSize+1 rows itself with no server change.
--
-- IMPORTANT client contract note: echo the cursor timestamp back VERBATIM as
-- the JSON string received (store it as String, not a decoded Date).
-- feed_order_at carries microseconds; a Date round-trip through a formatter
-- without fractional seconds would truncate and corrupt the cursor.
--
-- Security model: invoker rights (no SECURITY DEFINER) — RLS applies, same as
-- the existing get_feed_entries. comment_count is computed only for the
-- LIMITed page (bounded work per call, unlike the view's whole-table pass).
-- entries_with_comment_counts is untouched; existing RPCs keep working and
-- can be retired only after the client has fully migrated.
-- ============================================================================

create or replace function public.get_feed_page(
  p_collection_id uuid default null,
  p_include_subs boolean default false,
  p_limit integer default 50,
  p_before_order_at timestamptz default null,
  p_before_id uuid default null
)
returns table (
  id uuid,
  user_id uuid,
  parent_id uuid,
  root_id uuid,
  content text,
  created_at timestamptz,
  pinned_at timestamptz,
  is_content_hidden boolean,
  comment_count bigint,
  resurface_count integer,
  fire_count integer,
  attachments jsonb,
  collection_id uuid,
  collection_name text,
  collection_parent_id uuid,
  collection_parent_name text,
  feed_order_at timestamptz
)
language sql
stable
set search_path = public
as $$
  with page as (
    select
      e.id,
      e.user_id,
      e.parent_id,
      e.root_id,
      e.content,
      e.created_at,
      e.pinned_at,
      e.is_content_hidden,
      e.resurface_count,
      e.fire_count,
      e.attachments,
      c.id        as collection_id,
      c.name      as collection_name,
      c.parent_id as collection_parent_id,
      coalesce(e.last_resurfaced_at, e.created_at) as feed_order_at
    from public.entries e
    -- uq_collection_entries_entry_id guarantees at most one membership row,
    -- so these left joins can never fan out an entry into duplicate rows.
    left join public.collection_entries ce on ce.entry_id = e.id
    left join public.collections c        on c.id = ce.collection_id
    where e.parent_id is null
      and e.user_id = (select auth.uid())
      and (
        p_collection_id is null
        or (p_include_subs     and (c.id = p_collection_id or c.parent_id = p_collection_id))
        or (not p_include_subs and c.id = p_collection_id)
      )
      and (
        p_before_order_at is null
        or p_before_id is null
        or (coalesce(e.last_resurfaced_at, e.created_at), e.id)
             < (p_before_order_at, p_before_id)
      )
    order by coalesce(e.last_resurfaced_at, e.created_at) desc, e.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  )
  select
    p.id,
    p.user_id,
    p.parent_id,
    p.root_id,
    p.content,
    p.created_at,
    p.pinned_at,
    p.is_content_hidden,
    (
      select count(*)
      from public.entries ch
      where ch.root_id = p.id
        and ch.parent_id is not null
        and ch.user_id = (select auth.uid())
    ) as comment_count,
    p.resurface_count,
    p.fire_count,
    p.attachments,
    p.collection_id,
    p.collection_name,
    p.collection_parent_id,
    parent.name as collection_parent_name,
    p.feed_order_at
  from page p
  left join public.collections parent on parent.id = p.collection_parent_id
  order by p.feed_order_at desc, p.id desc;
$$;


-- ============================================================================
-- SECTION 3 · Execute grants: authenticated only
--
-- Kebab has no unauthenticated surface, so the RPC does not keep Supabase's
-- default execute grants for anon/public. (Under RLS an anon caller would
-- get zero rows anyway — this simply makes the boundary explicit.)
-- service_role keeps execute for admin/tooling use.
-- ============================================================================

revoke execute on function public.get_feed_page(uuid, boolean, integer, timestamptz, uuid) from public;
revoke execute on function public.get_feed_page(uuid, boolean, integer, timestamptz, uuid) from anon;
grant  execute on function public.get_feed_page(uuid, boolean, integer, timestamptz, uuid) to authenticated, service_role;


-- ============================================================================
-- SECTION 4 · RLS: wrap bare auth.uid() as (select auth.uid())
--
-- The still-open advisor finding: bare auth.uid() re-evaluates per row;
-- (select auth.uid()) becomes an InitPlan evaluated once per statement.
-- ALTER POLICY rewrites the expressions in place — no drop/recreate, no
-- permission gap. Covers all nine policies that exist today.
-- ============================================================================

alter policy "Users can view their own entries"    on public.entries
  using ((select auth.uid()) = user_id);

alter policy "Users can insert their own entries"  on public.entries
  with check ((select auth.uid()) = user_id);

alter policy "Users can update their own entries"  on public.entries
  using ((select auth.uid()) = user_id);

alter policy "Users can delete their own entries"  on public.entries
  using ((select auth.uid()) = user_id);

alter policy "Users can view own profile"          on public.profiles
  using ((select auth.uid()) = id);

alter policy "Users can insert own profile"        on public.profiles
  with check ((select auth.uid()) = id);

alter policy "collections_select_member"           on public.collections
  using (exists (
    select 1
    from public.collection_members cm
    where cm.collection_id = collections.id
      and cm.user_id = (select auth.uid())
  ));

alter policy "collection_entries_select_member"    on public.collection_entries
  using (exists (
    select 1
    from public.collection_members cm
    where cm.collection_id = collection_entries.collection_id
      and cm.user_id = (select auth.uid())
  ));

alter policy "collection_members_select_self"      on public.collection_members
  using ((select auth.uid()) = user_id);


-- ============================================================================
-- SECTION 5 · Verification (read-only; run after 1–4)
--
-- Pre-application validation already performed 2026-08-15 (inline queries,
-- production data, existing indexes): keyset math exact (412 roots − 75 =
-- 337 candidates), comment_count subplan loops == page size only, membership
-- lookups indexed (collection_entries_pkey by collection_id — Index Only
-- Scan; uq_collection_entries_entry_id by entry_id), parent-name lookups
-- memoized. The checks below re-verify through the real function after the
-- migration is applied, and confirm the new index is adopted.
-- ============================================================================

-- 5a. First page of All (expect newest first, ~single-digit ms):
-- select id, left(content, 40), feed_order_at
-- from get_feed_page() limit 5;

-- 5b. Keyset continuity — second page starts strictly after the first
--     page's last row, zero overlap (expect: empty result):
-- with p1 as (select * from get_feed_page(p_limit => 50)),
--      last as (select feed_order_at, id from p1 order by feed_order_at asc, id asc limit 1),
--      p2 as (select f.* from last, lateral get_feed_page(
--                p_limit => 50,
--                p_before_order_at => last.feed_order_at,
--                p_before_id => last.id) f)
-- select id from p1 intersect select id from p2;

-- 5c. Scope parity with today's client-side filter (parent aggregate —
--     KEBAB MASTER COLLECTION should return exactly its 81 aggregate
--     members as of 2026-08-15):
-- select count(*) from get_feed_page(
--   p_collection_id => 'dca4b3fe-75fb-4c9d-b48c-0b96399f3578',
--   p_include_subs => true, p_limit => 200);

-- 5d. Plan check — the All scope should now show an Index Scan on
--     entries_feed_order_idx (replacing the pre-index seq-scan + top-N sort
--     measured at 3.0 ms):
-- explain (analyze, buffers)
-- select * from get_feed_page(p_limit => 50);

-- 5e. Advisor: the nine "Auth RLS Initialization Plan" warnings should clear
--     on the next advisor refresh after Section 4.
