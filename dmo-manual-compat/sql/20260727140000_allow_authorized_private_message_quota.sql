-- Provenance: daianapython commit 16e161f468f1976d15ba40b1312dc5f247d64dab
-- Canonical source SHA-256: f8b47aa6bdb7ae63e765e9e42b4bdc756782e1b06ffa286ebf3446474605c896
-- Installer adaptation: transaction wrappers removed; the runner owns the transaction.

-- The replay-aware reservation already binds the verified tenant, bot, user,
-- and request fingerprint. Finalization may therefore resolve either a public
-- bot or a private bot that Python authorized before reserving the turn.
CREATE OR REPLACE FUNCTION public.finalize_tenant_message_quota_turn(
    p_request_id text,
    p_source text,
    p_history jsonb,
    p_response jsonb,
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tenant_id integer;
    v_reservation public.tenant_message_quota_reservations%ROWTYPE;
    v_history jsonb;
    v_response jsonb;
    v_stored_result jsonb;
BEGIN
    IF coalesce(btrim(p_request_id), '') = '' OR coalesce(btrim(p_source), '') = ''
       OR jsonb_typeof(p_history) IS DISTINCT FROM 'array' OR jsonb_array_length(p_history) <> 2
       OR p_history->0->>'created' <> 'user' OR p_history->1->>'created' <> 'bot'
       OR p_history->0->>'idBot' IS NULL OR p_history->0->>'idBot' <> p_history->1->>'idBot'
       OR p_history->0->>'idUser' IS NULL OR p_history->0->>'idUser' <> p_history->1->>'idUser'
       OR jsonb_typeof(p_response) IS DISTINCT FROM 'object'
    THEN RETURN jsonb_build_object('status', 'invalid_input'); END IF;

    SELECT a."idTenant" INTO v_tenant_id
    FROM public.aibot a
    WHERE a."idBot"::text = p_history->0->>'idBot';
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'bot_not_billable'); END IF;

    PERFORM public.reconcile_tenant_message_quota_reservations(v_tenant_id, p_at);
    SELECT * INTO v_reservation
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = v_tenant_id AND source = p_source AND "requestId" = p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF v_reservation.result->>'legacy' = 'true' THEN
        RETURN jsonb_build_object('status', 'legacy_unreplayable');
    END IF;
    IF v_reservation.result->>'idBot' IS DISTINCT FROM p_history->0->>'idBot'
       OR v_reservation.result->>'idUser' IS DISTINCT FROM p_history->0->>'idUser'
    THEN RETURN jsonb_build_object('status', 'identity_mismatch'); END IF;
    IF v_reservation.status <> 'reserved' THEN
        RETURN jsonb_build_object(
            'status', 'already_' || v_reservation.status,
            'history', coalesce(v_reservation.result->'response'->'botHistorySave', '[]'::jsonb),
            'response', v_reservation.result->'response'
        );
    END IF;

    WITH inserted AS (
        INSERT INTO public.history ("idBot", "idUser", message, created, metadata, dataframe)
        SELECT "idBot", "idUser", message, created, metadata, dataframe
        FROM jsonb_populate_recordset(NULL::public.history, p_history)
        RETURNING *
    )
    SELECT coalesce(jsonb_agg(to_jsonb(i)) FILTER (WHERE i.created = 'bot'), '[]'::jsonb)
    INTO v_history FROM inserted i;
    v_response := p_response || jsonb_build_object('botHistorySave', v_history);
    v_stored_result := v_reservation.result || jsonb_build_object('response', v_response);
    IF pg_column_size(v_stored_result) > 262144 THEN
        v_response := jsonb_build_object(
            'ok', true,
            'text', left(coalesce(p_response->>'text', ''), 8192),
            'type', 'degraded',
            'replayTruncated', true,
            'botHistorySave', jsonb_build_array(jsonb_build_object(
                'id', v_history->0->'id', 'idBot', v_history->0->'idBot',
                'idUser', v_history->0->'idUser', 'created', 'bot',
                'message', left(coalesce(v_history->0->>'message', ''), 8192),
                'createdAt', v_history->0->'createdAt'
            ))
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
    RETURN jsonb_build_object(
        'status', 'consumed', 'history', v_history, 'response', v_response
    );
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) TO service_role;
