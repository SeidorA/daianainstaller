
ALTER TABLE public.tenant_message_quota_reservations
    ADD COLUMN IF NOT EXISTS result jsonb;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.tenant_message_quota_reservations'::regclass
          AND conname = 'tenant_message_quota_reservation_result_object'
    ) THEN
        ALTER TABLE public.tenant_message_quota_reservations
            ADD CONSTRAINT tenant_message_quota_reservation_result_object
            CHECK (result IS NULL OR jsonb_typeof(result) = 'object');
    END IF;
END $$;

COMMENT ON COLUMN public.tenant_message_quota_reservations.result IS
    'Bound request identity and bounded replay response for idempotent public chat requests.';

-- Remove signatures produced only by the accidentally edited historical file.
-- The immutable historical four-argument functions remain available below.
DROP FUNCTION IF EXISTS public.reserve_tenant_message_quota(
    integer, text, text, timestamptz, text, text, text
);
DROP FUNCTION IF EXISTS public.finalize_tenant_message_quota_turn(
    text, text, jsonb, timestamptz, jsonb
);

-- Reconstruct the deployed compatibility implementation even when the edited
-- historical migration created only the accidental seven-argument overload.
CREATE OR REPLACE FUNCTION public.reserve_tenant_message_quota(
    p_tenant_id integer,
    p_request_id text,
    p_source text DEFAULT 'daiana_python',
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_plan public.tenant_plans%ROWTYPE;
    v_existing public.tenant_message_quota_reservations%ROWTYPE;
    v_start timestamptz;
    v_end timestamptz;
    v_consumed integer;
    v_reserved integer;
    v_result jsonb;
BEGIN
    IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
        RAISE EXCEPTION 'request ID is required';
    END IF;
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'quota source is required';
    END IF;

    SELECT * INTO v_plan
    FROM public.tenant_plans
    WHERE "idTenant" = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('allowed', true, 'status', 'not_enforced', 'tenantId', p_tenant_id);
    END IF;
    IF v_plan.status <> 'active' THEN
        RETURN jsonb_build_object('allowed', false, 'status', 'inactive_plan', 'tenantId', p_tenant_id);
    END IF;
    IF v_plan."expiresAt" IS NOT NULL AND p_at >= v_plan."expiresAt" THEN
        RETURN jsonb_build_object(
            'allowed', false, 'status', 'license_expired', 'tenantId', p_tenant_id,
            'expiresAt', v_plan."expiresAt", 'planName', v_plan."planName"
        );
    END IF;
    IF v_plan."maxMessages" IS NULL OR v_plan."maxMessages" < 0 THEN
        RETURN jsonb_build_object('allowed', false, 'status', 'invalid_plan', 'tenantId', p_tenant_id);
    END IF;

    PERFORM public.reconcile_tenant_message_quota_reservations(p_tenant_id, p_at);

    SELECT b."periodStartAt", b."periodEndAt" INTO v_start, v_end
    FROM public.tenant_message_quota_period_bounds(v_plan."periodStartAt", p_at) b;

    SELECT * INTO v_existing
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = p_tenant_id
      AND source = p_source
      AND "requestId" = p_request_id
    FOR UPDATE;

    IF FOUND AND (v_existing."periodStartAt" <> v_start OR v_existing.status <> 'released') THEN
        v_result := coalesce(
            public.tenant_message_quota_usage_json(p_tenant_id, v_existing."periodStartAt"),
            jsonb_build_object('tenantId', p_tenant_id)
        );
        RETURN v_result || jsonb_build_object(
            'allowed', false,
            'status', CASE
                WHEN v_existing."periodStartAt" <> v_start THEN 'request_id_reused'
                WHEN v_existing.status = 'reserved' THEN 'already_reserved'
                WHEN v_existing.status = 'consumed' THEN 'already_consumed'
                ELSE 'already_released'
            END,
            'requestId', p_request_id,
            'source', p_source
        );
    END IF;

    INSERT INTO public.tenant_message_quota_periods (
        "idTenant", "periodStartAt", "periodEndAt", "messageLimit", "consumedMessages"
    )
    SELECT
        p_tenant_id,
        v_start,
        v_end,
        v_plan."maxMessages",
        count(h.id)::integer
    FROM public.history h
    JOIN public.aibot a ON a."idBot" = h."idBot"
    WHERE a."idTenant" = p_tenant_id
      AND a.botpublic IS TRUE
      AND h.created = 'bot'
      AND h."createdAt" >= v_start
      AND h."createdAt" < v_end
    ON CONFLICT ("idTenant", "periodStartAt") DO NOTHING;

    UPDATE public.tenant_message_quota_periods
    SET "messageLimit" = v_plan."maxMessages", "updatedAt" = p_at
    WHERE "idTenant" = p_tenant_id
      AND "periodStartAt" = v_start;

    SELECT "consumedMessages", "reservedMessages" INTO v_consumed, v_reserved
    FROM public.tenant_message_quota_periods
    WHERE "idTenant" = p_tenant_id
      AND "periodStartAt" = v_start
    FOR UPDATE;

    IF v_consumed + v_reserved >= v_plan."maxMessages" THEN
        RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_start)
            || jsonb_build_object('allowed', false, 'status', 'exhausted');
    END IF;

    IF v_existing."requestId" IS NOT NULL THEN
        UPDATE public.tenant_message_quota_reservations
        SET status = 'reserved', "reservedAt" = p_at, "releasedAt" = NULL, "consumedAt" = NULL
        WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id;
    ELSE
        INSERT INTO public.tenant_message_quota_reservations (
            "idTenant", source, "requestId", "periodStartAt", "reservedAt"
        ) VALUES (p_tenant_id, p_source, p_request_id, v_start, p_at);
    END IF;

    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" + 1, "updatedAt" = p_at
    WHERE "idTenant" = p_tenant_id AND "periodStartAt" = v_start;

    RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_start)
        || jsonb_build_object(
            'allowed', true, 'status', 'reserved',
            'requestId', p_request_id, 'source', p_source
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_tenant_message_quota_turn(p_request_id text, p_source text,
    p_history jsonb, p_at timestamptz DEFAULT now()) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tenant_id integer; v_reservation public.tenant_message_quota_reservations%ROWTYPE; v_history jsonb;
BEGIN
    IF coalesce(btrim(p_request_id), '') = '' OR coalesce(btrim(p_source), '') = '' OR jsonb_typeof(p_history) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_history) <> 2 OR p_history->0->>'created' <> 'user' OR p_history->1->>'created' <> 'bot'
       OR p_history->0->>'idBot' IS NULL OR p_history->0->>'idBot' <> p_history->1->>'idBot' OR p_history->0->>'idUser' IS NULL
       OR p_history->0->>'idUser' <> p_history->1->>'idUser' THEN RETURN jsonb_build_object('status', 'invalid_input'); END IF;
    SELECT a."idTenant" INTO v_tenant_id FROM public.aibot a
    WHERE a."idBot"::text = p_history->0->>'idBot' AND a.botpublic IS TRUE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'bot_not_billable'); END IF;
    PERFORM public.reconcile_tenant_message_quota_reservations(v_tenant_id, p_at);
    SELECT * INTO v_reservation FROM public.tenant_message_quota_reservations WHERE "idTenant" = v_tenant_id
      AND source = p_source AND "requestId" = p_request_id FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF v_reservation.status <> 'reserved' THEN RETURN jsonb_build_object('status', 'already_' || v_reservation.status); END IF;
    WITH inserted AS (
        INSERT INTO public.history ("idBot", "idUser", message, created, metadata, dataframe)
        SELECT "idBot", "idUser", message, created, metadata, dataframe
        FROM jsonb_populate_recordset(NULL::public.history, p_history) RETURNING *
    )
    SELECT coalesce(jsonb_agg(to_jsonb(i)) FILTER (WHERE i.created = 'bot'), '[]'::jsonb)
    INTO v_history FROM inserted i;
    UPDATE public.tenant_message_quota_reservations SET status = 'consumed', "consumedAt" = p_at
    WHERE "idTenant" = v_tenant_id
      AND source = p_source AND "requestId" = p_request_id;
    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" - 1,
        "consumedMessages" = "consumedMessages" + 1, "updatedAt" = p_at
    WHERE "idTenant" = v_tenant_id AND "periodStartAt" = v_reservation."periodStartAt";
    RETURN jsonb_build_object('status', 'consumed', 'history', v_history);
END;
$$;

UPDATE public.tenant_message_quota_reservations
SET result = jsonb_build_object('legacy', true)
WHERE result IS NULL;

CREATE OR REPLACE FUNCTION public.mark_legacy_message_quota_reservation()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF NEW.result IS NULL THEN NEW.result := jsonb_build_object('legacy', true); END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS mark_legacy_message_quota_reservation
    ON public.tenant_message_quota_reservations;
CREATE TRIGGER mark_legacy_message_quota_reservation
BEFORE INSERT ON public.tenant_message_quota_reservations
FOR EACH ROW EXECUTE FUNCTION public.mark_legacy_message_quota_reservation();

-- Keep the deployed four-argument RPC for existing callers. The new overload
-- requires bound identity inputs, while source and evaluation time remain optional.
CREATE OR REPLACE FUNCTION public.reserve_tenant_message_quota(
    p_tenant_id integer,
    p_request_id text,
    p_bot_id text,
    p_user_id text,
    p_fingerprint text,
    p_source text DEFAULT 'daiana_python',
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_existing public.tenant_message_quota_reservations%ROWTYPE;
    v_result jsonb;
BEGIN
    IF coalesce(octet_length(p_bot_id), 257) > 256 OR coalesce(octet_length(p_user_id), 257) > 256 OR coalesce(p_fingerprint, '') !~ '^[0-9a-f]{64}$'
    THEN RETURN jsonb_build_object('allowed', false, 'status', 'invalid_identity'); END IF;
    SELECT * INTO v_existing
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id
    FOR UPDATE;

    IF FOUND AND v_existing.result->>'legacy' = 'true' THEN
        RETURN jsonb_build_object('allowed', false, 'status', 'legacy_unreplayable');
    END IF;
    IF FOUND AND (
        v_existing.result->>'idBot' IS DISTINCT FROM p_bot_id
        OR v_existing.result->>'idUser' IS DISTINCT FROM p_user_id
        OR v_existing.result->>'fingerprint' IS DISTINCT FROM p_fingerprint
    ) THEN
        RETURN jsonb_build_object('allowed', false, 'status', 'identity_mismatch');
    END IF;
    IF FOUND AND v_existing.status = 'consumed' THEN
        RETURN jsonb_build_object(
            'allowed', false, 'status', 'already_consumed', 'requestId', p_request_id,
            'history', coalesce(v_existing.result->'response'->'botHistorySave', '[]'::jsonb),
            'response', v_existing.result->'response'
        );
    END IF;

    v_result := public.reserve_tenant_message_quota(
        p_tenant_id, p_request_id, p_source, p_at
    );
    IF v_result->>'status' = 'reserved' THEN
        UPDATE public.tenant_message_quota_reservations
        SET result = jsonb_build_object(
            'idBot', p_bot_id, 'idUser', p_user_id, 'fingerprint', p_fingerprint
        )
        WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id;
    END IF;
    RETURN v_result;
END;
$$;

-- Keep the historical four-argument finalizer for rolling compatibility. The
-- replay-aware overload has a distinct required response argument.
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

    SELECT a."idTenant" INTO v_tenant_id FROM public.aibot a
    WHERE a."idBot"::text = p_history->0->>'idBot' AND a.botpublic IS TRUE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'bot_not_billable'); END IF;
    PERFORM public.reconcile_tenant_message_quota_reservations(v_tenant_id, p_at);
    SELECT * INTO v_reservation FROM public.tenant_message_quota_reservations
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
        FROM jsonb_populate_recordset(NULL::public.history, p_history) RETURNING *
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
    SET status = 'consumed', "consumedAt" = p_at,
        result = v_stored_result
    WHERE "idTenant" = v_tenant_id AND source = p_source AND "requestId" = p_request_id;
    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" - 1,
        "consumedMessages" = "consumedMessages" + 1, "updatedAt" = p_at
    WHERE "idTenant" = v_tenant_id AND "periodStartAt" = v_reservation."periodStartAt";
    RETURN jsonb_build_object('status', 'consumed', 'history', v_history, 'response', v_response);
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, text, text, text, timestamptz
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, timestamptz
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, timestamptz
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_legacy_message_quota_reservation() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, text, text, text, timestamptz
) TO service_role;
GRANT EXECUTE ON FUNCTION public.reserve_tenant_message_quota(
    integer, text, text, timestamptz
) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, jsonb, timestamptz
) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(
    text, text, jsonb, timestamptz
) TO service_role;

NOTIFY pgrst, 'reload schema';
