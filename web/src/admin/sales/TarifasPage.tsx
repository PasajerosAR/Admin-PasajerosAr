import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice } from '../../ui';
import { SearchSelect } from '../SearchSelect';
import type { Route, RouteStop, TicketPrice } from '../../lib/types';

const SEAT_CLASSES = ['Común', 'Semicama', 'Cama', 'Premium', 'Cama premium'];

export function TarifasPage() {
  const [selectedRoute, setSelectedRoute] = useState('');
  const [msg, setMsg]   = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState({ from_pos: '', to_pos: '', price: '', seat_class: '' });
  const [all, setAll] = useState({ price: '', seat_class: '' });   // "Aplicar a todos"

  const routes = useQuery(async () =>
    must(await supabase.from('routes').select('id,name,active').order('name')) as Route[], []);

  const stops = useQuery(async () => {
    if (!selectedRoute) return [];
    return must(await supabase
      .from('route_stops')
      .select('id,route_id,position,name')
      .eq('route_id', selectedRoute)
      .order('position')
    ) as RouteStop[];
  }, [selectedRoute]);

  const prices = useQuery(async () => {
    if (!selectedRoute) return [];
    return must(await supabase
      .from('ticket_prices')
      .select('*')
      .eq('route_id', selectedRoute)
      .eq('active', true)
      .order('from_pos')
      .order('to_pos')
    ) as TicketPrice[];
  }, [selectedRoute]);

  const set = (k: keyof typeof form) => (e: { target: { value: string } }) =>
    setForm({ ...form, [k]: e.target.value });

  const addPrice = async (e: FormEvent) => {
    e.preventDefault();
    if (!selectedRoute) return;
    const from_pos = parseInt(form.from_pos);
    const to_pos   = parseInt(form.to_pos);
    const price    = parseFloat(form.price);
    if (from_pos >= to_pos) {
      setMsg({ kind: 'error', text: 'La parada de origen debe ser anterior a la de destino.' });
      return;
    }
    if (isNaN(price) || price < 0) {
      setMsg({ kind: 'error', text: 'El precio no es válido.' });
      return;
    }
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('save_ticket_price', {
      p_route: selectedRoute,
      p_from_pos: from_pos,
      p_to_pos: to_pos,
      p_price: price,
      p_seat_class: form.seat_class.trim() || null
    });
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Tarifa guardada.' });
    setForm({ from_pos: '', to_pos: '', price: '', seat_class: '' });
    prices.reload();
  };

  const applyToAll = async (e: FormEvent) => {
    e.preventDefault();
    const price = parseFloat(all.price);
    if (isNaN(price) || price < 0) { setMsg({ kind: 'error', text: 'El precio no es válido.' }); return; }
    const scope = all.seat_class || 'todas las clases';
    if (!window.confirm(`¿Poner $${price.toFixed(2)} (${scope}) en todos los tramos de este recorrido entre localidades distintas? Las tarifas que ya existan se actualizan.`)) return;
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc('apply_price_to_all', {
      p_route: selectedRoute, p_price: price, p_seat_class: all.seat_class || null
    });
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: `Precio aplicado a ${data as number} tramos.` });
    setAll({ price: '', seat_class: '' });
    prices.reload();
  };

  const deactivate = async (id: string) => {
    const { error } = await supabase.from('ticket_prices').update({ active: false }).eq('id', id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else prices.reload();
  };

  const stopName = (pos: number) =>
    stops.data?.find((s) => s.position === pos)?.name ?? `Parada ${pos}`;

  return (
    <>
      <h1>Tarifas</h1>
      <p className="muted">Configurá el precio por tramo para cada recorrido. Las tarifas se usan al vender pasajes.</p>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <div className="card">
        <label>
          Recorrido
          <SearchSelect options={(routes.data ?? []).map((r) => ({ value: r.id, label: r.name }))} value={selectedRoute} onChange={setSelectedRoute} placeholder="Buscar recorrido" />
        </label>
      </div>

      {selectedRoute && (
        <>
          <form className="card stack" onSubmit={applyToAll}>
            <h2>Aplicar a todos</h2>
            <p className="muted">Un mismo precio para todos los tramos entre localidades distintas (por ejemplo Paraná a Santa Fe, sin importar la parada). Después podés cambiar un tramo suelto.</p>
            <div className="row">
              <label>
                Precio ($)
                <input type="number" min="0" step="0.01" value={all.price} onChange={(e) => setAll({ ...all, price: e.target.value })} required />
              </label>
              <label>
                Clase de asiento
                <select value={all.seat_class} onChange={(e) => setAll({ ...all, seat_class: e.target.value })}>
                  <option value="">Todas las clases</option>
                  {SEAT_CLASSES.map((seatClass) => <option key={seatClass} value={seatClass}>{seatClass}</option>)}
                </select>
              </label>
              <button type="submit" disabled={busy || stops.loading}>{busy ? 'Aplicando...' : 'Aplicar a todos'}</button>
            </div>
          </form>

          <form className="card stack" onSubmit={addPrice}>
            <h2>Agregar tarifa</h2>
            <div className="row">
              <label>
                Desde (parada origen)
                <select value={form.from_pos} onChange={set('from_pos')} required>
                  <option value="">—</option>
                  {(stops.data ?? []).map((s) => (
                    <option key={s.id} value={s.position}>{s.position}. {s.name}</option>
                  ))}
                </select>
              </label>
              <label>
                Hasta (parada destino)
                <select value={form.to_pos} onChange={set('to_pos')} required>
                  <option value="">—</option>
                  {(stops.data ?? []).map((s) => (
                    <option key={s.id} value={s.position}>{s.position}. {s.name}</option>
                  ))}
                </select>
              </label>
              <label>
                Precio ($)
                <input type="number" min="0" step="0.01" value={form.price} onChange={set('price')} required />
              </label>
              <label>
                Clase de asiento (opcional)
                <select value={form.seat_class} onChange={set('seat_class')}>
                  <option value="">Todas las clases</option>
                  {SEAT_CLASSES.map((seatClass) => (
                    <option key={seatClass} value={seatClass}>{seatClass}</option>
                  ))}
                </select>
              </label>
              <button type="submit" disabled={busy || stops.loading}>
                {busy ? 'Guardando...' : 'Agregar tarifa'}
              </button>
            </div>
          </form>

          <div className="card table-wrap">
            <h2>Tarifas activas</h2>
            {prices.loading ? <Loading /> : (
              <table>
                <thead>
                  <tr><th>Desde</th><th>Hasta</th><th>Clase</th><th>Precio</th><th /></tr>
                </thead>
                <tbody>
                  {(prices.data ?? []).length === 0 && (
                    <tr><td colSpan={5} className="muted">No hay tarifas para este recorrido.</td></tr>
                  )}
                  {(prices.data ?? []).map((p) => (
                    <tr key={p.id}>
                      <td>{stopName(p.from_pos)}</td>
                      <td>{stopName(p.to_pos)}</td>
                      <td>{p.seat_class ?? <span className="muted">Todos</span>}</td>
                      <td><b>${Number(p.price).toFixed(2)}</b></td>
                      <td>
                        <button className="danger" onClick={() => deactivate(p.id)}>Eliminar</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </>
      )}
    </>
  );
}
