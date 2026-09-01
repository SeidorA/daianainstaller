-- Keep Studio auth-trigger membership assignment scoped to explicit tenant mappings.
CREATE OR REPLACE FUNCTION "private"."sync_studio_memberships_from_auth"("p_auth_user" "auth"."users") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'auth', 'public', 'studio', 'private'
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
  v_join_tenant_value text;
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

  -- New-tenant provisioning creates the owner organization and workspace outside
  -- this auth trigger. Do not attach the user to a legacy organization here.
  if p_auth_user.raw_user_meta_data->>'create_new_tenant' = 'true' then
    return;
  end if;

  v_join_tenant_value := nullif(btrim(p_auth_user.raw_user_meta_data->>'join_tenant_id'), '');

  if v_join_tenant_value is not null
     and v_join_tenant_value ~ '^[0-9]+$' then
    -- Treat an out-of-range numeric tenant as an explicit request and fail closed.
    if length(v_join_tenant_value) > 10
       or (length(v_join_tenant_value) = 10
           and v_join_tenant_value > '2147483647') then
      raise warning 'Studio membership skipped: join_tenant_id % is out of range', v_join_tenant_value;
      return;
    end if;

    begin
      select m."studioOrganizationId"::uuid
      into v_org_id
      from public.tenant_studio_organization_mappings m
      where m."idTenant" = v_join_tenant_value::integer;
    exception when invalid_text_representation then
      raise warning 'Studio membership skipped: tenant % has an invalid Studio organization mapping', v_join_tenant_value;
      return;
    end;

    if v_org_id is null then
      raise warning 'Studio membership skipped: tenant % has no Studio organization mapping', v_join_tenant_value;
      return;
    end if;

    if not exists (
      select 1 from studio.organization o where o.id = v_org_id
    ) then
      raise warning 'Studio membership skipped: mapped Studio organization % does not exist', v_org_id;
      return;
    end if;

    -- Use an owner from the mapped organization only as the audit actor.
    select ou."userId"
    into v_owner_user_id
    from studio.organization_user ou
    join studio.role r on r.id = ou."roleId"
    where ou."organizationId" = v_org_id
      and r."name" = 'owner'
      and ou."status" = 'active'
    order by ou."createdDate" asc nulls last
    limit 1;

    v_owner_user_id := coalesce(v_owner_user_id, p_auth_user.id);
    v_membership_role_name := 'member';
    v_workspace_name := 'Personal Workspace';
  else
    -- Preserve the legacy Studio-only fallback when no numeric join tenant exists.
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

    v_owner_user_id := coalesce(v_owner_user_id, p_auth_user.id);
    v_membership_role_name := case
      when v_org_was_created then 'owner'
      else 'member'
    end;
    v_workspace_name := case
      when v_org_was_created then 'Default Workspace'
      else 'Personal Workspace'
    end;
  end if;

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
  where "name" = case when v_org_was_created then 'owner' else 'personal workspace' end
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
