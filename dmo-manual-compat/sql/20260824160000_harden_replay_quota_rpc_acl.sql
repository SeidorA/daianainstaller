-- Corrective ACL-only operation for replay-aware quota RPCs. CREATE OR REPLACE
-- preserves explicit grants, and Supabase API-role default privileges can grant
-- new overloads to anon and authenticated unless each role is revoked directly.
REVOKE EXECUTE ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, text, text, text, timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.finalize_tenant_message_quota_without_history(
    text, text, jsonb, timestamptz
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, text, text, text, timestamptz
) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_without_history(
    text, text, jsonb, timestamptz
) TO service_role;

NOTIFY pgrst, 'reload schema';
