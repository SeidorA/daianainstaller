-- Backfill tenant runtime secrets without replacing valid existing values.
UPDATE public.tenants
SET settings = coalesce(settings, '{}'::jsonb)
    || CASE
         WHEN nullif(btrim(settings->>'secretSeed'), '') IS NULL
           THEN jsonb_build_object('secretSeed', gen_random_uuid()::text)
         ELSE '{}'::jsonb
       END
    || CASE
         WHEN nullif(btrim(settings->>'teamsSecret'), '') IS NULL
           THEN jsonb_build_object('teamsSecret', 'waHW4b2Kfe_OoYXxnSUscqIMuESvQhunKt6deG1uXyU=')
         ELSE '{}'::jsonb
       END
WHERE nullif(btrim(settings->>'secretSeed'), '') IS NULL
   OR nullif(btrim(settings->>'teamsSecret'), '') IS NULL;
