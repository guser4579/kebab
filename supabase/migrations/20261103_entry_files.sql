-- ============================================================================
-- Kebab · Private bucket for file attachments (2026-11-03)
--
-- WHY
-- Thoughts can now carry files: PDFs, videos, and anything else (audio
-- recordings next). Documents can be far more sensitive than photos, so the
-- `entry-images` model of an unguessable public URL isn't good enough. These
-- originals go in a PRIVATE bucket, and the app reaches them only through
-- short-lived signed URLs, created when the user opens a file.
--
-- WHAT THIS DOES
--   1. Creates `entry-files`: private, 50 MB per object, no MIME allowlist
--      (any file type is allowed; the size is the only limit).
--   2. Adds owner-scoped SELECT + INSERT + DELETE policies for `authenticated`,
--      on the `{uid}/{uuid}.{ext}` convention every upload uses.
--      SELECT is not optional. Storage's delete first LOOKS UP the rows named
--      by the request, under RLS as the calling user. With no SELECT policy it
--      finds nothing, deletes nothing, and answers 200 [] — exactly what broke
--      `entry-images` deletes (see 20260820_entry_images_owner_select.sql).
--      There is deliberately no UPDATE policy. Objects are never overwritten:
--      a retry reuses the same path, and "already exists" counts as uploaded.
--   3. Re-creates delete_account() so it also removes `entry-files` records.
--      Everything else it does is unchanged from
--      20260816_account_profile.sql.
--
-- Thumbnails stay in `entry-images` under the same owner folder, so the
-- existing policies and delete_account() clause already cover them.
--
-- Idempotent. Safe to re-run. The app build that writes file attachments must
-- not ship before this is live.
-- ============================================================================

-- 1 · The bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('entry-files', 'entry-files', false, 52428800, null)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- 2 · Owner-only access, keyed on the first path segment.
drop policy if exists "entry_files_owner_select" on storage.objects;
create policy "entry_files_owner_select"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'entry-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "entry_files_owner_insert" on storage.objects;
create policy "entry_files_owner_insert"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'entry-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "entry_files_owner_delete" on storage.objects;
create policy "entry_files_owner_delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'entry-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- 3 · delete_account(): same ordered removal as before, plus `entry-files`.
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
     or (bucket_id = 'entry-files'
         and (storage.foldername(name))[1] = v_user_id::text)
     or (bucket_id = 'link-preview-images'
         and owner_id = v_user_id::text);

  delete from auth.users
  where id = v_user_id;
end;
$function$;

revoke execute on function public.delete_account() from public;
revoke execute on function public.delete_account() from anon;
grant  execute on function public.delete_account() to authenticated, service_role;


-- ============================================================================
-- Verification (read-only, after applying):
--
--   select id, public, file_size_limit, allowed_mime_types
--     from storage.buckets where id = 'entry-files';
--
--   -- expect exactly one SELECT, one INSERT and one DELETE policy:
--   select policyname, cmd, roles
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and policyname like 'entry_files_%'
--    order by cmd;
--
-- Then in the app: attach a file, send, delete the thought, and confirm the
-- object is gone from `entry-files` in the dashboard.
-- ============================================================================
