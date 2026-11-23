# Concentré 🍅

Le pomodoro en équipe : reste concentré·e, fais pousser ta plante, récolte des tomates et grimpe au classement avec tes amis.

- **Focus** : sessions de 25, 45 ou 60 minutes. En mode strict, ta plante fane si tu quittes la page.
- **Tomates** : la monnaie du jeu. Tu gagnes 1 tomate toutes les 10 minutes de focus réussi, et en session de groupe (2 personnes ou plus) +1 tomate par tranche de 25 minutes.
- **Club** : qui est en focus en ce moment, défi de la semaine, classement, podium et fil d'activité avec kudos.
- **Groupes** : lance un pomodoro à plusieurs, avec un bonus d'XP et de tomates.
- **Profil** : niveaux, badges, trophées, objectif quotidien et catégories.
- **Retours** : les testeurs signalent des bugs, proposent des idées et appuient celles des autres avec un +1. L'admin change le statut et répond.

## Technique
- Site statique : `index.html`, `cloud.js`, `supabase-config.js`. Pas de build.
- Supabase (offre gratuite) : comptes (e-mail + mot de passe), base Postgres et temps réel. Le schéma et les règles de sécurité sont dans `supabase-schema.sql`, et la rubrique Retours dans `supabase-retours.sql`.
- Hébergement : Vercel (offre Hobby), déployé automatiquement à chaque modification du dépôt GitHub.

L'URL et la clé « anon » dans `supabase-config.js` sont publiques par nature. Les données sont protégées par les règles RLS de la base.
