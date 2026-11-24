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
  origin: string; destination: string; from: string; to: string;
  receiptNumber: number; channel: string; paymentMethod: string; issueDate: string;
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
  const drawWrapped = (text: string, x: number, y: number, maxWidth: number, size: number, lineHeight: number, color = ink) => {
    const words = printable(text).split(/\s+/);
    const lines: string[] = [];
    let current = '';
    for (const word of words) {
      const next = current ? `${current} ${word}` : word;
      if (current && font.widthOfTextAtSize(next, size) > maxWidth) {
        lines.push(current);
        current = word;
      } else current = next;
    }
    if (current) lines.push(current);
    page.drawText(lines.join('\n'), { x, y, size, font, color, lineHeight });
  };

  page.drawRectangle({ x: 0, y: 760, width: 595, height: 82, color: brand });
  drawFit(details.company, 38, 805, 360, 18, true, rgb(1, 1, 1));
  draw('SERVICIO INTERURBANO', 38, 784, 9, false, rgb(0.84, 0.92, 0.97));
  draw('PASAJE ELECTRONICO', 424, 806, 10, true, rgb(1, 1, 1));
  draw('EMITIDO', 490, 786, 9, false, rgb(0.84, 0.92, 0.97));

  page.drawRectangle({ x: 38, y: 642, width: 519, height: 96, color: brandSoft });
  draw('ORIGEN (LOCALIDAD)', 54, 720, 8, true, muted);
  drawFit(details.origin, 54, 691, 200, 19, true, brand);
  draw('HACIA', 276, 699, 8, true, brand);
  draw('DESTINO (LOCALIDAD)', 342, 720, 8, true, muted);
  drawFit(details.destination, 342, 691, 200, 19, true, brand);
  draw('PARADA DE ASCENSO', 54, 675, 7, true, muted);
  drawFit(details.from, 54, 653, 200, 11, true, ink);
  draw('PARADA DE DESCENSO', 342, 675, 7, true, muted);
  drawFit(details.to, 342, 653, 200, 11, true, ink);

  const cols = [38, 168, 298, 428];
  const labels = ['FECHA DEL VIAJE', 'HORA DE SALIDA', 'SERVICIO', 'ASIENTO'];
  const values = [details.date, details.departure, details.service, ticket.seat_label ?? 'Sin asignar'];
  page.drawRectangle({ x: 38, y: 604, width: 519, height: 42, color: rgb(0.97, 0.98, 0.99), borderColor: line, borderWidth: 0.7 });
  for (let i = 0; i < 4; i++) {
    draw(labels[i], cols[i] + 8, 630, 7, false, muted);
    draw(values[i], cols[i] + 8, 613, 10, true);
    if (i > 0) page.drawLine({ start: { x: cols[i], y: 604 }, end: { x: cols[i], y: 646 }, thickness: 0.7, color: line });
  }

  draw('DATOS DEL PASAJERO', 38, 576, 9, true, brand);
  draw('NOMBRE Y APELLIDO', 38, 556, 7, false, muted);
  drawFit(ticket.passenger_name, 38, 538, 260, 11, true);
  draw('DOCUMENTO', 330, 556, 7, false, muted);
  draw(`DNI ${ticket.passenger_dni}`, 330, 538, 11, true);
  if (ticket.ticket_type !== 'regular') {
    const kind = ticket.ticket_type === 'courtesy' ? 'GENTILEZA' : 'DISCAPACIDAD';
    page.drawRectangle({ x: 38, y: 510, width: 106, height: 18, color: brandSoft });
    draw(kind, 46, 516, 8, true, brand);
  }
  page.drawLine({ start: { x: 38, y: 498 }, end: { x: 557, y: 498 }, thickness: 0.7, color: line });

  draw('DATOS DE LA COMPRA', 38, 478, 9, true, brand);
  page.drawRectangle({ x: 38, y: 402, width: 519, height: 62, color: rgb(0.97, 0.98, 0.99), borderColor: line, borderWidth: 0.7 });
  draw('NRO. DE COMPROBANTE', 50, 446, 7, false, muted);
  draw(receiptLabel(details.receiptNumber), 50, 424, 14, true, brand);
  draw('PUNTO DE VENTA', 218, 446, 7, false, muted);
  drawFit(details.channel, 218, 424, 155, 9, true);
  draw('MEDIO DE PAGO', 390, 446, 7, false, muted);
  drawFit(details.paymentMethod, 390, 424, 155, 9, true);
  draw('FECHA DE EMISION', 50, 411, 7, false, muted);
  draw(details.issueDate, 125, 411, 8, false);
  draw('RECORRIDO', 330, 411, 7, false, muted);
  drawFit(details.route, 390, 411, 155, 8, false);

  page.drawRectangle({ x: 38, y: 206, width: 519, height: 176, color: rgb(0.985, 0.993, 1), borderColor: line, borderWidth: 0.7 });
  draw('VALIDACION AL ABORDAR', 54, 353, 11, true, brand);
  draw('Escanea este codigo con el lector de la empresa.', 54, 334, 8, false, muted);
  draw('IMPORTE ABONADO', 54, 290, 8, true, muted);
  draw(`$ ${Number(ticket.price).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`, 54, 260, 22, true, brand);
  if (ticket.ticket_type !== 'regular') draw('PASAJE SIN CARGO', 54, 238, 9, true, brand);

  const qr = await QRCode.toBuffer(ticket.qr_code, { type: 'png', errorCorrectionLevel: 'M', margin: 1, width: 220 });
  const image = await pdf.embedPng(qr);
  page.drawImage(image, { x: 391, y: 220, width: 145, height: 145 });
  draw('INFORMACION PARA EL PASAJERO', 38, 178, 8, true, brand);
  draw('Presentate con anticipacion al horario indicado y lleva DNI para acreditar tu identidad.', 38, 162, 7, false, muted);
  draw('El pasaje puede presentarse en formato digital o impreso al abordar.', 38, 150, 7, false, muted);
  draw('DATOS OBLIGATORIOS: RESOLUCION 47/2005. PRESENTARSE CON DNI FISICO.', 38, 136, 6, true, brand);
  draw('CONDICIONES GENERALES', 38, 126, 7, true, brand);
  drawWrapped('1. DEVOLUCION DE PASAJES: (Res. 1317/53). Dentro de las 24 hs previas: 70%. Entre 48 hs y 24 hs: 80%. Mas de 48 hs: 90%. Unicamente al titular con DNI. 2. CANJE: No se admiten cambios de fecha/hora, solo devolucion bajo condiciones vigentes. 3. TARJETAS: Boletos con credito/debito no tienen devolucion en efectivo. 4. EQUIPAJE: Hasta 15 kg sin cargo (Res. 47/95). 5. EQUIPAJE DE MANO: Sin responsabilidad por perdida. 6. VALIDEZ: Solo valido con comprobante de control y en fecha/hora indicada. 7. MENORES: Menores de 5 años no pagan (sin asiento). Mayores de 5 abonaran pasaje completo. Res. SGT 43/2018. 8. ACEPTACION: La compra implica aceptacion de normas vigentes. 9. SEGURO: Responsabilidad Civil contratada. 10. ASIENTO: Sujeto a cambio por unidad. 11. CONTROL: Presentar al guarda/inspector si se requiere. 12. DNI: Obligatorio en servicios nacionales (Res. 76-E/2016).', 38, 115, 519, 6, 7.4, muted);
  page.drawLine({ start: { x: 38, y: 48 }, end: { x: 557, y: 48 }, thickness: 0.7, color: line });
  drawFit(`Canal: ${details.channel}  |  Comprobante ${receiptLabel(details.receiptNumber)}`, 38, 34, 515, 7, false, muted);
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
      routeId ? admin.from('routes').select('name, origin:places!routes_origin_place_id_fkey(name), destination:places!routes_destination_place_id_fkey(name)').eq('id', routeId).single() : Promise.resolve({ data: null, error: new Error('Route missing') }),
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
          origin: routeResult.data.origin?.name ?? '',
          destination: routeResult.data.destination?.name ?? '',
          date: new Date(`${tripResult.data.service_date}T12:00:00`).toLocaleDateString('es-AR'),
          departure: scheduled.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: 'America/Argentina/Buenos_Aires' }),
          from: stopNames.get(ticket.from_stop_id) ?? 'No disponible',
          to: stopNames.get(ticket.to_stop_id) ?? 'No disponible',
          receiptNumber: mine.data.receipt_number,
          channel: channelLabel(mine.data.channel),
          paymentMethod: paymentLabel(mine.data.payment_method),
          issueDate: new Date(mine.data.created_at).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: 'America/Argentina/Buenos_Aires' })
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
