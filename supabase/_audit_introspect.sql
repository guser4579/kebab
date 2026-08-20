-- ============================================================================
-- Kebab · READ-ONLY security introspection (2026-08-18 hardening pass)
--
-- Purpose: dump the authoritative backend authorization state that lives in
-- the Supabase dashboard (not in repo migrations) so the RLS / RPC / storage
-- audit can be proven from source rather than reasoned. NOTHING here writes,
-- alters, or drops. Safe to run on production. Run all sections; paste the
-- full output back.
--
-- How to run: Supabase Dashboard → SQL Editor → paste → Run. Each SELECT is
-- independent; if one errors (permissions), continue with the rest.
-- ============================================================================

-- 1. RLS enabled + forced on every public table --------------------------------
select c.relname                              as table_name,
       c.relrowsecurity                       as rls_enabled,
       c.relforcerowsecurity                  as rls_forced
from   pg_class c
join   pg_namespace n on n.oid = c.relnamespace
where  n.nspname = 'public' and c.relkind = 'r'
order  by c.relname;

-- 2. Every RLS policy: command, roles, USING, WITH CHECK ------------------------
select tablename,
       policyname,
       cmd,
       roles,
       qual        as using_expr,
       with_check  as with_check_expr
from   pg_policies
where  schemaname = 'public'
order  by tablename, cmd, policyname;

-- 3. Every public function: security mode, owner, search_path, grants -----------
select p.proname                                              as function_name,
       pg_get_function_identity_arguments(p.oid)              as args,
       case when p.prosecdef then 'DEFINER' else 'INVOKER' end as security,
       pg_get_userbyid(p.proowner)                            as owner,
       p.proconfig                                            as settings,   -- search_path etc.
       p.proacl                                               as grants
from   pg_proc p
join   pg_namespace n on n.oid = p.pronamespace
where  n.nspname = 'public'
order  by p.proname;

-- 4. Full source of every public function (the load-bearing audit artifact) ----
--    Look for: does it derive identity from auth.uid()? does it verify
--    ownership of EVERY referenced entry / collection? does it trust a
--    client-supplied user id? is dynamic SQL used?
select p.proname as function_name,
       pg_get_functiondef(p.oid) as definition
from   pg_proc p
join   pg_namespace n on n.oid = p.pronamespace
where  n.nspname = 'public'
order  by p.proname;

-- 5. Table-level grants to anon / authenticated (privilege surface) -------------
select table_name, grantee, privilege_type
from   information_schema.role_table_grants
where  table_schema = 'public'
   and grantee in ('anon','authenticated','public')
order  by table_name, grantee, privilege_type;

-- 6. Foreign keys + delete actions (cascade / restrict / set null) --------------
select conrelid::regclass         as child_table,
       conname                    as constraint_name,
       pg_get_constraintdef(oid)  as definition
from   pg_constraint
where  contype = 'f'
   and connamespace = 'public'::regnamespace
order  by child_table, conname;

-- 7. CHECK + UNIQUE + NOT NULL of interest on the core tables -------------------
select conrelid::regclass as tbl, conname, contype,
       pg_get_constraintdef(oid) as def
from   pg_constraint
where  connamespace = 'public'::regnamespace
   and conrelid::regclass::text in
       ('entries','collections','collection_entries','collection_members','profiles','feedback')
order  by tbl, contype, conname;

-- 8. Columns of the core tables (confirm user_id / created_by / defaults) -------
select table_name, column_name, data_type, is_nullable, column_default
from   information_schema.columns
where  table_schema = 'public'
   and table_name in
       ('entries','collections','collection_entries','collection_members','profiles','feedback')
order  by table_name, ordinal_position;

-- 9. Storage buckets: public flag + limits -------------------------------------
select id, name, public, file_size_limit, allowed_mime_types
from   storage.buckets
order  by id;

-- 10. Storage RLS policies (who can read/insert/update/delete objects) ----------
select policyname, cmd, roles, qual as using_expr, with_check as with_check_expr
from   pg_policies
where  schemaname = 'storage' and tablename = 'objects'
order  by cmd, policyname;

-- 11. Any triggers on the core tables (e.g. ownership stamping, signup) ---------
select event_object_table as tbl, trigger_name, action_timing, event_manipulation,
       action_statement
from   information_schema.triggers
where  trigger_schema in ('public','auth')
order  by tbl, trigger_name;
