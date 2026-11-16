import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Notice, formatTime, todayLocal } from '../../ui';
import type { RouteStop, TicketPrice, PaymentMethod } from '../../lib/types';
import { PAYMENT_METHOD_LABEL } from '../../lib/types';
import { normalizeSeatClass } from '../../lib/seatGrid';

interface TripOption {
  id: string;
  scheduled_departure: string;
  status: string;
  layout_id: string | null;
  services: { code: string } | null;
  service_departures: { routes: { name: string } | null; route_id: string } | null;
}

interface PassengerForm {
  passenger_name: string;
  passenger_dni: string;
  passenger_email: string;
  passenger_phone: string;
  from_stop_id: string;
  to_stop_id: string;
  seat_label: string;
  layout_cell_id: string;
  is_complimentary: boolean;
}

const EMPTY_PAX: PassengerForm = {
  passenger_name: '', passenger_dni: '', passenger_email: '',
  passenger_phone: '', from_stop_id: '', to_stop_id: '',
  seat_label: '', layout_cell_id: '', is_complimentary: false,
};

export function SellTicketPage() {
  const [date, setDate]           = useState(todayLocal());
  const [tripId, setTripId]       = useState('');
  const [payment, setPayment]     = useState<PaymentMethod>('cash');
  const [notes, setNotes]         = useState('');
  const [passengers, setPassengers] = useState<PassengerForm[]>([{ ...EMPTY_PAX }]);
  const [msg, setMsg]             = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy]           = useState(false);
  const [lastSale, setLastSale]   = useState<{
    sale_id: string;
    total: number;
    tickets: { id: string; qr_code: string; passenger_name: string; seat_label: string | null }[];
    email?: { sent: number; failed: number; reason?: string };
  } | null>(null);

  const trips = useQuery(async () =>
    must(await supabase
      .from('trips')
      .select('id,scheduled_departure,status,layout_id,services(code),service_departures(routes(name),route_id)')
      .eq('service_date', date)
      .in('status', ['scheduled', 'in_progress'])
      .order('scheduled_departure')
    ) as unknown as TripOption[], [date]);

  const selectedTrip = trips.data?.find((t) => t.id === tripId);
  const routeId = selectedTrip?.service_departures?.route_id ?? '';

  const stops = useQuery(async () => {
    if (!routeId) return [];
    return must(await supabase
      .from('route_stops')
      .select('id,position,name')
      .eq('route_id', routeId)
      .order('position')
    ) as RouteStop[];
  }, [routeId]);

  const prices = useQuery(async () => {
    if (!routeId) return [];
    return must(await supabase
      .from('ticket_prices')
      .select('*')
      .eq('route_id', routeId)
      .eq('active', true)
    ) as TicketPrice[];
  }, [routeId]);

  const seats = useQuery(async () => {
    const layoutId = selectedTrip?.layout_id;
    if (!layoutId) return [];
    return must(await supabase.from('layout_cells')
      .select('id,label,seat_class,kind,blocked,unusable')
      .eq('layout_id', layoutId)
      .eq('kind', 'seat')
      .eq('blocked', false)
      .eq('unusable', false)
      .order('label')) as { id: string; label: string; seat_class: string | null }[];
  }, [selectedTrip?.layout_id]);

  const reservations = useQuery(async () => {
    if (!tripId) return [];
    return must(await supabase.from('sale_tickets')
      .select('seat_label,from_stop_id,to_stop_id,status')
      .eq('trip_id', tripId)
      .in('status', ['valid', 'boarded'])) as {
        seat_label: string | null; from_stop_id: string; to_stop_id: string; status: string;
      }[];
  }, [tripId]);

  const lookupPrice = (fromId: string, toId: string, cellId: string): number => {
    const fromPos = stops.data?.find((s) => s.id === fromId)?.position ?? 0;
    const toPos   = stops.data?.find((s) => s.id === toId)?.position ?? 0;
    const seatClass = seats.data?.find((seat) => seat.id === cellId)?.seat_class ?? null;
    const matches = prices.data?.filter((p) => p.from_pos === fromPos && p.to_pos === toPos) ?? [];
    const match = matches.find((p) => normalizeSeatClass(p.seat_class) === normalizeSeatClass(seatClass))
      ?? matches.find((p) => p.seat_class === null);
    return match ? Number(match.price) : 0;
  };

  const priceFor = (pax: PassengerForm) =>
    pax.is_complimentary ? 0 : lookupPrice(pax.from_stop_id, pax.to_stop_id, pax.layout_cell_id);

  const seatAvailable = (cellId: string, fromId: string, toId: string, excludeIdx = -1) => {
    const label = seats.data?.find((seat) => seat.id === cellId)?.label;
    const fromPos = stops.data?.find((stop) => stop.id === fromId)?.position ?? 0;
    const toPos = stops.data?.find((stop) => stop.id === toId)?.position ?? 0;
    if (!label || !fromPos || toPos <= fromPos) return true;
    const overlaps = (a: number, b: number) => a < toPos && b > fromPos;
    const reserved = (reservations.data ?? []).some((ticket) => {
      if (ticket.seat_label !== label) return false;
      const ticketFrom = stops.data?.find((stop) => stop.id === ticket.from_stop_id)?.position ?? 0;
      const ticketTo = stops.data?.find((stop) => stop.id === ticket.to_stop_id)?.position ?? 0;
      return overlaps(ticketFrom, ticketTo);
    });
    const duplicate = passengers.some((passenger, index) => index !== excludeIdx && passenger.layout_cell_id === cellId
      && overlaps(
        stops.data?.find((stop) => stop.id === passenger.from_stop_id)?.position ?? 0,
        stops.data?.find((stop) => stop.id === passenger.to_stop_id)?.position ?? 0
      ));
    return !reserved && !duplicate;
  };

  const updatePax = (idx: number, patch: Partial<PassengerForm>) => {
    setPassengers((prev) => {
      const next = [...prev];
      next[idx] = { ...next[idx], ...patch };
      return next;
    });
  };

  const addPassenger = () => setPassengers((p) => [...p, { ...EMPTY_PAX }]);
  const removePassenger = (idx: number) => setPassengers((p) => p.filter((_, i) => i !== idx));

  const total = passengers.reduce((sum, passenger) => sum + priceFor(passenger), 0);

  const submit = async () => {
    setMsg(null);
    if (!tripId) { setMsg({ kind: 'error', text: 'Seleccioná un viaje.' }); return; }
    for (const [idx, p] of passengers.entries()) {
      if (!p.passenger_name.trim()) { setMsg({ kind: 'error', text: 'Falta el nombre de un pasajero.' }); return; }
      if (!p.passenger_dni.trim())  { setMsg({ kind: 'error', text: 'Falta el DNI de un pasajero.' }); return; }
      if (!p.passenger_email.trim()) { setMsg({ kind: 'error', text: 'Falta el email de un pasajero.' }); return; }
      if (!p.passenger_phone.trim()) { setMsg({ kind: 'error', text: 'Falta el teléfono de un pasajero.' }); return; }
      if (!p.from_stop_id) { setMsg({ kind: 'error', text: 'Seleccioná parada de origen.' }); return; }
      if (!p.to_stop_id)   { setMsg({ kind: 'error', text: 'Seleccioná parada de destino.' }); return; }
      if (selectedTrip?.layout_id && !p.layout_cell_id && !p.is_complimentary) {
        setMsg({ kind: 'error', text: 'Seleccioná un asiento para cada pasajero.' }); return;
      }
      if (p.layout_cell_id && !seatAvailable(p.layout_cell_id, p.from_stop_id, p.to_stop_id, idx)) {
        setMsg({ kind: 'error', text: 'El asiento elegido ya está ocupado en ese tramo.' }); return;
      }
      if (!p.is_complimentary && priceFor(p) <= 0) {
        setMsg({ kind: 'error', text: 'No hay una tarifa activa para el tramo y la clase de asiento seleccionados.' }); return;
      }
    }
    const hasPaidTickets = passengers.some((passenger) => !passenger.is_complimentary);
    if (payment === 'complimentary' && hasPaidTickets) {
      setMsg({ kind: 'error', text: 'Una venta de cortesía solo puede contener pasajes gratuitos.' }); return;
    }
    if (payment !== 'complimentary' && !hasPaidTickets) {
      setMsg({ kind: 'error', text: 'Seleccioná “Cortesía” como medio de pago para pasajes gratuitos.' }); return;
    }
    setBusy(true);
    const { data, error } = await supabase.functions.invoke('create-sale-ticket', {
      body: { trip_id: tripId, payment_method: payment, notes, passengers }
    });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setLastSale(data as typeof lastSale);
    const email = (data as { email?: { sent: number; failed: number; reason?: string } }).email;
    setMsg({ kind: email?.failed ? 'error' : 'ok', text: `Venta registrada. Se generaron ${passengers.length} QR. ${
      email?.failed
        ? `No se enviaron ${email.failed} correos${email.reason ? ` (${email.reason})` : ''}.`
        : `Se enviaron ${email?.sent ?? 0} pasajes por correo.`
    }` });
    // Resetear formulario
    setPassengers([{ ...EMPTY_PAX }]);
    setNotes('');
  };

  if (lastSale) {
    return (
      <>
        <h1>Venta confirmada ✓</h1>
        <Notice kind={lastSale.email?.failed ? 'error' : 'ok'}>
          Venta #{lastSale.sale_id.slice(-8)} registrada por ${Number(lastSale.total).toFixed(2)}.
          {lastSale.email?.failed
            ? ` No se pudieron enviar ${lastSale.email.failed} pasajes por correo.`
            : ` Se enviaron ${lastSale.email?.sent ?? 0} PDF por correo.`}
        </Notice>
        <div className="card stack">
          <h2>Pasajes generados</h2>
          {lastSale.tickets.map((t) => (
            <div key={t.id} className="card" style={{ background: 'var(--bg)' }}>
              <div className="row" style={{ alignItems: 'center' }}>
                <div>
                  <b>{t.passenger_name}</b>
                  {t.seat_label && <span className="pill info" style={{ marginLeft: 8 }}>Asiento {t.seat_label}</span>}
                  <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>QR: <code>{t.qr_code}</code></div>
                </div>
                <button className="secondary" onClick={() => window.print()}>Imprimir</button>
              </div>
            </div>
          ))}
        </div>
        <div className="row">
          <button onClick={() => setLastSale(null)}>Nueva venta</button>
          <a href="/admin/ventas/pasajes"><button className="secondary">Ver todos los pasajes</button></a>
        </div>
      </>
    );
  }

  return (
    <>
      <h1>Vender pasaje</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      {/* Paso 1: Selección de viaje */}
      <div className="card stack">
        <h2>1. Seleccionar viaje</h2>
        <div className="row">
          <label>
            Fecha
            <input type="date" value={date} onChange={(e) => { setDate(e.target.value); setTripId(''); }} />
          </label>
          <label>
            Viaje
            <select value={tripId} onChange={(e) => setTripId(e.target.value)} required>
              <option value="">— Seleccioná —</option>
              {trips.loading && <option disabled>Cargando...</option>}
              {(trips.data ?? []).map((t) => (
                <option key={t.id} value={t.id}>
                  {t.services?.code} · {t.service_departures?.routes?.name} · {formatTime(t.scheduled_departure)}
                  {t.status === 'in_progress' ? ' (en curso)' : ''}
                </option>
              ))}
            </select>
          </label>
        </div>
      </div>

      {/* Paso 2: Pasajeros */}
      {tripId && (
        <div className="card stack">
          <h2>2. Pasajeros</h2>
          {!selectedTrip?.layout_id && <Notice kind="error">Este viaje no tiene una disposición de asientos asignada; los pasajes se emitirán sin asiento.</Notice>}
          {passengers.map((pax, idx) => (
            <div key={idx} className="card" style={{ background: 'var(--bg)', position: 'relative' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
                <b>Pasajero {idx + 1}</b>
                {passengers.length > 1 && (
                  <button className="danger" style={{ minHeight: 32, padding: '0 10px', fontSize: 12 }}
                    onClick={() => removePassenger(idx)}>✕ Quitar</button>
                )}
              </div>
              <div className="row">
                <label>Nombre y apellido
                  <input value={pax.passenger_name} required
                    onChange={(e) => updatePax(idx, { passenger_name: e.target.value })} />
                </label>
                <label>DNI
                  <input value={pax.passenger_dni} inputMode="numeric" required
                    onChange={(e) => updatePax(idx, { passenger_dni: e.target.value })} />
                </label>
              </div>
              <div className="row">
                <label>Email
                  <input type="email" value={pax.passenger_email} required
                    onChange={(e) => updatePax(idx, { passenger_email: e.target.value })} />
                </label>
                <label>Teléfono
                  <input value={pax.passenger_phone} inputMode="tel" required
                    onChange={(e) => updatePax(idx, { passenger_phone: e.target.value })} />
                </label>
              </div>
              <div className="row">
                <label>
                  Parada origen
                  <select value={pax.from_stop_id} required
                    onChange={(e) => updatePax(idx, { from_stop_id: e.target.value })}>
                    <option value="">—</option>
                    {(stops.data ?? []).map((s) => (
                      <option key={s.id} value={s.id}>{s.position}. {s.name}</option>
                    ))}
                  </select>
                </label>
                <label>
                  Parada destino
                  <select value={pax.to_stop_id} required
                    onChange={(e) => updatePax(idx, { to_stop_id: e.target.value })}>
                    <option value="">—</option>
                    {(stops.data ?? []).map((s) => (
                      <option key={s.id} value={s.id}>{s.position}. {s.name}</option>
                    ))}
                  </select>
                </label>
                {selectedTrip?.layout_id && (
                  <label>Asiento
                    <select value={pax.layout_cell_id}
                      onChange={(e) => {
                        const seat = seats.data?.find((item) => item.id === e.target.value);
                        updatePax(idx, { layout_cell_id: seat?.id ?? '', seat_label: seat?.label ?? '' });
                      }}>
                      <option value="">— Seleccioná —</option>
                      {(seats.data ?? []).map((seat) => {
                        const available = seatAvailable(seat.id, pax.from_stop_id, pax.to_stop_id, idx);
                        return (
                          <option key={seat.id} value={seat.id} disabled={!available}>
                            {seat.label}{seat.seat_class ? ` · ${seat.seat_class}` : ''}{available ? '' : ' · ocupado'}
                          </option>
                        );
                      })}
                    </select>
                  </label>
                )}
              </div>
              <div className="row" style={{ alignItems: 'center' }}>
                <label style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flex: '0 0 auto' }}>
                  <input type="checkbox" checked={pax.is_complimentary}
                    onChange={(e) => updatePax(idx, { is_complimentary: e.target.checked })} />
                  QR de cortesía (precio $0)
                </label>
                <label>
                  Precio ($) · calculado por tarifa
                  <input value={priceFor(pax).toFixed(2)} readOnly />
                </label>
                {pax.from_stop_id && pax.to_stop_id && !pax.is_complimentary && priceFor(pax) === 0 && (
                  <span className="muted" style={{ fontSize: 12 }}>⚠ No hay tarifa configurada para este tramo.</span>
                )}
              </div>
            </div>
          ))}
          <button className="secondary" onClick={addPassenger} style={{ alignSelf: 'flex-start' }}>
            + Agregar pasajero
          </button>
        </div>
      )}

      {/* Paso 3: Pago */}
      {tripId && (
        <div className="card stack">
          <h2>3. Pago</h2>
          <div className="row">
            <label>
              Medio de pago
              <select value={payment} onChange={(e) => setPayment(e.target.value as PaymentMethod)}>
                {(Object.entries(PAYMENT_METHOD_LABEL) as [PaymentMethod, string][]).map(([k, v]) => (
                  <option key={k} value={k}>{v}</option>
                ))}
              </select>
            </label>
            <label>
              Notas (opcional)
              <input value={notes} placeholder="ej: referencia de transferencia"
                onChange={(e) => setNotes(e.target.value)} />
            </label>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', paddingTop: 8, borderTop: '1px solid var(--line)' }}>
            <div>
              <span className="muted">Total: </span>
              <b style={{ fontSize: 22 }}>${total.toFixed(2)}</b>
              <span className="muted" style={{ marginLeft: 8 }}>· {passengers.length} pasajero{passengers.length !== 1 ? 's' : ''}</span>
            </div>
            <button onClick={submit} disabled={busy} style={{ minWidth: 160 }}>
              {busy ? 'Procesando...' : 'Confirmar venta'}
            </button>
          </div>
        </div>
      )}
    </>
  );
}
