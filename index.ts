// Supabase Edge Function: manage-users
// Lets a signed-in MANAGER (profiles.role = 'editor') list, add, re-role, reset the password of, and delete users.
//
// WHY THIS EXISTS: creating and deleting logins needs the service_role key, which must never be in the website.
// Supabase injects that key into Edge Functions automatically, so it stays on Supabase's servers.
//
// SECURITY: every request is checked server-side: valid login, and that person is a manager. The website's
// buttons are a convenience only. Deploy with "Verify JWT" OFF (this function verifies the login itself).

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ROLES = ['submitter', 'viewer', 'editor'];

class Refusal extends Error { status: number; constructor(m: string, s = 400) { super(m); this.status = s; } }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

    // 1. who is calling?
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) throw new Refusal('Not signed in', 401);
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    if (whoErr || !who?.user) throw new Refusal('Not signed in', 401);
    const me = who.user;

    // 2. are they a manager?
    const { data: myProfile } = await admin.from('profiles').select('role').eq('id', me.id).maybeSingle();
    if (!myProfile || myProfile.role !== 'editor') throw new Refusal('Managers only', 403);

    const body = await req.json().catch(() => ({}));
    const action = String(body.action || '');

    const managerCount = async () => {
      const { count, error } = await admin.from('profiles').select('id', { count: 'exact', head: true }).eq('role', 'editor');
      if (error) throw error;
      return count ?? 0;
    };
    const validPassword = (p: unknown) => {
      if (typeof p !== 'string' || p.length < 6) throw new Refusal('Password must be at least 6 characters');
      if (p.length > 72) throw new Refusal('Password is too long (72 characters max)');
      return p;
    };
    const validId = (v: unknown) => {
      if (typeof v !== 'string' || !/^[0-9a-f-]{36}$/i.test(v)) throw new Refusal('Bad user id');
      return v;
    };

    if (action === 'list') {
      const users: any[] = [];
      for (let page = 1; page <= 50; page++) {
        const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
        if (error) throw error;
        users.push(...data.users);
        if (data.users.length < 1000) break;
      }
      const { data: profiles, error } = await admin.from('profiles').select('id, display_name, role');
      if (error) throw error;
      const byId = new Map((profiles || []).map((p) => [p.id, p]));
      const out = users.map((u) => {
        const p = byId.get(u.id);
        return { id: u.id, email: u.email, display_name: p?.display_name ?? null, role: p?.role ?? null, last_sign_in_at: u.last_sign_in_at ?? null };
      }).sort((a, b) => String(a.display_name ?? a.email).localeCompare(String(b.display_name ?? b.email)));
      return json({ users: out, me: me.id });
    }

    if (action === 'create') {
      const email = String(body.email || '').trim().toLowerCase();
      const name = String(body.display_name || '').trim();
      const role = String(body.role || 'viewer');
      if (!EMAIL_RE.test(email) || email.length > 254) throw new Refusal('Username is not valid');
      if (name.length < 1 || name.length > 100) throw new Refusal('Name is required (100 characters max)');
      if (!ROLES.includes(role)) throw new Refusal('Bad role');
      const password = validPassword(body.password);
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (error || !data?.user) {
        if (error && (/already|exists|registered/i.test(error.message) || (error as any).code === 'email_exists')) throw new Refusal('That username is already taken', 409);
        throw error || new Error('Could not create the user');
      }
      const { error: pErr } = await admin.from('profiles').insert({ id: data.user.id, display_name: name, role });
      if (pErr) {                                   // never leave a login that has no profile half-created
        await admin.auth.admin.deleteUser(data.user.id);
        throw pErr;
      }
      return json({ ok: true, id: data.user.id });
    }

    if (action === 'set_role') {
      const id = validId(body.id);
      const role = String(body.role || '');
      if (!ROLES.includes(role)) throw new Refusal('Bad role');
      if (id === me.id) throw new Refusal('You cannot change your own role');
      const { data: target } = await admin.from('profiles').select('role, display_name').eq('id', id).maybeSingle();
      if (target?.role === 'editor' && role !== 'editor' && (await managerCount()) <= 1) throw new Refusal('There must always be at least one Manager');
      if (target) {
        const { error } = await admin.from('profiles').update({ role }).eq('id', id);
        if (error) throw error;
      } else {                                      // a login that never got a profile: grant access now
        const { data: u, error: uErr } = await admin.auth.admin.getUserById(id);
        if (uErr || !u?.user) throw new Refusal('User not found', 404);
        const nm = String(u.user.email || 'User').split('@')[0].slice(0, 100) || 'User';
        const { error } = await admin.from('profiles').insert({ id, display_name: nm, role });
        if (error) throw error;
      }
      return json({ ok: true });
    }

    if (action === 'reset_password') {
      const id = validId(body.id);
      const password = validPassword(body.password);
      const { error } = await admin.auth.admin.updateUserById(id, { password });
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === 'delete') {
      const id = validId(body.id);
      if (id === me.id) throw new Refusal('You cannot delete your own account');
      const { data: target } = await admin.from('profiles').select('role').eq('id', id).maybeSingle();
      if (target?.role === 'editor' && (await managerCount()) <= 1) throw new Refusal('There must always be at least one Manager');
      const { error } = await admin.auth.admin.deleteUser(id);   // profile is removed with it; their lines stay
      if (error) throw error;
      return json({ ok: true });
    }

    throw new Refusal('Unknown action');
  } catch (e) {
    if (e instanceof Refusal) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: 'Something went wrong on the server: ' + ((e as Error)?.message || 'unknown') }, 500);
  }
});