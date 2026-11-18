-- Rejoindre par code avec validation de l'owner.
-- Le code crée une demande ; l'owner l'accepte (→ membre) ou la refuse.
-- Les deux côtés suivent les demandes en temps réel (onglet Requests).

create type public.join_request_status as enum ('pending', 'accepted', 'rejected', 'cancelled');

create table public.join_requests (
  id                 uuid primary key default gen_random_uuid(),
  activity_id        uuid not null references public.activities (id) on delete cascade,
  user_id            uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  -- Copie du nom et du logo : le demandeur n'a pas encore accès à l'activité
  activity_name      text not null,
  activity_cover     text,
  status             public.join_request_status not null default 'pending',
  -- false quand l'owner vient de répondre et que le demandeur n'a pas encore vu la réponse
  seen_by_requester  boolean not null default true,
  created_at         timestamptz not null default now(),
  decided_at         timestamptz
);

create unique index join_requests_one_pending on public.join_requests (activity_id, user_id)
  where status = 'pending';
create index join_requests_user on public.join_requests (user_id, created_at desc);
create index join_requests_activity on public.join_requests (activity_id, created_at desc);

alter table public.join_requests enable row level security;

-- Visible par le demandeur et par l'owner de l'activité ; écritures uniquement via les fonctions
create policy join_requests_select on public.join_requests for select to authenticated
  using (user_id = (select auth.uid()) or public.is_owner(activity_id));

alter table public.join_requests replica identity full;
alter publication supabase_realtime add table public.join_requests;

-- Le code ne fait plus entrer directement : il crée une demande
drop function public.join_activity_by_code(text);

create function public.join_activity_by_code(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_activity public.activities;
  v_request  uuid;
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non connecté';
  end if;
  select a.* into v_activity
  from public.activity_join_codes c join public.activities a on a.id = c.activity_id
  where c.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'));
  if v_activity.id is null then
    raise exception 'Code invalide';
  end if;
  if exists (select 1 from public.activity_members
             where activity_id = v_activity.id and user_id = auth.uid()) then
    raise exception 'Tu fais déjà partie de « % »', v_activity.name;
  end if;
  if exists (select 1 from public.join_requests
             where activity_id = v_activity.id and user_id = auth.uid() and status = 'pending') then
    raise exception 'Ta demande pour « % » est déjà en attente', v_activity.name;
  end if;

  insert into public.join_requests (activity_id, user_id, activity_name, activity_cover)
  values (v_activity.id, auth.uid(), v_activity.name, v_activity.cover_url)
  returning id into v_request;
  return jsonb_build_object('request_id', v_request, 'activity_name', v_activity.name);
end $$;

-- L'owner accepte (la personne devient membre) ou refuse
create function public.respond_join_request(p_request uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.join_requests;
begin
  select * into r from public.join_requests where id = p_request for update;
  if r.id is null then
    raise exception 'Demande introuvable';
  end if;
  if not public.is_owner(r.activity_id) then
    raise exception 'Seul le créateur de l''activité peut répondre';
  end if;
  if r.status <> 'pending' then
    raise exception 'Cette demande a déjà été traitée';
  end if;
  if p_accept then
    insert into public.activity_members (activity_id, user_id, role)
    values (r.activity_id, r.user_id, 'member')
    on conflict (activity_id, user_id) do nothing;
  end if;
  update public.join_requests
  set status = case when p_accept then 'accepted' else 'rejected' end::public.join_request_status,
      decided_at = now(),
      seen_by_requester = false
  where id = p_request;
end $$;

-- Le demandeur retire sa demande
create function public.cancel_join_request(p_request uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.join_requests set status = 'cancelled', decided_at = now()
  where id = p_request and user_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'Cette demande ne peut plus être annulée';
  end if;
end $$;

-- Le demandeur a vu les réponses (remet le badge à zéro)
create function public.mark_join_requests_seen()
returns void language sql security definer set search_path = '' as $$
  update public.join_requests set seen_by_requester = true
  where user_id = auth.uid() and not seen_by_requester;
$$;

revoke execute on function public.join_activity_by_code(text)          from public, anon;
revoke execute on function public.respond_join_request(uuid, boolean)  from public, anon;
revoke execute on function public.cancel_join_request(uuid)            from public, anon;
revoke execute on function public.mark_join_requests_seen()            from public, anon;
grant  execute on function public.join_activity_by_code(text)          to authenticated;
grant  execute on function public.respond_join_request(uuid, boolean)  to authenticated;
grant  execute on function public.cancel_join_request(uuid)            to authenticated;
grant  execute on function public.mark_join_requests_seen()            to authenticated;
