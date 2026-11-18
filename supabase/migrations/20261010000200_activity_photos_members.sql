-- Photos de l'activité (hors reçus) : tous les membres, spectateurs compris,
-- peuvent en ajouter et en supprimer, quel que soit l'auteur.
-- Les reçus de dépenses gardent leurs règles (créateur de la dépense / auteur de la photo).

drop policy attachments_insert on public.attachments;
create policy attachments_insert on public.attachments for insert to authenticated
  with check (
    uploaded_by = (select auth.uid())
    and (
      (expense_id is null and public.is_member(activity_id))
      or (public.can_edit(activity_id) and exists (
        select 1 from public.expenses e
        where e.id = expense_id and e.created_by = (select auth.uid())
      ))
    )
  );

drop policy attachments_delete on public.attachments;
create policy attachments_delete on public.attachments for delete to authenticated
  using (
    uploaded_by = (select auth.uid())
    or (expense_id is null and public.is_member(activity_id))
  );

-- Fichiers : chemin <activité>/photos/<fichier> pour les photos de l'activité
drop policy attachments_files_insert on storage.objects;
create policy attachments_files_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'attachments'
    and (
      public.can_edit(((storage.foldername(name))[1])::uuid)
      or ((storage.foldername(name))[2] = 'photos' and public.is_member(((storage.foldername(name))[1])::uuid))
    )
  );

drop policy attachments_files_delete on storage.objects;
create policy attachments_files_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'attachments'
    and (
      owner = (select auth.uid())
      or ((storage.foldername(name))[2] = 'photos' and public.is_member(((storage.foldername(name))[1])::uuid))
    )
  );
