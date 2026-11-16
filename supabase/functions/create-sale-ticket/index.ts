import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';
import QRCode from 'npm:qrcode@1.5.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

interface PassengerInput {
  passenger_name: string;
  passenger_dni: string;
  passenger_email: string;
  passenger_phone: string;
  from_stop_id: string;
  to_stop_id: string;
  seat_label?: string | null;
  layout_cell_id?: string | null;
  is_complimentary?: boolean;
}

interface TicketRow {
  id: string;
  qr_code: string;
  passenger_name: string;
  passenger_dni: string;
  passenger_email: string;
  passenger_phone: string;
  seat_label: string | null;
  price: number;
  from_stop_id: string;
  to_stop_id: string;
}

const printable = (value: string) => value.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
const htmlEntities: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;'
};
const htmlEscape = (value: string) => value.replace(/[&<>"']/g, (character) => htmlEntities[character]);

async function ticketPdf(ticket: TicketRow, details: {
  company: string; service: string; route: string; date: string; departure: string;
  from: string; to: string;
}) {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([420, 595]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const draw = (text: string, x: number, y: number, size = 11, isBold = false) => {
    page.drawText(printable(text), { x, y, size, font: isBold ? bold : font, color: rgb(0.12, 0.18, 0.25) });
  };

  draw(details.company, 32, 555, 16, true);
  draw(`Pasaje - Servicio ${details.service}`, 32, 526, 13, true);
  draw(`Recorrido: ${details.route}`, 32, 503);
  draw(`Fecha: ${details.date}    Salida: ${details.departure}`, 32, 481);
  draw(`Origen: ${details.from}`, 32, 451);
  draw(`Destino: ${details.to}`, 32, 429);
  draw(`Pasajero: ${ticket.passenger_name}`, 32, 391, 12, true);
  draw(`DNI: ${ticket.passenger_dni}`, 32, 368);
  draw(`Correo: ${ticket.passenger_email}`, 32, 347);
  draw(`Telefono: ${ticket.passenger_phone}`, 32, 326);
  draw(`Asiento: ${ticket.seat_label ?? 'Sin asignar'}    Precio: $${Number(ticket.price).toFixed(2)}`, 32, 305);
  draw('Presenta este QR al conductor para abordar.', 32, 275);

  const qr = await QRCode.toBuffer(ticket.qr_code, { type: 'png', errorCorrectionLevel: 'M', margin: 1, width: 220 });
  const image = await pdf.embedPng(qr);
  page.drawImage(image, { x: 100, y: 35, width: 220, height: 220 });
  return await pdf.save();
}

function base64(bytes: Uint8Array) {
  let binary = '';
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length)));
  }
  return btoa(binary);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  let committedSale: { sale_id: string; total: number; tickets: TicketRow[] } | null = null;
  let emailSent = 0;
  let emailFailed = 0;
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const authorization = req.headers.get('Authorization');
    if (!url || !anonKey || !authorization) return json({ error: 'No autenticado.' }, 401);

    const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data: who, error: authError } = await asCaller.auth.getUser();
    if (authError || !who.user) return json({ error: 'No autenticado.' }, 401);

    const body = await req.json();
    const tripId = String(body.trip_id ?? '');
    const paymentMethod = String(body.payment_method ?? '');
    const notes = String(body.notes ?? '').trim();
    const passengers: PassengerInput[] = Array.isArray(body.passengers) ? body.passengers : [];
    if (!tripId) return json({ error: 'Falta el viaje.' }, 400);
    if (!['cash', 'debit', 'credit', 'transfer', 'mp', 'complimentary'].includes(paymentMethod)) {
      return json({ error: 'Medio de pago inválido.' }, 400);
    }
    if (passengers.length === 0 || passengers.length > 20) {
      return json({ error: 'La venta debe incluir entre 1 y 20 pasajeros.' }, 400);
    }

    const { data, error } = await asCaller.rpc('create_sale_with_tickets', {
      p_trip: tripId,
      p_payment_method: paymentMethod,
      p_notes: notes || null,
      p_passengers: passengers
    });
    if (error) {
      const forbidden = /FORBIDDEN/i.test(error.message);
      return json({ error: error.message }, forbidden ? 403 : 400);
    }

    const result = data as { sale_id: string; total: number; tickets: TicketRow[] };
    committedSale = result;
    const resendKey = Deno.env.get('RESEND_API_KEY');
    const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL');
    if (!resendKey || !fromEmail) {
      return json({
        ...result,
        email: { sent: 0, failed: result.tickets.length, reason: 'RESEND_NOT_CONFIGURED' }
      }, 201);
    }

    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!serviceKey) return json({
      ...result, email: { sent: 0, failed: result.tickets.length, reason: 'SERVICE_ROLE_NOT_CONFIGURED' }
    }, 201);
    const admin = createClient(url, serviceKey);

    const ticketIds = result.tickets.map((ticket) => ticket.id);
    const [ticketsResult, saleResult] = await Promise.all([
      admin.from('sale_tickets').select('id, qr_code, passenger_name, passenger_dni, passenger_email, passenger_phone, seat_label, price, from_stop_id, to_stop_id').in('id', ticketIds),
      admin.from('sales').select('company_id, trip_id').eq('id', result.sale_id).single()
    ]);
    if (ticketsResult.error || saleResult.error || !saleResult.data) {
      return json({ ...result, email: { sent: 0, failed: result.tickets.length, reason: 'TICKET_DETAILS_UNAVAILABLE' } }, 201);
    }

    const tripResult = await admin.from('trips')
      .select('service_date, scheduled_departure, service:services(code), departure:service_departures(route_id)')
      .eq('id', saleResult.data.trip_id).single();
    if (tripResult.error || !tripResult.data) {
      return json({ ...result, email: { sent: 0, failed: result.tickets.length, reason: 'TRIP_DETAILS_UNAVAILABLE' } }, 201);
    }
    const routeId = (tripResult.data.departure as { route_id: string } | null)?.route_id;
    const service = tripResult.data.service as { code: string } | null;
    const [companyResult, routeResult, stopsResult] = await Promise.all([
      admin.from('companies').select('name').eq('id', saleResult.data.company_id).single(),
      routeId ? admin.from('routes').select('name').eq('id', routeId).single() : Promise.resolve({ data: null, error: new Error('Route missing') }),
      admin.from('route_stops').select('id, name').in('id', ticketsResult.data.flatMap((ticket) => [ticket.from_stop_id, ticket.to_stop_id]))
    ]);
    if (companyResult.error || routeResult.error || stopsResult.error || !service) {
      return json({ ...result, email: { sent: 0, failed: result.tickets.length, reason: 'ROUTE_DETAILS_UNAVAILABLE' } }, 201);
    }
    const stopNames = new Map(stopsResult.data.map((stop) => [stop.id, stop.name]));
    const scheduled = new Date(tripResult.data.scheduled_departure);
    const emailErrors: { ticket_id: string; reason: string }[] = [];
    for (const ticket of ticketsResult.data as TicketRow[]) {
      try {
        const pdf = await ticketPdf(ticket, {
          company: companyResult.data.name,
          service: service.code,
          route: routeResult.data.name,
          date: new Date(`${tripResult.data.service_date}T12:00:00`).toLocaleDateString('es-AR'),
          departure: scheduled.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Argentina/Buenos_Aires' }),
          from: stopNames.get(ticket.from_stop_id) ?? 'No disponible',
          to: stopNames.get(ticket.to_stop_id) ?? 'No disponible'
        });
        const response = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: fromEmail,
            to: [ticket.passenger_email],
            subject: `Tu pasaje ${service.code} - ${companyResult.data.name}`,
            html: `<p>Hola ${htmlEscape(ticket.passenger_name)}, adjuntamos tu pasaje con el código QR para abordar.</p>`,
            attachments: [{ filename: `pasaje-${ticket.id}.pdf`, content: base64(pdf) }]
          })
        });
        if (response.ok) emailSent++;
        else {
          emailFailed++;
          emailErrors.push({ ticket_id: ticket.id, reason: `RESEND_HTTP_${response.status}` });
        }
      } catch (error) {
        emailFailed++;
        emailErrors.push({
          ticket_id: ticket.id,
          reason: error instanceof Error ? error.message : 'EMAIL_SEND_FAILED'
        });
      }
    }

    return json({
      ...result,
      email: { sent: emailSent, failed: emailFailed, ...(emailFailed ? { reason: 'EMAIL_SEND_FAILED', errors: emailErrors } : {}) }
    }, 201);
  } catch (error) {
    if (committedSale) {
      const unprocessed = committedSale.tickets.length - emailSent - emailFailed;
      return json({
        ...committedSale,
        email: { sent: emailSent, failed: emailFailed + unprocessed, reason: 'EMAIL_PROCESSING_FAILED' }
      }, 201);
    }
    return json({ error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
