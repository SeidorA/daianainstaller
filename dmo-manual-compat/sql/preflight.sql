BEGIN READ ONLY;
DO $$
DECLARE
  populated boolean;
BEGIN
  IF to_regclass('private.daiana_installer_schema_migrations') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM private.daiana_installer_schema_migrations)' INTO populated;
  ELSE
    populated := false;
  END IF;
  IF NOT populated AND to_regclass('private.daiana_legacy_daianastudio_schema_migrations') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM private.daiana_legacy_daianastudio_schema_migrations)' INTO populated;
  END IF;
  IF populated THEN
    RAISE EXCEPTION 'populated Installer migration ledger blocks this manual package';
  END IF;
  IF (to_regnamespace('studio') IS NOT NULL)::integer + (to_regnamespace('daianastudio') IS NOT NULL)::integer <> 1 THEN
    RAISE EXCEPTION 'exactly one Studio schema is required; both or neither is unsafe';
  END IF;
  IF to_regnamespace('daianawebui') IS NULL THEN RAISE EXCEPTION 'WebUI schema is required for metadata fingerprinting'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN RAISE EXCEPTION 'required API roles are missing'; END IF;
  IF to_regclass('public.tenants') IS NULL OR to_regclass('public.tenant_plans') IS NULL OR to_regclass('public.aibot') IS NULL OR to_regclass('public.history') IS NULL THEN RAISE EXCEPTION 'quota prerequisites are missing'; END IF;
END $$;
COMMIT;
