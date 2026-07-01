CREATE OR REPLACE FUNCTION "private"."delete_domain_user_graph"("p_auth_user_id" "uuid", "p_email" "text", "p_hard_delete" boolean DEFAULT true) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
declare
  v_personal_workspace_ids uuid[];
begin
  if p_auth_user_id is null then
    return;
  end if;

  select coalesce(array_agg(w.id), array[]::uuid[])
  into v_personal_workspace_ids
  from studio.workspace w
  join studio.workspace_user wu on wu."workspaceId" = w.id
  where wu."userId" = p_auth_user_id
    and w."name" = 'Personal Workspace'
    and not exists (
      select 1
      from studio.workspace_user other_wu
      where other_wu."workspaceId" = w.id
        and other_wu."userId" <> p_auth_user_id
    )
    and not exists (
      select 1
      from studio.chat_flow cf
      where cf."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.apikey ak
      where ak."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.assistant a
      where a."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.credential c
      where c."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.custom_template ct
      where ct."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.dataset d
      where d."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.document_store ds
      where ds."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.evaluation e
      where e."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.evaluator ev
      where ev."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.execution ex
      where ex."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.tool t
      where t."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.variable v
      where v."workspaceId" = w.id
    )
    and not exists (
      select 1
      from studio.workspace_shared ws
      where ws."workspaceId" = w.id
    );

  delete from studio.workspace_user
  where "userId" = p_auth_user_id;

  delete from studio.workspace
  where id = any(v_personal_workspace_ids);

  delete from studio.organization_user
  where "userId" = p_auth_user_id;

  delete from studio."user"
  where id = p_auth_user_id;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."sync_auth_user_event"("p_op" "text", "p_new" "auth"."users", "p_old" "auth"."users") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'public', 'studio', 'private'
    AS $$
begin
  case upper(coalesce(p_op, ''))
    when 'INSERT' then
      perform private.sync_public_user_from_auth(p_new, 'insert');
      perform private.upsert_domain_user_from_auth(p_new, 'insert');
      perform private.sync_studio_memberships_from_auth(p_new);
    when 'UPDATE' then
      perform private.sync_auth_user_metadata(p_new.id);
      perform private.sync_domain_user_credential_from_auth(p_new, p_old);
    when 'DELETE' then
      perform private.delete_domain_user_graph(p_old.id, p_old.email, true);
    else
      raise exception 'private.sync_auth_user_event: unsupported operation %', p_op;
  end case;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."sync_auth_user_metadata"("p_auth_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'public', 'private'
    AS $$
declare
  v_tenant_id integer;
  v_role text;
begin
  if p_auth_user_id is null then
    return;
  end if;

  select u.id_tenantint, u.role
  into v_tenant_id, v_role
  from public.users u
  where u.id = p_auth_user_id;

  if v_tenant_id is null then
    return;
  end if;

  update auth.users au
  set raw_user_meta_data = coalesce(au.raw_user_meta_data, '{}'::jsonb)
    || jsonb_build_object(
      'id_tenantint', v_tenant_id,
      'public_user_id', p_auth_user_id,
      'role', coalesce(v_role, au.raw_user_meta_data->>'role', 'admin')
    )
  where au.id = p_auth_user_id
    and (
      au.raw_user_meta_data->>'id_tenantint' is distinct from v_tenant_id::text
      or au.raw_user_meta_data->>'public_user_id' is distinct from p_auth_user_id::text
      or au.raw_user_meta_data->>'role' is distinct from coalesce(v_role, au.raw_user_meta_data->>'role', 'admin')
    );
end;
$$;

CREATE OR REPLACE FUNCTION "private"."sync_domain_user_credential_from_auth"("p_new" "auth"."users", "p_old" "auth"."users") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
begin
  if p_new.id is null or p_old.id is null then
    return;
  end if;

  if p_new.encrypted_password is null
    or p_new.encrypted_password is not distinct from p_old.encrypted_password then
    return;
  end if;

  update studio."user" u
  set
    credential = p_new.encrypted_password,
    "updatedBy" = coalesce(u."updatedBy", u.id)
  where u.id = p_new.id;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."sync_public_user_from_auth"("p_auth_user" "auth"."users", "p_reason" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'public', 'private'
    AS $_$
declare
  v_tenant_id integer;
  v_join_tenant_id integer;
  v_existing_tenant_id integer;
  v_full_name text;
  v_first_name text;
  v_last_name text;
  v_provider_text text;
  v_tenant_was_created boolean := false;
  v_new_team_id uuid;
begin
  if p_auth_user.id is null then
    raise exception 'private.sync_public_user_from_auth: auth user id is required';
  end if;

  v_full_name := coalesce(
    p_auth_user.raw_user_meta_data->>'full_name',
    p_auth_user.raw_user_meta_data->>'name',
    split_part(coalesce(p_auth_user.email, ''), '@', 1),
    'User'
  );
  v_first_name := coalesce(p_auth_user.raw_user_meta_data->>'first_name', v_full_name);
  v_last_name := coalesce(p_auth_user.raw_user_meta_data->>'last_name', '');
  v_provider_text := coalesce(p_auth_user.raw_user_meta_data->>'provider', 'email');

  select u.id_tenantint
  into v_existing_tenant_id
  from public.users u
  where u.id = p_auth_user.id;

  if coalesce(p_reason, '') <> 'insert' and v_existing_tenant_id is not null then
    v_tenant_id := v_existing_tenant_id;
  else
    if coalesce(p_auth_user.raw_user_meta_data->>'id_tenantint', '') ~ '^[0-9]+$' then
      v_tenant_id := nullif((p_auth_user.raw_user_meta_data->>'id_tenantint')::int, 0);
    end if;
  end if;

  if coalesce(p_auth_user.raw_user_meta_data->>'join_tenant_id', '') ~ '^[0-9]+$' then
    v_join_tenant_id := nullif((p_auth_user.raw_user_meta_data->>'join_tenant_id')::int, 0);
  end if;

  if v_join_tenant_id is not null then
    select t."idTenant"
    into v_existing_tenant_id
    from public.tenants t
    where t."idTenant" = v_join_tenant_id
    limit 1;

    if v_existing_tenant_id is null then
      raise exception 'La organización especificada (ID: %) no existe', v_join_tenant_id;
    end if;
  elsif v_tenant_id is not null then
    select t."idTenant"
    into v_existing_tenant_id
    from public.tenants t
    where t."idTenant" = v_tenant_id
    limit 1;
  elsif coalesce(p_reason, '') = 'insert'
    and (
      coalesce((p_auth_user.raw_user_meta_data->>'create_new_tenant')::boolean, false)
      or v_provider_text != 'email'
    ) then
    insert into public.tenants (
      email,
      company,
      plan,
      settings
    ) values (
      p_auth_user.email,
      coalesce(p_auth_user.raw_user_meta_data->>'company', 'Mi Empresa'),
      'trial',
        jsonb_build_object(
        'domain', split_part(coalesce(p_auth_user.email, ''), '@', 2),
        'created_by', p_auth_user.id
      )
    )
    returning "idTenant" into v_existing_tenant_id;
    v_tenant_was_created := true;
  else
    select t."idTenant"
    into v_existing_tenant_id
    from public.tenants t
    where split_part(t.email, '@', 2) = split_part(coalesce(p_auth_user.email, ''), '@', 2)
    limit 1;

    if v_existing_tenant_id is null then
      insert into public.tenants (
        email,
        company,
        plan,
        settings
      ) values (
        p_auth_user.email,
        coalesce(p_auth_user.raw_user_meta_data->>'company', 'Mi Empresa'),
        'trial',
        jsonb_build_object(
          'domain', split_part(coalesce(p_auth_user.email, ''), '@', 2),
          'created_by', p_auth_user.id
        )
      )
      returning "idTenant" into v_existing_tenant_id;
      v_tenant_was_created := true;
    end if;
  end if;

  insert into public.users (
    id,
    email,
    first_name,
    last_name,
    id_tenantint,
    phone,
    country,
    company,
    imgurl,
    role,
    status,
    settings
  ) values (
    p_auth_user.id,
    p_auth_user.email,
    v_first_name,
    v_last_name,
    v_existing_tenant_id,
    coalesce(p_auth_user.raw_user_meta_data->>'phone', ''),
    coalesce(p_auth_user.raw_user_meta_data->>'country', ''),
    coalesce(p_auth_user.raw_user_meta_data->>'company', 'Mi Empresa'),
    coalesce(p_auth_user.raw_user_meta_data->>'avatar_url', ''),
    coalesce(p_auth_user.raw_user_meta_data->>'role', 'admin'),
    true,
    '{"screen": "/agents"}'::jsonb
  )
  on conflict (id) do update set
    email = excluded.email,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    id_tenantint = excluded.id_tenantint,
    phone = excluded.phone,
    country = excluded.country,
    company = excluded.company,
    imgurl = excluded.imgurl,
    role = excluded.role,
    status = excluded.status,
    settings = excluded.settings;

  perform private.sync_auth_user_metadata(p_auth_user.id);

  if v_tenant_was_created then
    insert into public.teams (
      name,
      description,
      "idTenant",
      visible
    ) values (
      'Default Team',
      'Equipo creado automáticamente para el nuevo usuario',
      v_existing_tenant_id,
      true
    )
    returning id into v_new_team_id;

    insert into public.teamsecurityuser (
      team, "user", tenant, role, member
    ) values (
      v_new_team_id,
      p_auth_user.id,
      v_existing_tenant_id,
      'admin',
      true
    );

    insert into public.aibot (
      "idTenant",
      name,
      description,
      "createdUser",
      team,
      "messageInitial",
      botpublic,
      type
    ) values (
      v_existing_tenant_id,
      'Daiana Help',
      'Asistente AI para ayudarte con tu plataforma',
      p_auth_user.id,
      v_new_team_id,
      '¡Hola! Soy Daiana Help, ¿en qué puedo asistirte hoy?',
      false,
      'document'
    );
  end if;

  return v_existing_tenant_id;
end;
$_$;

CREATE OR REPLACE FUNCTION "private"."sync_studio_memberships_from_auth"("p_auth_user" "auth"."users") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
declare
  v_owner_user_id uuid;
  v_org_id uuid;
  v_org_role_id uuid;
  v_ws_role_id uuid;
  v_workspace_id uuid;
  v_workspace_name text;
  v_org_was_created boolean := false;
  v_membership_role_name text;
begin
  if p_auth_user.id is null then
    return;
  end if;

  if not exists (
    select 1
    from studio."user" u
    where u.id = p_auth_user.id
  ) then
    return;
  end if;

  select ou."userId", ou."organizationId"
  into v_owner_user_id, v_org_id
  from studio.organization_user ou
  join studio.role r on r.id = ou."roleId"
  where r."name" = 'owner'
    and ou."status" = 'active'
  order by ou."createdDate" asc nulls last
  limit 1;

  if v_org_id is null then
    insert into studio.organization (
      "name",
      "createdBy",
      "updatedBy"
    ) values (
      'Default Organization',
      p_auth_user.id,
      p_auth_user.id
    )
    returning id into v_org_id;

    v_owner_user_id := p_auth_user.id;
    v_org_was_created := true;
  end if;

  if v_owner_user_id is null then
    v_owner_user_id := p_auth_user.id;
  end if;

  v_membership_role_name := case
    when v_org_was_created then 'owner'
    else 'member'
  end;

  v_workspace_name := case
    when v_org_was_created then 'Default Workspace'
    else 'Personal Workspace'
  end;

  select id into v_org_role_id
  from studio.role
  where "name" = v_membership_role_name
    and ("organizationId" = v_org_id or "organizationId" is null)
  order by ("organizationId" = v_org_id) desc
  limit 1;

  if v_org_role_id is null then
    insert into studio.role (
      "organizationId",
      "name",
      "description",
      "permissions",
      "createdBy",
      "updatedBy"
    ) values (
      null,
      v_membership_role_name,
      case
        when v_membership_role_name = 'owner' then 'Has full control over the organization.'
        else 'Has limited control over the organization.'
      end,
      case
        when v_membership_role_name = 'owner' then '["organization","workspace"]'
        else '[]'
      end,
      null,
      null
    )
    returning id into v_org_role_id;
  end if;

  select id into v_ws_role_id
  from studio.role
  where "name" = case
      when v_org_was_created then 'owner'
      else 'personal workspace'
    end
    and ("organizationId" = v_org_id or "organizationId" is null)
  order by ("organizationId" = v_org_id) desc
  limit 1;

  if v_ws_role_id is null then
    v_ws_role_id := v_org_role_id;
  end if;

  insert into studio.organization_user (
    "organizationId",
    "userId",
    "roleId",
    status,
    "createdBy",
    "updatedBy"
  ) values (
    v_org_id,
    p_auth_user.id,
    v_org_role_id,
    'active',
    v_owner_user_id,
    v_owner_user_id
  )
  on conflict ("organizationId", "userId") do update set
    "roleId" = excluded."roleId",
    status = excluded.status,
    "updatedBy" = excluded."updatedBy";

  select wu."workspaceId"
  into v_workspace_id
  from studio.workspace_user wu
  join studio.workspace w on w.id = wu."workspaceId"
  where wu."userId" = p_auth_user.id
    and w."organizationId" = v_org_id
    and w."name" = v_workspace_name
  limit 1;

  if v_workspace_id is null then
    insert into studio.workspace (
      "name",
      "organizationId",
      "createdBy",
      "updatedBy"
    ) values (
      v_workspace_name,
      v_org_id,
      v_owner_user_id,
      v_owner_user_id
    )
    returning id into v_workspace_id;
  end if;

  insert into studio.workspace_user (
    "workspaceId",
    "userId",
    "roleId",
    status,
    "createdBy",
    "updatedBy"
  ) values (
    v_workspace_id,
    p_auth_user.id,
    v_ws_role_id,
    'active',
    v_owner_user_id,
    v_owner_user_id
  )
  on conflict ("workspaceId", "userId") do update set
    "roleId" = excluded."roleId",
    status = excluded.status,
    "updatedBy" = excluded."updatedBy";
end;
$$;

CREATE OR REPLACE FUNCTION "private"."trg_auth_users_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
begin
  perform private.sync_auth_user_event('DELETE', null, old);
  return old;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."trg_auth_users_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
begin
  perform private.sync_auth_user_event('INSERT', new, null);
  return new;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."trg_auth_users_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
begin
  perform private.sync_auth_user_event('UPDATE', new, old);
  return new;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."upsert_domain_user_from_auth"("p_auth_user" "auth"."users", "p_reason" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'studio', 'private'
    AS $$
declare
  v_existing_id uuid;
  v_full_name text;
  v_normalized_email text;
  v_allow_credential_sync boolean;
begin
  if p_auth_user.id is null then
    raise exception 'private.upsert_domain_user_from_auth: auth user id is required';
  end if;

  v_allow_credential_sync := p_reason in ('insert', 'update_credential_state');
  v_normalized_email := nullif(lower(btrim(p_auth_user.email)), '');
  v_full_name := coalesce(
    p_auth_user.raw_user_meta_data->>'full_name',
    p_auth_user.raw_user_meta_data->>'name',
    split_part(coalesce(p_auth_user.email, ''), '@', 1),
    'User'
  );

  select u.id
  into v_existing_id
  from studio."user" u
  where u.id = p_auth_user.id
  for update;

  if v_existing_id is not null then
    update studio."user" u
    set
      "name" = v_full_name,
      email = coalesce(v_normalized_email, u.email),
      credential = case
        when v_allow_credential_sync and p_auth_user.encrypted_password is not null then p_auth_user.encrypted_password
        else u.credential
      end,
      status = 'active',
      "updatedBy" = coalesce(u."updatedBy", u.id)
    where u.id = p_auth_user.id;

    return p_auth_user.id;
  end if;

  begin
    insert into studio."user" (
      id,
      "name",
      email,
      credential,
      status,
      "createdBy",
      "updatedBy"
    ) values (
      p_auth_user.id,
      v_full_name,
      coalesce(v_normalized_email, p_auth_user.email),
      case
        when v_allow_credential_sync then p_auth_user.encrypted_password
        else null
      end,
      'active',
      p_auth_user.id,
      p_auth_user.id
    );
  exception
    when unique_violation then
      raise exception 'Cannot link auth user % to studio.user: email % already exists with a different id',
        p_auth_user.id,
        coalesce(v_normalized_email, p_auth_user.email);
  end;

  return p_auth_user.id;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."delete_related_documents"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  vec_ids text[];
  vec_id uuid;
begin
  -- Convertimos el string de idVectors en un array de texto
  if old."idVectors" is not null then
    vec_ids := string_to_array(old."idVectors", ',');
    
    -- Iteramos y borramos en documents
    foreach vec_id in array vec_ids
    loop
      delete from public.documents where id = vec_id;
    end loop;
  end if;

  return old;
end;
$$;

ALTER FUNCTION "public"."delete_related_documents"() OWNER TO postgres;

CREATE OR REPLACE FUNCTION "public"."fndashboard"("p_email" character varying, "p_period" character varying) RETURNS TABLE("card" "text", "kpi" "text", "value" bigint)
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    RETURN QUERY 
    --Uploaded Documents
    SELECT 'Uploaded Documents' as card, 'Uploaded Documents Current Period' as kpi, COUNT(d.id) as VALUE 
      FROM public.document d
      INNER JOIN public.aibot b ON d."idBot" = b."idBot"
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(d."createdAt", 'YYYY-MM') = p_period
    UNION ALL
    SELECT 'Uploaded Documents' as card, 'Uploaded Documents Previous Period' as kpi, COUNT(d.id) as VALUE 
      FROM public.document d
      INNER JOIN public.aibot b ON d."idBot" = b."idBot"
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(d."createdAt" + INTERVAL '1 month', 'YYYY-MM') = p_period
    UNION ALL
    --Virtual Assistants
    SELECT 'Virtual Assistants' as card, 'Virtual Assistants Current Period' as kpi, COUNT(b."idBot") as VALUE 
      FROM public.aibot b 
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(b."createdAt", 'YYYY-MM') = p_period
    UNION ALL
    SELECT 'Virtual Assistants' as card, 'Virtual Assistants Previous Period' as kpi, COUNT(b."idBot") as VALUE 
      FROM public.aibot b 
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(b."createdAt" + INTERVAL '1 month', 'YYYY-MM') = p_period
    UNION ALL
    --Teams
    SELECT 'Teams' as card, 'Teams Current Period' as kpi, COUNT(b.id) as VALUE 
      FROM public.teams b 
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(b."createdAt", 'YYYY-MM') = p_period
    UNION ALL
    SELECT 'Teams' as card, 'Teams Previous Period' as kpi, COUNT(b.id) as VALUE 
      FROM public.teams b 
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND TO_CHAR(b."createdAt" + INTERVAL '1 month', 'YYYY-MM') = p_period
    UNION ALL
    --Messages
    SELECT 'Messages' as card, 'Messages Current Period' as kpi, COUNT(h.id) as VALUE 
      FROM public.history h
      INNER JOIN public.aibot b ON h."idBot" = b."idBot"
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND created = 'bot'
      AND TO_CHAR(h."createdAt", 'YYYY-MM') = p_period
    UNION ALL
    SELECT 'Messages' as card, 'Messages Previous Period' as kpi, COUNT(h.id) as VALUE 
      FROM public.history h
      INNER JOIN public.aibot b ON h."idBot" = b."idBot"
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      WHERE t.email = p_email
      AND created = 'bot'
      AND TO_CHAR(h."createdAt" + INTERVAL '1 month', 'YYYY-MM') = p_period
    UNION ALL
    --Monthly History
    (SELECT 'History' as card, ss1.period, COALESCE(ss2.value, 0) value
      FROM
      (SELECT TO_CHAR(date_trunc('month', (DATE (p_period || '-01')) - (interval '1 month' * generate_series(0, 11))), 'YYYY-MM') AS period) ss1
      LEFT JOIN 
      (SELECT 'History' as card, TO_CHAR(h."createdAt", 'YYYY-MM') as kpi, COUNT(h.id) as VALUE 
        FROM public.history h 
        INNER JOIN public.aibot b ON h."idBot" = b."idBot"
        INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
        WHERE t.email = p_email
        AND h.created = 'bot'
        GROUP BY TO_CHAR(h."createdAt", 'YYYY-MM')) ss2 
      ON ss1.period = ss2.kpi
      ORDER BY 2 DESC)
    UNION ALL
    --TOP 5 Users
    (SELECT 'Top' as card, u.email as kpi, COUNT(h.id) as VALUE 
      FROM public.history h
      INNER JOIN public.aibot b ON h."idBot" = b."idBot"
      INNER JOIN public.tenants t ON b."idTenant" = t."idTenant" 
      INNER JOIN public.users u ON h."idUser" = u.id
      WHERE t.email = p_email
      AND TO_CHAR(h."createdAt", 'YYYY-MM') = p_period
      AND created = 'bot'
      GROUP BY u.email
      ORDER BY VALUE DESC LIMIT 5);
END; $$;

ALTER FUNCTION "public"."fndashboard"("p_email" character varying, "p_period" character varying) OWNER TO postgres;

CREATE OR REPLACE FUNCTION "public"."get_question_and_answer"("answ_id" integer) RETURNS TABLE("question_id" integer, "answer_id" integer, "id_bot" integer, "question" "text", "answer" "text", "question_created" timestamp with time zone, "answer_created" timestamp with time zone)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'piblic'
    AS $$
DECLARE
    v_question_id INTEGER;
    v_answer_id INTEGER;
    v_id_bot INTEGER;
    v_question TEXT;
    v_answer TEXT;
    v_question_created TIMESTAMP WITH TIME ZONE;
    v_answer_created TIMESTAMP WITH TIME ZONE;
BEGIN
    WITH answer_record AS (
        SELECT * FROM public.history WHERE id = answ_id
    ),
    question_record AS (
        SELECT * FROM public.history h
        WHERE h."idUser" = (SELECT "idUser" FROM answer_record)
          AND h."idBot" = (SELECT "idBot" FROM answer_record)
          AND h.id < answ_id
        ORDER BY h.id DESC
        LIMIT 1
    ),
    result AS (SELECT 
    q.id AS question_id,
    a.id AS answer_id,
      q."idBot" AS id_bot,
        q.message AS question,
        a.message AS answer,
        q."createdAt" AS question_created,
        a."createdAt" AS answer_created
      FROM 
        question_record q
    CROSS JOIN
        answer_record a
  )
  SELECT 
        r.question_id, r.answer_id, r.id_bot, r.question, r.answer, r.question_created, r.answer_created
    INTO 
        v_question_id, v_answer_id, v_id_bot, v_question, v_answer, v_question_created, v_answer_created
    FROM 
        result r; 
    -- Insertar en la tabla TRAINING
    INSERT INTO public.training (
        question_id, answer_id, id_bot, question, answer, question_created, answer_created
    )
    SELECT 
        v_question_id, v_answer_id, v_id_bot, v_question, v_answer, v_question_created, v_answer_created;

    -- Retornar el resultado
    RETURN QUERY
    SELECT 
        t.question_id, t.answer_id, t.id_bot, t.question, t.answer, t.question_created, t.answer_created
    FROM 
        public.training t
  WHERE t.answer_id = answ_id;
END;
$$;

ALTER FUNCTION "public"."get_question_and_answer"("answ_id" integer) OWNER TO postgres;

CREATE OR REPLACE FUNCTION "public"."handle_new_auth_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$DECLARE
  existing_tenant_id integer;
  new_team_id uuid;
  user_email text := NEW.email;
  user_first_name text := COALESCE(NEW.raw_user_meta_data->>'first_name', NEW.raw_user_meta_data->>'full_name','');
  user_last_name text := COALESCE(NEW.raw_user_meta_data->>'last_name', '');
  create_new_tenant boolean := COALESCE((NEW.raw_user_meta_data->>'create_new_tenant')::boolean, false);
  join_tenant_id integer := NULLIF(NEW.raw_user_meta_data->>'join_tenant_id', '')::integer;
  tenant_domain text := split_part(user_email, '@', 2);
  tenant_was_created boolean := false;
  provider_text text := COALESCE(NEW.raw_user_meta_data->>'provider', 'email');
BEGIN
  -- Primero verificar si se especificó un join_tenant_id
  IF join_tenant_id IS NOT NULL THEN
    -- Verificar que el tenant exista
    SELECT "idTenant" INTO existing_tenant_id 
    FROM public.tenants 
    WHERE "idTenant" = join_tenant_id
    LIMIT 1;
    
    IF existing_tenant_id IS NULL THEN
      RAISE EXCEPTION 'La organización especificada (ID: %) no existe', join_tenant_id;
    END IF;
  
  -- Luego verificar si debe crear nuevo tenant
  ELSIF create_new_tenant OR provider_text != 'email' THEN
    -- Crear nuevo tenant
    INSERT INTO public.tenants (
      email, 
      company,
      plan,
      settings
    ) VALUES (
      user_email,
      COALESCE(NEW.raw_user_meta_data->>'company', 'Mi Empresa'),
      'trial',
        jsonb_build_object(
        'domain', tenant_domain,
        'created_by', NEW.id
      )
    )
    RETURNING "idTenant" INTO existing_tenant_id;
    tenant_was_created := true;
  
  -- Finalmente, intentar coincidencia por dominio
  ELSE
    -- Búsqueda automática por dominio de email
    SELECT "idTenant" INTO existing_tenant_id 
    FROM public.tenants 
    WHERE split_part(email, '@', 2) = tenant_domain
    LIMIT 1;
  END IF;

  -- Si después de todo no tenemos tenant, crear uno
  IF existing_tenant_id IS NULL THEN
    INSERT INTO public.tenants (
      email, 
      company,
      plan,
      settings
    ) VALUES (
      user_email,
      COALESCE(NEW.raw_user_meta_data->>'company', 'Mi Empresa'),
      'trial',
        jsonb_build_object(
        'domain', tenant_domain,
        'created_by', NEW.id
      )
    )
    RETURNING "idTenant" INTO existing_tenant_id;
    tenant_was_created := true;
  END IF;

  -- Insertar usuario en public.users
  INSERT INTO public.users (
    id,
    email,
    first_name,
    last_name,
    id_tenantint,
    phone,
    country,
    company,
    imgurl,
    role,
    settings
  ) VALUES (
    NEW.id,
    user_email,
    user_first_name,
    user_last_name,
    existing_tenant_id,
    COALESCE(NEW.raw_user_meta_data->>'phone', ''),
    COALESCE(NEW.raw_user_meta_data->>'country', ''),
    COALESCE(NEW.raw_user_meta_data->>'company', 'Mi Empresa'),
    COALESCE(NEW.raw_user_meta_data->>'avatar_url', ''),
    COALESCE(NEW.raw_user_meta_data->>'role', 'admin'),
    '{"screen": "/agents"}'::jsonb
  );

  -- Actualizar metadata en auth.users
  UPDATE auth.users 
  SET raw_user_meta_data = raw_user_meta_data || jsonb_build_object(
    'id_tenantint', existing_tenant_id,
    'public_user_id', NEW.id,
    'role', COALESCE(NEW.raw_user_meta_data->>'role', 'admin')
  )
  WHERE id = NEW.id;

  -- ───────────────────────────────────────────────────────────────
  -- NUEVAS LÍNEAS: crear Team y Daiana Help aibot SOLO si es un nuevo tenant
  -- ───────────────────────────────────────────────────────────────
  IF tenant_was_created THEN
    -- 1) Crear un Team por defecto para el tenant
    INSERT INTO public.teams (
      name,
      description,
      "idTenant",
      visible
    ) VALUES (
      'Default Team',
      'Equipo creado automáticamente para el nuevo usuario',
      existing_tenant_id,
      true
    )
    RETURNING id INTO new_team_id;

    -- 2) Vincular al usuario con el nuevo Team (rol 'owner' a modo de ejemplo)
    INSERT INTO public.teamsecurityuser (
      team, "user", tenant, role, member
    ) VALUES (
      new_team_id,
      NEW.id,
      existing_tenant_id,
      'admin',
      true
    );

    -- 3) Crear un aibot llamado 'Daiana Help' asociado a ese Team
    INSERT INTO public.aibot (
      "idTenant",
      name,
      description,
      "createdUser",
      team,
      "messageInitial",
      botpublic, 
      type
    ) VALUES (
      existing_tenant_id,
      'Daiana Help',
      'Asistente AI para ayudarte con tu plataforma',
      NEW.id,
      new_team_id,
      '¡Hola! Soy Daiana Help, ¿en qué puedo asistirte hoy?',
      false,
      'document'
    );
  END IF;

  RETURN NEW;
END;$$;

ALTER FUNCTION "public"."handle_new_auth_user"() OWNER TO postgres;

CREATE OR REPLACE FUNCTION "public"."match_documents"("query_embedding" "extensions"."vector", "filter" "jsonb" DEFAULT '{}'::"jsonb") RETURNS TABLE("id" "uuid", "content" "text", "metadata" "jsonb", "similarity" double precision)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions'
    AS $$
#variable_conflict use_column
begin
  return query
  select
  id,
  content,
  metadata,
  1 - (documents.embedding <=> query_embedding) as similarity
  from documents
  where metadata @> filter
  order by documents.embedding <=> query_embedding;
end;
$$;

ALTER FUNCTION "public"."match_documents"("query_embedding" "extensions"."vector", "filter" "jsonb") OWNER TO postgres

CREATE OR REPLACE FUNCTION "public"."trigger_get_question_and_answer"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    -- Verificar si:
    -- 1. Es una respuesta (created = 'bot')
    -- 2. qualification cambió de NULL a true/false
    -- 3. Hubo un cambio real en qualification
    IF NEW.created = 'bot' AND 
      OLD.qualification IS NULL AND 
      NEW.qualification IS NOT NULL AND
      (OLD.qualification IS DISTINCT FROM NEW.qualification) THEN
        -- Ejecutar la función get_question_and_answer
        PERFORM get_question_and_answer(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

ALTER FUNCTION "public"."trigger_get_question_and_answer"() OWNER TO postgres;

CREATE OR REPLACE FUNCTION "public"."execute_query"("query_text" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$DECLARE    
result JSONB;
BEGIN    
    EXECUTE
    format('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_text) 
    INTO result;    
    RETURN result;
    EXCEPTION    
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error executing query: %' , SQLERRM;
END;
$$;

ALTER FUNCTION "public"."execute_query"("query_text" "text") OWNER TO postgres;

CREATE OR REPLACE FUNCTION "private"."bootstrap_admin"(
    p_email text,
    p_password text,
    p_name text DEFAULT 'Admin'
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO pg_catalog, auth, public, studio, private, extensions
  AS $$
DECLARE
    v_user_id uuid;
    v_email text;
    v_name text;
    v_encrypted_password text;
    v_columns text;
    v_values text;
    v_sql text;
    v_identity_columns text;
    v_identity_values text;
    v_identity_sql text;
BEGIN
    v_email := lower(btrim(p_email));
    v_name := coalesce(nullif(btrim(p_name), ''), 'Admin');

    IF v_email IS NULL OR v_email = '' THEN
        RAISE EXCEPTION 'Admin email is required';
    END IF;

    IF p_password IS NULL OR length(p_password) < 8 THEN
        RAISE EXCEPTION 'Admin password is required and must have at least 8 characters';
    END IF;

    SELECT u.id
    INTO v_user_id
    FROM "auth"."users" AS u
    WHERE lower(u.email) = v_email
    LIMIT 1;

    IF v_user_id IS NOT NULL THEN
        RETURN v_user_id;
    END IF;

    v_user_id := gen_random_uuid();
    v_encrypted_password := extensions.crypt(p_password, extensions.gen_salt('bf'));

    v_columns := 'instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at';

    v_values := format(
        '%L::uuid, %L::uuid, %L, %L, %L, %L, %L::jsonb, %L::jsonb, now(), now()',
        '00000000-0000-0000-0000-000000000000',
        v_user_id,
        'authenticated',
        'authenticated',
        v_email,
        v_encrypted_password,
        jsonb_build_object(
            'provider', 'email',
            'providers', jsonb_build_array('email')
        )::text,
        jsonb_build_object(
            'full_name', v_name,
            'name', v_name,
            'role', 'admin',
            'create_new_tenant', true
        )::text
    );

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'auth'
          AND table_name = 'users'
          AND column_name = 'email_confirmed_at'
          AND is_generated = 'NEVER'
    ) THEN
        v_columns := v_columns || ', email_confirmed_at';
        v_values := v_values || ', now()';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'auth'
          AND table_name = 'users'
          AND column_name = 'is_super_admin'
          AND is_generated = 'NEVER'
    ) THEN
        v_columns := v_columns || ', is_super_admin';
        v_values := v_values || ', false';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'auth'
          AND table_name = 'users'
          AND column_name = 'is_sso_user'
          AND is_generated = 'NEVER'
    ) THEN
        v_columns := v_columns || ', is_sso_user';
        v_values := v_values || ', false';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'auth'
          AND table_name = 'users'
          AND column_name = 'is_anonymous'
          AND is_generated = 'NEVER'
    ) THEN
        v_columns := v_columns || ', is_anonymous';
        v_values := v_values || ', false';
    END IF;

    v_sql := format(
        'INSERT INTO "auth"."users" (%s) VALUES (%s)',
        v_columns,
        v_values
    );

    EXECUTE v_sql;

    IF NOT EXISTS (
        SELECT 1
        FROM "auth"."identities" AS i
        WHERE i.provider = 'email'
          AND i.provider_id = v_user_id::text
    ) THEN

        v_identity_columns := 'provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at';

        v_identity_values := format(
            '%L, %L::uuid, %L::jsonb, %L, now(), now(), now()',
            v_user_id::text,
            v_user_id,
            jsonb_build_object(
                'sub', v_user_id::text,
                'email', v_email,
                'email_verified', true,
                'phone_verified', false
            )::text,
            'email'
        );

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = 'auth'
              AND table_name = 'identities'
              AND column_name = 'email'
              AND is_generated = 'NEVER'
        ) THEN
            v_identity_columns := v_identity_columns || ', email';
            v_identity_values := v_identity_values || format(', %L', v_email);
        END IF;

        IF EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = 'auth'
              AND table_name = 'identities'
              AND column_name = 'id'
              AND is_generated = 'NEVER'
        ) THEN
            v_identity_columns := v_identity_columns || ', id';
            v_identity_values := v_identity_values || format(', %L::uuid', gen_random_uuid());
        END IF;

        v_identity_sql := format(
            'INSERT INTO "auth"."identities" (%s) VALUES (%s)',
            v_identity_columns,
            v_identity_values
        );

        EXECUTE v_identity_sql;
    END IF;

    RETURN v_user_id;
END;
$$;

ALTER FUNCTION "private"."bootstrap_admin"(text, text, text) OWNER TO postgres;


--
-- Trigger functions
--

create trigger history_update_trigger after
update on public.history for each row execute function trigger_get_question_and_answer();

create trigger trg_delete_related_documents before
delete on public.document for each row execute function delete_related_documents();

create trigger trg_auth_users_insert after
insert
    on
    auth.users for each row execute function private.trg_auth_users_insert();

create trigger trg_auth_users_update after
update
    on
    auth.users for each row execute function private.trg_auth_users_update();

create trigger trg_auth_users_delete after
delete
    on
    auth.users for each row execute function private.trg_auth_users_delete();

create trigger wh_training after
insert on public.training for each row execute function supabase_functions.http_request('https://daianaapioca.seidoranalytics.com/api/training/load',
    'POST',
    '{"Content-type":"application/json"}',
    '{}',
    '5000');
