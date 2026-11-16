import { companyAdmin, corsHeaders, json } from '../_shared/mercadopago.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);
  try {
    const { admin } = await companyAdmin(req);
    const { data, error } = await admin.rpc('mp_company_connection_status');
    if (error) return json({ error: 'No se pudo consultar la conexión.' }, 500);
    const row = Array.isArray(data) ? data[0] : null;
    return json({
      connected: Boolean(row?.connected),
      mp_user_id: row?.connected ? row.mp_user_id : null,
      connected_at: row?.connected ? row.connected_at : null,
      test_mode: true
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'REQUEST_FAILED';
    const status = message === 'UNAUTHENTICATED' ? 401 : message === 'FORBIDDEN' ? 403 : 500;
    return json({ error: status === 500 ? 'No se pudo consultar la conexión.' : message }, status);
  }
});
