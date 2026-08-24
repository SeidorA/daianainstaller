BEGIN READ ONLY;
DO $$
BEGIN
  IF NOT has_table_privilege('service_role', 'public.tenant_message_quota_periods', 'SELECT') OR has_table_privilege('authenticated', 'public.tenant_message_quota_periods', 'SELECT') THEN RAISE EXCEPTION 'quota table grants are not hardened'; END IF;
  IF NOT has_function_privilege('service_role', 'public.list_studio_mapping_catalog()', 'EXECUTE') OR has_function_privilege('authenticated', 'public.list_studio_mapping_catalog()', 'EXECUTE') THEN RAISE EXCEPTION 'catalog must be service-role only'; END IF;
  IF (SELECT count(*) FROM public.history WHERE message_ref IS NULL) <> 0 THEN RAISE EXCEPTION 'history message_ref backfill is incomplete'; END IF;
  IF to_regclass('public.tenant_message_quota_periods') IS NULL OR to_regclass('public.tenant_message_quota_reservations') IS NULL THEN RAISE EXCEPTION 'quota objects are missing'; END IF;
  IF pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = 'public.reserve_tenant_message_quota(integer,text,text,text,text,text,timestamptz)'::regprocedure)) <> 'postgres' THEN RAISE EXCEPTION 'hardened quota RPC owner is wrong'; END IF;
END $$;
COMMIT;
