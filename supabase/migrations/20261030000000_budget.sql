-- Budget mensuel : salaire, revenus et charges qui reviennent chaque mois, dépenses du mois,
-- budget par catégorie et objectifs d'épargne. Données personnelles : chacun ne voit que les siennes.
-- Structure uniquement : aucune donnée insérée (les catégories sont fixes, définies dans l'app).

-- Réglages du budget (créés par l'utilisateur au premier lancement de l'onglet Budget)
create table public.budget_settings (
  user_id     uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  currency    char(3) not null default 'MAD' check (currency ~ '^[A-Z]{3}$'),
  payday      smallint not null default 28 check (payday between 1 and 31),
  reminders   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger budget_settings_updated_at before update on public.budget_settings
  for each row execute function public.set_updated_at();

-- Revenus (salaire, loyer perçu…) et charges fixes (loyer, factures, abonnements…) de chaque mois
create table public.budget_recurring (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('income', 'expense')),
  name        text not null check (length(trim(name)) between 1 and 80),
  amount      numeric(12, 2) not null check (amount > 0),
  category    text not null default 'autre' check (char_length(category) <= 30),
  day         smallint not null check (day between 1 and 31),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index budget_recurring_user_idx on public.budget_recurring (user_id);

-- Mouvements du mois : dépenses du quotidien, revenus ponctuels, charges payées et salaire reçu
create table public.budget_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind          text not null check (kind in ('income', 'expense')),
  name          text not null check (length(trim(name)) between 1 and 80),
  amount        numeric(12, 2) not null check (amount > 0),
  category      text not null default 'autre' check (char_length(category) <= 30),
  entry_date    date not null default current_date,
  recurring_id  uuid references public.budget_recurring (id) on delete set null,
  note          text check (char_length(note) <= 300),
  created_at    timestamptz not null default now()
);
create index budget_entries_user_date_idx on public.budget_entries (user_id, entry_date);
-- Une charge fixe ou un revenu régulier n'est payé / reçu qu'une fois par mois
create unique index budget_entries_recurring_month on public.budget_entries
  (recurring_id, (date_trunc('month', entry_date::timestamp))) where recurring_id is not null;

-- Budget maximum par catégorie et par mois (« enveloppes »)
create table public.budget_limits (
  user_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  category  text not null check (char_length(category) <= 30),
  amount    numeric(12, 2) not null check (amount > 0),
  primary key (user_id, category)
);

-- Objectifs d'épargne
create table public.budget_goals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 80),
  target      numeric(12, 2) not null check (target > 0),
  saved       numeric(12, 2) not null default 0 check (saved >= 0),
  deadline    date,
  created_at  timestamptz not null default now()
);
create index budget_goals_user_idx on public.budget_goals (user_id);

-- Chacun ne lit et ne modifie que ses propres lignes
do $$
declare t text;
begin
  foreach t in array array['budget_settings', 'budget_recurring', 'budget_entries', 'budget_limits', 'budget_goals'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))',
      t || '_own', t);
  end loop;
end $$;
