import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice, PageHead } from '../../ui';
import { SearchSelect } from '../SearchSelect';
import type { Route, RouteStop, TicketPrice } from '../../lib/types';
import { BulkBar, HeadCheck, RowCheck, confirmDelete, useBulk } from '../bulk';
import { useFareBands } from '../../lib/fareBands';

const SEAT_CLASSES = ['Común', 'Semicama', 'Cama', 'Premium', 'Cama premium'];
type DayPrices = Record<string, string>;   // código de franja → precio
// una fila de la grilla = un tramo y una clase, con el precio de cada franja
interface FareRow { key: string; from_pos: number; to_pos: number; seat_class: string | null; ids: string[]; byDay: Record<string, TicketPrice> }

export function TarifasPage() {
  const [selectedRoute, setSelectedRoute] = useState('');
  const [msg, setMsg]   = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState({ from_pos: '', to_pos: '', seat_class: '' });
  const [formPrices, setFormPrices] = useState<DayPrices>({});      // vacío = ese día no se vende
  const [all, setAll] = useState({ price: '', seat_class: '' });   // "Aplicar a todos"
  const { bands } = useFareBands();
  const codes = bands.map((b) => b.code);
  const bandLabel = (code: string) => bands.find((b) => b.code === code)?.name ?? code;
  const [allDaysSel, setAllDaysSel] = useState<string[] | null>(null);     // null = todas las franjas
  const allDays = allDaysSel ?? codes;
  const setAllDays = (v: string[]) => setAllDaysSel(v);
  const [edit, setEdit] = useState<Record<string, Partial<DayPrices>>>({});

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

  // guarda el precio de un tramo en cada tipo de día; precio vacío = ese día no se vende
  const saveDays = async (fromPos: number, toPos: number, seatClass: string | null, values: Partial<DayPrices>) => {
    for (const day of codes) {
      const raw = values[day];
      if (raw === undefined) continue;
      const price = raw.trim() === '' ? null : parseFloat(raw);
      if (price !== null && (isNaN(price) || price < 0)) throw new Error('PRICE_INVALID: revisá los precios');
      const { error } = await supabase.rpc('save_ticket_price', {
        p_route: selectedRoute, p_from_pos: fromPos, p_to_pos: toPos, p_price: price, p_seat_class: seatClass, p_day_type: day
      });
      if (error) throw error;
    }
  };

  const addPrice = async (e: FormEvent) => {
    e.preventDefault();
    if (!selectedRoute) return;
    const from_pos = parseInt(form.from_pos);
    const to_pos   = parseInt(form.to_pos);
    if (from_pos >= to_pos) {
      setMsg({ kind: 'error', text: 'La parada de origen debe ser anterior a la de destino.' });
      return;
    }
    const filled = Object.fromEntries(codes.filter((d) => (formPrices[d] ?? '').trim() !== '').map((d) => [d, formPrices[d]])) as Partial<DayPrices>;
    if (Object.keys(filled).length === 0) { setMsg({ kind: 'error', text: 'Cargá el precio de al menos una franja.' }); return; }
    setBusy(true);
    setMsg(null);
    try { await saveDays(from_pos, to_pos, form.seat_class.trim() || null, filled); }
    catch (err) { setBusy(false); setMsg({ kind: 'error', text: friendly(err) }); return; }
    setBusy(false);
    setMsg({ kind: 'ok', text: 'Tarifa guardada.' });
    setForm({ from_pos: '', to_pos: '', seat_class: '' });
    setFormPrices({});
    prices.reload();
  };

  const applyToAll = async (e: FormEvent) => {
    e.preventDefault();
    const price = parseFloat(all.price);
    if (isNaN(price) || price < 0) { setMsg({ kind: 'error', text: 'El precio no es válido.' }); return; }
    if (allDays.length === 0) { setMsg({ kind: 'error', text: 'Tildá al menos una franja.' }); return; }
    const scope = all.seat_class || 'todas las clases';
    const dayText = codes.filter((d) => allDays.includes(d)).map((d) => bandLabel(d).toLowerCase()).join(', ');
    if (!window.confirm(`¿Poner $${price.toFixed(2)} (${scope}, ${dayText}) en todos los tramos de este recorrido entre localidades distintas? Las tarifas que ya existan se actualizan.`)) return;
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc('apply_price_to_all', {
      p_route: selectedRoute, p_price: price, p_seat_class: all.seat_class || null, p_day_types: codes.filter((d) => allDays.includes(d))
    });
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: `Precio aplicado a ${data as number} tramos.` });
    setAll({ price: '', seat_class: '' });
    prices.reload();
  };

  // filas de la grilla: un tramo y una clase, con el precio de cada franja
  const rows: FareRow[] = [];
  for (const p of prices.data ?? []) {
    const key = `${p.from_pos}|${p.to_pos}|${p.seat_class ?? ''}`;
    let row = rows.find((r) => r.key === key);
    if (!row) { row = { key, from_pos: p.from_pos, to_pos: p.to_pos, seat_class: p.seat_class, ids: [], byDay: {} }; rows.push(row); }
    row.ids.push(p.id); row.byDay[p.day_type] = p;
  }
  const rowValue = (r: FareRow, d: string) => edit[r.key]?.[d] ?? (r.byDay[d] ? String(Number(r.byDay[d]!.price)) : '');

  const saveRow = async (r: FareRow) => {
    const values = edit[r.key]; if (!values) return;
    setBusy(true); setMsg(null);
    try { await saveDays(r.from_pos, r.to_pos, r.seat_class, values); }
    catch (err) { setBusy(false); setMsg({ kind: 'error', text: friendly(err) }); return; }
    setBusy(false);
    setEdit(({ [r.key]: _, ...rest }) => rest);
    setMsg({ kind: 'ok', text: 'Tarifa actualizada.' });
    prices.reload();
  };

  const removeRows = async (idsList: string[][]) => {
    setBusy(true);
    const { error } = await supabase.from('ticket_prices').update({ active: false }).in('id', idsList.flat());
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return false; }
    prices.reload();
    return true;
  };
  const deactivate = async (r: FareRow) => {
    if (!window.confirm('¿Eliminar esta tarifa (todas las franjas)?')) return;
    if (await removeRows([r.ids])) setMsg({ kind: 'ok', text: 'Tarifa eliminada.' });
  };

  const bulk = useBulk(rows.map((r) => r.key));
  const removeSelected = async () => {
    if (!confirmDelete(bulk.count, 'tarifa', 'tarifas')) return;
    if (await removeRows(rows.filter((r) => bulk.selected.includes(r.key)).map((r) => r.ids))) {
      setMsg({ kind: 'ok', text: bulk.count === 1 ? 'Tarifa eliminada.' : `${bulk.count} tarifas eliminadas.` });
      bulk.clear();
    }
  };

  const stopName = (pos: number) =>
    stops.data?.find((s) => s.position === pos)?.name ?? `Parada ${pos}`;

  return (
    <>
      <PageHead title="Tarifas" subtitle="Configurá el precio por tramo para cada recorrido, con un precio para cada franja horaria (se definen en “Franjas horarias”). Un tramo sin precio en una franja no se vende en esa franja." />
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <div className="card">
        <label>
          Recorrido
          <SearchSelect options={(routes.data ?? []).map((r) => ({ value: r.id, label: r.name }))} value={selectedRoute} onChange={setSelectedRoute} placeholder="Buscar recorrido" />
        </label>
      </div>

      {selectedRoute && (
        <>
          <form className="card stack fare-bulk-form" onSubmit={applyToAll}>
            <h2>Aplicar a todos</h2>
            <p className="muted">Un mismo precio para todos los tramos entre localidades distintas (por ejemplo Paraná a Santa Fe, sin importar la parada). Después podés cambiar un tramo suelto.</p>
            <div className="row fare-main-row">
              <label className="fare-price-field">
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
            <div className="row fare-day-options">
              {bands.map((b) => b.code).map((d) => (
                <label key={d}>
                  <input type="checkbox" checked={allDays.includes(d)}
                    onChange={(e) => setAllDays(e.target.checked ? [...allDays, d] : allDays.filter((x) => x !== d))} />{bandLabel(d)}
                </label>
              ))}
            </div>
          </form>

          <form className="card stack fare-add-form" onSubmit={addPrice}>
            <h2>Agregar tarifa</h2>
            <p className="muted">Dejá vacío el precio de las franjas en las que no se vende ese tramo.</p>
            <div className="row fare-add-main">
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
              {codes.map((d) => (
                <label key={d} className="fare-price-field" title={bandLabel(d)}>
                  {bandLabel(d)} ($)
                  <input type="number" min="0" step="0.01" value={formPrices[d] ?? ''} onChange={(e) => setFormPrices({ ...formPrices, [d]: e.target.value })} />
                </label>
              ))}
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
            <BulkBar bulk={bulk} one="tarifa" many="tarifas" busy={busy} onDelete={() => void removeSelected()} />
            {prices.loading ? <Loading /> : (
              <table>
                <thead>
                  <tr>
                    <HeadCheck bulk={bulk} /><th>Desde</th><th>Hasta</th><th>Clase</th>
                    {codes.map((d) => <th key={d}>{bandLabel(d)}</th>)}
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0 && (
                    <tr><td colSpan={5 + codes.length} className="muted">No hay tarifas para este recorrido.</td></tr>
                  )}
                  {rows.map((r) => (
                    <tr key={r.key}>
                      <RowCheck bulk={bulk} id={r.key} />
                      <td>{stopName(r.from_pos)}</td>
                      <td>{stopName(r.to_pos)}</td>
                      <td>{r.seat_class ?? <span className="muted">Todos</span>}</td>
                      {codes.map((d) => (
                        <td key={d}>
                          <input type="number" min="0" step="0.01" style={{ width: 96 }} placeholder="No se vende" aria-label={`${bandLabel(d)}: precio`}
                            value={rowValue(r, d)} onChange={(e) => setEdit({ ...edit, [r.key]: { ...edit[r.key], [d]: e.target.value } })} />
                        </td>
                      ))}
                      <td>
                        {edit[r.key] && <button disabled={busy} onClick={() => void saveRow(r)}>Guardar</button>}{' '}
                        <button className="danger" onClick={() => void deactivate(r)}>Eliminar</button>
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
