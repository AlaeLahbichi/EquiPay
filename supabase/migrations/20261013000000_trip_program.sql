-- Programme des voyages et sorties : les activités à faire (nom, lieu, adresse, date)
-- et le vote pour / contre de chaque participant.
--   - visible par tous les membres, spectateurs compris
--   - ajout et vote : owner et membres (pas les spectateurs)
--   - modification et suppression : l'auteur de l'élément ou l'owner de l'activité

create table public.trip_items (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references public.activities (id) on delete cascade,
  created_by   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 120),
  place        text check (char_length(place) <= 120),
  address      text check (char_length(address) <= 300),
  planned_on   date,
  planned_at   time,
  -- Position du lieu (remplie à partir de l'adresse, pour la carte)
  latitude     double precision check (latitude between -90 and 90),
  longitude    double precision check (longitude between -180 and 180),
  done         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index trip_items_activity_idx on public.trip_items (activity_id);

-- Un vote par personne et par élément : 1 = pour, -1 = contre (supprimer la ligne = retirer son vote).
-- activity_id est recopié pour le filtre du temps réel et les règles d'accès.
create table public.trip_votes (
  item_id      uuid not null references public.trip_items (id) on delete cascade,
  activity_id  uuid not null references public.activities (id) on delete cascade,
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  vote         smallint not null check (vote in (-1, 1)),
  updated_at   timestamptz not null default now(),
  primary key (item_id, user_id)
);
create index trip_votes_activity_idx on public.trip_votes (activity_id);

-- Seuls les voyages et les sorties ont un programme
create or replace function public.has_program(p_activity uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.activities a where a.id = p_activity and a.type in ('voyage', 'sortie')
  );
$$;

alter table public.trip_items enable row level security;
alter table public.trip_votes enable row level security;

create policy trip_items_select on public.trip_items for select to authenticated
  using (public.is_member(activity_id));

create policy trip_items_insert on public.trip_items for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and public.can_edit(activity_id)
    and public.has_program(activity_id)
  );

create policy trip_items_update on public.trip_items for update to authenticated
  using (created_by = (select auth.uid()) or public.is_owner(activity_id))
  with check (public.can_edit(activity_id));

create policy trip_items_delete on public.trip_items for delete to authenticated
  using (created_by = (select auth.uid()) or public.is_owner(activity_id));

create policy trip_votes_select on public.trip_votes for select to authenticated
  using (public.is_member(activity_id));

create policy trip_votes_insert on public.trip_votes for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.can_edit(activity_id)
    and exists (select 1 from public.trip_items i where i.id = item_id and i.activity_id = trip_votes.activity_id)
  );

create policy trip_votes_update on public.trip_votes for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and public.can_edit(activity_id));

create policy trip_votes_delete on public.trip_votes for delete to authenticated
  using (user_id = (select auth.uid()));

-- Temps réel : « replica identity full » pour que les suppressions (élément retiré, vote annulé)
-- arrivent aussi, avec leur activity_id, chez les autres participants
alter table public.trip_items replica identity full;
alter table public.trip_votes replica identity full;
alter publication supabase_realtime add table public.trip_items, public.trip_votes;
