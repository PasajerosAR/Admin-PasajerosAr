import {
  accessToken, adminClient, authenticatedUser, corsHeaders, json, mpRequest, requiredEnv, testMode
} from '../_shared/mercadopago.ts';

interface PassOrder { order_id: string; company_id: string; price: number; title: string; expires_at: string }
interface Preference { id?: string; sandbox_init_point?: string }

const publicErrors: Record<string, { message: string; status: number }> = {
  PASSENGER_PROFILE_REQUIRED: { message: 'Completá tu perfil de pasajero antes de comprar.', status: 400 },
  PRODUCT_NOT_FOUND: { message: 'Ese abono ya no está disponible.', status: 409 },
  TRIP_UNAVAILABLE: { message: 'Esta empresa no vende abonos por la web.', status: 409 },
  MERCADOPAGO_NOT_CONNECTED: { message: 'La empresa todavía no conectó Mercado Pago en modo de prueba.', status: 409 }
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  let orderId = '';
  let admin: ReturnType<typeof adminClient> | null = null;
  try {
    testMode();
    admin = adminClient();
    const user = await authenticatedUser(req);
    const body = await req.json();
    const productId = typeof body.product_id === 'string' ? body.product_id : '';
    if (!productId) return json({ error: 'Elegí un abono.' }, 400);

    const { data: orderData, error: orderError } = await admin.rpc('begin_pass_checkout', { p_user: user.id, p_product: productId });
    if (orderError) {
      const code = Object.keys(publicErrors).find((candidate) => orderError.message.includes(candidate)) ?? '';
      const mapped = publicErrors[code];
      return json({ error: mapped?.message ?? 'No se pudo iniciar la compra del abono.' }, mapped?.status ?? 400);
    }
    const order = orderData as PassOrder;
    orderId = order.order_id;

    const { data: connection, error: connectionError } = await admin.from('mp_company_connections')
      .select('company_id,mp_user_id,test_mode,active,access_token_encrypted,refresh_token_encrypted,token_expires_at')
      .eq('company_id', order.company_id).eq('active', true).eq('test_mode', true).maybeSingle();
    if (connectionError || !connection) throw new Error('MERCADOPAGO_CONNECTION_UNAVAILABLE');

    const token = await accessToken(admin, connection);
    const webUrl = new URL(requiredEnv('PASSENGER_WEB_URL'));
    if (webUrl.protocol !== 'https:') throw new Error('PASSENGER_WEB_URL_MUST_USE_HTTPS');
    const notificationUrl = new URL('/functions/v1/mercadopago-webhook', requiredEnv('SUPABASE_URL'));
    notificationUrl.searchParams.set('order_id', order.order_id);
    notificationUrl.searchParams.set('kind', 'pass');
    const resultUrl = new URL(webUrl);
    resultUrl.searchParams.set('pass_checkout', 'return');
    resultUrl.searchParams.set('order_id', order.order_id);

    const preference = await mpRequest<Preference>('/checkout/preferences', token, {
      method: 'POST',
      headers: { 'X-Idempotency-Key': order.order_id },
      body: JSON.stringify({
        items: [{ id: order.order_id, title: order.title, quantity: 1, currency_id: 'ARS', unit_price: Number(order.price) }],
        external_reference: order.order_id,
        metadata: { pass_checkout_order_id: order.order_id },
        notification_url: notificationUrl.toString(),
        back_urls: { success: resultUrl.toString(), pending: resultUrl.toString(), failure: resultUrl.toString() },
        auto_return: 'approved',
        expires: true,
        expiration_date_to: order.expires_at,
        payment_methods: { excluded_payment_types: [{ id: 'ticket' }] }
      })
    });
    if (!preference.id || !preference.sandbox_init_point) throw new Error('MERCADOPAGO_TEST_CHECKOUT_URL_MISSING');
    const checkoutUrl = new URL(preference.sandbox_init_point);
    const host = checkoutUrl.hostname.toLowerCase();
    const trusted = host === 'mercadopago.com.ar' || host.endsWith('.mercadopago.com.ar')
      || host === 'mercadopago.com' || host.endsWith('.mercadopago.com');
    if (checkoutUrl.protocol !== 'https:' || !trusted) throw new Error('MERCADOPAGO_TEST_CHECKOUT_URL_INVALID');
    const { error: saveError } = await admin.from('pass_checkout_orders')
      .update({ preference_id: preference.id, checkout_url: checkoutUrl.toString() })
      .eq('id', order.order_id).eq('status', 'pending');
    if (saveError) throw new Error('CHECKOUT_SAVE_FAILED');

    return json({ order_id: order.order_id, checkout_url: checkoutUrl.toString(), expires_at: order.expires_at }, 201);
  } catch (error) {
    if (orderId && admin) await admin.rpc('fail_pass_checkout', { p_order: orderId });
    const message = error instanceof Error ? error.message : 'CHECKOUT_FAILED';
    const userMessage = message === 'UNAUTHENTICATED' ? 'Iniciá sesión para continuar.'
      : message === 'MERCADOPAGO_REAUTHORIZE_REQUIRED' ? 'La empresa debe volver a conectar su cuenta de Mercado Pago.'
        : 'No se pudo iniciar el pago de prueba. Intentá nuevamente más tarde.';
    return json({ error: userMessage }, message === 'UNAUTHENTICATED' ? 401 : 500);
  }
});
