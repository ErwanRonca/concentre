-- Concentré : schéma Supabase.
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
-- Une seule table « docs » stocke toutes les collections de l'app (members, profiles, kudos, groups, gsessions),
-- chaque ligne étant un document JSON. La sécurité est assurée par les règles RLS ci-dessous.

create table if not exists public.docs (
  coll       text        not null,
  id         text        not null,
  data       jsonb       not null default '{}'::jsonb,
  end_at     bigint      generated always as ((data->>'endAt')::bigint) stored,
  updated_at timestamptz not null default now(),
  primary key (coll, id)
);
create index if not exists docs_end_at_idx on public.docs (coll, end_at);

-- Fusion profonde de deux objets JSON (pour rejoindre / quitter un groupe ou une session sans écraser les autres).
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language sql immutable as $$
  select case
    when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
      coalesce((
        select jsonb_object_agg(k,
          case when a ? k and b ? k then public.jsonb_deep_merge(a->k, b->k)
               when b ? k then b->k
               else a->k end)
        from (select jsonb_object_keys(a) as k union select jsonb_object_keys(b)) keys
      ), '{}'::jsonb)
    else b
  end
$$;

-- Mise à jour atomique d'un document (crée le document s'il n'existe pas). Les règles RLS s'appliquent.
create or replace function public.merge_doc(p_coll text, p_id text, p_patch jsonb)
returns void language plpgsql security invoker as $$
begin
  insert into public.docs (coll, id, data) values (p_coll, p_id, p_patch)
  on conflict (coll, id) do update
    set data = public.jsonb_deep_merge(public.docs.data, excluded.data),
        updated_at = now();
end
$$;

-- Sécurité : tout membre connecté lit le club ; chacun n'écrit que ses propres données personnelles.
-- Groupes et sessions de groupe sont modifiables par tout membre connecté (version test).
alter table public.docs enable row level security;

drop policy if exists "lecture membres" on public.docs;
create policy "lecture membres" on public.docs
  for select to authenticated using (true);

drop policy if exists "creation" on public.docs;
create policy "creation" on public.docs
  for insert to authenticated
  with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or coll in ('groups', 'gsessions')
  );

drop policy if exists "modification" on public.docs;
create policy "modification" on public.docs
  for update to authenticated
  using (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or coll in ('groups', 'gsessions')
  )
  with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or coll in ('groups', 'gsessions')
  );

-- Temps réel : diffuser les changements de la table aux membres connectés.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end
$$;
