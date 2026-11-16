import { adminClient, companyAdmin, corsHeaders, json } from '../_shared/mercadopago.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);
  try {
    const { admin, profile } = await companyAdmin(req);
    const { count, error: pendingError } = await admin.from('passenger_checkout_orders')
      .select('id', { count: 'exact', head: true })
      .eq('company_id', profile.company_id)
      .in('status', ['pending', 'expired', 'refund_required'])
      .gt('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());
    if (pendingError) return json({ error: 'No se pudo comprobar si hay pagos en curso.' }, 500);
    if (count) return json({ error: 'Esperá a que terminen los pagos en curso antes de desconectar la cuenta.' }, 409);

    const { error } = await admin.from('mp_company_connections').update({
      active: false,
      access_token_encrypted: '',
      refresh_token_encrypted: ''
    }).eq('company_id', profile.company_id);
    if (error) return json({ error: 'No se pudo desconectar Mercado Pago.' }, 500);
    return json({ disconnected: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'REQUEST_FAILED';
    const status = message === 'UNAUTHENTICATED' ? 401 : message === 'FORBIDDEN' ? 403 : 500;
    return json({ error: status === 500 ? 'No se pudo desconectar Mercado Pago.' : message }, status);
  }
});
