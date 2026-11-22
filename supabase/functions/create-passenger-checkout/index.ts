import {
  accessToken, adminClient, authenticatedUser, corsHeaders, json, mpRequest, requiredEnv, testMode
} from '../_shared/mercadopago.ts';

interface CheckoutOrder {
  order_id: string;
  company_id: string;
  price: number;
  service_code: string;
  route_name: string;
  service_date: string;
  tickets: {
    seat_label: string;
    price: number;
  }[];
  from_stop: string;
  to_stop: string;
  expires_at: string;
}

interface Preference {
  id?: string;
  init_point?: string;
}

const publicErrors: Record<string, { message: string; status: number }> = {
  CHECKOUT_INVALID: { message: 'Revisá el teléfono y los datos del viaje.', status: 400 },
  PASSENGER_INVALID: { message: 'Revisá el nombre, DNI y correo de cada pasajero adicional.', status: 400 },
  PASSENGER_PROFILE_REQUIRED: { message: 'Completá tu perfil de pasajero antes de comprar.', status: 400 },
  TRIP_UNAVAILABLE: { message: 'Este viaje ya no está disponible.', status: 409 },
  MERCADOPAGO_NOT_CONNECTED: { message: 'La empresa todavía no conectó Mercado Pago en modo de prueba.', status: 409 },
  STOP_INVALID: { message: 'El tramo seleccionado no es válido.', status: 400 },
  SEAT_UNAVAILABLE: { message: 'Uno de los asientos seleccionados ya no está disponible.', status: 409 },
  FARE_NOT_FOUND: { message: 'No hay una tarifa activa para el tramo y todas las clases seleccionadas.', status: 409 },
  SEAT_TAKEN: { message: 'Otra persona reservó uno de esos asientos. Actualizá la disponibilidad.', status: 409 }
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
    const tripId = typeof body.trip_id === 'string' ? body.trip_id : '';
    const fromStopId = typeof body.from_stop_id === 'string' ? body.from_stop_id : '';
    const toStopId = typeof body.to_stop_id === 'string' ? body.to_stop_id : '';
    const rawTickets = Array.isArray(body.tickets) ? body.tickets : [];
    const phone = String(body.passenger_phone ?? '').trim();
    if (!tripId || !fromStopId || !toStopId || rawTickets.length < 1 || rawTickets.length > 4
        || rawTickets.some((ticket) => !ticket || typeof ticket !== 'object'
          || typeof ticket.layout_cell_id !== 'string')
        || phone.length < 7 || phone.length > 40) {
      return json({ error: 'Elegí entre 1 y 4 asientos e ingresá un teléfono de contacto válido.' }, 400);
    }
    const tickets = rawTickets.map((ticket) => ({
      layout_cell_id: ticket.layout_cell_id,
      passenger_name: typeof ticket.passenger_name === 'string' ? ticket.passenger_name.trim() : '',
      passenger_dni: typeof ticket.passenger_dni === 'string' ? ticket.passenger_dni.trim() : '',
      passenger_email: typeof ticket.passenger_email === 'string' ? ticket.passenger_email.trim() : ''
    }));

    const { data: passenger, error: passengerError } = await admin.from('passenger_profiles')
      .select('user_id,email')
      .eq('user_id', user.id)
      .maybeSingle();
    if (passengerError) return json({ error: 'No se pudo validar la cuenta de pasajero.' }, 500);
    if (!passenger) return json({ error: publicErrors.PASSENGER_PROFILE_REQUIRED.message }, 400);

    const { data: orderData, error: orderError } = await admin.rpc('begin_passenger_checkout', {
      p_user: user.id,
      p_trip: tripId,
      p_from_stop: fromStopId,
      p_to_stop: toStopId,
      p_tickets: tickets,
      p_phone: phone
    });
    if (orderError) {
      const code = Object.keys(publicErrors).find((candidate) => orderError.message.includes(candidate)) ?? '';
      const mapped = publicErrors[code];
      return json({ error: mapped?.message ?? 'No se pudieron reservar los asientos.' }, mapped?.status ?? 400);
    }

    const order = orderData as CheckoutOrder;
    orderId = order.order_id;
    const { data: connection, error: connectionError } = await admin.from('mp_company_connections')
      .select('company_id,mp_user_id,test_mode,active,access_token_encrypted,refresh_token_encrypted,token_expires_at')
      .eq('company_id', order.company_id)
      .eq('active', true)
      .eq('test_mode', true)
      .maybeSingle();
    if (connectionError || !connection) throw new Error('MERCADOPAGO_CONNECTION_UNAVAILABLE');

    const token = await accessToken(admin, connection);
    const webUrl = new URL(requiredEnv('PASSENGER_WEB_URL'));
    if (webUrl.protocol !== 'https:') throw new Error('PASSENGER_WEB_URL_MUST_USE_HTTPS');
    const supabaseUrl = requiredEnv('SUPABASE_URL');
    const notificationUrl = new URL('/functions/v1/mercadopago-webhook', supabaseUrl);
    notificationUrl.searchParams.set('order_id', order.order_id);
    const resultUrl = (status: string) => {
      const url = new URL(webUrl);
      url.searchParams.set('checkout', status);
      url.searchParams.set('order_id', order.order_id);
      return url.toString();
    };

    const preference = await mpRequest<Preference>('/checkout/preferences', token, {
      method: 'POST',
      headers: { 'X-Idempotency-Key': order.order_id },
      body: JSON.stringify({
        items: order.tickets.map((ticket, index) => ({
          id: `${order.order_id}-${index + 1}`,
          title: `Servicio ${order.service_code} · Pasaje ${index + 1}`,
          description: `${order.route_name} · ${order.service_date} · ${order.from_stop} a ${order.to_stop} · Asiento ${ticket.seat_label}`,
          quantity: 1,
          currency_id: 'ARS',
          unit_price: Number(ticket.price)
        })),
        external_reference: order.order_id,
        metadata: { checkout_order_id: order.order_id },
        notification_url: notificationUrl.toString(),
        back_urls: {
          success: resultUrl('return'),
          pending: resultUrl('return'),
          failure: resultUrl('return')
        },
        auto_return: 'approved',
        expires: true,
        expiration_date_to: order.expires_at,
        payment_methods: {
          excluded_payment_types: [{ id: 'ticket' }]
        }
      })
    });

    if (!preference.id || !preference.init_point) throw new Error('MERCADOPAGO_TEST_CHECKOUT_URL_MISSING');
    const checkoutUrl = new URL(preference.init_point);
    const checkoutHost = checkoutUrl.hostname.toLowerCase();
    const trustedCheckoutHost = checkoutHost === 'mercadopago.com.ar'
      || checkoutHost.endsWith('.mercadopago.com.ar')
      || checkoutHost === 'mercadopago.com'
      || checkoutHost.endsWith('.mercadopago.com');
    if (checkoutUrl.protocol !== 'https:' || !trustedCheckoutHost) {
      throw new Error('MERCADOPAGO_TEST_CHECKOUT_URL_INVALID');
    }
    const { error: saveError } = await admin.from('passenger_checkout_orders').update({
      preference_id: preference.id,
      checkout_url: checkoutUrl.toString()
    }).eq('id', order.order_id).eq('status', 'pending');
    if (saveError) throw new Error('CHECKOUT_SAVE_FAILED');

    return json({
      order_id: order.order_id,
      checkout_url: checkoutUrl.toString(),
      expires_at: order.expires_at
    }, 201);
  } catch (error) {
    if (orderId && admin) {
      const { error: releaseError } = await admin.rpc('fail_passenger_checkout', { p_order: orderId });
      if (releaseError) return json({ error: 'No se pudo liberar la reserva. Contactá al soporte.' }, 500);
    }
    const message = error instanceof Error ? error.message : 'CHECKOUT_FAILED';
    const userMessage = message === 'UNAUTHENTICATED'
      ? 'Iniciá sesión para continuar.'
      : message === 'FORBIDDEN'
        ? 'No tenés permiso para realizar esta compra.'
        : message === 'MERCADOPAGO_REAUTHORIZE_REQUIRED'
          ? 'La empresa debe volver a conectar su cuenta de Mercado Pago.'
          : 'No se pudo iniciar el pago de prueba. Intentá nuevamente más tarde.';
    const status = message === 'UNAUTHENTICATED' ? 401 : message === 'FORBIDDEN' ? 403 : 500;
    return json({ error: userMessage }, status);
  }
});
