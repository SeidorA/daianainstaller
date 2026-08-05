-- Provenance: daianapython commit 16e161f468f1976d15ba40b1312dc5f247d64dab
-- Canonical source SHA-256: df03856e6ffe91d943f0d6cfa744292bafc98de51b5d5d00495c108d2bbe9d26
-- Installer adaptation: transaction wrappers removed; the runner owns the transaction.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.history
    ADD COLUMN IF NOT EXISTS message_ref text;

UPDATE public.history
SET message_ref = rtrim(translate(encode(gen_random_bytes(16), 'base64'), '+/', '-_'), '=')
WHERE message_ref IS NULL;

ALTER TABLE public.history
    ALTER COLUMN message_ref SET DEFAULT
        rtrim(translate(encode(gen_random_bytes(16), 'base64'), '+/', '-_'), '='),
    ALTER COLUMN message_ref SET NOT NULL;

ALTER TABLE public.history
    ADD CONSTRAINT history_message_ref_url_safe
        CHECK (message_ref ~ '^[A-Za-z0-9_-]{22,}$'),
    ADD CONSTRAINT history_message_ref_unique UNIQUE (message_ref);

CREATE TABLE IF NOT EXISTS public.figure_artifacts (
    message_ref text PRIMARY KEY REFERENCES public.history(message_ref) ON DELETE CASCADE,
    storage_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT figure_artifact_storage_key_safe
        CHECK (storage_key ~ '^figure_[A-Za-z0-9_-]{22,}\.html$')
);

REVOKE ALL ON public.figure_artifacts FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.figure_artifacts TO service_role;
