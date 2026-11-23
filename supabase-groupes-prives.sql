-- Concentré : groupes privés, accessibles uniquement par lien d'invitation.
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run (après supabase-schema.sql).
-- Effet : un groupe et ses sessions de groupe ne sont visibles que par ses membres.
-- On entre dans un groupe uniquement avec son lien d'invitation (fonction join_group).

-- Vrai si la personne connectée est membre (valeur > 0) du groupe p_gid.
create or replace function public.is_group_member(p_gid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.docs
    where coll = 'groups' and id = p_gid
      and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0
  )
$$;

-- Lecture : tout le monde voit la communauté (membres, profils, kudos),
-- mais un groupe et ses sessions seulement si on en est membre.
drop policy if exists "lecture membres" on public.docs;
create policy "lecture membres" on public.docs
  for select to authenticated using (
    coll not in ('groups', 'gsessions')
    or (coll = 'groups' and public.is_group_member(id))
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Création : ses propres données ; un groupe dont on est membre ; une session dans un de ses groupes.
drop policy if exists "creation" on public.docs;
create policy "creation" on public.docs
  for insert to authenticated with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or (coll = 'groups' and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0)
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Modification : ses propres données ; ses groupes (y compris pour les quitter) ; les sessions de ses groupes.
drop policy if exists "modification" on public.docs;
create policy "modification" on public.docs
  for update to authenticated
  using (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or (coll = 'groups' and public.is_group_member(id))
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  )
  with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or coll = 'groups'
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Rejoindre un groupe avec son lien : vérifie le code d'invitation, ajoute la personne, renvoie le nom du groupe.
create or replace function public.join_group(p_gid text, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'groups' and id = p_gid;
  if g is null or coalesce(g->>'invite', '') = '' or g->>'invite' <> p_code then
    raise exception 'invalid_invite';
  end if;
  update public.docs
    set data = jsonb_set(data, array['members', auth.uid()::text], to_jsonb((extract(epoch from now()) * 1000)::bigint), true),
        updated_at = now()
    where coll = 'groups' and id = p_gid;
  return g->>'name';
end
$$;

revoke execute on function public.join_group(text, text) from anon;
