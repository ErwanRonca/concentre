-- Concentré : chef de salle (après supabase-correctif-groupe.sql).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
-- Le créateur d'une salle (data.by) en est le chef : lui seul peut retirer quelqu'un avant le lancement.
-- Dans data.members : > 0 = présent, 0 = parti, -1 = retiré par le chef (ne peut plus revenir dans cette salle ;
-- en cas d'erreur, le chef crée une nouvelle salle).

-- Retirer quelqu'un de sa salle (chef uniquement, avant le lancement, pas soi-même).
create or replace function public.kick_member(p_gid text, p_uid text)
returns void language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'groups' and id = p_gid;
  if g is null or g->>'by' is distinct from auth.uid()::text then raise exception 'not_chef'; end if;
  if g->>'startAt' is not null then raise exception 'already_started'; end if;
  if p_uid = auth.uid()::text then raise exception 'cannot_kick_self'; end if;
  update public.docs
    set data = jsonb_set(data, array['members', p_uid], '-1'::jsonb, true), updated_at = now()
    where coll = 'groups' and id = p_gid;
end
$$;

revoke execute on function public.kick_member(text, text) from anon;

-- Rejoindre : refusé aussi si le chef nous a retiré.
create or replace function public.join_group(p_gid text, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select data into g from public.docs where coll = 'groups' and id = p_gid;
  if g is null or coalesce(g->>'invite', '') = '' or g->>'invite' <> p_code or g->>'closed' is not null then
    raise exception 'invalid_invite';
  end if;
  if coalesce((g->'members'->>(auth.uid()::text))::numeric, 0) < 0 then
    raise exception 'kicked';
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

-- Quitter : seulement si on est présent (un membre retiré reste à -1).
create or replace function public.leave_group(p_gid text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.docs
    set data = jsonb_set(data, array['members', auth.uid()::text], '0'::jsonb, true), updated_at = now()
    where coll = 'groups' and id = p_gid
      and coalesce((data->'members'->>(auth.uid()::text))::numeric, 0) > 0;
end
$$;

revoke execute on function public.leave_group(text) from anon;
