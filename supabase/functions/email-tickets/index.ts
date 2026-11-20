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

const PLACEHOLDER_EMAIL = 'taquilla@pasajeros.ar';

// Envia por correo los pasajes de una venta ya registrada (ventanilla). Solo a quienes dejaron un correo.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);
  try {
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const authorization = req.headers.get('Authorization');
    if (!url || !anonKey || !authorization) return json({ error: 'No autenticado.' }, 401);
    const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data: who, error: authError } = await asCaller.auth.getUser();
    if (authError || !who.user) return json({ error: 'No autenticado.' }, 401);

    const saleId = String((await req.json()).sale_id ?? '');
    if (!saleId) return json({ error: 'Falta la venta.' }, 400);
    // la venta tiene que ser visible para quien llama (misma empresa)
    const mine = await asCaller.from('sales').select('id, company_id, trip_id').eq('id', saleId).maybeSingle();
    if (mine.error || !mine.data) return json({ error: 'Venta no encontrada.' }, 404);

    const resendKey = Deno.env.get('RESEND_API_KEY');
    const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL');
    if (!resendKey || !fromEmail || !serviceKey) return json({ sent: 0, failed: 0, reason: 'RESEND_NOT_CONFIGURED' });
    const admin = createClient(url, serviceKey);

    const ticketsResult = await admin.from('sale_tickets')
      .select('id, qr_code, passenger_name, passenger_dni, passenger_email, passenger_phone, seat_label, price, from_stop_id, to_stop_id')
      .eq('sale_id', saleId).neq('status', 'cancelled').neq('passenger_email', PLACEHOLDER_EMAIL);
    if (ticketsResult.error) return json({ error: 'No se pudieron leer los pasajes.' }, 500);
    const tickets = ticketsResult.data as TicketRow[];
    if (tickets.length === 0) return json({ sent: 0, failed: 0 });

    const tripResult = await admin.from('trips')
      .select('service_date, scheduled_departure, service:services(code), departure:service_departures(route_id)')
      .eq('id', mine.data.trip_id).single();
    if (tripResult.error || !tripResult.data) return json({ sent: 0, failed: tickets.length, reason: 'TRIP_DETAILS_UNAVAILABLE' });
    const routeId = (tripResult.data.departure as { route_id: string } | null)?.route_id;
    const service = tripResult.data.service as { code: string } | null;
    const [companyResult, routeResult, stopsResult] = await Promise.all([
      admin.from('companies').select('name').eq('id', mine.data.company_id).single(),
      routeId ? admin.from('routes').select('name').eq('id', routeId).single() : Promise.resolve({ data: null, error: new Error('Route missing') }),
      admin.from('route_stops').select('id, name').in('id', tickets.flatMap((ticket) => [ticket.from_stop_id, ticket.to_stop_id]))
    ]);
    if (companyResult.error || routeResult.error || stopsResult.error || !service) {
      return json({ sent: 0, failed: tickets.length, reason: 'ROUTE_DETAILS_UNAVAILABLE' });
    }
    const stopNames = new Map(stopsResult.data.map((stop) => [stop.id, stop.name]));
    const scheduled = new Date(tripResult.data.scheduled_departure);
    let sent = 0;
    const errors: { ticket_id: string; reason: string }[] = [];
    for (const ticket of tickets) {
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
        if (response.ok) sent++;
        else errors.push({ ticket_id: ticket.id, reason: `RESEND_HTTP_${response.status}` });
      } catch (error) {
        errors.push({ ticket_id: ticket.id, reason: error instanceof Error ? error.message : 'EMAIL_SEND_FAILED' });
      }
    }
    return json({ sent, failed: errors.length, ...(errors.length ? { reason: 'EMAIL_SEND_FAILED', errors } : {}) });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
