-- ============================================================================
-- Kebab · Drop legacy Search RPCs (optional cleanup)
--
-- The rebuilt Search (2026-08-15) retrieves entirely on-device from a local
-- corpus mirror (plain RLS-scoped selects on entries + collection_entries).
-- No client code calls search_entries or search_entries_v2 anymore.
--
-- ⚠️ DO NOT RUN until the rebuilt-Search build has fully rolled out:
-- older TestFlight builds (≤ build 54) still call search_entries_v2, and
-- dropping it breaks Search in those builds. Keeping these functions around
-- in the meantime costs nothing.
-- ============================================================================

drop function if exists public.search_entries(text);
drop function if exists public.search_entries_v2(text);
