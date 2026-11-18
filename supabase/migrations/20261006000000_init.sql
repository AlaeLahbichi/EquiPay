-- =====================================================================
-- EquiPay — schéma initial
-- Appliqué avec : ./supabase/push.sh
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.activity_type as enum ('voyage', 'sortie', 'quotidien', 'credit');
-- owner : créateur | member : ajoute ses dépenses | viewer : spectateur (lecture seule)
create type public.member_role as enum ('owner', 'member', 'viewer');
create type public.attachment_kind as enum ('recu', 'devis', 'photo', 'autre');
create type public.invitation_status as enum ('pending', 'accepted', 'declined');

-- ---------------------------------------------------------------------
-- Utilitaire : mise à jour automatique de updated_at
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Profils (1 profil par compte Supabase Auth)
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9_]{3,30}$'),
  email       text not null unique,
  full_name   text,
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- Crée le profil automatiquement à l'inscription (email ou Google)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  base      text;
  candidate text;
begin
  base := left(regexp_replace(lower(coalesce(
            new.raw_user_meta_data ->> 'username',
            split_part(new.email, '@', 1))), '[^a-z0-9_]', '', 'g'), 24);
  if length(base) < 3 then
    base := 'user' || base;
  end if;

  candidate := base;
  while exists (select 1 from public.profiles where username = candidate) loop
    candidate := base || floor(random() * 100000)::int;
  end loop;

  insert into public.profiles (id, username, email, full_name, avatar_url)
  values (
    new.id,
    candidate,
    lower(new.email),
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture')
  );
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Email de l'utilisateur connecté
create or replace function public.current_email()
returns text language sql stable security definer set search_path = '' as $$
  select email from public.profiles where id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------
-- Activités (voyage, sortie, dépenses quotidiennes, crédit)
-- ---------------------------------------------------------------------
create table public.activities (
  id               uuid primary key default gen_random_uuid(),
  type             public.activity_type not null default 'voyage',
  name             text not null check (length(trim(name)) > 0),
  description      text,
  cover_url        text,
  default_currency char(3) not null default 'EUR' check (default_currency ~ '^[A-Z]{3}$'),
  start_date       date,
  end_date         date,
  country          text,
  city             text,
  created_by       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);

create trigger activities_updated_at before update on public.activities
  for each row execute function public.set_updated_at();

create index activities_name_trgm on public.activities using gin (name extensions.gin_trgm_ops);
create index activities_start_date on public.activities (start_date);

-- ---------------------------------------------------------------------
-- Membres d'une activité
-- ---------------------------------------------------------------------
create table public.activity_members (
  activity_id uuid not null references public.activities (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        public.member_role not null default 'member',
  joined_at   timestamptz not null default now(),
  primary key (activity_id, user_id)
);

create index activity_members_user on public.activity_members (user_id);

-- Rôle de l'utilisateur connecté dans une activité (null si non membre)
create or replace function public.my_role(p_activity uuid)
returns public.member_role language sql stable security definer set search_path = '' as $$
  select role from public.activity_members
  where activity_id = p_activity and user_id = (select auth.uid());
$$;

create or replace function public.is_member(p_activity uuid)
returns boolean language sql stable set search_path = '' as $$
  select public.my_role(p_activity) is not null;
$$;

create or replace function public.is_owner(p_activity uuid)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(public.my_role(p_activity) = 'owner', false);
$$;

-- Owner ou membre (un spectateur ne peut rien modifier)
create or replace function public.can_edit(p_activity uuid)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(public.my_role(p_activity) in ('owner', 'member'), false);
$$;

-- ---------------------------------------------------------------------
-- Code unique pour rejoindre une activité (visible par l'owner uniquement)
-- ---------------------------------------------------------------------
create table public.activity_join_codes (
  activity_id uuid primary key references public.activities (id) on delete cascade,
  code        text not null unique check (code ~ '^[A-Z2-9]{8}$'),
  created_at  timestamptz not null default now()
);

-- 8 caractères sans ambiguïté (pas de 0/O, 1/I/L)
create or replace function public.generate_join_code()
returns text language plpgsql set search_path = '' as $$
declare
  chars  constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
begin
  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    exit when not exists (select 1 from public.activity_join_codes where code = v_code);
  end loop;
  return v_code;
end $$;

-- À la création : le créateur devient "owner" et un code est généré
create or replace function public.setup_new_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.activity_members (activity_id, user_id, role)
  values (new.id, new.created_by, 'owner');
  insert into public.activity_join_codes (activity_id, code)
  values (new.id, public.generate_join_code());
  return new;
end $$;

create trigger activities_setup after insert on public.activities
  for each row execute function public.setup_new_activity();

-- Rejoindre une activité avec son code (devient "member")
create or replace function public.join_activity_by_code(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_activity uuid;
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non connecté';
  end if;
  select activity_id into v_activity from public.activity_join_codes
  where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'));
  if v_activity is null then
    raise exception 'Code invalide';
  end if;
  insert into public.activity_members (activity_id, user_id, role)
  values (v_activity, auth.uid(), 'member')
  on conflict (activity_id, user_id) do nothing;
  return v_activity;
end $$;

-- Générer un nouveau code (l'ancien ne fonctionne plus)
create or replace function public.regenerate_join_code(p_activity uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_code text;
begin
  if not public.is_owner(p_activity) then
    raise exception 'Seul le créateur peut changer le code';
  end if;
  update public.activity_join_codes
  set code = public.generate_join_code(), created_at = now()
  where activity_id = p_activity
  returning code into v_code;
  return v_code;
end $$;

-- ---------------------------------------------------------------------
-- Invitations par email
-- ---------------------------------------------------------------------
create table public.activity_invitations (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references public.activities (id) on delete cascade,
  email        text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role         public.member_role not null default 'member' check (role <> 'owner'),
  invited_by   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  status       public.invitation_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);

create unique index activity_invitations_pending
  on public.activity_invitations (activity_id, email) where status = 'pending';
create index activity_invitations_email on public.activity_invitations (email) where status = 'pending';

-- Normalise l'email et refuse d'inviter quelqu'un déjà membre
create or replace function public.prepare_invitation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.email := lower(trim(new.email));
  if exists (
    select 1 from public.activity_members m
    join public.profiles p on p.id = m.user_id
    where m.activity_id = new.activity_id and p.email = new.email
  ) then
    raise exception 'Cette personne est déjà membre de l''activité';
  end if;
  return new;
end $$;

create trigger activity_invitations_prepare before insert on public.activity_invitations
  for each row execute function public.prepare_invitation();

create or replace function public.has_pending_invitation(p_activity uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.activity_invitations
    where activity_id = p_activity and status = 'pending' and email = public.current_email()
  );
$$;

create or replace function public.accept_invitation(p_invitation uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  inv public.activity_invitations;
begin
  select * into inv from public.activity_invitations
  where id = p_invitation and status = 'pending' and email = public.current_email()
  for update;
  if not found then
    raise exception 'Invitation introuvable';
  end if;
  insert into public.activity_members (activity_id, user_id, role)
  values (inv.activity_id, auth.uid(), inv.role)
  on conflict (activity_id, user_id) do nothing;
  update public.activity_invitations
  set status = 'accepted', responded_at = now()
  where id = inv.id;
  return inv.activity_id;
end $$;

create or replace function public.decline_invitation(p_invitation uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.activity_invitations
  set status = 'declined', responded_at = now()
  where id = p_invitation and status = 'pending' and email = public.current_email();
  if not found then
    raise exception 'Invitation introuvable';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Dépenses
-- ---------------------------------------------------------------------
create table public.expenses (
  id            uuid primary key default gen_random_uuid(),
  activity_id   uuid not null references public.activities (id) on delete cascade,
  created_by    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  paid_by       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name          text not null check (length(trim(name)) > 0),
  description   text,
  amount        numeric(12, 2) not null check (amount > 0),
  currency      char(3) not null check (currency ~ '^[A-Z]{3}$'),
  -- Taux vers la devise par défaut de l'activité (1 si même devise)
  exchange_rate numeric(14, 6) not null default 1 check (exchange_rate > 0),
  expense_date  date not null default current_date,
  country       text,
  city          text,
  address       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger expenses_updated_at before update on public.expenses
  for each row execute function public.set_updated_at();

create index expenses_activity_date on public.expenses (activity_id, expense_date desc);
create index expenses_amount on public.expenses (activity_id, amount);
create index expenses_name_trgm on public.expenses using gin (name extensions.gin_trgm_ops);

-- Le créateur et le payeur doivent être owner ou member (pas spectateur)
create or replace function public.check_expense_members()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.activity_members
                 where activity_id = new.activity_id and user_id = new.created_by
                   and role in ('owner', 'member'))
  or not exists (select 1 from public.activity_members
                 where activity_id = new.activity_id and user_id = new.paid_by
                   and role in ('owner', 'member')) then
    raise exception 'Le créateur et le payeur doivent être membres (non spectateurs) de l''activité';
  end if;
  return new;
end $$;

create trigger expenses_check_members before insert or update on public.expenses
  for each row execute function public.check_expense_members();

-- ---------------------------------------------------------------------
-- Répartition d'une dépense (pourcentage par participant)
-- ---------------------------------------------------------------------
create table public.expense_shares (
  expense_id uuid not null references public.expenses (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  percentage numeric(5, 2) not null check (percentage > 0 and percentage <= 100),
  primary key (expense_id, user_id)
);

create index expense_shares_user on public.expense_shares (user_id);

-- Un participant doit être owner ou member (pas spectateur)
create or replace function public.check_share_member()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.expenses e
    join public.activity_members m on m.activity_id = e.activity_id and m.user_id = new.user_id
    where e.id = new.expense_id and m.role in ('owner', 'member')
  ) then
    raise exception 'Le participant doit être membre (non spectateur) de l''activité';
  end if;
  return new;
end $$;

create trigger expense_shares_check_member before insert or update on public.expense_shares
  for each row execute function public.check_share_member();

-- La somme des pourcentages d'une dépense doit faire 100 %
-- (vérifié en fin de transaction : on insère la dépense et ses parts ensemble)
create or replace function public.assert_shares_total(p_expense uuid)
returns void language plpgsql set search_path = '' as $$
declare
  total numeric;
begin
  if not exists (select 1 from public.expenses where id = p_expense) then
    return; -- dépense supprimée
  end if;
  select coalesce(sum(percentage), 0) into total
  from public.expense_shares where expense_id = p_expense;
  if total <> 100 then
    raise exception 'La somme des pourcentages doit être 100 %% (actuellement %)', total;
  end if;
end $$;

create or replace function public.check_shares_total_from_share()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public.assert_shares_total(old.expense_id);
  else
    perform public.assert_shares_total(new.expense_id);
  end if;
  return null;
end $$;

create or replace function public.check_shares_total_from_expense()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform public.assert_shares_total(new.id);
  return null;
end $$;

create constraint trigger expense_shares_total
  after insert or update or delete on public.expense_shares
  deferrable initially deferred
  for each row execute function public.check_shares_total_from_share();

create constraint trigger expenses_shares_total
  after insert on public.expenses
  deferrable initially deferred
  for each row execute function public.check_shares_total_from_expense();

-- On ne retire pas un membre qui a des dépenses (le passer en spectateur à la place)
create or replace function public.check_member_removal()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Suppression en cascade de l'activité ou du compte : on laisse faire
  if not exists (select 1 from public.activities where id = old.activity_id)
  or not exists (select 1 from public.profiles where id = old.user_id) then
    return old;
  end if;
  if exists (select 1 from public.expenses
             where activity_id = old.activity_id and paid_by = old.user_id)
  or exists (select 1 from public.expense_shares s
             join public.expenses e on e.id = s.expense_id
             where e.activity_id = old.activity_id and s.user_id = old.user_id) then
    raise exception 'Ce membre a des dépenses : passez-le en spectateur plutôt que de le retirer';
  end if;
  return old;
end $$;

create trigger activity_members_check_removal before delete on public.activity_members
  for each row execute function public.check_member_removal();

-- ---------------------------------------------------------------------
-- Pièces jointes (reçus, devis, photos)
-- ---------------------------------------------------------------------
create table public.attachments (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references public.activities (id) on delete cascade,
  expense_id   uuid references public.expenses (id) on delete cascade,
  uploaded_by  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind         public.attachment_kind not null default 'photo',
  storage_path text not null,
  created_at   timestamptz not null default now()
);

create index attachments_activity on public.attachments (activity_id);

-- ---------------------------------------------------------------------
-- Historique du chatbot / assistant IA
-- ---------------------------------------------------------------------
create table public.chat_messages (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  activity_id uuid references public.activities (id) on delete cascade,
  role        text not null check (role in ('user', 'assistant')),
  content     text not null,
  created_at  timestamptz not null default now()
);

create index chat_messages_user on public.chat_messages (user_id, created_at);

-- ---------------------------------------------------------------------
-- Vues : soldes et totaux (montants convertis dans la devise de l'activité)
-- ---------------------------------------------------------------------
create view public.activity_balances with (security_invoker = true) as
select
  m.activity_id,
  m.user_id,
  m.role,
  round(coalesce(p.paid, 0), 2)                       as total_paid,
  round(coalesce(o.owed, 0), 2)                       as total_owed,
  round(coalesce(p.paid, 0) - coalesce(o.owed, 0), 2) as balance
from public.activity_members m
left join (
  select activity_id, paid_by as user_id, sum(amount * exchange_rate) as paid
  from public.expenses
  group by activity_id, paid_by
) p on p.activity_id = m.activity_id and p.user_id = m.user_id
left join (
  select e.activity_id, s.user_id, sum(e.amount * e.exchange_rate * s.percentage / 100) as owed
  from public.expenses e
  join public.expense_shares s on s.expense_id = e.id
  group by e.activity_id, s.user_id
) o on o.activity_id = m.activity_id and o.user_id = m.user_id;

create view public.activity_totals with (security_invoker = true) as
select
  a.id                                                   as activity_id,
  a.default_currency                                     as currency,
  round(coalesce(sum(e.amount * e.exchange_rate), 0), 2) as total_amount,
  count(e.id)                                            as expense_count
from public.activities a
left join public.expenses e on e.activity_id = a.id
group by a.id, a.default_currency;

-- ---------------------------------------------------------------------
-- Sécurité (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.activities           enable row level security;
alter table public.activity_members     enable row level security;
alter table public.activity_join_codes  enable row level security;
alter table public.activity_invitations enable row level security;
alter table public.expenses             enable row level security;
alter table public.expense_shares       enable row level security;
alter table public.attachments          enable row level security;
alter table public.chat_messages        enable row level security;

-- Profils : visibles par les utilisateurs connectés (recherche par username/email)
create policy profiles_select on public.profiles for select to authenticated
  using (true);
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Activités : visibles par les membres (et les invités), modifiables par l'owner
create policy activities_select on public.activities for select to authenticated
  using (public.is_member(id) or created_by = (select auth.uid())
         or public.has_pending_invitation(id));
create policy activities_insert on public.activities for insert to authenticated
  with check (created_by = (select auth.uid()));
create policy activities_update on public.activities for update to authenticated
  using (public.is_owner(id)) with check (public.is_owner(id));
create policy activities_delete on public.activities for delete to authenticated
  using (public.is_owner(id));

-- Membres : visibles par les membres ; l'owner ajoute, change les rôles et retire ;
-- chacun (sauf l'owner) peut quitter l'activité
create policy members_select on public.activity_members for select to authenticated
  using (public.is_member(activity_id));
create policy members_insert on public.activity_members for insert to authenticated
  with check (public.is_owner(activity_id) and role in ('member', 'viewer'));
create policy members_update on public.activity_members for update to authenticated
  using (public.is_owner(activity_id) and role <> 'owner')
  with check (role in ('member', 'viewer'));
create policy members_delete on public.activity_members for delete to authenticated
  using (role <> 'owner'
         and (user_id = (select auth.uid()) or public.is_owner(activity_id)));

-- Code d'accès : visible par l'owner uniquement
create policy join_codes_select on public.activity_join_codes for select to authenticated
  using (public.is_owner(activity_id));

-- Invitations : l'owner invite et annule ; l'invité voit les siennes
create policy invitations_select on public.activity_invitations for select to authenticated
  using (public.is_owner(activity_id) or email = public.current_email());
create policy invitations_insert on public.activity_invitations for insert to authenticated
  with check (public.is_owner(activity_id) and invited_by = (select auth.uid()));
create policy invitations_delete on public.activity_invitations for delete to authenticated
  using (public.is_owner(activity_id));

-- Dépenses : visibles par tous les membres (spectateurs compris),
-- ajoutées par owner/member, modifiables uniquement par leur créateur
create policy expenses_select on public.expenses for select to authenticated
  using (public.is_member(activity_id));
create policy expenses_insert on public.expenses for insert to authenticated
  with check (public.can_edit(activity_id) and created_by = (select auth.uid()));
create policy expenses_update on public.expenses for update to authenticated
  using (created_by = (select auth.uid()) and public.can_edit(activity_id))
  with check (created_by = (select auth.uid()) and public.can_edit(activity_id));
create policy expenses_delete on public.expenses for delete to authenticated
  using (created_by = (select auth.uid()) and public.can_edit(activity_id));

-- Parts : visibles par les membres, modifiables par le créateur de la dépense
create policy shares_select on public.expense_shares for select to authenticated
  using (exists (select 1 from public.expenses e
                 where e.id = expense_id and public.is_member(e.activity_id)));
create policy shares_write on public.expense_shares for all to authenticated
  using (exists (select 1 from public.expenses e
                 where e.id = expense_id and e.created_by = (select auth.uid())
                   and public.can_edit(e.activity_id)))
  with check (exists (select 1 from public.expenses e
                      where e.id = expense_id and e.created_by = (select auth.uid())
                        and public.can_edit(e.activity_id)));

-- Pièces jointes : visibles par les membres, ajoutées par owner/member
create policy attachments_select on public.attachments for select to authenticated
  using (public.is_member(activity_id));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (public.can_edit(activity_id) and uploaded_by = (select auth.uid()));
create policy attachments_delete on public.attachments for delete to authenticated
  using (uploaded_by = (select auth.uid()));

-- Chatbot : chacun ne voit que ses messages
create policy chat_select on public.chat_messages for select to authenticated
  using (user_id = (select auth.uid()));
create policy chat_insert on public.chat_messages for insert to authenticated
  with check (user_id = (select auth.uid()));

-- Fonctions appelables depuis l'app : utilisateurs connectés uniquement
revoke execute on function public.join_activity_by_code(text)  from public, anon;
revoke execute on function public.regenerate_join_code(uuid)   from public, anon;
revoke execute on function public.accept_invitation(uuid)      from public, anon;
revoke execute on function public.decline_invitation(uuid)     from public, anon;
grant  execute on function public.join_activity_by_code(text)  to authenticated;
grant  execute on function public.regenerate_join_code(uuid)   to authenticated;
grant  execute on function public.accept_invitation(uuid)      to authenticated;
grant  execute on function public.decline_invitation(uuid)     to authenticated;

-- ---------------------------------------------------------------------
-- Stockage des fichiers
--   avatars/<user_id>/...             photo de profil (public)
--   activity-covers/<activity_id>/... photo de l'activité (public, owner)
--   attachments/<activity_id>/...     reçus, devis (privé, membres seulement)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('avatars', 'avatars', true),
  ('activity-covers', 'activity-covers', true),
  ('attachments', 'attachments', false)
on conflict (id) do nothing;

create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy covers_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'activity-covers' and public.is_owner(((storage.foldername(name))[1])::uuid));
create policy covers_update on storage.objects for update to authenticated
  using (bucket_id = 'activity-covers' and public.is_owner(((storage.foldername(name))[1])::uuid));

create policy attachments_files_select on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy attachments_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and public.can_edit(((storage.foldername(name))[1])::uuid));
create policy attachments_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and owner = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Temps réel : l'app est notifiée dès qu'une dépense, un membre ou une invitation change
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table
  public.expenses, public.expense_shares, public.activity_members, public.activity_invitations;
