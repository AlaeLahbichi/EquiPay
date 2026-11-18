-- =====================================================================
-- Dépenses depuis l'application
--   1. save_expense : crée ou modifie une dépense ET ses parts en une seule transaction
--      (la somme des pourcentages = 100 % est vérifiée en fin de transaction)
--   2. 1 photo maximum par dépense (au lieu de 2)
--   3. temps réel sur les photos et suppressions de dépenses
-- =====================================================================

-- p_expense_id null → création ; sinon modification (créateur uniquement, via RLS).
-- p_shares : [{"user_id": "...", "percentage": 50}, ...]
-- security invoker : les règles d'accès (RLS) et les vérifications s'appliquent normalement.
create or replace function public.save_expense(
  p_expense_id    uuid,
  p_activity_id   uuid,
  p_name          text,
  p_description   text,
  p_amount        numeric,
  p_currency      text,
  p_exchange_rate numeric,
  p_expense_date  date,
  p_paid_by       uuid,
  p_country       text,
  p_city          text,
  p_address       text,
  p_shares        jsonb
)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid;
begin
  if jsonb_typeof(p_shares) <> 'array' or jsonb_array_length(p_shares) = 0 then
    raise exception 'Choisis au moins un participant';
  end if;

  if p_expense_id is null then
    insert into public.expenses (activity_id, paid_by, name, description, amount, currency,
                                 exchange_rate, expense_date, country, city, address)
    values (p_activity_id, p_paid_by, trim(p_name), nullif(trim(p_description), ''), p_amount,
            upper(p_currency), p_exchange_rate, p_expense_date, nullif(trim(p_country), ''),
            nullif(trim(p_city), ''), nullif(trim(p_address), ''))
    returning id into v_id;
  else
    update public.expenses
    set paid_by = p_paid_by, name = trim(p_name), description = nullif(trim(p_description), ''),
        amount = p_amount, currency = upper(p_currency), exchange_rate = p_exchange_rate,
        expense_date = p_expense_date, country = nullif(trim(p_country), ''),
        city = nullif(trim(p_city), ''), address = nullif(trim(p_address), '')
    where id = p_expense_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Seul le créateur de la dépense peut la modifier';
    end if;
    delete from public.expense_shares where expense_id = v_id;
  end if;

  insert into public.expense_shares (expense_id, user_id, percentage)
  select v_id, (s ->> 'user_id')::uuid, (s ->> 'percentage')::numeric
  from jsonb_array_elements(p_shares) s;

  return v_id;
end $$;

revoke execute on function public.save_expense(uuid, uuid, text, text, numeric, text, numeric, date,
                                               uuid, text, text, text, jsonb) from public, anon;
grant  execute on function public.save_expense(uuid, uuid, text, text, numeric, text, numeric, date,
                                               uuid, text, text, text, jsonb) to authenticated;

-- 1 photo maximum par dépense
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
  if exists (select 1 from public.attachments
             where expense_id = new.expense_id and id <> new.id) then
    raise exception 'Une dépense peut avoir au maximum 1 photo';
  end if;
  return new;
end $$;

-- Temps réel : nouvelles photos, et suppressions filtrables par activité
alter table public.attachments replica identity full;
alter table public.expenses replica identity full;
alter publication supabase_realtime add table public.attachments;
