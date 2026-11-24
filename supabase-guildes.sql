-- Concentré : guildes (après supabase-chef-de-salle.sql).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
--
-- Une guilde (coll = 'guilds') est un groupe permanent : un nom, un chef (data.by), des membres
-- (data.members : uid → date d'entrée > 0 ; 0 = parti ; -1 = exclu par le chef), un lien d'invitation (data.invite).
-- 20 membres maximum par guilde, 3 guildes maximum par personne.
-- Une session de guilde est une salle (coll = 'groups') avec data.guild = id de la guilde :
-- tous les membres de la guilde la voient et peuvent la rejoindre sans lien.

-- Vrai si la personne connectée est membre (valeur > 0) de la guilde p_gid.
create or replace function public.is_guild_member(p_gid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.docs
    where coll = 'guilds' and id = p_gid
      and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0
  )
$$;

-- Lecture : une guilde par ses membres ; une salle par ses membres ou par les membres de sa guilde.
drop policy if exists "lecture membres" on public.docs;
create policy "lecture membres" on public.docs
  for select to authenticated using (
    coll not in ('groups', 'gsessions', 'guilds')
    or (coll = 'groups' and (
          coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0
          or (data ? 'guild' and public.is_guild_member(data->>'guild'))))
    or (coll = 'guilds' and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0)
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Création : ses propres données ; une salle dont on est membre (et, pour une salle de guilde, membre de la guilde) ;
-- une guilde dont on est le chef et le seul membre.
drop policy if exists "creation" on public.docs;
create policy "creation" on public.docs
  for insert to authenticated with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or (coll = 'groups' and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0
        and (not (data ? 'guild') or public.is_guild_member(data->>'guild')))
    or (coll = 'guilds' and data->>'by' = auth.uid()::text
        and (select count(*) from jsonb_object_keys(coalesce(data->'members', '{}'::jsonb))) = 1
        and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0)
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Modification directe : ses données ; ses salles ; sa guilde seulement pour le chef (nom).
-- Rejoindre, quitter et exclure passent par les fonctions ci-dessous.
drop policy if exists "modification" on public.docs;
create policy "modification" on public.docs
  for update to authenticated
  using (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or (coll = 'groups' and public.is_group_member(id))
    or (coll = 'guilds' and data->>'by' = auth.uid()::text)
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  )
  with check (
    (coll in ('members', 'profiles', 'kudos') and id = auth.uid()::text)
    or coll = 'groups'
    or (coll = 'guilds' and data->>'by' = auth.uid()::text)
    or (coll = 'gsessions' and public.is_group_member(data->>'gid'))
  );

-- Suppression : une salle par ses membres ; une guilde par son chef.
drop policy if exists "suppression guilde" on public.docs;
create policy "suppression guilde" on public.docs
  for delete to authenticated using (coll = 'guilds' and data->>'by' = auth.uid()::text);

-- Demander à rejoindre une guilde (avec son lien, ou sans lien si elle est ouverte) : la demande (data.requests : uid → date) attend
-- qu'un membre de la guilde l'accepte ou la refuse. Renvoie {name, status: 'member' | 'requested'}.
drop function if exists public.join_guild(text, text);
create or replace function public.join_guild(p_gid text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; me text := auth.uid()::text; n int;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'guilds' and id = p_gid;
  -- Lien d'invitation valide, ou guilde ouverte (data.open) : n'importe qui peut demander à rejoindre.
  if g is null then raise exception 'invalid_invite'; end if;
  if not (coalesce(g->>'open', 'false') = 'true' or (coalesce(g->>'invite', '') <> '' and g->>'invite' = coalesce(p_code, ''))) then raise exception 'invalid_invite'; end if;
  if coalesce((g->'members'->>me)::numeric, 0) < 0 then raise exception 'kicked'; end if;
  if coalesce((g->'members'->>me)::numeric, 0) > 0 then return jsonb_build_object('name', g->>'name', 'status', 'member'); end if;
  select count(*) into n from jsonb_each_text(g->'members') m where m.value::numeric > 0;
  if n >= 20 then raise exception 'guild_full'; end if;
  if not (coalesce(g->'requests', '{}'::jsonb) ? me) then
    if (select count(*) from jsonb_object_keys(coalesce(g->'requests', '{}'::jsonb))) >= 30 then raise exception 'too_many_requests'; end if;
    update public.docs
      set data = jsonb_set(data, '{requests}', coalesce(data->'requests', '{}'::jsonb)
                   || jsonb_build_object(me, (extract(epoch from now()) * 1000)::bigint), true),
          updated_at = now()
      where coll = 'guilds' and id = p_gid;
  end if;
  return jsonb_build_object('name', g->>'name', 'status', 'requested');
end
$$;

-- Accepter ou refuser une demande (n'importe quel membre de la guilde).
create or replace function public.answer_guild_request(p_gid text, p_uid text, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare g jsonb; n int; theirs int;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'guilds' and id = p_gid;
  if g is null or coalesce((g->'members'->>(auth.uid()::text))::numeric, 0) <= 0 then raise exception 'not_member'; end if;
  if not (coalesce(g->'requests', '{}'::jsonb) ? p_uid) then return; end if;
  g := jsonb_set(g, '{requests}', (g->'requests') - p_uid, true);
  if p_accept then
    select count(*) into n from jsonb_each_text(g->'members') m where m.value::numeric > 0;
    if n >= 20 then raise exception 'guild_full'; end if;
    select count(*) into theirs from public.docs
      where coll = 'guilds' and coalesce((data->'members'->>p_uid)::numeric, 0) > 0;
    if theirs >= 3 then raise exception 'too_many_guilds'; end if;
    g := jsonb_set(g, array['members', p_uid], to_jsonb((extract(epoch from now()) * 1000)::bigint), true);
  end if;
  update public.docs set data = g, updated_at = now() where coll = 'guilds' and id = p_gid;
end
$$;

-- Annuler sa propre demande.
create or replace function public.cancel_guild_request(p_gid text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.docs
    set data = jsonb_set(data, '{requests}', coalesce(data->'requests', '{}'::jsonb) - (auth.uid()::text), true), updated_at = now()
    where coll = 'guilds' and id = p_gid and coalesce(data->'requests', '{}'::jsonb) ? (auth.uid()::text);
end
$$;

revoke execute on function public.answer_guild_request(text, text, boolean) from anon;
revoke execute on function public.cancel_guild_request(text) from anon;

-- Quitter une guilde. Si le chef part, le membre le plus ancien devient chef ; s'il ne reste personne, la guilde est supprimée.
create or replace function public.leave_guild(p_gid text)
returns void language plpgsql security definer set search_path = public as $$
declare g jsonb; me text := auth.uid()::text; heir text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'guilds' and id = p_gid;
  if g is null or coalesce((g->'members'->>me)::numeric, 0) <= 0 then return; end if;
  g := jsonb_set(g, array['members', me], '0'::jsonb, true);
  if g->>'by' = me then
    select m.key into heir from jsonb_each_text(g->'members') m
      where m.value::numeric > 0 order by m.value::numeric limit 1;
    if heir is null then
      delete from public.docs where coll = 'guilds' and id = p_gid;
      return;
    end if;
    g := jsonb_set(g, array['by'], to_jsonb(heir), true);
  end if;
  update public.docs set data = g, updated_at = now() where coll = 'guilds' and id = p_gid;
end
$$;

-- Exclure un membre (chef uniquement) : il ne peut plus revenir avec le lien.
create or replace function public.kick_guild(p_gid text, p_uid text)
returns void language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'guilds' and id = p_gid;
  if g is null or g->>'by' is distinct from auth.uid()::text then raise exception 'not_chef'; end if;
  if p_uid = auth.uid()::text then raise exception 'cannot_kick_self'; end if;
  update public.docs
    set data = jsonb_set(data, array['members', p_uid], '-1'::jsonb, true), updated_at = now()
    where coll = 'guilds' and id = p_gid;
end
$$;

revoke execute on function public.join_guild(text, text) from anon;
revoke execute on function public.leave_guild(text) from anon;
revoke execute on function public.kick_guild(text, text) from anon;
revoke execute on function public.is_guild_member(text) from anon;

-- Vitrine publique des guildes (coll = 'guildpub') pour le classement des guildes dans Communauté :
-- seulement le nom et la liste des membres actifs, jamais le lien d'invitation.
-- Lisible par tous les connectés ; écrite uniquement par ce déclencheur (aucune règle n'autorise les utilisateurs à l'écrire).
create or replace function public.sync_guildpub()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from public.docs where coll = 'guildpub' and id = old.id;
    return old;
  end if;
  insert into public.docs (coll, id, data)
  values ('guildpub', new.id, jsonb_build_object(
    'name', new.data->>'name',
    'open', coalesce(new.data->>'open', 'false') = 'true',
    'members', coalesce((select jsonb_agg(m.key) from jsonb_each_text(coalesce(new.data->'members', '{}'::jsonb)) m
                         where m.value::numeric > 0), '[]'::jsonb)))
  on conflict (coll, id) do update set data = excluded.data, updated_at = now();
  return new;
end
$$;

drop trigger if exists guildpub_sync on public.docs;
create trigger guildpub_sync after insert or update on public.docs
  for each row when (new.coll = 'guilds') execute function public.sync_guildpub();
drop trigger if exists guildpub_sync_del on public.docs;
create trigger guildpub_sync_del after delete on public.docs
  for each row when (old.coll = 'guilds') execute function public.sync_guildpub();
