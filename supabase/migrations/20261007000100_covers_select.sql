-- Supprimer ou remplacer un fichier nécessite aussi le droit de le lire via l'API
create policy covers_select on storage.objects for select to authenticated
  using (bucket_id = 'activity-covers' and public.is_member(((storage.foldername(name))[1])::uuid));
