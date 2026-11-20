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
  ticket_type: 'regular' | 'courtesy' | 'disability';
  from_stop_id: string;
  to_stop_id: string;
}

const printable = (value: string) => value.normalize('NFC');
const htmlEntities: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;'
};
const htmlEscape = (value: string) => value.replace(/[&<>"']/g, (character) => htmlEntities[character]);
const receiptLabel = (number: number) => String(number).padStart(8, '0');
const channelLabel = (channel: string) => channel === 'web' ? 'Web - Punto de venta' : 'Ventanilla';
const paymentLabel = (method: string) => ({
  cash: 'Efectivo', debit: 'Debito', credit: 'Credito', transfer: 'Transferencia', mp: 'Mercado Pago', complimentary: 'Sin cargo'
}[method] ?? method);

async function ticketPdf(ticket: TicketRow, details: {
  company: string; service: string; route: string; date: string; departure: string;
  from: string; to: string; receiptNumber: number; channel: string; paymentMethod: string; issueDate: string;
}) {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const brand = rgb(0.06, 0.36, 0.55);
  const brandSoft = rgb(0.89, 0.94, 0.97);
  const ink = rgb(0.12, 0.20, 0.28);
  const muted = rgb(0.36, 0.43, 0.49);
  const line = rgb(0.78, 0.83, 0.87);
  const draw = (text: string, x: number, y: number, size = 11, isBold = false, color = ink) => {
    page.drawText(printable(text), { x, y, size, font: isBold ? bold : font, color });
  };
  const drawFit = (text: string, x: number, y: number, maxWidth: number, size = 11, isBold = false, color = ink) => {
    const value = printable(text);
    const face = isBold ? bold : font;
    let fittedSize = size;
    while (fittedSize > 7 && face.widthOfTextAtSize(value, fittedSize) > maxWidth) fittedSize -= 1;
    page.drawText(value, { x, y, size: fittedSize, font: face, color });
  };

  page.drawRectangle({ x: 0, y: 760, width: 595, height: 82, color: brand });
  drawFit(details.company, 38, 805, 360, 18, true, rgb(1, 1, 1));
  draw('SERVICIO INTERURBANO', 38, 784, 9, false, rgb(0.84, 0.92, 0.97));
  draw('PASAJE ELECTRONICO', 424, 806, 10, true, rgb(1, 1, 1));
  draw('EMITIDO', 490, 786, 9, false, rgb(0.84, 0.92, 0.97));

  page.drawRectangle({ x: 38, y: 670, width: 519, height: 68, color: brandSoft });
  draw('ORIGEN', 54, 720, 8, true, muted);
  drawFit(details.from, 54, 691, 200, 19, true, brand);
  draw('HACIA', 276, 699, 8, true, brand);
  draw('DESTINO', 342, 720, 8, true, muted);
  drawFit(details.to, 342, 691, 200, 19, true, brand);

  const cols = [38, 168, 298, 428];
  const labels = ['FECHA DEL VIAJE', 'HORA DE SALIDA', 'SERVICIO', 'ASIENTO'];
  const values = [details.date, details.departure, details.service, ticket.seat_label ?? 'Sin asignar'];
  page.drawRectangle({ x: 38, y: 615, width: 519, height: 42, color: rgb(0.97, 0.98, 0.99), borderColor: line, borderWidth: 0.7 });
  for (let i = 0; i < 4; i++) {
    draw(labels[i], cols[i] + 8, 641, 7, false, muted);
    draw(values[i], cols[i] + 8, 624, 10, true);
    if (i > 0) page.drawLine({ start: { x: cols[i], y: 615 }, end: { x: cols[i], y: 657 }, thickness: 0.7, color: line });
  }

  draw('DATOS DEL PASAJERO', 38, 588, 9, true, brand);
  draw('NOMBRE Y APELLIDO', 38, 568, 7, false, muted);
  drawFit(ticket.passenger_name, 38, 550, 260, 11, true);
  draw('DOCUMENTO', 330, 568, 7, false, muted);
  draw(`DNI ${ticket.passenger_dni}`, 330, 550, 11, true);
  if (ticket.ticket_type !== 'regular') {
    const kind = ticket.ticket_type === 'courtesy' ? 'GENTILEZA' : 'DISCAPACIDAD';
    page.drawRectangle({ x: 38, y: 522, width: 106, height: 18, color: brandSoft });
    draw(kind, 46, 528, 8, true, brand);
  }
  page.drawLine({ start: { x: 38, y: 510 }, end: { x: 557, y: 510 }, thickness: 0.7, color: line });

  draw('DATOS DE LA COMPRA', 38, 490, 9, true, brand);
  page.drawRectangle({ x: 38, y: 414, width: 519, height: 62, color: rgb(0.97, 0.98, 0.99), borderColor: line, borderWidth: 0.7 });
  draw('NRO. DE COMPROBANTE', 50, 458, 7, false, muted);
  draw(receiptLabel(details.receiptNumber), 50, 436, 14, true, brand);
  draw('PUNTO DE VENTA', 218, 458, 7, false, muted);
  drawFit(details.channel, 218, 436, 155, 9, true);
  draw('MEDIO DE PAGO', 390, 458, 7, false, muted);
  drawFit(details.paymentMethod, 390, 436, 155, 9, true);
  draw('FECHA DE EMISION', 50, 423, 7, false, muted);
  draw(details.issueDate, 125, 423, 8, false);
  draw('RECORRIDO', 330, 423, 7, false, muted);
  drawFit(details.route, 390, 423, 155, 8, false);

  page.drawRectangle({ x: 38, y: 218, width: 519, height: 176, color: rgb(0.985, 0.993, 1), borderColor: line, borderWidth: 0.7 });
  draw('VALIDACION AL ABORDAR', 54, 365, 11, true, brand);
  draw('Escanea este codigo con el lector de la empresa.', 54, 346, 8, false, muted);
  draw('IMPORTE ABONADO', 54, 302, 8, true, muted);
  draw(`$ ${Number(ticket.price).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`, 54, 272, 22, true, brand);
  if (ticket.ticket_type !== 'regular') draw('PASAJE SIN CARGO', 54, 250, 9, true, brand);

  const qr = await QRCode.toBuffer(ticket.qr_code, { type: 'png', errorCorrectionLevel: 'M', margin: 1, width: 220 });
  const image = await pdf.embedPng(qr);
  page.drawImage(image, { x: 391, y: 232, width: 145, height: 145 });
  draw('INFORMACION PARA EL PASAJERO', 38, 189, 8, true, brand);
  draw('Presentate con anticipacion al horario indicado y lleva DNI para acreditar tu identidad.', 38, 171, 8, false, muted);
  draw('El pasaje puede presentarse impreso o en formato digital al abordar.', 38, 157, 8, false, muted);
  page.drawLine({ start: { x: 38, y: 140 }, end: { x: 557, y: 140 }, thickness: 0.7, color: line });
  drawFit(`Canal: ${details.channel}  |  Comprobante ${receiptLabel(details.receiptNumber)}`, 38, 124, 515, 8, false, muted);
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
    const mine = await asCaller.from('sales').select('id, company_id, trip_id, channel, receipt_number, payment_method, created_at').eq('id', saleId).maybeSingle();
    if (mine.error || !mine.data) return json({ error: 'Venta no encontrada.' }, 404);

    const resendKey = Deno.env.get('RESEND_API_KEY');
    const fromEmail = Deno.env.get('TICKETS_FROM_EMAIL');
    if (!resendKey || !fromEmail || !serviceKey) return json({ sent: 0, failed: 0, reason: 'RESEND_NOT_CONFIGURED' });
    const admin = createClient(url, serviceKey);

    const ticketsResult = await admin.from('sale_tickets')
      .select('id, qr_code, passenger_name, passenger_dni, passenger_email, passenger_phone, seat_label, price, ticket_type, from_stop_id, to_stop_id')
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
          to: stopNames.get(ticket.to_stop_id) ?? 'No disponible',
          receiptNumber: mine.data.receipt_number,
          channel: channelLabel(mine.data.channel),
          paymentMethod: paymentLabel(mine.data.payment_method),
          issueDate: new Date(mine.data.created_at).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Argentina/Buenos_Aires' })
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
