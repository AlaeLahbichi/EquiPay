-- Offres (gratuite + 3 payantes), quotas des fonctions d'IA, limite d'activités
-- et réponses du formulaire de bienvenue. Structure uniquement : aucune donnée insérée.

-- ---------------------------------------------------------------------
-- Profil : offre choisie et formulaire de bienvenue
-- ---------------------------------------------------------------------
alter table public.profiles
  add column plan             text not null default 'free' check (plan in ('free', 'plus', 'pro', 'premium')),
  add column plan_since       timestamptz,
  add column onboarded_at     timestamptz,
  add column default_currency char(3) check (default_currency ~ '^[A-Z]{3}$'),
  add column country          text check (char_length(country) <= 60),
  add column usages           text[] not null default '{}',
  add column referral         text check (char_length(referral) <= 60);

-- L'offre ne se change que par choose_plan (jamais par une simple mise à jour du profil)
create or replace function public.protect_plan()
returns trigger language plpgsql set search_path = '' as $$
begin
  if (new.plan is distinct from old.plan or new.plan_since is distinct from old.plan_since)
     and coalesce(current_setting('equipay.plan_change', true), '') <> 'on' then
    raise exception 'L''offre se change depuis la page des offres' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger profiles_protect_plan before update on public.profiles
  for each row execute function public.protect_plan();

-- ---------------------------------------------------------------------
-- Limites de chaque offre (null = illimité). Les quotas d'IA sont mensuels.
-- ---------------------------------------------------------------------
create or replace function public.plan_limit(p_plan text, p_feature text)
returns int language sql immutable set search_path = '' as $$
  select case p_feature
    when 'activities' then case p_plan when 'free' then 3 when 'plus' then 10 else null end
    when 'scan'       then case p_plan when 'free' then 5 when 'plus' then 30 when 'pro' then 100 else null end
    when 'describe'   then case p_plan when 'free' then 10 when 'plus' then 60 when 'pro' then 200 else null end
    when 'trip'       then case p_plan when 'free' then 2 when 'plus' then 10 when 'pro' then 40 else null end
  end;
$$;

-- ---------------------------------------------------------------------
-- Utilisations des fonctions d'IA (écrites par le backend au nom de l'utilisateur)
-- ---------------------------------------------------------------------
create table public.ai_usage (
  id       bigint generated always as identity primary key,
  user_id  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  feature  text not null check (feature in ('scan', 'describe', 'trip')),
  used_at  timestamptz not null default now()
);
create index ai_usage_user_idx on public.ai_usage (user_id, feature, used_at);

alter table public.ai_usage enable row level security;
-- Lecture de ses propres utilisations ; ni ajout ni suppression directe (pas de remise à zéro possible)
create policy ai_usage_select on public.ai_usage for select to authenticated
  using (user_id = (select auth.uid()));

-- Quota restant pour une fonction d'IA, sans le consommer
create or replace function public.ai_quota(p_feature text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_plan  text;
  v_limit int;
  v_used  int;
begin
  if v_uid is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  if p_feature not in ('scan', 'describe', 'trip') then
    raise exception 'Fonction inconnue : %', p_feature;
  end if;
  select coalesce(plan, 'free') into v_plan from public.profiles where id = v_uid;
  v_limit := public.plan_limit(v_plan, p_feature);
  select count(*) into v_used from public.ai_usage
   where user_id = v_uid and feature = p_feature and used_at >= date_trunc('month', now());
  return jsonb_build_object(
    'allowed', v_limit is null or v_used < v_limit,
    'plan', v_plan, 'used', v_used, 'limit', v_limit);
end $$;

-- Compte une utilisation réussie
create or replace function public.record_ai_usage(p_feature text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  insert into public.ai_usage (user_id, feature) values (auth.uid(), p_feature);
end $$;

-- Offre et consommation du mois, pour la page « Mon offre »
create or replace function public.my_plan_usage()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'plan', p.plan,
    'plan_since', p.plan_since,
    'features', jsonb_build_object(
      'activities', jsonb_build_object(
        'used', (select count(*) from public.activities a where a.created_by = p.id),
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

-- Choix d'une offre. Mode démonstration : aucun paiement réel n'est encaissé.
create or replace function public.choose_plan(p_plan text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise' using errcode = '42501';
  end if;
  if p_plan not in ('free', 'plus', 'pro', 'premium') then
    raise exception 'Offre inconnue : %', p_plan;
  end if;
  perform set_config('equipay.plan_change', 'on', true);
  update public.profiles
     set plan = p_plan,
         plan_since = case when p_plan = 'free' then null else now() end
   where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Nombre d'activités créées, selon l'offre du créateur
-- ---------------------------------------------------------------------
create or replace function public.check_activity_quota()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_plan  text;
  v_limit int;
begin
  select coalesce(plan, 'free') into v_plan from public.profiles where id = new.created_by;
  v_limit := public.plan_limit(v_plan, 'activities');
  if v_limit is not null
     and (select count(*) from public.activities where created_by = new.created_by) >= v_limit then
    raise exception 'Ton offre permet de créer % activités. Passe à une offre supérieure pour en créer davantage.', v_limit
      using errcode = 'P0001', hint = 'plan_limit';
  end if;
  return new;
end $$;

create trigger activities_quota before insert on public.activities
  for each row execute function public.check_activity_quota();
