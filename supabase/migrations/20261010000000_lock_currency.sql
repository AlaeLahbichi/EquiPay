-- La devise d'une activité ne change plus dès qu'elle a des dépenses :
-- chaque dépense garde un taux de change vers cette devise, qui deviendrait faux.
create or replace function public.check_currency_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.default_currency is distinct from old.default_currency
  and exists (select 1 from public.expenses where activity_id = old.id) then
    raise exception 'La devise ne peut plus être changée : l''activité contient déjà des dépenses';
  end if;
  return new;
end $$;

create trigger activities_check_currency before update of default_currency on public.activities
  for each row execute function public.check_currency_change();
