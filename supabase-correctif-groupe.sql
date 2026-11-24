-- Concentré : correctif des sessions de groupe (après supabase-sessions-groupe.sql).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
--
-- Problème : merge_doc faisait « insert … on conflict do update ». Postgres vérifie alors la règle de
-- création sur le patch seul ({startAt, endAt}), qui ne contient pas la liste des membres : refusé.
-- Résultat : impossible de lancer une salle, de changer ses durées ou d'en sortir.

-- 1. Mise à jour d'abord ; création seulement si le document n'existe pas encore.
create or replace function public.merge_doc(p_coll text, p_id text, p_patch jsonb)
returns void language plpgsql security invoker as $$
begin
  update public.docs set data = public.jsonb_deep_merge(data, p_patch), updated_at = now()
    where coll = p_coll and id = p_id;
  if not found then
    insert into public.docs (coll, id, data) values (p_coll, p_id, p_patch)
    on conflict (coll, id) do update
      set data = public.jsonb_deep_merge(public.docs.data, excluded.data), updated_at = now();
  end if;
end
$$;

-- 2. Quitter une salle : on se retire soi-même (après coup, la salle n'est plus visible pour soi,
--    ce que la règle de lecture refuserait dans une mise à jour normale).
create or replace function public.leave_group(p_gid text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.docs
    set data = jsonb_set(data, array['members', auth.uid()::text], '0'::jsonb, true), updated_at = now()
    where coll = 'groups' and id = p_gid and data->'members' ? auth.uid()::text;
end
$$;

revoke execute on function public.leave_group(text) from anon;
