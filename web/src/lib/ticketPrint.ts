import QRCode from 'qrcode';

export interface PrintableTicket {
  qr_code: string; seat_label: string | null; price: number | string;
  passenger_name: string; passenger_dni: string; from: string; to: string;
}
export interface TripInfo { company: string; service: string; route: string; date: string; departure: string }
export type PrintFormat = 'ticket' | 'a4';

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
const money = (n: number | string) => `$ ${Number(n).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** HTML imprimible: un pasaje por hoja. 'ticket' = rollo de 80 mm, 'a4' = hoja comun. */
export async function ticketsHtml(tickets: PrintableTicket[], info: TripInfo, format: PrintFormat): Promise<string> {
  const qrs = await Promise.all(tickets.map((t) => QRCode.toDataURL(t.qr_code, { errorCorrectionLevel: 'M', margin: 1, width: 240 })));
  const page = format === 'ticket'
    ? '@page { size: 80mm auto; margin: 3mm } body { width: 74mm; font-size: 11px } .qr { width: 42mm }'
    : '@page { size: A4; margin: 15mm } body { width: 150mm; margin: 0 auto; font-size: 14px } .qr { width: 60mm }';
  const sheets = tickets.map((t, i) => `
    <section>
      <h1>${esc(info.company)}</h1>
      <h2>Pasaje · Servicio ${esc(info.service)}</h2>
      <p>${esc(info.route)}</p>
      <p><b>${esc(info.date)}</b> · Salida <b>${esc(info.departure)}</b></p>
      <p>Origen: <b>${esc(t.from)}</b><br>Destino: <b>${esc(t.to)}</b></p>
      <p>Pasajero: <b>${esc(t.passenger_name)}</b><br>DNI: ${esc(t.passenger_dni)}</p>
      <p>Asiento: <b>${esc(t.seat_label ?? 'Sin asignar')}</b> · Precio: <b>${money(t.price)}</b></p>
      <img class="qr" src="${qrs[i]}" alt="QR del pasaje">
      <p class="small">Presentá este QR al conductor para abordar.</p>
    </section>`).join('');
  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Pasajes</title><style>
    ${page}
    body { font-family: Arial, Helvetica, sans-serif; color: #111; margin: 0 }
    section { page-break-after: always; text-align: center; padding: 4px 0 }
    section:last-child { page-break-after: auto }
    h1 { font-size: 1.3em; margin: 0 0 4px } h2 { font-size: 1.1em; margin: 0 0 6px }
    p { margin: 4px 0 } .small { font-size: .85em; color: #444 } .qr { display: block; margin: 6px auto }
  </style></head><body>${sheets}</body></html>`;
}

/** Imprime sin abrir ventanas nuevas (no las bloquea el navegador): usa un iframe oculto. */
export async function printTickets(tickets: PrintableTicket[], info: TripInfo, format: PrintFormat): Promise<void> {
  const html = await ticketsHtml(tickets, info, format);
  const frame = document.createElement('iframe');
  frame.setAttribute('aria-hidden', 'true');
  frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0';
  document.body.appendChild(frame);
  const doc = frame.contentDocument;
  if (!doc || !frame.contentWindow) { frame.remove(); throw new Error('No se pudo preparar la impresión.'); }
  doc.open(); doc.write(html); doc.close();
  await new Promise<void>((resolve) => { frame.onload = () => resolve(); window.setTimeout(resolve, 400); });
  frame.contentWindow.focus();
  frame.contentWindow.print();
  window.setTimeout(() => frame.remove(), 60_000);
}
