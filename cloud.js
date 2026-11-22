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
        }
      };
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

/* ---------- écran de connexion ---------- */
const AUTH_ERRORS = {
  "Invalid login credentials": "E-mail ou mot de passe incorrect.",
  "User already registered": "Un compte existe déjà avec cet e-mail : connecte-toi.",
  "Email not confirmed": "Ton e-mail n'est pas encore confirmé.",
  "Password should be at least 6 characters.": "Le mot de passe doit faire au moins 6 caractères."
};
const authMsg = e => AUTH_ERRORS[e && e.message] || (e && e.message) || "Erreur inconnue.";

function loginScreen(sb) {
  return new Promise(resolve => {
    let mode = "signup";
    const wrap = document.createElement("div");
    wrap.className = "login";
    wrap.innerHTML = `
      <form class="login-card" novalidate>
        <div class="login-mark" aria-hidden="true">🍅</div>
        <h1>Concentré</h1>
        <p class="login-intro">Le pomodoro en équipe : reste concentré·e, fais pousser ta plante et récolte des tomates avec tes amis.</p>
        <div class="login-tabs" role="tablist">
          <button type="button" role="tab" data-mode="signup">Créer un compte</button>
          <button type="button" role="tab" data-mode="signin">Se connecter</button>
        </div>
        <label class="login-field" data-only="signup">Pseudo<input name="pseudo" autocomplete="nickname" maxlength="24" placeholder="Comment le club t'appelle"></label>
        <label class="login-field">E-mail<input name="email" type="email" autocomplete="email" required></label>
        <label class="login-field">Mot de passe<input name="password" type="password" minlength="6" required></label>
        <button class="login-main" type="submit">Créer mon compte</button>
        <button class="login-local" type="button">Essayer sans compte</button>
        <p class="login-err" role="alert"></p>
      </form>`;
    document.body.append(wrap);
    const form = wrap.querySelector("form");
    const errBox = wrap.querySelector(".login-err");
    const main = wrap.querySelector(".login-main");
    const setMode = m => {
      mode = m; errBox.textContent = "";
      wrap.querySelectorAll(".login-tabs button").forEach(b => b.setAttribute("aria-selected", String(b.dataset.mode === m)));
      wrap.querySelectorAll("[data-only]").forEach(x => { x.hidden = x.dataset.only !== m; });
      main.textContent = m === "signup" ? "Créer mon compte" : "Me connecter";
      form.password.autocomplete = m === "signup" ? "new-password" : "current-password";
    };
    wrap.querySelectorAll(".login-tabs button").forEach(b => b.addEventListener("click", () => setMode(b.dataset.mode)));
    setMode("signup");

    form.addEventListener("submit", async ev => {
      ev.preventDefault();
      errBox.textContent = "";
      const email = form.email.value.trim(), password = form.password.value, pseudo = form.pseudo.value.trim();
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
    wrap.querySelector(".login-local").addEventListener("click", () => {
      try { localStorage.setItem(LOCAL_KEY, "1"); } catch (e) {}
      wrap.remove(); resolve(null);
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
  const sb = createClient(supabaseConfig.url, supabaseConfig.anonKey, { auth: { persistSession: true, autoRefreshToken: true } });
  const { data } = await sb.auth.getSession();
  let u = data.session ? data.session.user : null;
  let skip = false; try { skip = localStorage.getItem(LOCAL_KEY) === "1"; } catch (e) {}
  if (!u && !skip) u = await loginScreen(sb);
  if (!u) {
    accountButton("Se connecter", () => { try { localStorage.removeItem(LOCAL_KEY); } catch (e) {} location.reload(); });
    return { db: null, user: null };
  }
  try { localStorage.removeItem(LOCAL_KEY); } catch (e) {}
  accountButton("Déconnexion (" + displayName(u) + ")", async () => { await sb.auth.signOut(); try { localStorage.setItem(LOCAL_KEY, "1"); } catch (e) {} location.reload(); });
  return { db: makeDb(sb), user: makeUser(sb, u) };
}

start().then(api => window.__pousseCloudReady(api), e => { console.error(e); window.__pousseCloudReady({ db: null, user: null }); });
