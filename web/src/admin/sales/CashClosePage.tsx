import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice, TimeInput, todayLocal } from '../../ui';
import { PAYMENT_METHOD_LABEL, type PaymentMethod } from '../../lib/types';
import { formatMoney } from '../../lib/taquilla';
import { useAuth } from '../../auth/AuthProvider';

interface Row { seller_id: string; seller_name: string; payment_method: PaymentMethod; sales: number; tickets: number; collected: number; refunded: number }
interface PassRow { seller_id: string; seller_name: string; payment_method: PaymentMethod; passes: number; collected: number }
const money = (n: number) => formatMoney(Number(n));

// Cierre de caja: lo cobrado por vendedor y forma de pago. El vendedor ve lo suyo; el admin de empresa, todos.
export function CashClosePage() {
  const { profile } = useAuth();
  const isAdmin = profile?.role === 'company_admin';
  const [day, setDay] = useState(todayLocal());
  const [from, setFrom] = useState('00:00');
  const [to, setTo] = useState('23:59');
  const [seller, setSeller] = useState('');
  const [msg, setMsg] = useState<string | null>(null);

  const sellers = useQuery(async () => isAdmin
    ? must(await supabase.from('profiles').select('id,full_name,role').in('role', ['seller', 'company_admin']).order('full_name')) as { id: string; full_name: string }[]
    : [], [isAdmin]);
  const report = useQuery(async () => {
    const start = new Date(`${day}T${from}:00`); const end = new Date(`${day}T${to}:59`);
    if (Number.isNaN(start.getTime()) || end <= start) { setMsg('El horario final tiene que ser posterior al inicial.'); return [] as Row[]; }
    setMsg(null);
    return must(await supabase.rpc('cash_close', { p_from: start.toISOString(), p_to: new Date(end.getTime() + 1000).toISOString(), p_seller: seller || null })) as Row[];
  }, [day, from, to, seller]);

  // abonos vendidos en el período (el viaje usado con abono no cobra nada)
  const passSales = useQuery(async () => {
    const start = new Date(`${day}T${from}:00`); const end = new Date(`${day}T${to}:59`);
    if (Number.isNaN(start.getTime()) || end <= start) return [] as PassRow[];
    return must(await supabase.rpc('pass_cash_close', { p_from: start.toISOString(), p_to: new Date(end.getTime() + 1000).toISOString(), p_seller: seller || null })) as PassRow[];
  }, [day, from, to, seller]);
  const passRows = passSales.data ?? [];

  const rows = report.data ?? [];
  const bySeller = new Map<string, Row[]>();
  for (const r of rows) bySeller.set(r.seller_id, [...(bySeller.get(r.seller_id) ?? []), r]);
  const sum = (list: Row[], k: 'collected' | 'refunded' | 'tickets') => list.reduce((n, r) => n + Number(r[k]), 0);

  return (
    <>
      <h1>Cierre de caja</h1>
      <p className="muted">Lo cobrado por forma de pago. Los pasajes cancelados se descuentan.</p>
      {msg && <Notice kind="warn">{msg}</Notice>}
      {report.error && <Notice>{friendly(new Error(report.error))}</Notice>}
      <div className="card row no-print">
        <label>Día<input type="date" value={day} onChange={(e) => setDay(e.target.value)} /></label>
        <label>Desde<TimeInput value={from} onChange={setFrom} /></label>
        <label>Hasta<TimeInput value={to} onChange={setTo} /></label>
        {isAdmin && (
          <label>Vendedor
            <select value={seller} onChange={(e) => setSeller(e.target.value)}>
              <option value="">Todos</option>
              {(sellers.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
            </select>
          </label>
        )}
        <button type="button" className="secondary" onClick={() => window.print()}>Imprimir</button>
      </div>
      {passRows.length > 0 && (
        <div className="card table-wrap">
          <h2>Abonos vendidos</h2>
          <table>
            <thead><tr><th>Vendedor</th><th>Forma de pago</th><th>Abonos</th><th>Cobrado</th></tr></thead>
            <tbody>
              {passRows.map((r) => <tr key={`${r.seller_id}${r.payment_method}`}><td>{r.seller_name}</td><td>{PAYMENT_METHOD_LABEL[r.payment_method]}</td><td>{r.passes}</td><td><b>{money(r.collected)}</b></td></tr>)}
              <tr><td><b>Total abonos</b></td><td /><td><b>{passRows.reduce((n, r) => n + Number(r.passes), 0)}</b></td><td><b>{money(passRows.reduce((n, r) => n + Number(r.collected), 0))}</b></td></tr>
            </tbody>
          </table>
          <p className="muted">Se suman al efectivo y demás cobros de la caja; no están incluidos en las tablas de pasajes.</p>
        </div>
      )}
      {report.loading ? <Loading /> : bySeller.size === 0 ? <div className="card muted">No hay ventas de pasajes en ese horario.</div> : (
        <>
          {[...bySeller.entries()].map(([id, list]) => (
            <div key={id} className="card table-wrap">
              <h2>{list[0].seller_name}</h2>
              <table>
                <thead><tr><th>Forma de pago</th><th>Ventas</th><th>Pasajes</th><th>Cobrado</th><th>Cancelado</th></tr></thead>
                <tbody>
                  {list.map((r) => (
                    <tr key={r.payment_method}><td>{PAYMENT_METHOD_LABEL[r.payment_method]}</td><td>{r.sales}</td><td>{r.tickets}</td><td><b>{money(r.collected)}</b></td><td>{r.refunded > 0 ? money(r.refunded) : '-'}</td></tr>
                  ))}
                  <tr><td><b>Total</b></td><td /><td><b>{sum(list, 'tickets')}</b></td><td><b>{money(sum(list, 'collected'))}</b></td><td>{sum(list, 'refunded') > 0 ? money(sum(list, 'refunded')) : '-'}</td></tr>
                </tbody>
              </table>
            </div>
          ))}
          {bySeller.size > 1 && <div className="card"><h2>Total general: {money(sum(rows, 'collected'))}</h2></div>}
        </>
      )}
    </>
  );
}
