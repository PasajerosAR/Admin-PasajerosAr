import {
  accessToken, adminClient, json, mpRequest, requiredEnv, sha256Hex
} from '../_shared/mercadopago.ts';

interface Payment {
  id: number | string;
  status: string;
  transaction_amount: number;
  currency_id: string;
  external_reference: string | null;
  preference_id: string | null;
  collector_id: number | string;
  live_mode: boolean;
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

async function validSignature(req: Request, dataId: string): Promise<boolean> {
  const signature = req.headers.get('x-signature');
  const requestId = req.headers.get('x-request-id');
  const secret = Deno.env.get('MP_WEBHOOK_SECRET');
  if (!signature || !requestId || !secret || !dataId) return false;
  const parts = Object.fromEntries(signature.split(',').map((part) => {
    const [key, ...value] = part.trim().split('=');
    return [key, value.join('=')];
  }));
  if (!parts.ts || !parts.v1) return false;
  const manifest = `id:${dataId.toLowerCase()};request-id:${requestId};ts:${parts.ts};`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const digest = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest)));
  const expected = Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return constantTimeEqual(expected, parts.v1.toLowerCase());
}

async function refundPayment(token: string, orderId: string, paymentId: string) {
  return await mpRequest<{ id: number | string; status: string }>(`/v1/payments/${encodeURIComponent(paymentId)}/refunds`, token, {
    method: 'POST',
    headers: { 'X-Idempotency-Key': `${orderId}-${paymentId}-refund` },
    body: JSON.stringify({})
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);
  try {
    const admin = adminClient();
    const body = await req.json();
    const bodyType = String(body.type ?? body.topic ?? '');
    if (bodyType !== 'payment') return json({ received: true });
    const url = new URL(req.url);
    const paymentId = String(body.data?.id ?? url.searchParams.get('data.id') ?? '');
    const orderId = url.searchParams.get('order_id') ?? '';
    if (!paymentId || !orderId || !(await validSignature(req, paymentId))) {
      return json({ error: 'Notificación inválida.' }, 401);
    }

    const { data: order, error: orderError } = await admin.from('passenger_checkout_orders')
      .select('id,company_id,status,price,preference_id,mp_connection_id')
      .eq('id', orderId)
      .maybeSingle();
    if (orderError) return json({ error: 'No se pudo consultar la compra.' }, 500);
    if (!order) return json({ received: true });

    const { data: connection, error: connectionError } = await admin.from('mp_company_connections')
      .select('company_id,mp_user_id,test_mode,active,access_token_encrypted,refresh_token_encrypted,token_expires_at')
      .eq('company_id', order.company_id)
      .eq('active', true)
      .eq('test_mode', true)
      .maybeSingle();
    if (connectionError || !connection) return json({ error: 'Cuenta de Mercado Pago no disponible.' }, 503);

    const token = await accessToken(admin, connection);
    const payment = await mpRequest<Payment>(`/v1/payments/${encodeURIComponent(paymentId)}`, token);
    if (String(payment.id) !== paymentId || String(payment.collector_id) !== connection.mp_user_id
        || payment.external_reference !== order.id || payment.preference_id !== order.preference_id
        || payment.live_mode !== false) {
      return json({ error: 'El pago no coincide con la compra de prueba.' }, 401);
    }
    if (payment.status !== 'approved') return json({ received: true });

    if (payment.currency_id !== 'ARS' || Number(payment.transaction_amount) !== Number(order.price)) {
      const { error: refundMarkError } = await admin.from('passenger_checkout_orders').update({
        status: 'refund_required',
        mp_payment_id: paymentId,
        refund_status: 'pending'
      }).eq('id', order.id).neq('status', 'approved');
      if (refundMarkError) return json({ error: 'No se pudo registrar la devolución pendiente.' }, 500);
      try {
        const refund = await refundPayment(token, order.id, paymentId);
        if (refund.status !== 'approved') {
          return json({ received: true, refund_pending: true });
        }
        const { error } = await admin.from('passenger_checkout_orders').update({
          status: 'cancelled',
          refund_status: 'refunded'
        }).eq('id', order.id).neq('status', 'approved');
        if (error) return json({ error: 'No se pudo registrar la devolución.' }, 500);
        return json({ received: true, refunded: true });
      } catch {
        const { error } = await admin.from('passenger_checkout_orders').update({ refund_status: 'failed' })
          .eq('id', order.id).neq('status', 'approved');
        if (error) return json({ error: 'No se pudo registrar el estado de la devolución.' }, 500);
        return json({ error: 'No se pudo iniciar la devolución del pago.' }, 500);
      }
    }

    const { data: result, error: finalizeError } = await admin.rpc('finalize_passenger_checkout', {
      p_order: order.id,
      p_payment_id: paymentId,
      p_amount: payment.transaction_amount,
      p_currency: payment.currency_id
    });
    if (finalizeError) return json({ error: 'No se pudo emitir el pasaje.' }, 500);
    if (result?.status === 'refund_required') {
      const { error: refundMarkError } = await admin.from('passenger_checkout_orders').update({ refund_status: 'pending' })
        .eq('id', order.id).eq('status', 'refund_required');
      if (refundMarkError) return json({ error: 'No se pudo registrar la devolución pendiente.' }, 500);
      try {
        const refund = await refundPayment(token, order.id, paymentId);
        if (refund.status !== 'approved') {
          return json({ received: true, refund_pending: true });
        }
        const { error } = await admin.from('passenger_checkout_orders').update({
          status: 'cancelled',
          refund_status: 'refunded'
        }).eq('id', order.id).eq('status', 'refund_required');
        if (error) return json({ error: 'No se pudo registrar la devolución.' }, 500);
        return json({ received: true, refunded: true });
      } catch {
        const { error } = await admin.from('passenger_checkout_orders').update({ refund_status: 'failed' })
          .eq('id', order.id).eq('status', 'refund_required');
        if (error) return json({ error: 'No se pudo registrar el estado de la devolución.' }, 500);
        return json({ error: 'No se pudo iniciar la devolución del pago.' }, 500);
      }
    }
    return json({ received: true, status: result?.status ?? 'pending' });
  } catch {
    return json({ error: 'Error al procesar la notificación.' }, 500);
  }
});
