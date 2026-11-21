import { companyAdmin, corsHeaders, json } from '../_shared/mercadopago.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);
  try {
    // El cliente admin no tiene sesion de usuario: se consulta la conexion de la empresa del administrador directamente.
    const { admin, profile } = await companyAdmin(req);
    const { data: row, error } = await admin.from('mp_company_connections')
      .select('mp_user_id,connected_at')
      .eq('company_id', profile.company_id)
      .eq('active', true)
      .maybeSingle();
    if (error) return json({ error: 'No se pudo consultar la conexión.' }, 500);
    return json({
      connected: Boolean(row),
      mp_user_id: row?.mp_user_id ?? null,
      connected_at: row?.connected_at ?? null,
      test_mode: true
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'REQUEST_FAILED';
    const status = message === 'UNAUTHENTICATED' ? 401 : message === 'FORBIDDEN' ? 403 : 500;
    return json({ error: status === 500 ? 'No se pudo consultar la conexión.' : message }, status);
  }
});
