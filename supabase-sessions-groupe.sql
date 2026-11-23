-- Concentré : sessions de groupe éphémères (après supabase-groupes-prives.sql).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
-- Une « salle » (coll = 'groups') vit le temps d'un pomodoro : on y entre par son lien tant
-- qu'elle n'est pas lancée, puis elle est supprimée à la fin.

-- Rejoindre une salle avec son lien : refusé si le lien est faux, si la salle est fermée ou déjà lancée.
create or replace function public.join_group(p_gid text, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'groups' and id = p_gid;
  if g is null or coalesce(g->>'invite', '') = '' or g->>'invite' <> p_code or g->>'closed' is not null then
    raise exception 'invalid_invite';
  end if;
  if g->>'startAt' is not null then
    raise exception 'already_started';
  end if;
  update public.docs
    set data = jsonb_set(data, array['members', auth.uid()::text], to_jsonb((extract(epoch from now()) * 1000)::bigint), true),
        updated_at = now()
    where coll = 'groups' and id = p_gid;
  return g->>'name';
end
$$;

revoke execute on function public.join_group(text, text) from anon;

-- Suppression : un membre peut supprimer sa salle (à la fin de la session ou en la fermant).
drop policy if exists "suppression salle" on public.docs;
create policy "suppression salle" on public.docs
  for delete to authenticated using (coll = 'groups' and public.is_group_member(id));

-- Ménage : les anciens groupes permanents et les anciennes sessions de groupe disparaissent.
delete from public.docs where coll = 'gsessions' or (coll = 'groups' and data->>'min' is null);
