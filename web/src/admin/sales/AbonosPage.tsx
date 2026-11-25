import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice } from '../../ui';
import { formatMoney } from '../../lib/taquilla';
import { useAuth } from '../../auth/AuthProvider';
import { DAY_TYPES, DAY_TYPE_LABEL, DAY_TYPE_LETTER, daysTag, type DayType } from '../../lib/dayType';
import { BulkBar, HeadCheck, RowCheck, confirmDelete, useBulk } from '../bulk';

interface Pair { place_a: string; place_b: string; place_a_name: string; place_b_name: string; seat_class: string | null; base_price: number }
interface Product { id: string; place_a: string; place_b: string; seat_class: string | null; trips: number; price: number; valid_days: number; active: boolean; day_types: DayType[] }
interface PassRow {
  pass_id: string; holder_name: string; holder_dni: string; place_a_name: string; place_b_name: string; seat_class: string | null;
  trips_total: number; trips_left: number; price: number; purchased_at: string; expires_at: string; status: string; expired: boolean; day_types: DayType[]
}
type Method = 'cash' | 'debit' | 'credit' | 'transfer';
const METHODS: { key: Method; label: string }[] = [
  { key: 'cash', label: 'Efectivo' }, { key: 'debit', label: 'Débito' }, { key: 'credit', label: 'Crédito' }, { key: 'transfer', label: 'Transferencia' }
];
const TIERS = [5, 10, 15, 20, 25, 30];
const DEFAULT_DISCOUNT: Record<number, number> = { 5: 5, 10: 10, 15: 12, 20: 15, 25: 17, 30: 20 };
const pairKey = (a: string, b: string, c: string | null) => `${a}|${b}|${c ?? ''}`;
const roundPrice = (n: number) => Math.max(Math.round(n / 10) * 10, 0);
const fmtDate = (iso: string) => new Date(iso).toLocaleDateString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires' });

// Abonos: paquetes de viajes por tramo. La empresa los configura (admin) y se venden en ventanilla; se usan al vender un pasaje.
export function AbonosPage() {
  const { profile } = useAuth();
  const isAdmin = profile?.role === 'company_admin';
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const pairs = useQuery(async () => isAdmin ? must(await supabase.rpc('pass_fare_pairs')) as Pair[] : [], [isAdmin]);
  const products = useQuery(async () => must(await supabase.from('pass_products')
    .select('id,place_a,place_b,seat_class,trips,price,valid_days,active,day_types').order('trips')) as Product[], []);
  const names = new Map<string, string>();
  for (const p of pairs.data ?? []) { names.set(p.place_a, p.place_a_name); names.set(p.place_b, p.place_b_name); }

  // ---- generador
  const [tiers, setTiers] = useState<Record<number, boolean>>({ 5: true, 10: true, 20: true });
  const [disc, setDisc] = useState<Record<number, string>>(Object.fromEntries(TIERS.map((t) => [t, String(DEFAULT_DISCOUNT[t])])));
  const [days, setDays] = useState('30');
  const [target, setTarget] = useState('');   // '' = todos los tramos
  const [genDays, setGenDays] = useState<DayType[]>([...DAY_TYPES]);   // días en los que valen los abonos que se generan
  const run = async (fn: () => Promise<void>, ok: string) => {
    setBusy(true); setMsg(null);
    try { await fn(); setMsg({ kind: 'ok', text: ok }); products.reload(); } catch (e) { setMsg({ kind: 'error', text: friendly(e) }); } finally { setBusy(false); }
  };
  const generate = () => {
    const chosen = TIERS.filter((t) => tiers[t]);
    if (chosen.length === 0) { setMsg({ kind: 'error', text: 'Elegí al menos una cantidad de viajes.' }); return; }
    const validDays = Number(days);
    if (!Number.isInteger(validDays) || validDays < 1 || validDays > 365) { setMsg({ kind: 'error', text: 'La vigencia tiene que ser de 1 a 365 días.' }); return; }
    if (genDays.length === 0) { setMsg({ kind: 'error', text: 'Tildá al menos un tipo de día en el que valga el abono.' }); return; }
    const daysKey = (d: DayType[]) => DAY_TYPES.filter((t) => d.includes(t)).join(',');
    const existing = new Set((products.data ?? []).filter((p) => p.active).map((p) => `${pairKey(p.place_a, p.place_b, p.seat_class)}|${p.trips}|${daysKey(p.day_types)}`));
    const rows = (pairs.data ?? [])
      .filter((p) => !target || pairKey(p.place_a, p.place_b, p.seat_class) === target)
      .flatMap((p) => chosen.map((t) => ({
        place_a: p.place_a, place_b: p.place_b, seat_class: p.seat_class, trips: t, valid_days: validDays, active: true, day_types: genDays,
        price: roundPrice(Number(p.base_price) * t * (1 - Math.min(Math.max(Number(disc[t]) || 0, 0), 90) / 100))
      })))
      .filter((r) => !existing.has(`${pairKey(r.place_a, r.place_b, r.seat_class)}|${r.trips}|${daysKey(r.day_types)}`));
    if (rows.length === 0) { setMsg({ kind: 'error', text: 'Esos abonos ya existen (o no hay tramos con tarifa).' }); return; }
    void run(async () => { must(await supabase.from('pass_products').insert(rows)); }, `Se crearon ${rows.length} abonos. Podés ajustar los precios en la lista.`);
  };

  // ---- lista / edición
  const [edit, setEdit] = useState<Record<string, { price?: string; valid_days?: string; day_types?: DayType[] }>>({});
  const [pct, setPct] = useState('');
  const saveRow = (p: Product) => {
    const e = edit[p.id]; if (!e) return;
    const patch = { price: e.price !== undefined ? Number(e.price) : p.price, valid_days: e.valid_days !== undefined ? Number(e.valid_days) : p.valid_days, day_types: e.day_types ?? p.day_types };
    if (!(patch.price >= 0) || !Number.isInteger(patch.valid_days) || patch.valid_days < 1) { setMsg({ kind: 'error', text: 'Revisá el precio y la vigencia.' }); return; }
    if (patch.day_types.length === 0) { setMsg({ kind: 'error', text: 'Tildá al menos un tipo de día.' }); return; }
    void run(async () => { must(await supabase.from('pass_products').update(patch).eq('id', p.id)); setEdit(({ [p.id]: _, ...rest }) => rest); }, 'Abono actualizado.');
  };
  const toggle = (p: Product) => void run(async () => { must(await supabase.from('pass_products').update({ active: !p.active }).eq('id', p.id)); }, p.active ? 'Abono pausado.' : 'Abono activado.');
  const remove = (p: Product) => {
    if (!window.confirm('¿Eliminar este abono? Los ya vendidos no se modifican.')) return;
    void run(async () => { must(await supabase.from('pass_products').delete().eq('id', p.id)); }, 'Abono eliminado.');
  };
  const bulk = useBulk((products.data ?? []).map((p) => p.id));
  const removeSelected = () => {
    if (!confirmDelete(bulk.count, 'abono', 'abonos', 'Los abonos ya vendidos no se modifican.')) return;
    const ids = bulk.selected;
    void run(async () => { must(await supabase.from('pass_products').delete().in('id', ids)); bulk.clear(); }, ids.length === 1 ? 'Abono eliminado.' : `${ids.length} abonos eliminados.`);
  };
  const raise = () => {
    const n = Number(pct);
    if (!Number.isFinite(n) || n === 0 || n < -90 || n > 500) { setMsg({ kind: 'error', text: 'Ingresá un porcentaje (por ejemplo 15 o -10).' }); return; }
    const list = (products.data ?? []).filter((p) => p.active);
    if (list.length === 0 || !window.confirm(`¿Aplicar ${n > 0 ? '+' : ''}${n}% a los ${list.length} abonos activos?`)) return;
    void run(async () => {
      for (const p of list) must(await supabase.from('pass_products').update({ price: roundPrice(Number(p.price) * (1 + n / 100)) }).eq('id', p.id));
      setPct('');
    }, 'Precios actualizados.');
  };

  const label = (p: { place_a: string; place_b: string; seat_class: string | null }) =>
    `${names.get(p.place_a) ?? '…'} ↔ ${names.get(p.place_b) ?? '…'}${p.seat_class ? ` · ${p.seat_class}` : ''}`;

  // ---- venta
  const [sellForm, setSellForm] = useState({ product: '', dni: '', name: '', email: '', method: 'cash' as Method });
  const sellable = (products.data ?? []).filter((p) => p.active);
  const sellNames = useQuery(async () => {
    const ids = [...new Set((products.data ?? []).flatMap((p) => [p.place_a, p.place_b]))];
    return ids.length ? must(await supabase.from('places').select('id,name').in('id', ids)) as { id: string; name: string }[] : [];
  }, [(products.data ?? []).map((p) => p.id).join(',')]);
  for (const n of sellNames.data ?? []) names.set(n.id, n.name);
  const lookup = async () => {
    const dni = sellForm.dni.replace(/\D/g, '');
    if (dni.length < 6) return;
    const { data } = await supabase.rpc('ventanilla_find_passenger', { p_dni: dni });
    const hit = (data as { full_name: string; email: string | null }[] | null)?.[0];
    if (hit) setSellForm((f) => ({ ...f, name: f.name || hit.full_name, email: f.email || hit.email || '' }));
  };
  const sell = (e: FormEvent) => {
    e.preventDefault();
    if (!sellForm.product) { setMsg({ kind: 'error', text: 'Elegí el abono.' }); return; }
    if (sellForm.name.trim().length < 2 || sellForm.dni.replace(/\D/g, '').length < 7) { setMsg({ kind: 'error', text: 'Cargá nombre y apellido y un DNI válido (7 a 10 dígitos).' }); return; }
    void run(async () => {
      must(await supabase.rpc('pass_sell', {
        p_product: sellForm.product, p_holder_dni: sellForm.dni.replace(/\D/g, ''), p_holder_name: sellForm.name.trim(),
        p_holder_email: sellForm.email.trim() || null, p_payment_method: sellForm.method
      }));
      setSellForm((f) => ({ ...f, dni: '', name: '', email: '' })); sold.reload();
    }, 'Abono vendido. Ya se puede usar desde la ventanilla con el DNI del titular.');
  };

  // ---- vendidos
  const [q, setQ] = useState('');
  const sold = useQuery(async () => must(await supabase.rpc('staff_find_passes', { p_dni: q || null, p_only_active: false, p_limit: 100 })) as PassRow[], [q]);
  const voidPass = (p: PassRow) => {
    const reason = window.prompt(`Anular el abono de ${p.holder_name} (quedan ${p.trips_left} viajes). Motivo:`);
    if (reason === null) return;
    void run(async () => { must(await supabase.rpc('pass_void', { p_pass: p.pass_id, p_reason: reason })); sold.reload(); }, 'Abono anulado.');
  };
  const stateOf = (p: PassRow) => p.status === 'cancelled' ? 'Anulado' : p.expired ? 'Vencido' : p.trips_left === 0 ? 'Agotado' : 'Vigente';

  return (
    <>
      <h1>Abonos</h1>
      <p className="muted">Paquetes de viajes por tramo (en ambos sentidos). Se venden acá y se usan en la ventanilla eligiendo “Abono” como forma de pago.</p>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {[pairs.error, products.error, sold.error].filter(Boolean).map((e) => <Notice key={e}>{friendly(new Error(e as string))}</Notice>)}

      <form className="card stack" onSubmit={sell}>
        <h2>Vender un abono</h2>
        {sellable.length === 0 ? <p className="muted">{isAdmin ? 'Primero generá los abonos más abajo.' : 'La empresa todavía no configuró abonos.'}</p> : (
          <>
            <label>Abono
              <select value={sellForm.product} onChange={(e) => setSellForm({ ...sellForm, product: e.target.value })}>
                <option value="">Elegir...</option>
                {sellable.map((p) => <option key={p.id} value={p.id}>{label(p)} · {p.trips} viajes · {formatMoney(Number(p.price))} · {p.valid_days} días{daysTag(p.day_types)}</option>)}
              </select>
            </label>
            <div className="row">
              <label>DNI del titular<input inputMode="numeric" maxLength={12} value={sellForm.dni} onChange={(e) => setSellForm({ ...sellForm, dni: e.target.value })} onBlur={() => void lookup()} /></label>
              <label className="grow">Nombre y apellido<input maxLength={150} value={sellForm.name} onChange={(e) => setSellForm({ ...sellForm, name: e.target.value })} /></label>
              <label className="grow">Correo (opcional)<input type="email" maxLength={200} value={sellForm.email} onChange={(e) => setSellForm({ ...sellForm, email: e.target.value })} /></label>
            </div>
            <div className="vt-methods" role="radiogroup" aria-label="Forma de pago">
              {METHODS.map((m) => <button key={m.key} type="button" role="radio" aria-checked={sellForm.method === m.key} className={sellForm.method === m.key ? 'is-active' : ''} onClick={() => setSellForm({ ...sellForm, method: m.key })}>{m.label}</button>)}
            </div>
            <div><button type="submit" disabled={busy}>Cobrar abono</button></div>
          </>
        )}
      </form>

      <div className="card stack">
        <h2>Abonos vendidos</h2>
        <label>Buscar por DNI<input inputMode="numeric" placeholder="Todos" value={q} onChange={(e) => setQ(e.target.value.replace(/\D/g, ''))} /></label>
        {sold.loading ? <Loading /> : (sold.data ?? []).length === 0 ? <p className="muted">No hay abonos vendidos.</p> : (
          <div className="table-wrap"><table>
            <thead><tr><th>Titular</th><th>Tramo</th><th>Viajes</th><th>Vence</th><th>Estado</th><th /></tr></thead>
            <tbody>{(sold.data ?? []).map((p) => (
              <tr key={p.pass_id}>
                <td>{p.holder_name}<br /><small className="muted">DNI {p.holder_dni}</small></td>
                <td>{p.place_a_name} ↔ {p.place_b_name}{p.seat_class ? ` · ${p.seat_class}` : ''}{daysTag(p.day_types)}</td>
                <td><b>{p.trips_left}</b> / {p.trips_total}</td>
                <td>{fmtDate(p.expires_at)}</td>
                <td>{stateOf(p)}</td>
                <td>{isAdmin && p.status === 'active' && <button type="button" className="secondary" disabled={busy} onClick={() => voidPass(p)}>Anular</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </div>

      {isAdmin && (
        <>
          <div className="card stack">
            <h2>Generar abonos desde las tarifas</h2>
            <p className="muted">El precio sugerido es la tarifa del tramo × cantidad de viajes, menos el descuento. Después lo podés ajustar en la lista.</p>
            {pairs.loading ? <Loading /> : (pairs.data ?? []).length === 0 ? <Notice kind="warn">Primero cargá tarifas en “Tarifas”.</Notice> : (
              <>
                <label>Tramo
                  <select value={target} onChange={(e) => setTarget(e.target.value)}>
                    <option value="">Todos los tramos con tarifa</option>
                    {(pairs.data ?? []).map((p) => <option key={pairKey(p.place_a, p.place_b, p.seat_class)} value={pairKey(p.place_a, p.place_b, p.seat_class)}>{label(p)} · {formatMoney(Number(p.base_price))} por viaje</option>)}
                  </select>
                </label>
                <div className="table-wrap"><table>
                  <thead><tr><th>Viajes</th><th>Descuento %</th></tr></thead>
                  <tbody>{TIERS.map((t) => (
                    <tr key={t}>
                      <td><label><input type="checkbox" checked={!!tiers[t]} onChange={(e) => setTiers({ ...tiers, [t]: e.target.checked })} /> {t} viajes</label></td>
                      <td><input type="number" min={0} max={90} aria-label={`Descuento de ${t} viajes`} value={disc[t]} onChange={(e) => setDisc({ ...disc, [t]: e.target.value })} /></td>
                    </tr>
                  ))}</tbody>
                </table></div>
                <fieldset className="stack" style={{ border: 0, padding: 0, margin: 0 }}>
                  <legend>Días en que vale el abono</legend>
                  <div className="row">
                    {DAY_TYPES.map((t) => (
                      <label key={t} title={DAY_TYPE_LABEL[t]} style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                        <input type="checkbox" style={{ width: 20, minHeight: 20 }} checked={genDays.includes(t)}
                          onChange={(e) => setGenDays(e.target.checked ? [...genDays, t] : genDays.filter((x) => x !== t))} />{DAY_TYPE_LETTER[t]} · {DAY_TYPE_LABEL[t]}
                      </label>
                    ))}
                  </div>
                </fieldset>
                <div className="row">
                  <label>Vigencia (días desde la compra)<input type="number" min={1} max={365} value={days} onChange={(e) => setDays(e.target.value)} /></label>
                  <button type="button" disabled={busy} onClick={generate}>Generar abonos</button>
                </div>
              </>
            )}
          </div>

          <div className="card stack">
            <h2>Abonos configurados</h2>
            <div className="row">
              <label>Aumentar / bajar todos los precios (%)<input type="number" placeholder="Ej. 15" value={pct} onChange={(e) => setPct(e.target.value)} /></label>
              <button type="button" className="secondary" disabled={busy} onClick={raise}>Aplicar a los activos</button>
            </div>
            <BulkBar bulk={bulk} one="abono" many="abonos" busy={busy} onDelete={removeSelected} />
            {products.loading ? <Loading /> : (products.data ?? []).length === 0 ? <p className="muted">Todavía no hay abonos.</p> : (
              <div className="table-wrap"><table>
                <thead><tr><HeadCheck bulk={bulk} /><th>Tramo</th><th>Viajes</th><th>Precio</th><th>Vigencia (días)</th><th>Vale en</th><th>Estado</th><th /></tr></thead>
                <tbody>{(products.data ?? []).map((p) => {
                  const e = edit[p.id];
                  return (
                    <tr key={p.id}>
                      <RowCheck bulk={bulk} id={p.id} />
                      <td>{label(p)}</td><td>{p.trips}</td>
                      <td><input type="number" min={0} aria-label="Precio" style={{ width: '7rem' }} value={e?.price ?? String(p.price)} onChange={(ev) => setEdit({ ...edit, [p.id]: { ...e, price: ev.target.value } })} /></td>
                      <td><input type="number" min={1} max={365} aria-label="Días de vigencia" style={{ width: '5rem' }} value={e?.valid_days ?? String(p.valid_days)} onChange={(ev) => setEdit({ ...edit, [p.id]: { ...e, valid_days: ev.target.value } })} /></td>
                      <td>
                        <div className="row" style={{ gap: 8, flexWrap: 'nowrap' }}>
                          {DAY_TYPES.map((t) => {
                            const cur = e?.day_types ?? p.day_types;
                            return (
                              <label key={t} title={DAY_TYPE_LABEL[t]} style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                                <input type="checkbox" style={{ width: 18, minHeight: 18 }} aria-label={DAY_TYPE_LABEL[t]} checked={cur.includes(t)}
                                  onChange={(ev) => setEdit({ ...edit, [p.id]: { ...e, day_types: ev.target.checked ? [...cur, t] : cur.filter((x) => x !== t) } })} />{DAY_TYPE_LETTER[t]}
                              </label>
                            );
                          })}
                        </div>
                      </td>
                      <td>{p.active ? 'Activo' : 'Pausado'}</td>
                      <td className="row">
                        {e && <button type="button" disabled={busy} onClick={() => saveRow(p)}>Guardar</button>}
                        <button type="button" className="secondary" disabled={busy} onClick={() => toggle(p)}>{p.active ? 'Pausar' : 'Activar'}</button>
                        <button type="button" className="secondary" disabled={busy} onClick={() => remove(p)}>Eliminar</button>
                      </td>
                    </tr>
                  );
                })}</tbody>
              </table></div>
            )}
          </div>
        </>
      )}
    </>
  );
}
