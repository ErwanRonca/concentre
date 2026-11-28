-- Concentré : bulle de support (après supabase-retours.sql).
-- À coller une seule fois dans Supabase → SQL Editor → New query → Run.
-- Les retours deviennent des tickets privés : chacun ne voit que les siens, l'administrateur les voit tous
-- (et peut toujours changer le statut, répondre et supprimer, comme avant).

drop policy if exists "fb lecture" on public.feedback;
create policy "fb lecture" on public.feedback for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
