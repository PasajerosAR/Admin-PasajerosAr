import QRCode from 'qrcode';

export interface PrintableTicket {
  qr_code: string; seat_label: string | null; price: number | string;
  passenger_name: string; passenger_dni: string; from: string; to: string;
  receiptNumber: number | string;
  salesChannel: string;
  paymentMethod: string;
  issueDate: string;
  ticket_type?: string;
}
export interface TripInfo { company: string; service: string; route: string; date: string; departure: string }
export type PrintFormat = 'ticket' | 'a4';

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
const money = (n: number | string) => `$ ${Number(n).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const receipt = (n: number | string) => String(n).padStart(8, '0');

/** A4 uses the institutional layout; ticket uses the compact 80 mm layout. */
export async function ticketsHtml(tickets: PrintableTicket[], info: TripInfo, format: PrintFormat): Promise<string> {
  const qrs = await Promise.all(tickets.map((t) => QRCode.toDataURL(t.qr_code, { errorCorrectionLevel: 'M', margin: 1, width: 240 })));
  const a4 = format === 'a4';
  const pages = tickets.map((t, i) => a4 ? `
    <section class="sheet a4">
      <header class="brand-header">
        <div><div class="eyebrow">SERVICIO INTERURBANO</div><h1>${esc(info.company)}</h1></div>
        <div class="document-label"><b>PASAJE ELECTRÓNICO</b><span>EMITIDO</span></div>
      </header>
      <div class="route-block">
        <div><span class="label">ORIGEN</span><strong>${esc(t.from)}</strong></div>
        <span class="route-arrow">→</span>
        <div><span class="label">DESTINO</span><strong>${esc(t.to)}</strong></div>
      </div>
      <div class="trip-grid">
        <div><span class="label">FECHA DEL VIAJE</span><b>${esc(info.date)}</b></div>
        <div><span class="label">HORA DE SALIDA</span><b>${esc(info.departure)}</b></div>
        <div><span class="label">SERVICIO</span><b>${esc(info.service)}</b></div>
        <div><span class="label">ASIENTO</span><b>${esc(t.seat_label ?? 'Sin asignar')}</b></div>
      </div>
      <section class="detail-section">
        <h2>DATOS DEL PASAJERO</h2>
        <div class="passenger-grid"><div><span class="label">NOMBRE Y APELLIDO</span><b>${esc(t.passenger_name)}</b></div><div><span class="label">DOCUMENTO</span><b>DNI ${esc(t.passenger_dni)}</b></div></div>
        ${t.ticket_type ? `<div class="ticket-kind">${esc(t.ticket_type)}</div>` : ''}
      </section>
      <section class="detail-section purchase-section">
        <h2>DATOS DE LA COMPRA</h2>
        <div class="purchase-grid">
          <div class="receipt-number"><span class="label">N.º DE COMPROBANTE</span><b>${receipt(t.receiptNumber)}</b></div>
          <div><span class="label">PUNTO DE VENTA</span><b>${esc(t.salesChannel)}</b></div>
          <div><span class="label">FECHA DE EMISIÓN</span><b>${esc(t.issueDate)}</b></div>
          <div><span class="label">MEDIO DE PAGO</span><b>${esc(t.paymentMethod)}</b></div>
        </div>
      </section>
      <div class="validation-block">
        <div class="validation-copy"><b>VALIDACIÓN AL ABORDAR</b><span>Escaneá este código con el lector de la empresa.</span><div class="amount-label">IMPORTE ABONADO</div><strong class="amount">${money(t.price)}</strong></div>
        <img class="qr" src="${qrs[i]}" alt="Código QR del pasaje">
      </div>
      <footer class="passenger-info"><b>INFORMACIÓN PARA EL PASAJERO</b><p>Presentate con anticipación al horario indicado. Llevá DNI para acreditar tu identidad. El pasaje debe presentarse en formato digital o impreso al abordar.</p></footer>
    </section>` : `
    <section class="sheet compact">
      <header class="compact-header"><div class="eyebrow">PASAJE ELECTRÓNICO</div><h1>${esc(info.company)}</h1><span>SERVICIO INTERURBANO</span></header>
      <div class="compact-receipt"><span>N.º COMPROBANTE</span><b>${receipt(t.receiptNumber)}</b></div>
      <div class="compact-route"><strong>${esc(t.from)}</strong><span>→</span><strong>${esc(t.to)}</strong></div>
      <div class="compact-trip"><b>${esc(info.date)} · ${esc(info.departure)}</b><span>Servicio ${esc(info.service)} · Asiento ${esc(t.seat_label ?? 'Sin asignar')}</span></div>
      <div class="compact-passenger"><span>PASAJERO</span><b>${esc(t.passenger_name)}</b><span>DNI ${esc(t.passenger_dni)}</span>${t.ticket_type ? `<b class="ticket-kind">${esc(t.ticket_type)}</b>` : ''}</div>
      <div class="compact-sale"><span>${esc(t.salesChannel)}</span><span>${esc(t.paymentMethod)}</span></div>
      <div class="compact-issued">Emitido: ${esc(t.issueDate)}</div>
      <img class="qr" src="${qrs[i]}" alt="Código QR del pasaje">
      <div class="compact-amount"><span>IMPORTE</span><b>${money(t.price)}</b></div>
      <footer>Presentá este QR al conductor para abordar.</footer>
    </section>`).join('');
  const pageStyle = a4
    ? '@page { size: A4; margin: 12mm } body { font-size: 12px } .sheet { width: 100%; max-width: 186mm; min-height: 260mm; margin: 0 auto }'
    : '@page { size: 80mm auto; margin: 3mm } body { width: 74mm; font-size: 11px } .sheet { width: 74mm }';
  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Pasajes</title><style>
    ${pageStyle}
    :root { --brand: #0f5c8c; --brand-soft: #e4f0f8; --ink: #20364a; --muted: #5c6c79; --line: #c8d4de }
    * { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact }
    body { font-family: Arial, Helvetica, sans-serif; color: var(--ink); margin: 0 }
    .sheet { page-break-after: always; break-after: page; background: #fff }
    .sheet:last-child { page-break-after: auto; break-after: auto }
    .label, .eyebrow { display: block; color: var(--muted); font-size: 9px; letter-spacing: .06em; margin-bottom: 5px }
    .brand-header { min-height: 72px; padding: 16px 20px; display: flex; justify-content: space-between; align-items: center; background: var(--brand); color: #fff; border-radius: 8px 8px 0 0 }
    .brand-header .eyebrow, .document-label span { color: #d9edf8; margin: 0 }
    h1 { font-size: 20px; line-height: 1.15; margin: 4px 0 0; overflow-wrap: anywhere }
    .document-label { display: grid; gap: 5px; text-align: right; font-size: 11px }
    .document-label span { font-size: 9px; letter-spacing: .08em }
    .route-block { display: grid; grid-template-columns: 1fr 28px 1fr; align-items: center; gap: 12px; padding: 20px; background: var(--brand-soft); border-bottom: 1px solid var(--line) }
    .route-block strong { display: block; font-size: 22px; overflow-wrap: anywhere }
    .route-arrow { text-align: center; font-size: 22px; color: var(--brand) }
    .trip-grid { display: grid; grid-template-columns: repeat(4, 1fr); border: 1px solid var(--line); margin: 16px 0; background: #f7fafc }
    .trip-grid > div, .purchase-grid > div { padding: 10px 12px; border-right: 1px solid var(--line) }
    .trip-grid > div:last-child, .purchase-grid > div:last-child { border-right: 0 }
    .trip-grid b, .purchase-grid b { display: block; font-size: 12px }
    .detail-section { margin: 14px 0 }
    .detail-section h2 { color: var(--brand); font-size: 10px; letter-spacing: .08em; margin: 0 0 8px }
    .passenger-grid { display: grid; grid-template-columns: 1fr 1fr; border-bottom: 1px solid var(--line); padding: 5px 0 12px }
    .passenger-grid b { display: block; font-size: 13px }
    .ticket-kind { display: inline-block; margin-top: 8px; padding: 4px 8px; color: var(--brand); background: var(--brand-soft); border-radius: 4px; font-size: 10px }
    .purchase-grid { display: grid; grid-template-columns: 1fr 1fr; border: 1px solid var(--line); background: #f7fafc }
    .purchase-grid > div { border-bottom: 1px solid var(--line) }
    .purchase-grid > div:nth-child(2n) { border-right: 0 }
    .purchase-grid > div:nth-last-child(-n+2) { border-bottom: 0 }
    .receipt-number b { color: var(--brand); font-size: 17px }
    .validation-block { display: flex; align-items: center; justify-content: space-between; gap: 14px; margin-top: 18px; padding: 14px 16px; border: 1px solid var(--line); background: #fbfdff }
    .validation-copy { display: grid; gap: 5px }
    .validation-copy > b { color: var(--brand); font-size: 12px }
    .validation-copy > span, .passenger-info p { color: var(--muted); font-size: 10px; line-height: 1.45 }
    .amount-label { margin-top: 8px; font-size: 9px; color: var(--muted) }
    .amount { color: var(--brand); font-size: 23px }
    .qr { display: block; width: 42mm; height: 42mm; object-fit: contain }
    .passenger-info { margin-top: 16px; padding-top: 10px; border-top: 1px solid var(--line); font-size: 9px }
    .passenger-info > b { color: var(--brand); letter-spacing: .06em }
    .passenger-info p { margin: 6px 0 0 }
    .compact { text-align: center; color: #182d3e }
    .compact-header { padding: 10px 4px 9px; border-bottom: 2px solid var(--brand) }
    .compact-header h1 { font-size: 16px; color: var(--brand); margin: 2px 0 }
    .compact-header .eyebrow, .compact-header > span { font-size: 8px; color: var(--muted); letter-spacing: .06em }
    .compact-receipt { display: flex; justify-content: space-between; align-items: center; padding: 8px; margin: 8px 0; color: var(--brand); background: var(--brand-soft); text-align: left }
    .compact-receipt span, .compact-sale { font-size: 9px; letter-spacing: .04em }
    .compact-receipt b { font-size: 15px }
    .compact-route { display: grid; grid-template-columns: 1fr 20px 1fr; gap: 4px; align-items: center; padding: 8px 0; font-size: 15px }
    .compact-route strong { overflow-wrap: anywhere }
    .compact-route span { color: var(--brand); font-size: 18px }
    .compact-trip { padding: 7px 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); display: grid; gap: 4px; font-size: 10px }
    .compact-passenger { display: grid; gap: 3px; padding: 8px 2px; text-align: left }
    .compact-passenger span { color: var(--muted); font-size: 9px }
    .compact-sale { display: flex; justify-content: space-between; gap: 4px; padding: 6px 0; border-top: 1px dashed var(--line); border-bottom: 1px dashed var(--line) }
    .compact-issued { padding-top: 5px; color: var(--muted); text-align: left; font-size: 9px }
    .compact .qr { width: 38mm; height: 38mm; margin: 9px auto }
    .compact-amount { display: flex; align-items: center; justify-content: space-between; padding: 7px 8px; background: var(--brand); color: #fff }
    .compact-amount span { font-size: 9px; letter-spacing: .06em }
    .compact-amount b { font-size: 16px }
    .compact footer { padding: 7px 0; color: var(--muted); font-size: 9px }
    @media print { .sheet { margin: 0 auto } }
  </style></head><body>${pages}</body></html>`;
}

/** Prints without opening a new window (which browsers may block), using a hidden iframe. */
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
