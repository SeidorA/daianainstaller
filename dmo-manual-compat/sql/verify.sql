BEGIN READ ONLY;
DO $$
DECLARE
  signature text;
BEGIN
  IF NOT has_table_privilege('service_role', 'public.tenant_message_quota_periods', 'SELECT') OR has_table_privilege('authenticated', 'public.tenant_message_quota_periods', 'SELECT') THEN RAISE EXCEPTION 'quota table grants are not hardened'; END IF;
  IF NOT has_function_privilege('service_role', 'public.list_studio_mapping_catalog()', 'EXECUTE') OR has_function_privilege('authenticated', 'public.list_studio_mapping_catalog()', 'EXECUTE') THEN RAISE EXCEPTION 'catalog must be service-role only'; END IF;
  IF (SELECT count(*) FROM public.history WHERE message_ref IS NULL) <> 0 THEN RAISE EXCEPTION 'history message_ref backfill is incomplete'; END IF;
  IF to_regclass('public.tenant_message_quota_periods') IS NULL OR to_regclass('public.tenant_message_quota_reservations') IS NULL THEN RAISE EXCEPTION 'quota objects are missing'; END IF;
  IF pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = 'public.reserve_tenant_message_quota(integer,text,text,text,text,text,timestamptz)'::regprocedure)) <> 'postgres' THEN RAISE EXCEPTION 'hardened quota RPC owner is wrong'; END IF;
  FOREACH signature IN ARRAY ARRAY[
    'public.reserve_tenant_message_quota(integer,text,text,timestamptz)',
    'public.reserve_tenant_message_quota(integer,text,text,text,text,text,timestamptz)',
    'public.finalize_tenant_message_quota_turn(text,text,jsonb,timestamptz)',
    'public.finalize_tenant_message_quota_turn(text,text,jsonb,jsonb,timestamptz)',
    'public.finalize_tenant_message_quota_without_history(text,text,jsonb,timestamptz)'
  ] LOOP
    IF to_regprocedure(signature) IS NULL THEN
      RAISE EXCEPTION 'required quota RPC is missing: %', signature;
    END IF;
    IF NOT has_function_privilege('service_role', signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'service_role cannot execute required quota RPC: %', signature;
    END IF;
    IF has_function_privilege('anon', signature, 'EXECUTE')
       OR has_function_privilege('authenticated', signature, 'EXECUTE')
       OR EXISTS (
         SELECT 1
         FROM pg_proc function_catalog
         CROSS JOIN LATERAL aclexplode(coalesce(
           function_catalog.proacl,
           acldefault('f', function_catalog.proowner)
         )) function_acl
         WHERE function_catalog.oid = to_regprocedure(signature)
           AND function_acl.grantee = 0
           AND function_acl.privilege_type = 'EXECUTE'
       ) THEN
      RAISE EXCEPTION 'forbidden role can execute quota RPC: %', signature;
    END IF;
  END LOOP;
END $$;
COMMIT;
