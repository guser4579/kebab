-- ============================================================================
-- Kebab · Entry reminders (V1)
-- Drafted 2026-08-19.
--
-- One durable record per entry ("bring this back to me later"). iOS delivers
-- it with a LOCAL notification; this table is the source of truth for the
-- reminder itself, so the record survives relaunch, reinstall, and the local
-- notification queue being wiped. No push infrastructure is involved.
--
-- Shape notes:
--   * entry_id is the PRIMARY KEY — the "one active reminder per entry"
--     rule expressed in SQL. The client always upserts.
--   * fire_at is the delivery instant for BOTH modes. For mode='random' it
--     is generated once on the client and never shown to the user; nothing
--     server-side ever re-rolls it.
--   * acknowledged_at ends the fired/unread state (user revisited the entry).
--     note_dismissed_at ends the delivered note banner.
--   * entry_id → entries ON DELETE CASCADE: deleting an entry purges its
--     reminder, so no orphan record can outlive it. delete_account() deletes
--     entries first, so account deletion cascades through this table too.
--
-- All statements idempotent.
-- ============================================================================

create table if not exists public.entry_reminders (
  entry_id          uuid primary key
                      references public.entries(id) on delete cascade,
  user_id           uuid not null
                      references auth.users(id) on delete cascade,
  fire_at           timestamptz not null,
  mode              text not null default 'scheduled',
  note              text,
  created_at        timestamptz not null default now(),
  acknowledged_at   timestamptz,
  note_dismissed_at timestamptz
);

alter table public.entry_reminders drop constraint if exists entry_reminders_mode_check;
alter table public.entry_reminders add  constraint entry_reminders_mode_check
  check (mode in ('scheduled', 'random'));

-- Matches the client-side note limit.
alter table public.entry_reminders drop constraint if exists entry_reminders_note_length;
alter table public.entry_reminders add  constraint entry_reminders_note_length
  check (note is null or char_length(note) <= 280);

-- The only query the client makes is "all my reminders".
create index if not exists entry_reminders_user_idx
  on public.entry_reminders (user_id);

alter table public.entry_reminders enable row level security;

-- Own rows only, all four verbs. (select auth.uid()) per the initplan rule.
drop policy if exists "Users can read own reminders" on public.entry_reminders;
create policy "Users can read own reminders" on public.entry_reminders
  for select
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own reminders" on public.entry_reminders;
create policy "Users can insert own reminders" on public.entry_reminders
  for insert
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update own reminders" on public.entry_reminders;
create policy "Users can update own reminders" on public.entry_reminders
  for update
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own reminders" on public.entry_reminders;
create policy "Users can delete own reminders" on public.entry_reminders
  for delete
  using ((select auth.uid()) = user_id);

revoke all on table public.entry_reminders from anon;
grant select, insert, update, delete on table public.entry_reminders to authenticated;

-- ============================================================================
-- Verification (read-only, after applying):
-- select column_name, data_type from information_schema.columns
--   where table_schema='public' and table_name='entry_reminders';
-- select policyname, cmd from pg_policies
--   where schemaname='public' and tablename='entry_reminders';
-- select conname, confdeltype from pg_constraint
--   where conrelid='public.entry_reminders'::regclass;
-- ============================================================================
