/* Concentré — couche cloud Supabase.
   Expose la même API que celle utilisée par l'app (db.collection().onSnapshot, db.doc().set/update,
   user.me/can/profiles), pour que index.html n'ait presque pas à changer.
   Toutes les collections vivent dans une table « docs » (coll, id, data jsonb) : voir supabase-schema.sql. */
import { supabaseConfig } from "./supabase-config.js";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm";

const configured = supabaseConfig && /^https:\/\//.test(supabaseConfig.url || "") && supabaseConfig.anonKey && !String(supabaseConfig.anonKey).startsWith("COLLE");
const LOCAL_KEY = "pousse.skipLogin";

function mapErr(e) {
  const err = new Error((e && e.message) || "erreur");
  const c = e && (e.code || e.status);
  err.code = c === "42501" ? "permission_denied" : c === 413 || c === "54000" ? "quota_exceeded" : String(c || "unknown");
  return err;
}

/* ---------- base de données ---------- */
function makeDb(sb) {
  const snap = (map, filter) => ({
    docs: [...map.values()].filter(r => !filter || filter(r.data)).map(r => ({ id: r.id, exists: true, data: () => r.data })),
    metadata: { fromCache: false }
  });

  /* Abonnement : on écoute le temps réel d'abord, puis on charge l'état initial, pour ne rien rater entre les deux. */
  function subscribe(coll, cb, onErr, opts = {}) {
    const map = new Map();
    let loaded = false;
    const ts = r => Date.parse(r.updated_at) || 0;
    const put = r => { const cur = map.get(r.id); if (!cur || ts(r) >= ts(cur)) map.set(r.id, { id: r.id, data: r.data, updated_at: r.updated_at }); };
    const emit = () => { if (loaded) cb(snap(map, opts.filter)); };
    const channel = sb.channel("docs-" + coll + "-" + Math.random().toString(36).slice(2))
      .on("postgres_changes", { event: "*", schema: "public", table: "docs", filter: "coll=eq." + coll }, p => {
        if (p.eventType === "DELETE") { if (p.old && p.old.id) map.delete(p.old.id); }
        else if (p.new) put(p.new);
        emit();
      })
      .subscribe();
    (async () => {
      let q = sb.from("docs").select("id,data,updated_at").eq("coll", coll);
      if (opts.gtEndAt != null) q = q.gt("end_at", opts.gtEndAt);
      const { data, error } = await q;
      if (error) { onErr && onErr(mapErr(error)); return; }
      data.forEach(put);
      loaded = true;
      emit();
    })();
    return () => sb.removeChannel(channel);
  }

  return {
    collection(name) {
      return {
        onSnapshot: (cb, onErr) => subscribe(name, cb, onErr),
        where(field, op, value) {
          if (field !== "endAt" || op !== ">") throw new Error("Filtre non pris en charge : " + field + " " + op);
          return { onSnapshot: (cb, onErr) => subscribe(name, cb, onErr, { gtEndAt: value, filter: d => (d.endAt || 0) > value }) };
        }
      };
    },
    doc(path) {
      const [coll, id] = path.split("/");
      return {
        set: async (data) => {
          const { error } = await sb.from("docs").upsert({ coll, id, data, updated_at: new Date().toISOString() }, { onConflict: "coll,id" });
          if (error) throw mapErr(error);
        },
        /* update fusionne les objets imbriqués (rejoindre/quitter un groupe ou une session). */
        update: async (data) => {
          const { error } = await sb.rpc("merge_doc", { p_coll: coll, p_id: id, p_patch: data });
          if (error) throw mapErr(error);
        },
        /* suppression (une salle de groupe terminée) */
        delete: async () => {
          const { error } = await sb.from("docs").delete().eq("coll", coll).eq("id", id);
          if (error) throw mapErr(error);
        }
      };
    },
    /* Appel d'une fonction de la base (ex. join_group pour rejoindre un groupe privé par lien). */
    async rpc(fn, args) {
      const { data, error } = await sb.rpc(fn, args);
      if (error) throw mapErr(error);
      return data;
    }
  };
}

/* ---------- utilisateur ---------- */
function displayName(u) {
  const m = u.user_metadata || {};
  return m.pseudo || m.full_name || m.name || (u.email ? u.email.split("@")[0] : "Moi");
}

function makeUser(sb, u) {
  const me = { id: u.id, name: displayName(u), avatarUrl: (u.user_metadata || {}).avatar_url || "" };
  sb.from("docs").upsert({ coll: "profiles", id: u.id, data: { name: me.name, avatarUrl: me.avatarUrl }, updated_at: new Date().toISOString() }, { onConflict: "coll,id" }).then(() => {});
  return {
    me: async () => me,
    id: async () => me.id,
    can: async () => true,
    profiles: async (ids) => {
      const out = {};
      if (!ids.length) return out;
      const { data } = await sb.from("docs").select("id,data").eq("coll", "profiles").in("id", ids);
      (data || []).forEach(r => { out[r.id] = r.data; });
      return out;
    }
  };
}

/* ---------- retours (bugs, idées, remarques) : tables feedback / feedback_votes, voir supabase-retours.sql ---------- */
function makeFeedback(sb, me) {
  const check = r => { if (r.error) throw mapErr(r.error); return r.data; };
  return {
    async list() {
      const [f, v] = await Promise.all([
        sb.from("feedback").select("*").order("created_at", { ascending: false }).limit(500),
        sb.from("feedback_votes").select("feedback_id,user_id")
      ]);
      const rows = check(f), votes = check(v);
      const by = {};
      votes.forEach(x => { (by[x.feedback_id] = by[x.feedback_id] || []).push(x.user_id); });
      return rows.map(r => ({ ...r, votes: by[r.id] || [], ts: Date.parse(r.created_at) || 0 }));
    },
    async add({ kind, message, context }) {
      check(await sb.from("feedback").insert({ kind, message, context, pseudo: me.name }));
    },
    async vote(id, on) {
      check(on
        ? await sb.from("feedback_votes").insert({ feedback_id: id })
        : await sb.from("feedback_votes").delete().eq("feedback_id", id).eq("user_id", me.id));
    },
    async setStatus(id, patch) {
      check(await sb.from("feedback").update({ ...patch, updated_at: new Date().toISOString() }).eq("id", id));
    },
    async remove(id) {
      check(await sb.from("feedback").delete().eq("id", id));
    },
    async isAdmin() {
      const { data, error } = await sb.rpc("is_admin");
      return !error && data === true;
    },
    onChange(cb) {
      let t;
      const ping = () => { clearTimeout(t); t = setTimeout(cb, 300); };
      sb.channel("feedback-" + Math.random().toString(36).slice(2))
        .on("postgres_changes", { event: "*", schema: "public", table: "feedback" }, ping)
        .on("postgres_changes", { event: "*", schema: "public", table: "feedback_votes" }, ping)
        .subscribe();
    }
  };
}

/* ---------- écran de connexion (compte obligatoire) ---------- */
const AUTH_ERRORS = {
  "Invalid login credentials": "E-mail ou mot de passe incorrect.",
  "User already registered": "Un compte existe déjà avec cet e-mail : connecte-toi.",
  "Email not confirmed": "Ton e-mail n'est pas encore confirmé.",
  "Password should be at least 6 characters.": "Le mot de passe doit faire au moins 6 caractères.",
  "New password should be different from the old password.": "Choisis un mot de passe différent de l'ancien.",
  "Unable to validate email address: invalid format": "Cette adresse e-mail n'est pas valide."
};
const hasInvite = () => { try { return !!localStorage.getItem("pousse.invite"); } catch (e) { return false; } };
const authMsg = e => {
  const m = (e && e.message) || "";
  if (AUTH_ERRORS[m]) return AUTH_ERRORS[m];
  if (/rate limit|too many|security purposes/i.test(m)) return "Trop de demandes d'affilée : réessaie dans quelques minutes.";
  return m || "Erreur inconnue.";
};
const appUrl = () => location.origin + location.pathname;

/* mode : "signup" (créer un compte), "signin" (se connecter), "forgot" (recevoir un lien pour changer de mot de passe). */
function loginScreen(sb, notice) {
  return new Promise(resolve => {
    let mode = "signup";
    const wrap = document.createElement("div");
    wrap.className = "login";
    wrap.innerHTML = `
      <form class="login-card" novalidate>
        <div class="login-mark" aria-hidden="true">🍅</div>
        <h1>Concentré</h1>
        <p class="login-intro">Le pomodoro en équipe : reste concentré·e, fais pousser ta plante et récolte des tomates avec tes amis.</p>
        ${hasInvite() ? `<p class="login-invite">Un ami t'invite à une session de groupe : crée ton compte (ou connecte-toi) pour le rejoindre.</p>` : ""}
        <div class="login-tabs" role="tablist" data-hide="forgot">
          <button type="button" role="tab" data-mode="signup">Créer un compte</button>
          <button type="button" role="tab" data-mode="signin">Se connecter</button>
        </div>
        <p class="login-forgot-intro" data-only="forgot">Entre l'e-mail de ton compte : tu vas recevoir un lien pour choisir un nouveau mot de passe.</p>
        <label class="login-field" data-only="signup">Pseudo<input name="pseudo" autocomplete="nickname" maxlength="24" placeholder="Comment les autres t'appellent"></label>
        <label class="login-field">E-mail<input name="email" type="email" autocomplete="email" required></label>
        <label class="login-field" data-hide="forgot">Mot de passe<input name="password" type="password" minlength="6"></label>
        <button class="login-link" type="button" data-only="signin" data-go="forgot">Mot de passe oublié ?</button>
        <button class="login-main" type="submit">Créer mon compte</button>
        <button class="login-link" type="button" data-only="forgot" data-go="signin">Retour à la connexion</button>
        <p class="login-err" role="alert"></p>
        <p class="login-ok" role="status"></p>
      </form>`;
    document.body.append(wrap);
    const form = wrap.querySelector("form");
    const errBox = wrap.querySelector(".login-err"), okBox = wrap.querySelector(".login-ok");
    const main = wrap.querySelector(".login-main");
    const setMode = m => {
      mode = m; errBox.textContent = ""; okBox.textContent = "";
      wrap.querySelectorAll(".login-tabs button").forEach(b => b.setAttribute("aria-selected", String(b.dataset.mode === m)));
      wrap.querySelectorAll("[data-only]").forEach(x => { x.hidden = x.dataset.only !== m; });
      wrap.querySelectorAll("[data-hide]").forEach(x => { x.hidden = x.dataset.hide === m; });
      main.textContent = m === "signup" ? "Créer mon compte" : m === "signin" ? "Me connecter" : "Envoyer le lien";
      form.password.autocomplete = m === "signup" ? "new-password" : "current-password";
    };
    wrap.querySelectorAll(".login-tabs button").forEach(b => b.addEventListener("click", () => setMode(b.dataset.mode)));
    wrap.querySelectorAll("[data-go]").forEach(b => b.addEventListener("click", () => setMode(b.dataset.go)));
    setMode(notice ? "forgot" : "signup");
    if (notice) errBox.textContent = notice;

    form.addEventListener("submit", async ev => {
      ev.preventDefault();
      errBox.textContent = ""; okBox.textContent = "";
      const email = form.email.value.trim(), password = form.password.value, pseudo = form.pseudo.value.trim();
      if (mode === "forgot") {
        if (!email) { errBox.textContent = "Entre l'e-mail de ton compte."; form.email.focus(); return; }
        main.disabled = true;
        try {
          const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: appUrl() });
          if (error) throw error;
          okBox.textContent = "C'est envoyé ! Si un compte existe avec cet e-mail, tu vas recevoir un lien (pense à regarder dans les spams). Ouvre-le sur cet appareil pour choisir ton nouveau mot de passe.";
        } catch (e) { errBox.textContent = authMsg(e); }
        finally { main.disabled = false; }
        return;
      }
      if (mode === "signup" && !pseudo) { errBox.textContent = "Choisis un pseudo."; form.pseudo.focus(); return; }
      if (!email || password.length < 6) { errBox.textContent = "Entre ton e-mail et un mot de passe d'au moins 6 caractères."; return; }
      main.disabled = true;
      try {
        const res = mode === "signup"
          ? await sb.auth.signUp({ email, password, options: { data: { pseudo } } })
          : await sb.auth.signInWithPassword({ email, password });
        if (res.error) throw res.error;
        if (!res.data.session) { errBox.textContent = "Compte créé, mais la confirmation par e-mail est activée dans Supabase : désactive-la (voir le guide)."; return; }
        wrap.remove(); resolve(res.data.session.user);
      } catch (e) { errBox.textContent = authMsg(e); }
      finally { main.disabled = false; }
    });
  });
}

/* Après un clic sur le lien « mot de passe oublié » : choisir le nouveau mot de passe. */
function newPasswordScreen(sb) {
  return new Promise(resolve => {
    const wrap = document.createElement("div");
    wrap.className = "login";
    wrap.innerHTML = `
      <form class="login-card" novalidate>
        <div class="login-mark" aria-hidden="true">🔑</div>
        <h1>Nouveau mot de passe</h1>
        <p class="login-intro">Choisis ton nouveau mot de passe (6 caractères minimum).</p>
        <label class="login-field">Nouveau mot de passe<input name="p1" type="password" autocomplete="new-password" minlength="6" required></label>
        <label class="login-field">Confirme-le<input name="p2" type="password" autocomplete="new-password" minlength="6" required></label>
        <button class="login-main" type="submit">Enregistrer</button>
        <p class="login-err" role="alert"></p>
      </form>`;
    document.body.append(wrap);
    const form = wrap.querySelector("form"), errBox = wrap.querySelector(".login-err"), main = wrap.querySelector(".login-main");
    form.p1.focus();
    form.addEventListener("submit", async ev => {
      ev.preventDefault(); errBox.textContent = "";
      const p1 = form.p1.value, p2 = form.p2.value;
      if (p1.length < 6) { errBox.textContent = "Le mot de passe doit faire au moins 6 caractères."; return; }
      if (p1 !== p2) { errBox.textContent = "Les deux mots de passe ne sont pas identiques."; return; }
      main.disabled = true;
      try {
        const { error } = await sb.auth.updateUser({ password: p1 });
        if (error) throw error;
        wrap.remove(); resolve(true);
      } catch (e) { errBox.textContent = authMsg(e); }
      finally { main.disabled = false; }
    });
  });
}

function accountButton(label, onClick) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "account-btn"; b.textContent = label;
  b.addEventListener("click", onClick);
  document.body.append(b);
}

async function start() {
  if (!configured) { console.warn("Concentré : supabase-config.js n'est pas rempli, mode local."); return { db: null, user: null }; }
  /* Le lien reçu par e-mail revient avec #access_token=…&type=recovery (ou #error=… s'il a expiré) : on le lit avant que Supabase ne l'efface. */
  const hash = location.hash || "";
  const recovery = /type=recovery/.test(hash);
  const linkError = /error_code=|error=/.test(hash) && !/access_token=/.test(hash);
  try { localStorage.removeItem(LOCAL_KEY); } catch (e) {}
  const sb = createClient(supabaseConfig.url, supabaseConfig.anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  const { data } = await sb.auth.getSession();
  let u = data.session ? data.session.user : null;
  if (recovery || linkError) history.replaceState(null, "", location.pathname + location.search + "#focus");
  if (recovery && u) { await newPasswordScreen(sb); window.__pousseToast = "Mot de passe modifié."; }
  while (!u) u = await loginScreen(sb, linkError ? "Ce lien a expiré ou a déjà servi. Redemande un lien ci-dessous." : "");
  accountButton("Déconnexion (" + displayName(u) + ")", async () => { await sb.auth.signOut(); location.reload(); });
  const user = makeUser(sb, u);
  return { db: makeDb(sb), user, feedback: makeFeedback(sb, { id: u.id, name: displayName(u) }) };
}

start().then(api => window.__pousseCloudReady(api), e => { console.error(e); window.__pousseCloudReady({ db: null, user: null }); });
