-- ============================================================================
-- Kebab · V1 feedback table
-- Drafted 2026-08-17. Write-only from the app: authenticated users insert
-- their own row; nothing in the client can read, update, or delete feedback.
-- The maker reads submissions in the dashboard (service role bypasses RLS).
-- user_id survives as NULL if the account is later deleted (feedback is
-- addressed to the maker, not user-owned data).
-- ============================================================================

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  name text,
  email text,
  message text not null check (char_length(message) <= 10000),
  app_version text,
  created_at timestamptz not null default now()
);

alter table public.feedback enable row level security;

drop policy if exists "Users can submit feedback" on public.feedback;
create policy "Users can submit feedback" on public.feedback
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

-- No select/update/delete policies on purpose. Trim the default grants so
-- the API surface matches: insert only, authenticated only.
revoke all on public.feedback from anon, public;
revoke select, update, delete on public.feedback from authenticated;
grant insert on public.feedback to authenticated;

-- Verification (read-only, after applying):
-- select policyname, cmd from pg_policies
--   where schemaname = 'public' and tablename = 'feedback';
