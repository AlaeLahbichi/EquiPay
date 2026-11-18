-- Archivage des activités : propre à chaque utilisateur (archiver une activité
-- la range dans « Activités archivées » pour soi, sans la cacher aux autres membres).
alter table public.activity_members add column archived_at timestamptz;

-- Archive ou désarchive plusieurs activités pour l'utilisateur connecté.
-- (La policy members_update est réservée à l'owner : on passe par cette fonction.)
create or replace function public.set_activities_archived(p_activities uuid[], p_archived boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non connecté';
  end if;
  update public.activity_members
  set archived_at = case when p_archived then now() else null end
  where user_id = auth.uid() and activity_id = any (p_activities);
end $$;

revoke execute on function public.set_activities_archived(uuid[], boolean) from public, anon;
grant execute on function public.set_activities_archived(uuid[], boolean) to authenticated;
