CREATE OR REPLACE FUNCTION public.list_studio_mapping_catalog()
RETURNS TABLE (
    "organizationId" text,
    "organizationName" text,
    "workspaceId" text,
    "workspaceName" text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, studio
AS $$
    SELECT
        organization.id::text,
        organization.name,
        workspace.id::text,
        workspace.name
    FROM studio.organization organization
    LEFT JOIN studio.workspace workspace
        ON workspace."organizationId" = organization.id
    ORDER BY organization.name, workspace.name;
$$;

ALTER FUNCTION public.list_studio_mapping_catalog() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_studio_mapping_catalog() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_studio_mapping_catalog() TO service_role;

NOTIFY pgrst, 'reload schema';
