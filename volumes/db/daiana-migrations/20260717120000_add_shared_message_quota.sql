-- Installer adaptation of the canonical DaianaPython migration:
-- daianapython/supabase/migrations/20260717120000_add_shared_message_quota.sql
-- Canonical source baseline commit: 9806ee4799b95658bbded4ccd7da46877c56a51f
-- Canonical source baseline tree: bd5949be0ae29658218245a3934955352a9c171b
-- Canonical source content SHA-256: a39c1f4d8d2f7cfb7ff4122fd41fd8938352ec278a7a09a477dd196df871d85d
-- Approved installer adaptation is intentionally non-byte-identical: runner transaction/history,
-- privilege hardening, seed-safe provisioning, and PostgREST reload intentionally differ.

-- Studio identifiers are stored explicitly. They must never be inferred from
-- customer, email, or display-name data shared by the two products.
CREATE TABLE public.tenant_studio_organization_mappings (
    "idTenant" integer PRIMARY KEY
        REFERENCES public.tenants("idTenant") ON DELETE CASCADE,
    "studioOrganizationId" text NOT NULL UNIQUE,
    "createdAt" timestamptz NOT NULL DEFAULT now(),
    "updatedAt" timestamptz NOT NULL DEFAULT now(),
    UNIQUE ("idTenant", "studioOrganizationId"),
    CONSTRAINT tenant_studio_organization_id_not_blank
        CHECK (btrim("studioOrganizationId") <> '')
);

COMMENT ON TABLE public.tenant_studio_organization_mappings IS
    'Authoritative explicit mapping from a Daiana tenant to one Studio organization.';

CREATE TABLE public.tenant_studio_workspace_mappings (
    "idTenant" integer NOT NULL,
    "studioOrganizationId" text NOT NULL,
    "studioWorkspaceId" text PRIMARY KEY,
    "createdAt" timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tenant_studio_workspace_organization_fkey
        FOREIGN KEY ("idTenant", "studioOrganizationId")
        REFERENCES public.tenant_studio_organization_mappings
            ("idTenant", "studioOrganizationId")
        ON DELETE CASCADE,
    CONSTRAINT tenant_studio_workspace_organization_id_not_blank
        CHECK (btrim("studioOrganizationId") <> ''),
    CONSTRAINT tenant_studio_workspace_id_not_blank
        CHECK (btrim("studioWorkspaceId") <> '')
);

COMMENT ON TABLE public.tenant_studio_workspace_mappings IS
    'Optional Studio workspaces belonging to an explicitly mapped organization; a workspace maps to exactly one tenant.';

CREATE INDEX tenant_studio_workspace_tenant_idx
    ON public.tenant_studio_workspace_mappings ("idTenant");

CREATE OR REPLACE FUNCTION public.mutate_tenant_studio_organization_mapping(
    p_action text,
    p_tenant_id integer,
    p_organization_id uuid,
    p_current_organization_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_current_organization_id text;
BEGIN
    IF p_action NOT IN ('create', 'update', 'delete') THEN
        RETURN jsonb_build_object('status', 'invalid_action');
    END IF;
    IF p_tenant_id IS NULL OR p_organization_id IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_input');
    END IF;
    IF p_action IN ('update', 'delete') AND p_current_organization_id IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_input');
    END IF;

    PERFORM pg_advisory_xact_lock(18471, p_tenant_id);

    IF NOT EXISTS (SELECT 1 FROM public.tenants WHERE "idTenant" = p_tenant_id) THEN
        RETURN jsonb_build_object('status', 'tenant_not_found');
    END IF;

    SELECT "studioOrganizationId" INTO v_current_organization_id
    FROM public.tenant_studio_organization_mappings
    WHERE "idTenant" = p_tenant_id;

    IF p_action = 'create' THEN
        IF v_current_organization_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'status',
                CASE WHEN v_current_organization_id = p_organization_id::text
                    THEN 'organization_exists' ELSE 'tenant_conflict' END
            );
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.tenant_studio_organization_mappings
            WHERE "studioOrganizationId" = p_organization_id::text
        ) THEN
            RETURN jsonb_build_object('status', 'organization_conflict');
        END IF;

        BEGIN
            INSERT INTO public.tenant_studio_organization_mappings
                ("idTenant", "studioOrganizationId")
            VALUES (p_tenant_id, p_organization_id::text);
        EXCEPTION WHEN unique_violation THEN
            RETURN jsonb_build_object('status', 'organization_conflict');
        END;
        RETURN jsonb_build_object('status', 'created');
    END IF;

    IF v_current_organization_id IS NULL
       OR v_current_organization_id <> p_current_organization_id::text THEN
        RETURN jsonb_build_object('status', 'stale_mapping');
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.tenant_studio_workspace_mappings
        WHERE "idTenant" = p_tenant_id
    ) THEN
        RETURN jsonb_build_object('status', 'workspace_mappings_exist');
    END IF;

    IF p_action = 'update' THEN
        IF EXISTS (
            SELECT 1 FROM public.tenant_studio_organization_mappings
            WHERE "studioOrganizationId" = p_organization_id::text
              AND "idTenant" <> p_tenant_id
        ) THEN
            RETURN jsonb_build_object('status', 'organization_conflict');
        END IF;
        BEGIN
            UPDATE public.tenant_studio_organization_mappings
            SET "studioOrganizationId" = p_organization_id::text, "updatedAt" = now()
            WHERE "idTenant" = p_tenant_id;
        EXCEPTION WHEN unique_violation THEN
            RETURN jsonb_build_object('status', 'organization_conflict');
        END;
        RETURN jsonb_build_object('status', 'updated');
    END IF;

    DELETE FROM public.tenant_studio_organization_mappings
    WHERE "idTenant" = p_tenant_id;
    RETURN jsonb_build_object('status', 'deleted');
END;
$$;

CREATE OR REPLACE FUNCTION public.mutate_tenant_studio_workspace_mapping(
    p_action text,
    p_tenant_id integer,
    p_organization_id uuid,
    p_workspace_id uuid,
    p_current_workspace_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_current_organization_id text;
BEGIN
    IF p_action NOT IN ('create', 'update', 'delete') THEN
        RETURN jsonb_build_object('status', 'invalid_action');
    END IF;
    IF p_tenant_id IS NULL OR p_organization_id IS NULL OR p_workspace_id IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_input');
    END IF;
    IF p_action = 'update' AND p_current_workspace_id IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_input');
    END IF;

    PERFORM pg_advisory_xact_lock(18471, p_tenant_id);

    SELECT "studioOrganizationId" INTO v_current_organization_id
    FROM public.tenant_studio_organization_mappings
    WHERE "idTenant" = p_tenant_id;

    IF v_current_organization_id IS NULL THEN
        RETURN jsonb_build_object('status', 'organization_required');
    END IF;
    IF v_current_organization_id <> p_organization_id::text THEN
        RETURN jsonb_build_object('status', 'tenant_conflict');
    END IF;

    IF p_action = 'create' THEN
        IF EXISTS (
            SELECT 1 FROM public.tenant_studio_workspace_mappings
            WHERE "studioWorkspaceId" = p_workspace_id::text
        ) THEN
            RETURN jsonb_build_object('status', 'workspace_conflict');
        END IF;
        BEGIN
            INSERT INTO public.tenant_studio_workspace_mappings
                ("idTenant", "studioOrganizationId", "studioWorkspaceId")
            VALUES (p_tenant_id, p_organization_id::text, p_workspace_id::text);
        EXCEPTION WHEN unique_violation THEN
            RETURN jsonb_build_object('status', 'workspace_conflict');
        END;
        RETURN jsonb_build_object('status', 'created');
    END IF;

    IF p_action = 'update' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.tenant_studio_workspace_mappings
            WHERE "idTenant" = p_tenant_id
              AND "studioOrganizationId" = p_organization_id::text
              AND "studioWorkspaceId" = p_current_workspace_id::text
        ) THEN
            RETURN jsonb_build_object('status', 'stale_mapping');
        END IF;
        IF p_workspace_id <> p_current_workspace_id AND EXISTS (
            SELECT 1 FROM public.tenant_studio_workspace_mappings
            WHERE "studioWorkspaceId" = p_workspace_id::text
        ) THEN
            RETURN jsonb_build_object('status', 'workspace_conflict');
        END IF;
        BEGIN
            UPDATE public.tenant_studio_workspace_mappings
            SET "studioWorkspaceId" = p_workspace_id::text
            WHERE "idTenant" = p_tenant_id
              AND "studioWorkspaceId" = p_current_workspace_id::text;
        EXCEPTION WHEN unique_violation THEN
            RETURN jsonb_build_object('status', 'workspace_conflict');
        END;
        RETURN jsonb_build_object('status', 'updated');
    END IF;

    DELETE FROM public.tenant_studio_workspace_mappings
    WHERE "idTenant" = p_tenant_id
      AND "studioOrganizationId" = p_organization_id::text
      AND "studioWorkspaceId" = p_workspace_id::text;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'stale_mapping');
    END IF;
    RETURN jsonb_build_object('status', 'deleted');
END;
$$;

CREATE TABLE public.tenant_message_quota_periods (
    "idTenant" integer NOT NULL
        REFERENCES public.tenants("idTenant") ON DELETE CASCADE,
    "periodStartAt" timestamptz NOT NULL,
    "periodEndAt" timestamptz NOT NULL,
    "messageLimit" integer NOT NULL CHECK ("messageLimit" >= 0),
    "consumedMessages" integer NOT NULL DEFAULT 0 CHECK ("consumedMessages" >= 0),
    "reservedMessages" integer NOT NULL DEFAULT 0 CHECK ("reservedMessages" >= 0),
    "createdAt" timestamptz NOT NULL DEFAULT now(),
    "updatedAt" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("idTenant", "periodStartAt"),
    CONSTRAINT tenant_message_quota_period_valid
        CHECK ("periodStartAt" < "periodEndAt")
);

COMMENT ON TABLE public.tenant_message_quota_periods IS
    'Atomic tenant-wide monthly quota counters shared by DaianaPython and Studio.';

CREATE TABLE public.tenant_message_quota_reservations (
    "idTenant" integer NOT NULL,
    source text NOT NULL,
    "requestId" text NOT NULL,
    "periodStartAt" timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'reserved',
    "reservedAt" timestamptz NOT NULL DEFAULT now(),
    "consumedAt" timestamptz,
    "releasedAt" timestamptz,
    PRIMARY KEY ("idTenant", source, "requestId"),
    CONSTRAINT tenant_message_quota_reservation_period_fkey
        FOREIGN KEY ("idTenant", "periodStartAt")
        REFERENCES public.tenant_message_quota_periods
            ("idTenant", "periodStartAt")
        ON DELETE CASCADE,
    CONSTRAINT tenant_message_quota_reservation_source_not_blank
        CHECK (btrim(source) <> ''),
    CONSTRAINT tenant_message_quota_reservation_request_id_not_blank
        CHECK (btrim("requestId") <> ''),
    CONSTRAINT tenant_message_quota_reservation_status_valid
        CHECK (status IN ('reserved', 'consumed', 'released'))
);

COMMENT ON TABLE public.tenant_message_quota_reservations IS
    'Idempotent message reservations. Source namespaces request IDs across consuming products.';

CREATE INDEX tenant_message_quota_reservation_period_idx
    ON public.tenant_message_quota_reservations ("idTenant", "periodStartAt", status);

CREATE OR REPLACE FUNCTION public.tenant_message_quota_add_months(
    p_anchor timestamptz,
    p_months integer
) RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_anchor_utc timestamp := p_anchor AT TIME ZONE 'UTC';
    v_month_start date;
    v_last_day integer;
    v_day integer;
BEGIN
    v_month_start := (date_trunc('month', v_anchor_utc) + make_interval(months => p_months))::date;
    v_last_day := extract(day FROM (v_month_start + interval '1 month - 1 day'))::integer;
    v_day := least(extract(day FROM v_anchor_utc)::integer, v_last_day);

    RETURN (
        v_month_start::timestamp
        + make_interval(days => v_day - 1)
        + (v_anchor_utc - date_trunc('day', v_anchor_utc))
    ) AT TIME ZONE 'UTC';
END;
$$;

COMMENT ON FUNCTION public.tenant_message_quota_add_months(timestamptz, integer) IS
    'Adds calendar months in UTC while clamping end-of-month anchors.';

CREATE OR REPLACE FUNCTION public.tenant_message_quota_period_bounds(
    p_anchor timestamptz,
    p_at timestamptz DEFAULT now()
) RETURNS TABLE ("periodStartAt" timestamptz, "periodEndAt" timestamptz)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_months integer;
BEGIN
    IF p_anchor IS NULL OR p_at IS NULL THEN
        RAISE EXCEPTION 'quota period anchor and evaluation time are required';
    END IF;

    IF p_at < p_anchor THEN
        "periodStartAt" := p_anchor;
        "periodEndAt" := public.tenant_message_quota_add_months(p_anchor, 1);
        RETURN NEXT;
        RETURN;
    END IF;

    v_months := (
        (extract(year FROM p_at AT TIME ZONE 'UTC')::integer
            - extract(year FROM p_anchor AT TIME ZONE 'UTC')::integer) * 12
        + extract(month FROM p_at AT TIME ZONE 'UTC')::integer
        - extract(month FROM p_anchor AT TIME ZONE 'UTC')::integer
    );

    "periodStartAt" := public.tenant_message_quota_add_months(p_anchor, v_months);
    IF "periodStartAt" > p_at THEN
        v_months := v_months - 1;
        "periodStartAt" := public.tenant_message_quota_add_months(p_anchor, v_months);
    END IF;
    "periodEndAt" := public.tenant_message_quota_add_months(p_anchor, v_months + 1);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_tenant_message_quota_period(
    p_tenant_id integer,
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_plan public.tenant_plans%ROWTYPE;
    v_start timestamptz;
    v_end timestamptz;
BEGIN
    SELECT * INTO v_plan
    FROM public.tenant_plans
    WHERE "idTenant" = p_tenant_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'not_enforced', 'tenantId', p_tenant_id);
    END IF;
    IF v_plan.status <> 'active' THEN
        RETURN jsonb_build_object('status', 'inactive_plan', 'tenantId', p_tenant_id);
    END IF;
    IF v_plan."expiresAt" IS NOT NULL AND p_at >= v_plan."expiresAt" THEN
        RETURN jsonb_build_object(
            'status', 'license_expired', 'tenantId', p_tenant_id,
            'expiresAt', v_plan."expiresAt", 'planName', v_plan."planName"
        );
    END IF;

    SELECT b."periodStartAt", b."periodEndAt" INTO v_start, v_end
    FROM public.tenant_message_quota_period_bounds(v_plan."periodStartAt", p_at) b;

    IF v_plan."maxMessages" IS NULL OR v_plan."maxMessages" < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_plan', 'tenantId', p_tenant_id);
    END IF;

    RETURN jsonb_build_object(
        'status', 'active',
        'tenantId', p_tenant_id,
        'limit', v_plan."maxMessages",
        'periodStartAt', v_start,
        'periodEndAt', v_end,
        'expiresAt', v_plan."expiresAt",
        'planName', v_plan."planName"
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.tenant_message_quota_usage_json(
    p_tenant_id integer,
    p_period_start_at timestamptz
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT jsonb_build_object(
        'tenantId', q."idTenant",
        'limit', q."messageLimit",
        'consumed', q."consumedMessages",
        'reserved', q."reservedMessages",
        'remaining', greatest(q."messageLimit" - q."consumedMessages" - q."reservedMessages", 0),
        'periodStartAt', q."periodStartAt",
        'periodEndAt', q."periodEndAt"
    )
    FROM public.tenant_message_quota_periods q
    WHERE q."idTenant" = p_tenant_id
      AND q."periodStartAt" = p_period_start_at;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_tenant_message_quota_reservations(
    p_tenant_id integer,
    p_at timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(p_tenant_id);
    WITH expired AS (
        UPDATE public.tenant_message_quota_reservations
        SET status = 'released', "releasedAt" = p_at
        WHERE "idTenant" = p_tenant_id
          AND status = 'reserved'
          AND "reservedAt" <= p_at - interval '15 minutes'
        RETURNING "periodStartAt"
    ), expired_counts AS (
        SELECT "periodStartAt", count(*)::integer AS count
        FROM expired
        GROUP BY "periodStartAt"
    )
    UPDATE public.tenant_message_quota_periods q
    SET "reservedMessages" = greatest(q."reservedMessages" - e.count, 0),
        "updatedAt" = p_at
    FROM expired_counts e
    WHERE q."idTenant" = p_tenant_id
      AND q."periodStartAt" = e."periodStartAt";
END;
$$;

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

CREATE OR REPLACE FUNCTION public.consume_tenant_message_quota(
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
    v_reservation public.tenant_message_quota_reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_reservation
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'not_found', 'tenantId', p_tenant_id, 'requestId', p_request_id);
    END IF;
    IF v_reservation.status <> 'reserved' THEN
        RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_reservation."periodStartAt")
            || jsonb_build_object('status', 'already_' || v_reservation.status, 'requestId', p_request_id);
    END IF;

    UPDATE public.tenant_message_quota_reservations
    SET status = 'consumed', "consumedAt" = p_at
    WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id;

    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" - 1,
        "consumedMessages" = "consumedMessages" + 1,
        "updatedAt" = p_at
    WHERE "idTenant" = p_tenant_id AND "periodStartAt" = v_reservation."periodStartAt";

    RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_reservation."periodStartAt")
        || jsonb_build_object('status', 'consumed', 'requestId', p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_tenant_message_quota(
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
    v_reservation public.tenant_message_quota_reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_reservation
    FROM public.tenant_message_quota_reservations
    WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'not_found', 'tenantId', p_tenant_id, 'requestId', p_request_id);
    END IF;
    IF v_reservation.status <> 'reserved' THEN
        RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_reservation."periodStartAt")
            || jsonb_build_object('status', 'already_' || v_reservation.status, 'requestId', p_request_id);
    END IF;

    UPDATE public.tenant_message_quota_reservations
    SET status = 'released', "releasedAt" = p_at
    WHERE "idTenant" = p_tenant_id AND source = p_source AND "requestId" = p_request_id;

    UPDATE public.tenant_message_quota_periods
    SET "reservedMessages" = "reservedMessages" - 1, "updatedAt" = p_at
    WHERE "idTenant" = p_tenant_id AND "periodStartAt" = v_reservation."periodStartAt";

    RETURN public.tenant_message_quota_usage_json(p_tenant_id, v_reservation."periodStartAt")
        || jsonb_build_object('status', 'released', 'requestId', p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_tenant_message_quota_usage(
    p_tenant_id integer,
    p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_period jsonb;
    v_start timestamptz;
    v_usage jsonb;
BEGIN
    v_period := public.resolve_tenant_message_quota_period(p_tenant_id, p_at);
    IF v_period->>'status' <> 'active' THEN
        RETURN v_period;
    END IF;

    v_start := (v_period->>'periodStartAt')::timestamptz;
    PERFORM public.reconcile_tenant_message_quota_reservations(p_tenant_id, p_at);
    v_usage := public.tenant_message_quota_usage_json(p_tenant_id, v_start);
    IF v_usage IS NULL THEN
        RETURN v_period || jsonb_build_object(
            'consumed', 0, 'reserved', 0, 'remaining', (v_period->>'limit')::integer
        );
    END IF;
    RETURN v_period || v_usage;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_daiana_tenant_from_studio(
    p_studio_organization_id text,
    p_studio_workspace_id text DEFAULT NULL
) RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT organization_mapping."idTenant"
    FROM public.tenant_studio_organization_mappings organization_mapping
    WHERE organization_mapping."studioOrganizationId" = p_studio_organization_id
      AND (
          p_studio_workspace_id IS NULL
          OR EXISTS (
              SELECT 1
              FROM public.tenant_studio_workspace_mappings workspace_mapping
              WHERE workspace_mapping."idTenant" = organization_mapping."idTenant"
                AND workspace_mapping."studioOrganizationId" = p_studio_organization_id
                AND workspace_mapping."studioWorkspaceId" = p_studio_workspace_id
          )
      );
$$;

COMMENT ON FUNCTION public.resolve_daiana_tenant_from_studio(text, text) IS
    'Resolves only explicit Studio organization/workspace mappings; returns NULL when no exact mapping exists.';

ALTER TABLE public.tenant_studio_organization_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_studio_workspace_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_message_quota_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_message_quota_reservations ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.tenant_studio_organization_mappings OWNER TO postgres;
ALTER TABLE public.tenant_studio_workspace_mappings OWNER TO postgres;
ALTER TABLE public.tenant_message_quota_periods OWNER TO postgres;
ALTER TABLE public.tenant_message_quota_reservations OWNER TO postgres;

REVOKE ALL ON public.tenant_studio_organization_mappings FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.tenant_studio_workspace_mappings FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.tenant_message_quota_periods FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON public.tenant_message_quota_reservations FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.tenant_studio_organization_mappings TO service_role;
GRANT SELECT ON public.tenant_studio_workspace_mappings TO service_role;
GRANT SELECT ON public.tenant_message_quota_periods TO service_role;
GRANT SELECT ON public.tenant_message_quota_reservations TO service_role;

ALTER FUNCTION public.tenant_message_quota_add_months(timestamptz, integer) OWNER TO postgres;
ALTER FUNCTION public.tenant_message_quota_period_bounds(timestamptz, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.tenant_message_quota_usage_json(integer, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.reconcile_tenant_message_quota_reservations(integer, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.resolve_tenant_message_quota_period(integer, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.reserve_tenant_message_quota(integer, text, text, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.finalize_tenant_message_quota_turn(text, text, jsonb, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.consume_tenant_message_quota(integer, text, text, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.release_tenant_message_quota(integer, text, text, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.get_tenant_message_quota_usage(integer, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.resolve_daiana_tenant_from_studio(text, text) OWNER TO postgres;
ALTER FUNCTION public.mutate_tenant_studio_organization_mapping(text, integer, uuid, uuid) OWNER TO postgres;
ALTER FUNCTION public.mutate_tenant_studio_workspace_mapping(text, integer, uuid, uuid, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.tenant_message_quota_add_months(timestamptz, integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.tenant_message_quota_period_bounds(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.tenant_message_quota_usage_json(integer, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.reconcile_tenant_message_quota_reservations(integer, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.resolve_tenant_message_quota_period(integer, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.reserve_tenant_message_quota(integer, text, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_turn(text, text, jsonb, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.consume_tenant_message_quota(integer, text, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.release_tenant_message_quota(integer, text, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_tenant_message_quota_usage(integer, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.resolve_daiana_tenant_from_studio(text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mutate_tenant_studio_organization_mapping(text, integer, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mutate_tenant_studio_workspace_mapping(text, integer, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.resolve_tenant_message_quota_period(integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.reserve_tenant_message_quota(integer, text, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn(text, text, jsonb, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_tenant_message_quota(integer, text, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_tenant_message_quota(integer, text, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_tenant_message_quota_usage(integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_daiana_tenant_from_studio(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.mutate_tenant_studio_organization_mapping(text, integer, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.mutate_tenant_studio_workspace_mapping(text, integer, uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION private.provision_known_studio_mapping() RETURNS text
LANGUAGE plpgsql SET search_path = pg_catalog, public, studio AS $$
DECLARE
    v_status text;
    v_expected_objects integer;
BEGIN
    SELECT
        (EXISTS (SELECT 1 FROM public.tenants WHERE "idTenant" = 1))::integer
        + (EXISTS (SELECT 1 FROM studio.organization WHERE id = 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'))::integer
        + (EXISTS (SELECT 1 FROM studio.workspace WHERE id = 'cd469aed-4042-477b-b508-9de39d395056' AND "organizationId" = 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'))::integer
    INTO v_expected_objects;
    IF v_expected_objects = 0 THEN
        RAISE NOTICE 'Skipping fixed Studio mapping: expected seed objects are absent; custom installation detected';
        RETURN 'skipped_custom';
    ELSIF v_expected_objects <> 3 THEN
        RAISE EXCEPTION 'Cannot provision fixed Studio mapping: partial expected seed objects (% of 3 present)', v_expected_objects;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tenant_studio_organization_mappings
        WHERE "idTenant" = 1
          AND "studioOrganizationId" <> 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'
    ) OR EXISTS (
        SELECT 1 FROM public.tenant_studio_organization_mappings
        WHERE "studioOrganizationId" = 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'
          AND "idTenant" <> 1
    ) THEN
        RAISE EXCEPTION 'Conflicting fixed Studio organization mapping for tenant 1 / organization ca2a7ece-14c6-458c-9266-5c3d96e547f2';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tenant_studio_organization_mappings
        WHERE "idTenant" = 1
          AND "studioOrganizationId" = 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'
    ) THEN
        v_status := public.mutate_tenant_studio_organization_mapping(
            'create', 1, 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'::uuid
        )->>'status';
        IF v_status <> 'created' THEN
            RAISE EXCEPTION 'Failed to provision fixed Studio organization mapping: status=%', v_status;
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.tenant_studio_workspace_mappings
        WHERE "studioWorkspaceId" = 'cd469aed-4042-477b-b508-9de39d395056'
          AND ("idTenant" <> 1 OR "studioOrganizationId" <> 'ca2a7ece-14c6-458c-9266-5c3d96e547f2')
    ) THEN
        RAISE EXCEPTION 'Conflicting fixed Studio workspace mapping for workspace cd469aed-4042-477b-b508-9de39d395056';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tenant_studio_workspace_mappings
        WHERE "idTenant" = 1
          AND "studioOrganizationId" = 'ca2a7ece-14c6-458c-9266-5c3d96e547f2'
          AND "studioWorkspaceId" = 'cd469aed-4042-477b-b508-9de39d395056'
    ) THEN
        v_status := public.mutate_tenant_studio_workspace_mapping(
            'create',
            1,
            'ca2a7ece-14c6-458c-9266-5c3d96e547f2'::uuid,
            'cd469aed-4042-477b-b508-9de39d395056'::uuid
        )->>'status';
        IF v_status <> 'created' THEN
            RAISE EXCEPTION 'Failed to provision fixed Studio workspace mapping: status=%', v_status;
        END IF;
    END IF;
    RETURN 'provisioned';
END;
$$;
REVOKE ALL ON FUNCTION private.provision_known_studio_mapping() FROM PUBLIC;
SELECT private.provision_known_studio_mapping();

NOTIFY pgrst, 'reload schema';
