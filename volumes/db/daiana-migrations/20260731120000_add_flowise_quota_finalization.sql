-- Provenance: daianapython commit 68565fb1870da340a6f5f3f6bc258f7bf3d70ab8
-- Canonical source SHA-256: 2c937d837d323b2a2bd867f2dbe94bab5f221248127dc791c33952a04bfbc72b
-- Installer adaptation: transaction wrappers removed; the runner owns the transaction.

-- Flowise/Studio owns conversation history. Consume the reservation and retain
-- the replay response without duplicating either turn in public.history.
CREATE OR REPLACE FUNCTION public.finalize_tenant_message_quota_without_history(
    p_request_id text,
    p_source text,
    p_response jsonb,
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tenant_id integer;
    v_bot_id text;
    v_user_id text;
    v_reservation public.tenant_message_quota_reservations%ROWTYPE;
    v_response jsonb;
    v_stored_result jsonb;
BEGIN
    IF coalesce(btrim(p_request_id), '') = '' OR coalesce(btrim(p_source), '') = ''
       OR jsonb_typeof(p_response) IS DISTINCT FROM 'object'
    THEN RETURN jsonb_build_object('status', 'invalid_input'); END IF;

    SELECT * INTO v_reservation
    FROM public.tenant_message_quota_reservations
    WHERE source = p_source AND "requestId" = p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF v_reservation.result->>'legacy' = 'true' THEN
        RETURN jsonb_build_object('status', 'legacy_unreplayable');
    END IF;

    v_bot_id := v_reservation.result->>'idBot';
    v_user_id := v_reservation.result->>'idUser';
    SELECT a."idTenant" INTO v_tenant_id
    FROM public.aibot a
    WHERE a."idBot"::text = v_bot_id;
    IF NOT FOUND OR v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'bot_not_billable');
    END IF;
    IF v_reservation."idTenant" <> v_tenant_id THEN
        RETURN jsonb_build_object('status', 'identity_mismatch');
    END IF;
    PERFORM public.reconcile_tenant_message_quota_reservations(v_tenant_id, p_at);
    SELECT * INTO v_reservation
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = v_tenant_id AND source = p_source AND "requestId" = p_request_id
    FOR UPDATE;
    IF v_reservation.status <> 'reserved' THEN
        RETURN jsonb_build_object(
            'status', 'already_' || v_reservation.status,
            'history', coalesce(v_reservation.result->'response'->'botHistorySave', '[]'::jsonb),
            'response', v_reservation.result->'response'
        );
    END IF;

    v_response := p_response || jsonb_build_object('botHistorySave', '[]'::jsonb);
    v_stored_result := v_reservation.result || jsonb_build_object('response', v_response);
    IF pg_column_size(v_stored_result) > 262144 THEN
        v_response := jsonb_build_object(
            'ok', true,
            'text', left(coalesce(p_response->>'text', ''), 8192),
            'type', 'degraded',
            'replayTruncated', true,
            'botHistorySave', '[]'::jsonb
        );
        v_stored_result := v_reservation.result || jsonb_build_object('response', v_response);
    END IF;
    IF pg_column_size(v_stored_result) > 262144 THEN
        RAISE EXCEPTION 'bounded replay response exceeds 256 KiB' USING ERRCODE = '22001';
    END IF;

    UPDATE public.tenant_message_quota_reservations
    SET status = 'consumed', "consumedAt" = p_at, result = v_stored_result
    WHERE "idTenant" = v_tenant_id AND source = p_source AND "requestId" = p_request_id;
    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" - 1,
        "consumedMessages" = "consumedMessages" + 1,
        "updatedAt" = p_at
    WHERE "idTenant" = v_tenant_id AND "periodStartAt" = v_reservation."periodStartAt";
    RETURN jsonb_build_object('status', 'consumed', 'history', '[]'::jsonb, 'response', v_response);
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_without_history(
    text, text, jsonb, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_without_history(
    text, text, jsonb, timestamptz
) TO service_role;
