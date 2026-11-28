// Edge Function de Supabase (Deno). Ingreso con empresa + usuario + contraseña.
// Busca el correo de ese usuario sin mostrárselo a nadie, inicia sesión y devuelve la sesión.
// Cualquier falla responde lo mismo ("usuario o contraseña incorrectos") para no revelar qué usuarios existen.
// NO PROBADA en este entorno (requiere un proyecto de Supabase real): ver README.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const BAD = { error: 'Empresa, usuario o contraseña incorrectos.' };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const b = await req.json();
    const company = String(b.company ?? '').trim().toLowerCase();
    const username = String(b.username ?? '').trim().toLowerCase();
    const password = String(b.password ?? '');
    if (!company || !username || !password || username.length > 30 || company.length > 80) return json(BAD, 401);

    const url = Deno.env.get('SUPABASE_URL')!;
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: co } = await admin.from('companies').select('id').ilike('login_code', company.replace(/[\\%_]/g, (c) => `\\${c}`)).maybeSingle();
    if (!co) return json(BAD, 401);
    const { data: prof } = await admin.from('profiles').select('id, active')
      .eq('company_id', co.id).ilike('username', username.replace(/[\\%_]/g, (c) => `\\${c}`)).maybeSingle();
    if (!prof || !prof.active) return json(BAD, 401);
    const { data: u } = await admin.auth.admin.getUserById(prof.id);
    const email = u.user?.email;
    if (!email) return json(BAD, 401);

    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { auth: { persistSession: false } });
    const { data, error } = await anon.auth.signInWithPassword({ email, password });
    if (error || !data.session) return json(BAD, 401);
    return json({ access_token: data.session.access_token, refresh_token: data.session.refresh_token });
  } catch (_e) {
    return json(BAD, 401);
  }
});
