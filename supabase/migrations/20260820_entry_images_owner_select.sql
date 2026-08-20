-- ============================================================================
-- Kebab · Make entry-images cleanup actually delete (2026-08-20)
--
-- SYMPTOM
-- Deleting an entry left its uploaded image BYTES in the bucket forever, and
-- `AuthViewModel.purgeUserStorageObjects` — the account-deletion privacy purge
-- — was silently a no-op for its entire life. Both call
-- `storage.remove(paths:)`, which answered:
--
--     DELETE /storage/v1/object/entry-images   ->  200  []
--
-- 200-with-empty-list is not an error, so every caller treated it as success
-- while nothing was removed and the objects stayed publicly readable.
--
-- ROOT CAUSE — it is the SELECT policy, not the DELETE policy.
-- `entry-images` already had the right DELETE policy ("Users can delete their
-- own entry images", identical predicate to the one below). What it did NOT
-- have is a SELECT policy for `authenticated`. Storage's delete must first
-- LOOK UP the rows named by the request, and that lookup runs under RLS as the
-- calling user. With no SELECT policy the lookup returns zero rows, so zero
-- rows are deleted and the API reports an empty success.
--
-- Verified live from the signed-in client on 2026-08-20, before this change:
--
--     jwt role                                    -> authenticated
--     raw DELETE .../object/entry-images          -> 200  []
--     storage.list(path: "{uid}")                 -> 0 object(s)
--     public GET of those same objects            -> 200, real JPEG bytes
--
-- Zero visible objects in a folder that demonstrably contains many is the
-- whole story: reads worked because a PUBLIC bucket serves
-- `/object/public/...` straight from the CDN, bypassing RLS entirely. Nothing
-- in the app ever exercised an RLS-scoped read of this bucket, so the missing
-- policy stayed invisible until something tried to delete.
--
-- Compare `link-preview-images`, which has SELECT + INSERT + UPDATE + DELETE
-- for `authenticated` — its deletes work. `entry-images` had INSERT + DELETE
-- only.
--
-- WHAT THIS DOES
--   1. Adds the missing owner-scoped SELECT policy on `entry-images`.
--   2. Drops `entry_images_owner_delete` — the DELETE policy the first
--      revision of this migration added before the diagnosis was correct. It
--      is an exact duplicate of the pre-existing "Users can delete their own
--      entry images" and only adds confusion. Dropping it changes nothing:
--      the original policy still grants the DELETE.
--
-- The SELECT grant is strictly narrower than what the bucket already exposes:
-- these objects are ALREADY world-readable by URL. This only lets a signed-in
-- user enumerate the metadata of objects in their own `{uid}/` folder, which
-- is exactly the `{uid}/{uuid}.jpg` convention every upload uses
-- (ImageStorageRepository.uploadImageData, ProfileRepository.uploadAvatar) and
-- the same predicate `delete_account` uses server-side
-- (20260816_account_profile.sql). No other bucket is touched.
--
-- Idempotent. Safe to re-run.
-- ============================================================================

-- 1 · The missing piece: let a user see their own objects, so a delete can
--     find them.
drop policy if exists "entry_images_owner_select" on storage.objects;

create policy "entry_images_owner_select"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'entry-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- 2 · Remove the redundant duplicate DELETE policy added by this migration's
--     first revision. "Users can delete their own entry images" already covers
--     it. Skip this if you never applied that revision — the drop is a no-op.
drop policy if exists "entry_images_owner_delete" on storage.objects;


-- ============================================================================
-- Verification (read-only, after applying):
--
--   -- expect exactly one SELECT and one DELETE policy for entry-images:
--   select policyname, cmd, roles, qual
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and qual::text like '%entry-images%'
--    order by cmd;
--
-- Then in the app: create an entry with an image, note its public URL, delete
-- the entry, and re-fetch the URL with a cache-busting query string. Expect
-- 400 "Object not found" and NO image bytes. A signed-in user must still be
-- unable to list or remove anything under another uid's folder.
-- ============================================================================
