import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useQuery } from '../lib/useQuery';
import { useAuth } from '../auth/AuthProvider';

const count = async (table: string, filter?: (q: any) => any) => {   // eslint-disable-line @typescript-eslint/no-explicit-any
  let q = supabase.from(table).select('id', { count: 'exact', head: true });
  if (filter) q = filter(q);
  const { count: n } = await q;
  return n ?? 0;
};

// Lista de pasos para empresas nuevas: desaparece cuando todo está cargado.
export function FirstSteps() {
  const { blockedFeatures } = useAuth();
  const sales = !blockedFeatures.includes('fares');
  const done = useQuery(async () => ({
    vehicles: await count('vehicles'),
    drivers: await count('profiles', (q) => q.eq('role', 'driver')),
    routes: await count('routes', (q) => q.eq('active', true)),
    services: await count('services', (q) => q.is('deleted_at', null)),
    prices: sales ? await count('ticket_prices', (q) => q.eq('active', true)) : 1
  }), [sales]);
  const d = done.data;
  if (!d) return null;
  const steps: [string, string, boolean][] = [
    ['Cargá tus vehículos', '/admin/vehiculos', d.vehicles > 0],
    ['Cargá tus conductores', '/admin/conductores', d.drivers > 0],
    ['Definí un recorrido', '/admin/recorridos', d.routes > 0],
    ['Armá un servicio con sus salidas', '/admin/servicios', d.services > 0],
    ...(sales ? [['Cargá las tarifas', '/admin/ventas/tarifas', d.prices > 0] as [string, string, boolean]] : [])
  ];
  if (steps.every((s) => s[2])) return null;
  return (
    <div className="card first-steps">
      <h2>Primeros pasos</h2>
      <ol>
        {steps.map(([label, to, ok]) => (
          <li key={to} className={ok ? 'done' : ''}>{ok ? '✓ ' : ''}{ok ? label : <Link to={to}>{label}</Link>}</li>
        ))}
      </ol>
    </div>
  );
}
