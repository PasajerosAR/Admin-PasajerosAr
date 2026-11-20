import { useEffect, useMemo, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice, formatTime, todayLocal } from '../../ui';
import type { RouteStop } from '../../lib/types';
import {
  columnTemplate, formatMoney, priceFor, seatClassName, seatOccupied, seatState, summarize,
  type TaquillaCell, type TaquillaPrice, type TaquillaRange
} from '../../lib/taquilla';
import { printTickets, type PrintFormat, type PrintableTicket } from '../../lib/ticketPrint';
import { SearchSelect } from '../SearchSelect';

type Method = 'cash' | 'debit' | 'credit' | 'transfer';
type TicketKind = 'regular' | 'courtesy' | 'disability';
const METHODS: { key: Method; label: string }[] = [
  { key: 'cash', label: 'Efectivo' }, { key: 'debit', label: 'Débito' }, { key: 'credit', label: 'Crédito' }, { key: 'transfer', label: 'Transferencia' }
];
const REFRESH_MS = 8000;
const CELL_LABEL: Record<string, string> = { door: 'Puerta', stairs: 'Escalera', driver: 'Conductor', toilet: 'Baño', trunk: 'Bodega' };

interface TripOption {
  id: string; scheduled_departure: string; status: string; layout_id: string | null;
  services: { code: string } | null; service_departures: { route_id: string; routes: { name: string; origin: { name: string } | null; destination: { name: string } | null } | null } | null;
}
interface Pax { dni: string; name: string; email: string; ticketKind?: TicketKind; found?: string }
interface SoldTicket {
  id: string; qr_code: string; seat_label: string; price: number; passenger_name: string; passenger_dni: string;
  email: string | null; from_stop_id: string; to_stop_id: string; ticket_type: TicketKind;
}
interface Sale { sale_id: string; total: number; tickets: SoldTicket[]; email?: { sent: number; failed: number; reason?: string } | null; method: Method | 'complimentary'; receipt_number: number; channel: 'counter' | 'web'; created_at: string }

export function VentanillaPage() {
  const [date, setDate] = useState(todayLocal());
  const [tripId, setTripId] = useState('');
  const [fromId, setFromId] = useState('');
  const [toId, setToId] = useState('');
  const [floor, setFloor] = useState(1);
  const [picked, setPicked] = useState<string[]>([]);
  const [method, setMethod] = useState<Method>('cash');
  const [pax, setPax] = useState<Record<string, Pax>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sale, setSale] = useState<Sale | null>(null);
  const [format, setFormat] = useState<PrintFormat>(() => { try { return window.localStorage.getItem('ventanilla.format') === 'a4' ? 'a4' : 'ticket'; } catch { return 'ticket'; } });
  const [holdUntil, setHoldUntil] = useState<number | null>(null);
  const [now, setNow] = useState(Date.now());

  const trips = useQuery(async () => must(await supabase.from('trips')
    .select('id,scheduled_departure,status,layout_id,services(code),service_departures(route_id,routes(name,origin:places!routes_origin_place_id_fkey(name),destination:places!routes_destination_place_id_fkey(name)))')
    .eq('service_date', date).in('status', ['scheduled', 'in_progress']).order('scheduled_departure')) as unknown as TripOption[], [date]);
  const trip = trips.data?.find((t) => t.id === tripId);
  const routeId = trip?.service_departures?.route_id ?? '';
  const layoutId = trip?.layout_id ?? null;

  const company = useQuery(async () => must(await supabase.from('companies').select('name').limit(1)) as { name: string }[], []);
  const stops = useQuery(async () => routeId ? must(await supabase.from('route_stops').select('id,route_id,position,name').eq('route_id', routeId).order('position')) as RouteStop[] : [], [routeId]);
  const cells = useQuery(async () => layoutId ? must(await supabase.from('layout_cells')
    .select('id,floor,row_idx,col_idx,kind,label,seat_class,blocked,unusable').eq('layout_id', layoutId)) as TaquillaCell[] : [], [layoutId]);
  const floors = useQuery(async () => layoutId ? must(await supabase.from('layout_floors').select('floor,rows,cols').eq('layout_id', layoutId).order('floor')) as { floor: number; rows: number; cols: number }[] : [], [layoutId]);
  const prices = useQuery(async () => routeId ? must(await supabase.from('ticket_prices').select('from_pos,to_pos,price,seat_class').eq('route_id', routeId).eq('active', true)) as TaquillaPrice[] : [], [routeId]);
  const reservations = useQuery(async () => tripId ? must(await supabase.rpc('taquilla_seat_status', { p_trip: tripId })) as TaquillaRange[] : [], [tripId]);
  const reloadRanges = reservations.reload;
  useEffect(() => {
    const id = window.setInterval(() => { if (!document.hidden) reloadRanges(); }, REFRESH_MS);
    return () => window.clearInterval(id);
  }, [reloadRanges]);

  // al cambiar de viaje: tramo completo por defecto
  const stopList = stops.data ?? [];
  useEffect(() => {
    setPicked([]); setPax({}); setSale(null); setError(null); setFloor(1);
    setFromId(stopList[0]?.id ?? ''); setToId(stopList[stopList.length - 1]?.id ?? '');
  }, [tripId, stopList.length]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setPicked([]); }, [fromId, toId]);
  // al salir se libera lo reservado
  useEffect(() => () => { if (tripId) void supabase.rpc('taquilla_hold_seats', { p_trip: tripId, p_seats: [] }); }, [tripId]);
  useEffect(() => {
    if (holdUntil === null) return;
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [holdUntil]);

  const posOf = (id: string) => stopList.find((s) => s.id === id)?.position ?? 0;
  const fromPos = posOf(fromId); const toPos = posOf(toId);
  const validTrip = fromPos > 0 && toPos > fromPos;

  const all = cells.data ?? [];
  const floorList = floors.data ?? [];
  const dims = floorList.find((f) => f.floor === floor) ?? floorList[0];
  const floorCells = useMemo(() => all.filter((c) => c.floor === (dims?.floor ?? 1)), [all, dims?.floor]);
  const cellAt = useMemo(() => new Map(floorCells.map((c) => [`${c.row_idx}:${c.col_idx}`, c])), [floorCells]);
  const stateOf = (c: TaquillaCell) => seatState(
    c, validTrip && seatOccupied(reservations.data ?? [], c.label, fromPos, toPos),
    validTrip ? priceFor(prices.data ?? [], fromPos, toPos, c.seat_class) : null, picked.includes(c.id));
  const chosen = picked.map((id) => all.find((c) => c.id === id)).filter((c): c is TaquillaCell => !!c)
    .map((c) => {
      const label = c.label ?? '?';
      const ticketKind = pax[label]?.ticketKind ?? 'regular';
      const fare = priceFor(prices.data ?? [], fromPos, toPos, c.seat_class) ?? 0;
      return { label, seatClass: seatClassName(c), fare, ticketKind, price: ticketKind === 'regular' ? fare : 0 };
    })
    .sort((a, b) => a.label.localeCompare(b.label, 'es', { numeric: true }));
  const total = chosen.reduce((n, s) => n + s.price, 0);
  const floorClass = (n: number) => {
    const classes = [...new Set(all.filter((c) => c.floor === n && c.kind === 'seat' && !c.blocked && !c.unusable).map(seatClassName))];
    return classes.length === 0 ? '' : classes.length === 1 ? classes[0] : 'Varios tipos';
  };

  // reserva unos minutos lo elegido (compartido con la taquilla del conductor y la web)
  const pickedLabels = chosen.map((c) => c.label).join('|');
  const holdSeq = useRef(0);
  useEffect(() => {
    const seq = ++holdSeq.current;
    if (!validTrip || !tripId) return;
    const seats = pickedLabels ? pickedLabels.split('|').map((l) => ({ seat_label: l, from_stop_id: fromId, to_stop_id: toId })) : [];
    void supabase.rpc('taquilla_hold_seats', { p_trip: tripId, p_seats: seats }).then(({ data, error: err }) => {
      if (seq !== holdSeq.current) return;
      if (err) { setError(friendly(err)); setHoldUntil(null); reloadRanges(); return; }
      setHoldUntil(data ? new Date(data as string).getTime() : null);
    });
  }, [pickedLabels, fromId, toId, tripId, validTrip, reloadRanges]);
  const holdLeft = holdUntil === null ? null : Math.max(Math.ceil((holdUntil - now) / 1000), 0);
  const minutes = (s: number) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;

  const toggle = (c: TaquillaCell) => {
    const state = stateOf(c);
    if (state === 'busy' || state === 'off') return;
    setError(null);
    setPicked((p) => (p.includes(c.id) ? p.filter((id) => id !== c.id) : [...p, c.id]));
  };
  const setField = (label: string, patch: Partial<Pax>) => setPax((p) => ({ ...p, [label]: { ...(p[label] ?? { dni: '', name: '', email: '' }), ...patch } }));
  // al terminar el DNI se busca al pasajero (cuenta de la web o pasaje anterior)
  const lookup = async (label: string) => {
    const dni = (pax[label]?.dni ?? '').replace(/\D/g, '');
    if (dni.length < 6) return;
    const { data } = await supabase.rpc('ventanilla_find_passenger', { p_dni: dni });
    const hit = (data as { full_name: string; email: string | null; source: string }[] | null)?.[0];
    if (!hit) return;
    setPax((p) => {
      const cur = p[label] ?? { dni, name: '', email: '' };
      return { ...p, [label]: { ...cur, name: cur.name || hit.full_name, email: cur.email || hit.email || '', found: hit.source === 'web' ? 'Cuenta de la web' : 'Pasajero anterior' } };
    });
  };

  const stopName = (id: string) => stopList.find((s) => s.id === id)?.name ?? '';
  const info = () => ({
    company: company.data?.[0]?.name ?? '', service: trip?.services?.code ?? '', route: trip?.service_departures?.routes?.name ?? '',
    origin: trip?.service_departures?.routes?.origin?.name ?? '', destination: trip?.service_departures?.routes?.destination?.name ?? '',
    date: new Date(`${date}T12:00:00`).toLocaleDateString('es-AR'), departure: trip ? formatTime(trip.scheduled_departure) : ''
  });
  const printable = (s: Sale): PrintableTicket[] => s.tickets.map((t) => ({
    qr_code: t.qr_code, seat_label: t.seat_label, price: t.price, passenger_name: t.passenger_name, passenger_dni: t.passenger_dni,
    from: stopName(t.from_stop_id), to: stopName(t.to_stop_id),
    receiptNumber: s.receipt_number, salesChannel: s.channel === 'web' ? 'Web · Punto de venta' : 'Ventanilla',
    paymentMethod: s.method === 'complimentary' ? 'Sin cargo' : METHODS.find((m) => m.key === s.method)?.label ?? s.method,
    issueDate: new Date(s.created_at).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Argentina/Buenos_Aires' }),
    ticket_type: t.ticket_type === 'courtesy' ? 'Gentileza' : t.ticket_type === 'disability' ? 'Discapacidad' : undefined
  }));
  const print = async (s: Sale) => {
    try { await printTickets(printable(s), info(), format); } catch (e) { setError(friendly(e)); }
  };

  const sell = async () => {
    if (busy || chosen.length === 0) return;
    const bad = chosen.find((s) => (pax[s.label]?.name ?? '').trim().length < 2 || (pax[s.label]?.dni ?? '').replace(/\D/g, '').length < 6);
    if (bad) { setError(`Cargá nombre y apellido y DNI del pasajero del asiento ${bad.label}.`); return; }
    setBusy(true); setError(null);
    try {
      const seats = chosen.map((s) => ({
        seat_label: s.label, from_stop_id: fromId, to_stop_id: toId,
        passenger_name: pax[s.label].name.trim(), passenger_dni: pax[s.label].dni.replace(/\D/g, ''),
        passenger_email: (pax[s.label].email ?? '').trim(), ticket_type: s.ticketKind
      }));
      const r = must(await supabase.rpc('taquilla_sell', { p_trip: tripId, p_payment_method: method, p_seats: seats })) as { sale_id: string; total: number; tickets: SoldTicket[] };
      const saleMeta = must(await supabase.from('sales').select('receipt_number,channel,created_at').eq('id', r.sale_id).single()) as Pick<Sale, 'receipt_number' | 'channel' | 'created_at'>;
      const done: Sale = { ...r, ...saleMeta, method: r.total === 0 ? 'complimentary' : method, email: null };
      setSale(done); setPicked([]); setPax({}); setHoldUntil(null); reloadRanges();
      void print(done);   // sale la impresión en el momento
      if (r.tickets.some((t) => t.email)) {
        const res = await supabase.functions.invoke('email-tickets', { body: { sale_id: r.sale_id } });
        const out = (res.data ?? { sent: 0, failed: 1 }) as { sent: number; failed: number; reason?: string };
        setSale((cur) => (cur ? { ...cur, email: res.error ? { sent: 0, failed: 1, reason: 'EMAIL_SEND_FAILED' } : out } : cur));
      }
    } catch (e) {
      setError(friendly(e)); reloadRanges();
    } finally { setBusy(false); }
  };

  const tripOptions = (trips.data ?? []).map((t) => ({
    value: t.id,
    label: `${formatTime(t.scheduled_departure)} · #${t.services?.code ?? '-'} · ${t.service_departures?.routes?.name ?? ''}${t.status === 'in_progress' ? ' (en curso)' : ''}`
  }));
  const loading = cells.loading || floors.loading || prices.loading || stops.loading || (reservations.loading && !reservations.data);

  return (
    <>
      <h1>Ventanilla</h1>
      <p className="muted">Vendé pasajes con los mismos asientos y tarifas que la web y la taquilla del conductor.</p>
      {error && <Notice kind="error">{error}</Notice>}

      {sale && (
        <div className="card stack">
          <h2>Venta registrada · {formatMoney(sale.total)}</h2>
          <p className="muted">{sale.method === 'complimentary' ? 'Sin cargo' : METHODS.find((m) => m.key === sale.method)?.label} · {sale.tickets.length} pasaje{sale.tickets.length === 1 ? '' : 's'}: {sale.tickets.map((t) => `${t.passenger_name} (asiento ${t.seat_label}${t.ticket_type === 'courtesy' ? ', gentileza' : t.ticket_type === 'disability' ? ', discapacidad' : ''})`).join(', ')}</p>
          {sale.email && <Notice kind={sale.email.failed ? 'error' : 'ok'}>{sale.email.failed ? `No se pudieron enviar ${sale.email.failed} correos${sale.email.reason === 'RESEND_NOT_CONFIGURED' ? ' (el envío de correos no está configurado)' : ''}.` : `Se enviaron ${sale.email.sent} pasajes por correo.`}</Notice>}
          <div className="row">
            <button type="button" onClick={() => void print(sale)}>Imprimir de nuevo</button>
            <button type="button" className="secondary" onClick={() => setSale(null)}>Nueva venta</button>
          </div>
        </div>
      )}

      <div className="card stack">
        <div className="row">
          <label>Fecha<input type="date" value={date} onChange={(e) => { setDate(e.target.value); setTripId(''); }} /></label>
          <label className="grow">Viaje
            <SearchSelect options={tripOptions} value={tripId} onChange={setTripId} placeholder={trips.loading ? 'Cargando...' : 'Buscar por hora, servicio o recorrido'} emptyLabel="No hay viajes para esta fecha" />
          </label>
        </div>
        {trips.error && <Notice>{trips.error}</Notice>}
      </div>

      {trip && (
        <div className="card stack">
          <div className="row">
            <label>Sube en
              <select value={fromId} onChange={(e) => setFromId(e.target.value)}>{stopList.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
            </label>
            <label>Baja en
              <select value={toId} onChange={(e) => setToId(e.target.value)}>{stopList.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
            </label>
          </div>
          {!validTrip && <Notice kind="warn">La parada de bajada tiene que ser posterior a la de subida.</Notice>}
          {!trip.layout_id && <Notice kind="warn">Este viaje no tiene una disposición de asientos asignada.</Notice>}
          {loading ? <Loading /> : (
            <>
              {floorList.length > 1 && (
                <div className="vt-floors" role="tablist" aria-label="Piso">
                  {floorList.map((f) => (
                    <button key={f.floor} type="button" role="tab" aria-selected={(dims?.floor ?? 1) === f.floor}
                      className={(dims?.floor ?? 1) === f.floor ? 'is-active' : ''} onClick={() => setFloor(f.floor)}>
                      Piso {f.floor}<small>{floorClass(f.floor)}</small>
                    </button>
                  ))}
                </div>
              )}
              <div className="vt-legend"><span><i className="free" />Disponible</span><span><i className="busy" />Ocupado</span><span><i className="off" />No habilitado</span><span><i className="selected" />Elegido</span></div>
              {dims && (
                <div className="vt-plan" style={{ gridTemplateColumns: columnTemplate(floorCells, dims.cols) }}>
                  {Array.from({ length: dims.rows * dims.cols }, (_, i) => {
                    const row = Math.floor(i / dims.cols); const col = i % dims.cols;
                    const c = cellAt.get(`${row}:${col}`);
                    if (!c || c.kind === 'empty' || c.kind === 'aisle') return <div key={i} />;
                    if (c.kind !== 'seat') return <div key={i} className="vt-cell">{CELL_LABEL[c.kind] ?? ''}</div>;
                    const state = stateOf(c);
                    return (
                      <button key={i} type="button" className={`vt-seat ${state}`} aria-pressed={state === 'selected'} disabled={state === 'busy' || state === 'off'}
                        title={`${seatClassName(c)}${state === 'busy' ? ' · ocupado' : ''}`} onClick={() => toggle(c)}>{c.label}</button>
                    );
                  })}
                </div>
              )}
              <p className="muted">En gris: asientos bloqueados o sin tarifa para este tramo.</p>
            </>
          )}
        </div>
      )}

      {trip && chosen.length > 0 && (
        <div className="card stack">
          <h2>Pasajeros</h2>
          {chosen.map((s) => (
            <div key={s.label} className="vt-pax">
              <b>Asiento {s.label}</b><span className="muted">{s.seatClass} · {formatMoney(s.price)}</span>
              <label>Tipo de pasaje
                <select value={pax[s.label]?.ticketKind ?? 'regular'} onChange={(e) => setField(s.label, { ticketKind: e.target.value as TicketKind })}>
                  <option value="regular">Regular · {formatMoney(s.fare)}</option>
                  <option value="courtesy">Gentileza · sin cargo</option>
                  <option value="disability">Discapacidad · sin cargo</option>
                </select>
              </label>
              <input aria-label={`DNI, asiento ${s.label}`} placeholder="DNI" inputMode="numeric" maxLength={12} value={pax[s.label]?.dni ?? ''}
                onChange={(e) => setField(s.label, { dni: e.target.value })} onBlur={() => void lookup(s.label)} />
              <input aria-label={`Nombre y apellido, asiento ${s.label}`} placeholder="Nombre y apellido" maxLength={150} value={pax[s.label]?.name ?? ''}
                onChange={(e) => setField(s.label, { name: e.target.value })} />
              <input aria-label={`Correo, asiento ${s.label}`} placeholder="Correo (opcional)" type="email" maxLength={200} value={pax[s.label]?.email ?? ''}
                onChange={(e) => setField(s.label, { email: e.target.value })} />
              {pax[s.label]?.found && <small className="muted">{pax[s.label]?.found}</small>}
            </div>
          ))}
          <div className="vt-summary">
            {summarize(chosen).map((r) => <div key={r.seatClass}><span>{r.seatClass} × {r.count}</span><b>{formatMoney(r.subtotal)}</b></div>)}
            <div className="vt-total"><span>Total</span><b>{formatMoney(total)}</b></div>
          </div>
          {holdLeft !== null && <p className="muted">{holdLeft > 0 ? `Asientos reservados ${minutes(holdLeft)}` : 'La reserva venció: otro puede tomar estos asientos.'}</p>}
          <div className="vt-methods" role="radiogroup" aria-label="Forma de pago">
            {METHODS.map((m) => <button key={m.key} type="button" role="radio" aria-checked={method === m.key} className={method === m.key ? 'is-active' : ''} onClick={() => setMethod(m.key)}>{m.label}</button>)}
            <button type="button" role="radio" aria-checked={false} disabled title="Próximamente">QR Mercado Pago (próximamente)</button>
          </div>
          <div className="row">
            <label>Imprimir en
              <select value={format} onChange={(e) => { const v = e.target.value as PrintFormat; setFormat(v); try { window.localStorage.setItem('ventanilla.format', v); } catch { /* sin almacenamiento */ } }}>
                <option value="ticket">Ticket 80 mm</option><option value="a4">Hoja A4</option>
              </select>
            </label>
            <button type="button" disabled={busy || !validTrip} onClick={() => void sell()}>{busy ? 'Registrando...' : `Cobrar e imprimir · ${formatMoney(total)}`}</button>
          </div>
        </div>
      )}
    </>
  );
}
