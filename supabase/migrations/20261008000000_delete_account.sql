-- Suppression du compte par l'utilisateur lui-même (bouton « Supprimer mon compte »).
-- Supprimer auth.users efface en cascade le profil, ses activités, dépenses et messages.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Connexion requise';
  end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
