-- La limite d'activités porte sur les activités EN COURS créées par l'utilisateur
-- (les activités archivées ne comptent plus), et résiliation de l'abonnement.
-- Structure uniquement : aucune donnée insérée.

-- Nom affiché d'une offre et offre suivante, pour les messages
create or replace function public.plan_label(p_plan text)
returns text language sql immutable set search_path = '' as $$
  select case p_plan when 'plus' then 'Plus' when 'pro' then 'Pro' when 'premium' then 'Premium' else 'Gratuit' end;
$$;

create or replace function public.next_plan(p_plan text)
returns text language sql immutable set search_path = '' as $$
  select case p_plan when 'free' then 'plus' when 'plus' then 'pro' when 'pro' then 'premium' end;
$$;

-- Activités en cours créées par l'utilisateur (non archivées par lui)
create or replace function public.active_activity_count(p_user uuid)
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int
    from public.activities a
    join public.activity_members m on m.activity_id = a.id and m.user_id = a.created_by
   where a.created_by = p_user and m.archived_at is null;
$$;

-- Message affiché quand la limite est atteinte, avec l'offre supérieure à proposer
create or replace function public.activity_limit_message(p_plan text, p_limit int)
returns text language sql immutable set search_path = '' as $$
  select format('Ton offre %s permet %s activités en cours. ', public.plan_label(p_plan), p_limit)
      || case
           when public.next_plan(p_plan) is null then 'Archive une activité terminée pour en créer une nouvelle.'
           else format('Passe à l''offre %s pour en avoir %s, ou archive une activité terminée.',
                       public.plan_label(public.next_plan(p_plan)),
                       coalesce(public.plan_limit(public.next_plan(p_plan), 'activities')::text, 'en illimité'))
         end;
$$;

create or replace function public.check_activity_quota()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_plan  text;
  v_limit int;
begin
  select coalesce(plan, 'free') into v_plan from public.profiles where id = new.created_by;
  v_limit := public.plan_limit(v_plan, 'activities');
  if v_limit is not null and public.active_activity_count(new.created_by) >= v_limit then
    raise exception '%', public.activity_limit_message(v_plan, v_limit)
      using errcode = 'P0001', hint = 'plan_limit';
  end if;
  return new;
end $$;

-- Désarchiver une activité qu'on a créée la remet « en cours » : même limite qu'à la création
create or replace function public.set_activities_archived(p_activities uuid[], p_archived boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_plan  text;
  v_limit int;
  v_back  int;
begin
  if v_uid is null then
    raise exception 'Utilisateur non connecté';
  end if;
  if not p_archived then
    select coalesce(plan, 'free') into v_plan from public.profiles where id = v_uid;
    v_limit := public.plan_limit(v_plan, 'activities');
    select count(*) into v_back
      from public.activity_members m
      join public.activities a on a.id = m.activity_id and a.created_by = v_uid
     where m.user_id = v_uid and m.activity_id = any (p_activities) and m.archived_at is not null;
    if v_limit is not null and v_back > 0 and public.active_activity_count(v_uid) + v_back > v_limit then
      raise exception '%', public.activity_limit_message(v_plan, v_limit)
        using errcode = 'P0001', hint = 'plan_limit';
    end if;
  end if;
  update public.activity_members
  set archived_at = case when p_archived then now() else null end
  where user_id = v_uid and activity_id = any (p_activities);
end $$;

-- « Mon offre » : les activités comptées sont celles en cours
create or replace function public.my_plan_usage()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'plan', p.plan,
    'plan_since', p.plan_since,
    'features', jsonb_build_object(
      'activities', jsonb_build_object(
        'used', public.active_activity_count(p.id),
        'limit', public.plan_limit(p.plan, 'activities')),
      'scan', jsonb_build_object(
        'used', (select count(*) from public.ai_usage u where u.user_id = p.id and u.feature = 'scan'
                   and u.used_at >= date_trunc('month', now())),
        'limit', public.plan_limit(p.plan, 'scan')),
      'describe', jsonb_build_object(
        'used', (select count(*) from public.ai_usage u where u.user_id = p.id and u.feature = 'describe'
                   and u.used_at >= date_trunc('month', now())),
        'limit', public.plan_limit(p.plan, 'describe')),
      'trip', jsonb_build_object(
        'used', (select count(*) from public.ai_usage u where u.user_id = p.id and u.feature = 'trip'
                   and u.used_at >= date_trunc('month', now())),
        'limit', public.plan_limit(p.plan, 'trip'))))
  from public.profiles p
  where p.id = auth.uid();
$$;

-- Résiliation : retour immédiat à l'offre Gratuite (mode démonstration, rien à rembourser).
-- Les activités et dépenses sont conservées ; seules les limites de l'offre Gratuite s'appliquent.
alter table public.profiles add column plan_cancelled_at timestamptz;

create or replace function public.cancel_plan()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  perform set_config('equipay.plan_change', 'on', true);
  update public.profiles
     set plan = 'free', plan_since = null, plan_cancelled_at = now()
   where id = auth.uid() and plan <> 'free';
end $$;

revoke execute on function public.cancel_plan() from public, anon;
grant execute on function public.cancel_plan() to authenticated;
revoke execute on function public.active_activity_count(uuid) from public, anon;
