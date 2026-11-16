// Edge Function: create-platform-staff
// El platform_admin crea colaboradores de plataforma con permisos configurables.
// NO PROBADA en este entorno (requiere un proyecto de Supabase real): ver README.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const VALID_SECTIONS = ['companies', 'routes', 'places', 'gps', 'reports', 'all'] as const;
type Section = typeof VALID_SECTIONS[number];

interface PermissionEntry { section: Section; can_edit: boolean }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const authHeader = req.headers.get('Authorization') ?? '';

    // 1. Caller debe ser platform_admin activo
    const asCaller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } }
    });
    const { data: who } = await asCaller.auth.getUser();
    if (!who.user) return json({ error: 'No autenticado.' }, 401);

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: caller } = await admin
      .from('profiles')
      .select('id, role, active')
      .eq('id', who.user.id)
      .maybeSingle();

    if (!caller || !caller.active || caller.role !== 'platform_admin') {
      return json({ error: 'Solo el administrador general puede crear colaboradores de plataforma.' }, 403);
    }

    // 2. Validar datos
    const b = await req.json();
    const full_name   = String(b.full_name ?? '').trim();
    const email       = String(b.email ?? '').trim().toLowerCase();
    const password    = String(b.password ?? '');
    const permissions: PermissionEntry[] = Array.isArray(b.permissions) ? b.permissions : [];

    if (!full_name) return json({ error: 'Falta el nombre.' }, 400);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'El correo no es válido.' }, 400);
    if (password.length < 8) return json({ error: 'La contraseña debe tener al menos 8 caracteres.' }, 400);

    for (const p of permissions) {
      if (!VALID_SECTIONS.includes(p.section)) {
        return json({ error: `Sección inválida: ${p.section}` }, 400);
      }
    }

    // 3. Crear usuario auth + perfil platform_staff
    const { data: created, error: e1 } = await admin.auth.admin.createUser({
      email, password, email_confirm: true
    });
    if (e1 || !created.user) {
      return json({ error: e1?.message ?? 'No se pudo crear el usuario.' }, 400);
    }

    const { error: e2 } = await admin.from('profiles').insert({
      id: created.user.id,
      company_id: null,
      role: 'platform_staff',
      full_name
    });
    if (e2) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: e2.message }, 400);
    }

    // 4. Insertar permisos configurados
    if (permissions.length > 0) {
      const rows = permissions.map((p) => ({
        profile_id: created.user.id,
        section: p.section,
        can_edit: Boolean(p.can_edit),
        granted_by: who.user.id
      }));
      const { error: e3 } = await admin.from('platform_permissions').insert(rows);
      if (e3) {
        // Limpiar usuario creado si falla la insercion de permisos
        await admin.from('profiles').delete().eq('id', created.user.id);
        await admin.auth.admin.deleteUser(created.user.id);
        return json({ error: e3.message }, 400);
      }
    }

    return json({ id: created.user.id });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
