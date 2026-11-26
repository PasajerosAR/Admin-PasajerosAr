import { must, useQuery } from '../../lib/useQuery';
import { supabase } from '../../lib/supabase';
import { Loading, PageHead } from '../../ui';
import { todayLocal } from '../../ui';

interface DailyRow {
  sale_date: string;
  sale_count: number;
  total_amount: number;
  refunded_count: number;
  complimentary_count: number;
}

function monthStart() {
  const today = todayLocal();
  return `${today.slice(0, 7)}-01`;
}

export function SalesDashboardPage() {
  const start = monthStart();
  const today = todayLocal();
  const rows = useQuery(async () => must(await supabase
    .from('daily_sales_summary')
    .select('sale_date,sale_count,total_amount,refunded_count,complimentary_count')
    .gte('sale_date', start)
    .lte('sale_date', today)
    .order('sale_date', { ascending: false })) as DailyRow[], [start, today]);

  const summary = (rows.data ?? []).reduce((value, row) => ({
    sales: value.sales + Number(row.sale_count),
    amount: value.amount + Number(row.total_amount),
    refunded: value.refunded + Number(row.refunded_count),
    complimentary: value.complimentary + Number(row.complimentary_count)
  }), { sales: 0, amount: 0, refunded: 0, complimentary: 0 });

  return (
    <>
      <PageHead title="Ventas" subtitle="Resumen del mes actual. Las devoluciones se registran para auditoría; el reintegro se gestiona manualmente." />
      {rows.loading ? <Loading /> : (
        <>
          <div className="stats">
            <div className="stat" aria-label="Ventas del mes"><span>Ventas</span><b>{summary.sales}</b></div>
            <div className="stat" aria-label="Total vendido"><span>Importe vendido</span><b>${summary.amount.toFixed(2)}</b></div>
            <div className="stat" aria-label="Pasajes de cortesía"><span>Pasajes de cortesía</span><b>{summary.complimentary}</b></div>
            <div className="stat" aria-label="Ventas devueltas"><span>Ventas devueltas</span><b>{summary.refunded}</b></div>
          </div>
          <div className="card list-card">
            <div className="list-head"><h2>Actividad diaria</h2></div>
            <table>
              <thead><tr><th>Fecha</th><th>Ventas</th><th>Importe</th><th>Devoluciones</th><th>Cortesías</th></tr></thead>
              <tbody>
                {(rows.data ?? []).length === 0 && <tr><td colSpan={5} className="muted">Todavía no hay ventas este mes.</td></tr>}
                {(rows.data ?? []).map((row, index) => (
                  <tr key={`${row.sale_date}-${index}`}>
                    <td>{new Date(row.sale_date).toLocaleDateString('es-AR')}</td>
                    <td>{row.sale_count}</td>
                    <td>${Number(row.total_amount).toFixed(2)}</td>
                    <td>{row.refunded_count}</td>
                    <td>{row.complimentary_count}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
