import { useState } from 'react';
import { useAuth } from '../../auth/AuthProvider';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { supabase } from '../../lib/supabase';
import { Loading, Notice, PageHead, todayLocal } from '../../ui';

interface ReportRow {
  company_id?: string;
  company_name?: string;
  sale_date: string;
  payment_method: string;
  sale_count: number;
  ticket_count?: number;
  total_amount: number;
  refunded_count: number;
  complimentary_count: number;
}

function firstOfMonth() {
  return `${todayLocal().slice(0, 7)}-01`;
}

function csvCell(value: string | number) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

export function SalesReportsPage() {
  const { profile } = useAuth();
  const global = profile?.role === 'platform_admin' || profile?.role === 'platform_staff';
  const [from, setFrom] = useState(firstOfMonth());
  const [to, setTo] = useState(todayLocal());
  const [rangeError, setRangeError] = useState('');

  const report = useQuery(async () => {
    if (from > to) throw new Error('La fecha inicial no puede ser posterior a la final.');
    if (global) {
      return must(await supabase.rpc('platform_sales_report', {
        p_from: from, p_to: to, p_company_id: null
      })) as ReportRow[];
    }
    return must(await supabase.from('daily_sales_summary')
      .select('company_id,sale_date,payment_method,sale_count,total_amount,refunded_count,complimentary_count')
      .gte('sale_date', from)
      .lte('sale_date', to)
      .order('sale_date', { ascending: false })) as ReportRow[];
  }, [from, to, global]);

  const exportCsv = () => {
    const header = ['Fecha', 'Empresa', 'Medio de pago', 'Ventas', 'Pasajes', 'Importe', 'Devoluciones', 'Cortesias'];
    const lines = (report.data ?? []).map((row) => [
      row.sale_date, row.company_name ?? '', row.payment_method, row.sale_count,
      row.ticket_count ?? '', Number(row.total_amount).toFixed(2), row.refunded_count, row.complimentary_count
    ].map(csvCell).join(','));
    const blob = new Blob(['\uFEFF', [header.map(csvCell).join(','), ...lines].join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `reporte-ventas-${from}-${to}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  };

  const setRange = (nextFrom: string, nextTo: string) => {
    if (nextFrom > nextTo) {
      setRangeError('La fecha inicial no puede ser posterior a la fecha final.');
      return;
    }
    setRangeError('');
    setFrom(nextFrom);
    setTo(nextTo);
  };

  const rows = report.data ?? [];
  const totals = rows.reduce((value, row) => ({
    sales: value.sales + Number(row.sale_count),
    tickets: value.tickets + Number(row.ticket_count ?? 0),
    amount: value.amount + Number(row.total_amount),
    refunds: value.refunds + Number(row.refunded_count),
    complimentary: value.complimentary + Number(row.complimentary_count)
  }), { sales: 0, tickets: 0, amount: 0, refunds: 0, complimentary: 0 });

  return (
    <>
      <PageHead title="Reportes de ventas" />
      <div className="toolbar">
        <div className="filters">
          <label>Desde<input type="date" value={from} onChange={(e) => setRange(e.target.value, to)} /></label>
          <label>Hasta<input type="date" value={to} onChange={(e) => setRange(from, e.target.value)} /></label>
          <button className="secondary" onClick={exportCsv} disabled={report.loading || rows.length === 0}>Descargar CSV</button>
        </div>
      </div>
      {rangeError && <Notice kind="error">{rangeError}</Notice>}
      {report.error && <Notice kind="error">{friendly(report.error)}</Notice>}
      {report.loading ? <Loading /> : (
        <>
          <div className="stats">
            <div className="stat"><span>Ventas</span><b>{totals.sales}</b></div>
            <div className="stat"><span>Pasajes</span><b>{totals.tickets}</b></div>
            <div className="stat"><span>Importe</span><b>${totals.amount.toFixed(2)}</b></div>
            <div className="stat"><span>Cortesías</span><b>{totals.complimentary}</b></div>
            <div className="stat"><span>Ventas devueltas</span><b>{totals.refunds}</b></div>
          </div>
          <div className="card list-card">
            <div className="table-wrap"><table>
              <thead><tr>{global && <th>Empresa</th>}<th>Fecha</th><th>Medio de pago</th><th>Ventas</th>{global && <th>Pasajes</th>}<th>Importe</th><th>Devoluciones</th><th>Cortesías</th></tr></thead>
              <tbody>
                {rows.length === 0 && <tr><td colSpan={global ? 8 : 7} className="muted">No hay ventas en el período elegido.</td></tr>}
                {rows.map((row, index) => (
                  <tr key={`${row.company_id ?? ''}-${row.sale_date}-${row.payment_method}-${index}`}>
                    {global && <td>{row.company_name ?? '—'}</td>}
                    <td>{new Date(row.sale_date).toLocaleDateString('es-AR')}</td>
                    <td>{row.payment_method}</td>
                    <td>{row.sale_count}</td>
                    {global && <td>{row.ticket_count ?? 0}</td>}
                    <td>${Number(row.total_amount).toFixed(2)}</td>
                    <td>{row.refunded_count}</td>
                    <td>{row.complimentary_count}</td>
                  </tr>
                ))}
              </tbody>
            </table></div>
          </div>
        </>
      )}
    </>
  );
}
