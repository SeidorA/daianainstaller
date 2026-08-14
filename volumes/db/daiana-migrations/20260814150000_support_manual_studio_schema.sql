CREATE OR REPLACE FUNCTION public.list_studio_mapping_catalog()
RETURNS TABLE (
    "organizationId" text,
    "organizationName" text,
    "workspaceId" text,
    "workspaceName" text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    studio_schema text;
BEGIN
    IF to_regclass('studio.organization') IS NOT NULL THEN
        studio_schema := 'studio';
    ELSIF to_regclass('daianastudio.organization') IS NOT NULL THEN
        studio_schema := 'daianastudio';
    ELSE
        RAISE EXCEPTION 'Studio organization table is unavailable';
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT organization.id::text, organization.name, workspace.id::text, workspace.name
         FROM %I.organization organization
         LEFT JOIN %I.workspace workspace ON workspace."organizationId" = organization.id
         ORDER BY organization.name, workspace.name',
        studio_schema,
        studio_schema
    );
END;
$$;

ALTER FUNCTION public.list_studio_mapping_catalog() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_studio_mapping_catalog() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_studio_mapping_catalog() TO service_role;

NOTIFY pgrst, 'reload schema';
