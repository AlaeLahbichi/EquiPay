-- =====================================================================
-- Photos des dépenses : 0, 1 ou 2 maximum par dépense
-- =====================================================================

-- Vérifie la limite et que la photo appartient à la même activité que la dépense
create or replace function public.check_expense_attachments()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.expense_id is null then
    return new; -- photo de l'activité, pas de limite
  end if;
  -- Verrouille la dépense : deux ajouts simultanés ne peuvent pas dépasser la limite
  perform 1 from public.expenses
  where id = new.expense_id and activity_id = new.activity_id
  for update;
  if not found then
    raise exception 'La photo doit appartenir à l''activité de la dépense';
  end if;
  if (select count(*) from public.attachments
      where expense_id = new.expense_id and id <> new.id) >= 2 then
    raise exception 'Une dépense peut avoir au maximum 2 photos';
  end if;
  return new;
end $$;

create trigger attachments_check_expense
  before insert or update of expense_id, activity_id on public.attachments
  for each row execute function public.check_expense_attachments();

-- Seul le créateur d'une dépense peut y joindre des photos
drop policy attachments_insert on public.attachments;
create policy attachments_insert on public.attachments for insert to authenticated
  with check (
    public.can_edit(activity_id)
    and uploaded_by = (select auth.uid())
    and (expense_id is null or exists (
      select 1 from public.expenses e
      where e.id = expense_id and e.created_by = (select auth.uid())
    ))
  );

-- L'owner peut supprimer l'ancienne photo de l'activité
create policy covers_delete on storage.objects for delete to authenticated
  using (bucket_id = 'activity-covers' and public.is_owner(((storage.foldername(name))[1])::uuid));
