import { useEffect, useRef, useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { Loading, Notice, PageHead } from '../../ui';
import { useAuth } from '../../auth/AuthProvider';
import { WEEK_DAYS, gridFromRows, useFareBands } from '../../lib/fareBands';

interface Exc { id: string; on_date: string; from_hour: number; to_hour: number; band_id: string }
const hh = (h: number) => `${String(h).padStart(2, '0')}:00`;
const fmtDate = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('es-AR', { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' });

// Franjas horarias de precio: catálogo de franjas, semana base (día × hora de salida) y excepciones por fecha.
export function FranjasPage() {
  const { profile } = useAuth();
  const { bands, loading: bandsLoading, reload: reloadBands } = useFareBands();
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>, ok: string) => {
    setBusy(true); setMsg(null);
    try { await fn(); setMsg({ kind: 'ok', text: ok }); } catch (e) { setMsg({ kind: 'error', text: friendly(e) }); } finally { setBusy(false); }
  };

  // ---- franjas
  const [bandForm, setBandForm] = useState({ id: '', name: '', color: '#0f5b8a' });
  const saveBand = (e: FormEvent) => {
    e.preventDefault();
    void run(async () => {
      const { error } = await supabase.rpc('save_fare_band', { p_id: bandForm.id || null, p_name: bandForm.name, p_color: bandForm.color });
      if (error) throw error;
      setBandForm({ id: '', name: '', color: '#0f5b8a' }); reloadBands();
    }, 'Franja guardada.');
  };
  const removeBand = (id: string, name: string) => {
    if (!window.confirm(`¿Eliminar la franja “${name}”? Solo se puede si no tiene tarifas, abonos, viajes ni lugar en la semana.`)) return;
    void run(async () => { const { error } = await supabase.rpc('delete_fare_band', { p_id: id }); if (error) throw error; reloadBands(); }, 'Franja eliminada.');
  };

  // ---- semana base
  const weekly = useQuery(async () => profile?.company_id
    ? must(await supabase.from('fare_band_weekly').select('dow,hour,band_id').eq('company_id', profile.company_id)) as { dow: number; hour: number; band_id: string }[]
    : [], [profile?.company_id]);
  const [grid, setGrid] = useState<string[][] | null>(null);          // códigos; null = sin cambios
  const byCode = new Map(bands.map((b) => [b.code, b]));
  const current = (() => {
    const ids = new Map(bands.map((b) => [b.id, b.code]));
    return gridFromRows((weekly.data ?? []).flatMap((r) => ids.get(r.band_id) ? [{ dow: r.dow, hour: r.hour, code: ids.get(r.band_id)! }] : []), bands[0]?.code ?? 'weekday');
  })();
  const cells = grid ?? current;
  const [brush, setBrush] = useState('');
  const paint = brush || bands[0]?.code || '';
  const painting = useRef(false);
  useEffect(() => { const up = () => { painting.current = false; }; window.addEventListener('pointerup', up); return () => window.removeEventListener('pointerup', up); }, []);
  const setCell = (d: number, h: number) => {
    if (!paint || cells[d][h] === paint) return;
    setGrid(cells.map((row, i) => (i === d ? row.map((c, j) => (j === h ? paint : c)) : row)));
  };
  const saveWeek = () => void run(async () => {
    const { error } = await supabase.rpc('save_fare_week', { p_grid: cells });
    if (error) throw error;
    setGrid(null); weekly.reload();
  }, 'Semana guardada. Rige para los viajes que se generen desde ahora; los ya generados conservan su franja.');

  // ---- excepciones
  const exceptions = useQuery(async () => profile?.company_id
    ? must(await supabase.from('fare_band_exceptions').select('id,on_date,from_hour,to_hour,band_id').eq('company_id', profile.company_id).gte('on_date', new Date().toISOString().slice(0, 10)).order('on_date').order('from_hour')) as Exc[]
    : [], [profile?.company_id]);
  const [exc, setExc] = useState({ date: '', from: '0', to: '24', band: '' });
  const addExc = (e: FormEvent) => {
    e.preventDefault();
    if (!exc.date || !exc.band) { setMsg({ kind: 'error', text: 'Elegí la fecha y la franja.' }); return; }
    void run(async () => {
      const { error } = await supabase.rpc('save_fare_exception', { p_date: exc.date, p_from_hour: Number(exc.from), p_to_hour: Number(exc.to), p_band: exc.band });
      if (error) throw error;
      setExc({ date: '', from: '0', to: '24', band: exc.band }); exceptions.reload();
    }, 'Excepción guardada. Rige para los viajes que se generen desde ahora.');
  };
  const removeExc = (id: string) => void run(async () => { const { error } = await supabase.rpc('delete_fare_exception', { p_id: id }); if (error) throw error; exceptions.reload(); }, 'Excepción eliminada.');
  const bandOf = (id: string) => bands.find((b) => b.id === id);

  return (
    <>
      <PageHead title="Franjas horarias" subtitle="Definí franjas de precio (por ejemplo Nocturno o Hora pico), pintá en qué días y horas de salida rige cada una y cargá excepciones por fecha. Las tarifas y los abonos se configuran por franja. El tipo de día (hábil, sábado, domingo, feriado) sigue decidiendo qué horarios corren." />
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {bandsLoading ? <Loading /> : (
        <>
          <div className="card stack">
            <h2>Franjas</h2>
            <div className="table-wrap"><table>
              <thead><tr><th>Franja</th><th /></tr></thead>
              <tbody>{bands.map((b) => (
                <tr key={b.id}>
                  <td><span style={{ display: 'inline-block', width: 14, height: 14, borderRadius: 3, background: b.color, marginRight: 8, verticalAlign: 'middle' }} aria-hidden="true" />{b.name}</td>
                  <td className="row">
                    <button type="button" className="secondary" disabled={busy} onClick={() => setBandForm({ id: b.id, name: b.name, color: b.color })}>Editar</button>
                    <button type="button" className="secondary" disabled={busy} onClick={() => removeBand(b.id, b.name)}>Eliminar</button>
                  </td>
                </tr>
              ))}</tbody>
            </table></div>
            <form className="row" onSubmit={saveBand}>
              <label className="grow">{bandForm.id ? 'Nombre de la franja' : 'Nueva franja'}<input maxLength={40} value={bandForm.name} onChange={(e) => setBandForm({ ...bandForm, name: e.target.value })} placeholder="Ej. Nocturno" required /></label>
              <label>Color<input type="color" value={bandForm.color} onChange={(e) => setBandForm({ ...bandForm, color: e.target.value })} /></label>
              <button type="submit" disabled={busy}>{bandForm.id ? 'Guardar cambios' : 'Agregar franja'}</button>
              {bandForm.id && <button type="button" className="secondary" onClick={() => setBandForm({ id: '', name: '', color: '#0f5b8a' })}>Cancelar</button>}
            </form>
          </div>

          <div className="card stack">
            <h2>Semana base</h2>
            <p className="muted">Elegí una franja y pintá las celdas (tocá o arrastrá). Cada celda es la hora de salida del viaje, en hora de Argentina.</p>
            <div className="row" role="radiogroup" aria-label="Franja a pintar">
              {bands.map((b) => (
                <button key={b.id} type="button" role="radio" aria-checked={paint === b.code} className={paint === b.code ? '' : 'secondary'}
                  style={{ borderLeft: `8px solid ${b.color}` }} onClick={() => setBrush(b.code)}>{b.name}</button>
              ))}
            </div>
            {weekly.loading ? <Loading /> : (
              <div className="table-wrap" style={{ touchAction: 'none' }}>
                <table style={{ borderCollapse: 'collapse', userSelect: 'none' }}>
                  <thead><tr><th />{Array.from({ length: 24 }, (_, h) => <th key={h} style={{ fontSize: 11, padding: '2px 0', textAlign: 'center' }}>{h}</th>)}</tr></thead>
                  <tbody>{WEEK_DAYS.map((name, d) => (
                    <tr key={name}>
                      <th style={{ textAlign: 'left', paddingRight: 8, whiteSpace: 'nowrap' }}>{name}</th>
                      {cells[d].map((code, h) => (
                        <td key={h} title={`${name} ${hh(h)}: ${byCode.get(code)?.name ?? code}`}
                          style={{ width: 26, minWidth: 26, height: 26, padding: 0, background: byCode.get(code)?.color ?? '#999999', border: '1px solid rgba(255,255,255,.6)', cursor: 'pointer' }}
                          onPointerDown={(e) => { (e.target as Element).releasePointerCapture?.(e.pointerId); painting.current = true; setCell(d, h); }}
                          onPointerEnter={() => { if (painting.current) setCell(d, h); }} />
                      ))}
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            )}
            <div className="row">
              <button type="button" disabled={busy || !grid} onClick={saveWeek}>Guardar semana</button>
              {grid && <button type="button" className="secondary" disabled={busy} onClick={() => setGrid(null)}>Descartar cambios</button>}
            </div>
          </div>

          <div className="card stack">
            <h2>Excepciones por fecha</h2>
            <p className="muted">Para feriados, puentes o fechas especiales: pisan la semana base en ese rango de horas de salida.</p>
            <form className="row" onSubmit={addExc}>
              <label>Fecha<input type="date" value={exc.date} onChange={(e) => setExc({ ...exc, date: e.target.value })} required /></label>
              <label>Desde<select value={exc.from} onChange={(e) => setExc({ ...exc, from: e.target.value })}>{Array.from({ length: 24 }, (_, h) => <option key={h} value={h}>{hh(h)}</option>)}</select></label>
              <label>Hasta<select value={exc.to} onChange={(e) => setExc({ ...exc, to: e.target.value })}>{Array.from({ length: 24 }, (_, h) => <option key={h + 1} value={h + 1}>{hh(h + 1)}</option>)}</select></label>
              <label>Franja<select value={exc.band} onChange={(e) => setExc({ ...exc, band: e.target.value })} required><option value="">Elegir...</option>{bands.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
              <button type="submit" disabled={busy}>Agregar excepción</button>
            </form>
            {exceptions.loading ? <Loading /> : (exceptions.data ?? []).length === 0 ? <p className="muted">No hay excepciones próximas.</p> : (
              <div className="table-wrap"><table>
                <thead><tr><th>Fecha</th><th>Horas</th><th>Franja</th><th /></tr></thead>
                <tbody>{(exceptions.data ?? []).map((x) => (
                  <tr key={x.id}>
                    <td>{fmtDate(x.on_date)}</td><td>{hh(x.from_hour)} a {hh(x.to_hour)}</td>
                    <td>{bandOf(x.band_id)?.name ?? '—'}</td>
                    <td><button type="button" className="secondary" disabled={busy} onClick={() => removeExc(x.id)}>Eliminar</button></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
        </>
      )}
    </>
  );
}
