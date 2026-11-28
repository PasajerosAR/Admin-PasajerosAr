// Edge Function de Supabase (Deno). Pone una contraseña nueva a otro usuario.
//  - El administrador de empresa lo hace con los usuarios de su empresa.
//  - El administrador general lo hace con los administradores de empresa.
// NO PROBADA en este entorno (requiere un proyecto de Supabase real): ver README.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const asCaller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: who } = await asCaller.auth.getUser();
    if (!who.user) return json({ error: 'No autenticado.' }, 401);

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: caller } = await admin.from('profiles').select('company_id, role, active').eq('id', who.user.id).maybeSingle();
    if (!caller || !caller.active) return json({ error: 'No autorizado.' }, 403);

    const b = await req.json();
    const userId = String(b.user_id ?? '');
    const password = String(b.password ?? '');
    if (password.length < 8) return json({ error: 'La contraseña debe tener al menos 8 caracteres.' }, 400);
    if (userId === who.user.id) return json({ error: 'Tu propia contraseña se cambia desde tu perfil.' }, 400);

    const { data: target } = await admin.from('profiles').select('company_id, role').eq('id', userId).maybeSingle();
    if (!target) return json({ error: 'No se encontró el usuario.' }, 404);
    const allowed = (caller.role === 'company_admin' && target.company_id === caller.company_id && ['driver', 'seller', 'company_admin'].includes(target.role))
      || (caller.role === 'platform_admin' && target.role === 'company_admin');
    if (!allowed) return json({ error: 'No podés cambiar la contraseña de ese usuario.' }, 403);

    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
