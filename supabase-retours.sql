-- Concentré : rubrique « Retours » (bugs, idées, remarques des testeurs).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run (après supabase-schema.sql).

-- Les retours : une ligne par retour, lisible directement dans Supabase → Table Editor → feedback.
create table if not exists public.feedback (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  pseudo     text not null default '',
  kind       text not null check (kind in ('bug', 'idee', 'remarque')),
  message    text not null check (char_length(message) between 3 and 2000),
  context    jsonb not null default '{}'::jsonb,
  status     text not null default 'nouveau' check (status in ('nouveau', 'etude', 'prevu', 'fait', 'refuse')),
  reply      text not null default ''
);

-- Les « +1 » : un testeur peut appuyer un retour existant au lieu de le réécrire.
create table if not exists public.feedback_votes (
  feedback_id bigint not null references public.feedback(id) on delete cascade,
  user_id     uuid   not null default auth.uid() references auth.users(id) on delete cascade,
  primary key (feedback_id, user_id)
);

-- Les administrateurs : peuvent changer le statut d'un retour et y répondre.
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

alter table public.feedback       enable row level security;
alter table public.feedback_votes enable row level security;
alter table public.admins         enable row level security;

-- feedback : tout membre connecté lit et poste ; seul un admin change le statut ou répond ; l'auteur ou un admin peut supprimer.
drop policy if exists "fb lecture" on public.feedback;
create policy "fb lecture" on public.feedback for select to authenticated using (true);
drop policy if exists "fb ajout" on public.feedback;
create policy "fb ajout" on public.feedback for insert to authenticated
  with check (user_id = auth.uid() and status = 'nouveau' and reply = '');
drop policy if exists "fb admin" on public.feedback;
create policy "fb admin" on public.feedback for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists "fb suppression" on public.feedback;
create policy "fb suppression" on public.feedback for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- feedback_votes : chacun ajoute ou retire uniquement son propre +1.
drop policy if exists "vote lecture" on public.feedback_votes;
create policy "vote lecture" on public.feedback_votes for select to authenticated using (true);
drop policy if exists "vote ajout" on public.feedback_votes;
create policy "vote ajout" on public.feedback_votes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "vote retrait" on public.feedback_votes;
create policy "vote retrait" on public.feedback_votes for delete to authenticated using (user_id = auth.uid());

-- admins : aucune règle = personne ne peut lire ni modifier cette table depuis l'app (seulement depuis Supabase).

-- Temps réel : la liste des retours se met à jour toute seule.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'feedback') then
    alter publication supabase_realtime add table public.feedback;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'feedback_votes') then
    alter publication supabase_realtime add table public.feedback_votes;
  end if;
end
$$;

-- ⚠️ DERNIÈRE ÉTAPE, à faire à part (ne la mets pas dans le dépôt GitHub avec ton e-mail) :
-- pour devenir admin, lance cette ligne dans le SQL Editor en remplaçant l'e-mail par celui de ton compte Concentré :
--   insert into public.admins (user_id) select id from auth.users where email = 'ton.email@exemple.fr';
