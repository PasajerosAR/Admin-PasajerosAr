import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice, formatTime, todayLocal } from '../../ui';
import type { PaymentMethod, SaleTicket } from '../../lib/types';
import { PAYMENT_METHOD_LABEL, TICKET_STATUS_LABEL } from '../../lib/types';
import { RefundModal } from './RefundModal';
import { useAuth } from '../../auth/AuthProvider';
import { printTickets } from '../../lib/ticketPrint';
import { friendly } from '../../lib/errors';

interface TicketRow extends SaleTicket {
  sales: {
    payment_method: PaymentMethod;
    created_at: string;
    channel: 'counter' | 'web';
    receipt_number: number;
    notes: string | null;
    seller: { full_name: string } | null;
  } | null;
  trips: {
    scheduled_departure: string;
    service_date: string;
    services: { code: string } | null;
    service_departures: { routes: { name: string } | null } | null;
  } | null;
  from_stop: { name: string } | null;
  to_stop:   { name: string } | null;
}

export function TicketsPage() {
  const { profile } = useAuth();
  const [search, setSearch]   = useState('');
  const [dateFrom, setDateFrom] = useState(todayLocal());
  const [dateTo, setDateTo]   = useState(todayLocal());
  const [statusFilter, setStatusFilter] = useState<SaleTicket['status'] | 'all'>('all');
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const tickets = useQuery(async () => {
    let q = supabase
      .from('sale_tickets')
      .select(`
        *,
        sales(payment_method, created_at, channel, receipt_number, notes, seller:profiles!sales_seller_id_fkey(full_name)),
        trips(scheduled_departure, service_date, services(code), service_departures(routes(name))),
        from_stop:route_stops!sale_tickets_from_stop_id_fkey(name),
        to_stop:route_stops!sale_tickets_to_stop_id_fkey(name)
      `)
      .gte('created_at', `${dateFrom}T00:00:00`)
      .lte('created_at', `${dateTo}T23:59:59`)
      .order('created_at', { ascending: false });
    if (statusFilter !== 'all') q = q.eq('status', statusFilter);
    return must(await q) as unknown as TicketRow[];
  }, [dateFrom, dateTo, statusFilter]);

  const company = useQuery(async () => must(await supabase.from('companies').select('name').limit(1)) as { name: string }[], []);
  const reprint = async (t: TicketRow) => {
    try {
      await printTickets([{
        qr_code: t.qr_code, seat_label: t.seat_label, price: t.price, passenger_name: t.passenger_name, passenger_dni: t.passenger_dni,
        from: t.from_stop?.name ?? '', to: t.to_stop?.name ?? '',
        receiptNumber: t.sales?.receipt_number ?? t.id.slice(0, 8),
        salesChannel: t.sales?.channel === 'web' ? 'Web · Punto de venta' : t.sales?.notes === 'Venta en taquilla' ? 'Taquilla del conductor' : 'Ventanilla',
        paymentMethod: t.sales ? PAYMENT_METHOD_LABEL[t.sales.payment_method] : 'No disponible',
        issueDate: t.sales ? new Date(t.sales.created_at).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Argentina/Buenos_Aires' }) : '',
        ticket_type: t.ticket_type === 'courtesy' ? 'Gentileza' : t.ticket_type === 'disability' ? 'Discapacidad' : undefined
      }], {
        company: company.data?.[0]?.name ?? '', service: t.trips?.services?.code ?? '', route: t.trips?.service_departures?.routes?.name ?? '',
        date: t.trips ? new Date(`${t.trips.service_date}T12:00:00`).toLocaleDateString('es-AR') : '',
        departure: t.trips ? formatTime(t.trips.scheduled_departure) : ''
      }, (() => { try { return window.localStorage.getItem('ventanilla.format') === 'a4' ? 'a4' as const : 'ticket' as const; } catch { return 'ticket' as const; } })());
    } catch (e) { setMsg({ kind: 'error', text: friendly(e) }); }
  };

  const filtered = (tickets.data ?? []).filter((t) => {
    if (!search) return true;
    const s = search.toLowerCase();
    return (
      t.passenger_name.toLowerCase().includes(s) ||
      t.passenger_dni.includes(s) ||
      t.passenger_email.toLowerCase().includes(s) ||
      t.qr_code.includes(s)
    );
  });

  const statusPillClass: Record<SaleTicket['status'], string> = {
    valid: 'info', boarded: 'ok', cancelled: 'bad'
  };

  const onCancelled = () => {
    setCancellingId(null);
    setMsg({ kind: 'ok', text: 'Pasaje cancelado y registrado en el historial.' });
    tickets.reload();
  };

  return (
    <>
      <h1>Pasajes</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      {cancellingId && (
        <RefundModal
          ticketId={cancellingId}
          onClose={() => setCancellingId(null)}
          onSuccess={onCancelled}
        />
      )}

      <div className="card">
        <div className="row operation-filters">
          <label>
            Desde
            <input type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} />
          </label>
          <label>
            Hasta
            <input type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)} />
          </label>
          <label>
            Estado
            <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)}>
              <option value="all">Todos</option>
              <option value="valid">Válido</option>
              <option value="boarded">Abordó</option>
              <option value="cancelled">Cancelado</option>
            </select>
          </label>
          <label>
            Buscar pasajero / DNI / QR
            <input placeholder="nombre, DNI o código QR"
              value={search} onChange={(e) => setSearch(e.target.value)} />
          </label>
        </div>
      </div>

      <div className="card table-wrap">
        {tickets.loading ? <Loading /> : (
          <>
            <p className="muted" style={{ marginBottom: 8 }}>
              {filtered.length} pasaje{filtered.length !== 1 ? 's' : ''} encontrado{filtered.length !== 1 ? 's' : ''}
            </p>
            <table>
              <thead>
                <tr>
                  <th>Pasajero</th>
                  <th>DNI</th>
                  <th>Tramo</th>
                  <th>Viaje</th>
                  <th>Asiento</th>
                  <th>Precio</th>
                  <th>Pago</th>
                  <th>Vendido por</th>
                  <th>Estado</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {filtered.length === 0 && (
                  <tr><td colSpan={10} className="muted">No hay pasajes para los filtros seleccionados.</td></tr>
                )}
                {filtered.map((t) => (
                  <tr key={t.id}>
                    <td>
                      <b>{t.passenger_name}</b>
                      {t.is_complimentary && <span className="pill info" style={{ marginLeft: 6 }}>Cortesía</span>}
                      {t.ticket_type === 'disability' && <span className="pill info" style={{ marginLeft: 6 }}>Discapacidad</span>}
                      <div className="muted" style={{ fontSize: 11 }}>{t.passenger_email}</div>
                    </td>
                    <td>{t.passenger_dni}</td>
                    <td>
                      <span className="muted" style={{ fontSize: 12 }}>
                        {t.from_stop?.name} → {t.to_stop?.name}
                      </span>
                    </td>
                    <td>
                      {t.trips?.services?.code && <b>{t.trips.services.code}</b>}
                      {t.trips?.scheduled_departure && (
                        <div className="muted" style={{ fontSize: 11 }}>
                          {formatTime(t.trips.scheduled_departure)} · {t.trips.service_date}
                        </div>
                      )}
                    </td>
                    <td>{t.seat_label ?? <span className="muted">—</span>}</td>
                    <td><b>${Number(t.price).toFixed(2)}</b></td>
                    <td className="muted" style={{ fontSize: 12 }}>
                      {t.sales?.payment_method ? PAYMENT_METHOD_LABEL[t.sales.payment_method] : '—'}
                    </td>
                    <td className="muted" style={{ fontSize: 12 }}>
                      {t.sales?.seller?.full_name ?? '—'}
                    </td>
                    <td>
                      <span className={`pill ${statusPillClass[t.status]}`}>
                        {TICKET_STATUS_LABEL[t.status]}
                      </span>
                      {t.status === 'cancelled' && t.cancel_reason && (
                        <div className="muted" style={{ fontSize: 11, marginTop: 2 }} title={t.cancel_reason}>
                          {t.cancel_reason.slice(0, 30)}{t.cancel_reason.length > 30 ? '…' : ''}
                        </div>
                      )}
                    </td>
                    <td>
                      {t.status !== 'cancelled' && <button className="secondary" style={{ fontSize: 12, minHeight: 32, padding: '0 10px', marginRight: 6 }} onClick={() => void reprint(t)}>Imprimir</button>}
                      {t.status === 'valid' && (profile?.role === 'company_admin' || profile?.role === 'seller') && (
                        <button className="danger" style={{ fontSize: 12, minHeight: 32, padding: '0 10px' }}
                          onClick={() => setCancellingId(t.id)}>
                          Cancelar
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </div>
    </>
  );
}
