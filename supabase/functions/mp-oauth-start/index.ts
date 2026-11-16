import { companyAdmin, corsHeaders, json, requiredEnv, sha256Hex, testMode } from '../_shared/mercadopago.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  try {
    testMode();
    const { admin, user, profile } = await companyAdmin(req);
    const stateBytes = crypto.getRandomValues(new Uint8Array(32));
    const state = Array.from(stateBytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
    const { error } = await admin.from('mp_oauth_states').insert({
      state_hash: await sha256Hex(state),
      company_id: profile.company_id,
      initiated_by: user.id,
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString()
    });
    if (error) return json({ error: 'No se pudo iniciar la conexión con Mercado Pago.' }, 500);

    const authorization = new URL('https://auth.mercadopago.com/authorization');
    authorization.search = new URLSearchParams({
      response_type: 'code',
      client_id: requiredEnv('MP_CLIENT_ID'),
      platform_id: 'mp',
      state,
      redirect_uri: requiredEnv('MP_REDIRECT_URI'),
      scope: 'offline_access'
    }).toString();
    return json({ authorization_url: authorization.toString() });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'REQUEST_FAILED';
    const status = message === 'UNAUTHENTICATED' ? 401 : message === 'FORBIDDEN' ? 403 : 500;
    return json({ error: status === 500 ? 'No se pudo iniciar la conexión con Mercado Pago.' : message }, status);
  }
});
