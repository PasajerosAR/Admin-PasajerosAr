import {
  adminClient, encryptToken, json, redirect, requiredEnv, sha256Hex, testMode
} from '../_shared/mercadopago.ts';

Deno.serve(async (req) => {
  if (req.method !== 'GET') return json({ error: 'Método no permitido.' }, 405);
  const adminUrl = Deno.env.get('ADMIN_WEB_URL');
  if (!adminUrl) return json({ error: 'ADMIN_WEB_URL_MISSING' }, 500);
  const returnTo = new URL('/admin/ventas/mercadopago', adminUrl);

  try {
    testMode();
    const query = new URL(req.url).searchParams;
    const code = query.get('code');
    const state = query.get('state');
    if (query.has('error') || !code || !state) {
      returnTo.searchParams.set('connection_error', 'authorization');
      return redirect(returnTo.toString());
    }

    const admin = adminClient();
    const stateHash = await sha256Hex(state);
    const { data: oauthState, error: stateError } = await admin.from('mp_oauth_states')
      .update({ used_at: new Date().toISOString() })
      .eq('state_hash', stateHash)
      .is('used_at', null)
      .gt('expires_at', new Date().toISOString())
      .select('company_id,initiated_by')
      .maybeSingle();
    if (stateError || !oauthState) {
      returnTo.searchParams.set('connection_error', 'state');
      return redirect(returnTo.toString());
    }

    const response = await fetch('https://api.mercadopago.com/oauth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id: requiredEnv('MP_CLIENT_ID'),
        client_secret: requiredEnv('MP_CLIENT_SECRET'),
        grant_type: 'authorization_code',
        code,
        redirect_uri: requiredEnv('MP_REDIRECT_URI'),
        test_token: true
      })
    });
    if (!response.ok) {
      returnTo.searchParams.set('connection_error', 'token');
      return redirect(returnTo.toString());
    }
    const tokens = await response.json() as {
      access_token?: string; refresh_token?: string; expires_in?: number; user_id?: number | string
    };
    if (!tokens.access_token || !tokens.refresh_token || !tokens.expires_in || !tokens.user_id) {
      returnTo.searchParams.set('connection_error', 'token');
      return redirect(returnTo.toString());
    }

    const { error: saveError } = await admin.from('mp_company_connections').upsert({
      company_id: oauthState.company_id,
      mp_user_id: String(tokens.user_id),
      test_mode: true,
      access_token_encrypted: await encryptToken(tokens.access_token),
      refresh_token_encrypted: await encryptToken(tokens.refresh_token),
      token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
      connected_by: oauthState.initiated_by,
      connected_at: new Date().toISOString(),
      active: true
    });
    if (saveError) {
      returnTo.searchParams.set('connection_error', 'save');
      return redirect(returnTo.toString());
    }
    returnTo.searchParams.set('connected', '1');
    return redirect(returnTo.toString());
  } catch {
    returnTo.searchParams.set('connection_error', 'configuration');
    return redirect(returnTo.toString());
  }
});
