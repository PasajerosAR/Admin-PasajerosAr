import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { FilterBox, Loading, Notice, matches } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Route, RouteStop, Service, ServiceDeparture, ServiceStop } from '../lib/types';
import { DAY_TYPES, DAY_TYPE_LABEL, DAY_TYPE_LETTER, type DayType } from '../lib/dayType';

interface Times { minutes_from_start: number; dwell_minutes: number; publish_from_web?: boolean }
interface DepForm { id: string | null; route_id: string; time: string; types: DayType[]; active: boolean }
const blankDep = (route_id = ''): DepForm => ({ id: null, route_id, time: '08:00', types: ['weekday', 'saturday', 'sunday'], active: true });
const addMinutesToTime = (time: string, minutes: number) => {
  const [hours, mins] = time.split(':').map(Number);
  const total = (hours * 60 + mins + minutes) % (24 * 60);
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
};

// Un servicio agrupa varias salidas (de ida y de vuelta). Los tiempos por parada son iguales para todas las salidas de un mismo sentido.
export function ServicesPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [folder, setFolder] = useState<DayType>('weekday');
  const [q, setQ] = useState('');
  const [editing, setEditing] = useState<string | null>(null); // id o 'nuevo'
  const [code, setCode] = useState('');
  const [deps, setDeps] = useState<DepForm[]>([]);
  const [times, setTimes] = useState<Record<string, Times>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);

  const services = useQuery(async () => must(await supabase.from('services').select('*').is('deleted_at', null).order('code')) as Service[], []);
  const allDeps = useQuery(async () => must(await supabase.from('service_departures').select('*').order('departure_time')) as ServiceDeparture[], []);
  const routes = useQuery(async () => must(await supabase.from('routes').select('*').eq('active', true).order('name')) as Route[], []);
  const stops = useQuery(async () => must(await supabase.from('route_stops').select('*').order('position')) as RouteStop[], []);
  const svcStops = useQuery(async () => must(await supabase.from('service_stops').select('*')) as ServiceStop[], []);
  const standard = useQuery(async () => must(await supabase.from('route_times').select('route_stop_id,minutes_from_start,dwell_minutes')) as Omit<ServiceStop, 'service_id'>[], []);
  const routeName = (id: string) => routes.data?.find((r) => r.id === id)?.name ?? '-';
  const stopsOf = (rid: string) => (stops.data ?? []).filter((s) => s.route_id === rid);
  const usedRoutes = [...new Set(deps.map((d) => d.route_id).filter(Boolean))];

  // Tiempos de un sentido nuevo: los del servicio si ya estaban guardados, si no los estándar del recorrido, si no escalonados cada 20 min.
  const withDefaults = (current: Record<string, Times>, rids: string[], saved: Omit<ServiceStop, 'service_id'>[] = []) => {
    const next = { ...current };
    for (const rid of rids) stopsOf(rid).forEach((s, i) => {
      if (next[s.id]) return;
      const p = saved.find((x) => x.route_stop_id === s.id) ?? standard.data?.find((x) => x.route_stop_id === s.id);
      next[s.id] = p ? { minutes_from_start: p.minutes_from_start, dwell_minutes: p.dwell_minutes, publish_from_web: p.publish_from_web ?? false } : { minutes_from_start: i * 20, dwell_minutes: 0, publish_from_web: false };
    });
    return next;
  };

  const openNew = () => { setMsg(null); setEditing('nuevo'); setCode(''); setDeps([blankDep()]); setTimes({}); };
  const openEdit = (s: Service) => {
    setMsg(null); setEditing(s.id); setCode(s.code);
    const mine = (allDeps.data ?? []).filter((d) => d.service_id === s.id);
    setDeps(mine.map((d) => ({ id: d.id, route_id: d.route_id, time: d.departure_time.slice(0, 5), types: d.day_types, active: d.active })));
    setTimes(withDefaults({}, [...new Set(mine.map((d) => d.route_id))], (svcStops.data ?? []).filter((x) => x.service_id === s.id)));
  };

  const patchDep = (i: number, p: Partial<DepForm>) => {
    const next = deps.map((d, j) => (j === i ? { ...d, ...p } : d));
    setDeps(next);
    if (p.route_id) setTimes(withDefaults(times, [p.route_id]));
  };

  const save = async (e: FormEvent) => {
    e.preventDefault();
    const existing = services.data?.find((s) => s.id === editing);
    const { data: savedServiceId, error } = await supabase.rpc('save_service', {
      p_service: editing === 'nuevo' ? null : editing, p_code: code, p_active: existing?.active ?? true,
      p_departures: deps.map((d) => ({ id: d.id, route_id: d.route_id, time: d.time, day_types: d.types, active: d.active })),
      p_stops: usedRoutes.flatMap((rid) => stopsOf(rid).map((s) => ({ route_stop_id: s.id, ...times[s.id] })))
    });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    const savedFlags = await Promise.all(usedRoutes.map((rid) => supabase.rpc('save_service_web_departures', {
      p_service: savedServiceId,
      p_route: rid,
      p_stop_ids: stopsOf(rid).filter((stop, index, routeStops) => index > 0 && index < routeStops.length - 1 && times[stop.id]?.publish_from_web).map((stop) => stop.id)
    })));
    const flagError = savedFlags.find((result) => result.error)?.error;
    if (flagError) { setMsg({ kind: 'error', text: `El servicio se guardó, pero no se pudieron guardar las salidas publicadas en la web: ${friendly(flagError)}` }); return; }
    // la primera vez que se cargan los tiempos de un sentido quedan como estándar
    const fresh = usedRoutes.filter((rid) => !hasStandard(rid));
    if (fresh.length) await saveStandard(fresh);
    setMsg({ kind: 'ok', text: 'Servicio guardado.' });
    setEditing(null); services.reload(); allDeps.reload(); svcStops.reload();
  };

  const remove = async (s: Service) => {
    if (!window.confirm(`Eliminar el servicio ${s.code}? Desaparece de la lista; los viajes y ventas ya hechos se conservan en el historial. Los viajes futuros se cancelan.`)) return;
    setRemoving(s.id);
    const { error } = await supabase.rpc('remove_service', { p_service: s.id });
    setRemoving(null);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: `Servicio ${s.code} eliminado.` });
    if (editing === s.id) setEditing(null);
    services.reload(); allDeps.reload(); svcStops.reload();
  };

  const toggle = async (s: Service) => {
    const { error } = await supabase.from('services').update({ active: !s.active }).eq('id', s.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else services.reload();
  };

  // Guarda los tiempos de un sentido como los estándar de la empresa para ese recorrido.
  const saveStandard = async (rids: string[]) => {
    const rows = rids.flatMap((rid) => stopsOf(rid).map((s) => ({ company_id: profile?.company_id, route_stop_id: s.id, ...times[s.id] })));
    const { error } = await supabase.from('route_times').upsert(rows);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return false; }
    standard.reload();
    return true;
  };
  const useStandard = (rid: string) => {
    const next = { ...times };
    for (const s of stopsOf(rid)) {
      const p = standard.data?.find((x) => x.route_stop_id === s.id);
      if (p) next[s.id] = { minutes_from_start: p.minutes_from_start, dwell_minutes: p.dwell_minutes };
    }
    setTimes(next);
  };
  const hasStandard = (rid: string) => stopsOf(rid).some((s) => standard.data?.some((x) => x.route_stop_id === s.id));

  const patchTime = (id: string, p: Partial<Times>) => setTimes({ ...times, [id]: { ...times[id], ...p } });
  const inFolder = (s: Service) => (allDeps.data ?? []).filter((d) => d.service_id === s.id && d.day_types.includes(folder));
  const folderServices = (services.data ?? []).filter((s) => inFolder(s).length > 0);
  const countIn = (t: DayType) => (services.data ?? []).filter((s) => (allDeps.data ?? []).some((d) => d.service_id === s.id && d.day_types.includes(t))).length;
  const summary = (s: Service) => {
    const mine = inFolder(s);
    return [...new Set(mine.map((d) => d.route_id))].map((rid) => (
      <div key={rid}><b>{routeName(rid)}:</b> {mine.filter((d) => d.route_id === rid).map((d) => (
        <span key={d.id} title={d.day_types.map((t) => DAY_TYPE_LABEL[t]).join(', ')} style={{ marginRight: 10 }}>
          {d.departure_time.slice(0, 5)} <span className="muted" style={{ fontSize: 12 }}>{DAY_TYPES.filter((t) => d.day_types.includes(t)).map((t) => DAY_TYPE_LETTER[t]).join('')}</span>
        </span>))}</div>
    ));
  };

  return (
    <>
      <div className="row page-heading" style={{ alignItems: 'center' }}>
        <h1>Servicios</h1>
        {canEdit && <button onClick={openNew}>Nuevo servicio</button>}
      </div>
      
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && editing && (
        <form className="card stack" onSubmit={save} aria-label="Servicio">
          <h2>{editing === 'nuevo' ? 'Nuevo servicio' : 'Editar servicio'}</h2>
          <label style={{ maxWidth: 240 }}>Código del servicio<input value={code} onChange={(e) => setCode(e.target.value)} required placeholder="214" /></label>

          <h3 style={{ margin: '4px 0 0' }}>Salidas</h3>
          <p className="muted" style={{ margin: 0 }}>Cargá todas las salidas del servicio: ida y vuelta, cada una con su horario y los tipos de día en que circula. Un feriado puede tener su propia grilla de horarios.</p>
          {deps.map((d, i) => (
            <div key={i} className="card" style={{ background: d.active ? undefined : '#f3f4f6' }}>
              <div className="row" style={{ alignItems: 'flex-end' }}>
                <label>Sentido (recorrido)
                  <select value={d.route_id} onChange={(e) => patchDep(i, { route_id: e.target.value })} required>
                    <option value="">Elegir...</option>
                    {(routes.data ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
                  </select>
                </label>
                <label style={{ flex: '0 0 140px' }}>Hora de salida<input type="time" value={d.time} onChange={(e) => patchDep(i, { time: e.target.value })} required /></label>
                <label style={{ flex: '0 0 auto', flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                  <input type="checkbox" style={{ width: 20, minHeight: 20 }} checked={d.active} onChange={(e) => patchDep(i, { active: e.target.checked })} />Activa
                </label>
                <button type="button" className="danger" disabled={deps.length <= 1} onClick={() => setDeps(deps.filter((_, j) => j !== i))}>Quitar</button>
              </div>
              <div className="row" style={{ marginTop: 8, flexWrap: 'wrap', gap: 10 }} role="group" aria-label="Tipos de día de la salida">
                {DAY_TYPES.map((t) => (
                  <label key={t} style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flex: '0 0 auto' }}>
                    <input type="checkbox" style={{ width: 20, minHeight: 20 }} checked={d.types.includes(t)}
                      onChange={(e) => patchDep(i, { types: e.target.checked ? [...d.types, t] : d.types.filter((x) => x !== t) })} />{DAY_TYPE_LABEL[t]}
                  </label>
                ))}
              </div>
            </div>
          ))}
          <div className="row">
            <button type="button" className="secondary" onClick={() => setDeps([...deps, blankDep(deps.at(-1)?.route_id)])}>Agregar salida</button>
          </div>

          {usedRoutes.map((rid) => (
            <div key={rid} className="table-wrap service-times">
              <table>
                <caption className="muted" style={{ textAlign: 'left', paddingBottom: 6 }}>Tiempos en cada parada: <b>{routeName(rid)}</b> (valen para todas sus salidas)
                  <span style={{ marginLeft: 10 }}>
                    <button type="button" className="secondary" disabled={!hasStandard(rid)} onClick={() => useStandard(rid)}>Usar horarios estándar</button>{' '}
                    <button type="button" className="secondary" onClick={async () => { if (await saveStandard([rid])) setMsg({ kind: 'ok', text: `Horarios estándar de ${routeName(rid)} guardados.` }); }}>Guardar como estándar</button>
                  </span></caption>
                <thead><tr><th>#</th><th>Parada</th><th>Minutos desde la salida</th><th>Permanencia (min)</th><th>Salida independiente en la web</th></tr></thead>
                <tbody>
                  {stopsOf(rid).map((s, i, routeStops) => (
                    <tr key={s.id}>
                      <td>{i + 1}</td><td>{s.name}</td>
                      <td><input className="service-time-number" aria-label={`Minutos desde la salida en ${s.name}`} type="number" min={0} disabled={i === 0} value={times[s.id]?.minutes_from_start ?? 0}
                        onChange={(e) => patchTime(s.id, { minutes_from_start: Number(e.target.value) })} /></td>
                      <td><input className="service-time-number" aria-label={`Permanencia en ${s.name}`} type="number" min={0} value={times[s.id]?.dwell_minutes ?? 0}
                        onChange={(e) => patchTime(s.id, { dwell_minutes: Number(e.target.value) })} /></td>
                      <td>
                        {i > 0 && i < routeStops.length - 1 && (
                          <div className="service-web-controls">
                            <label className="service-web-toggle" aria-label={`Publicar ${s.name} como salida independiente en la web`}>
                              <input type="checkbox" checked={times[s.id]?.publish_from_web ?? false}
                                onChange={(e) => patchTime(s.id, { publish_from_web: e.target.checked })} />
                            </label>
                            <div className="service-web-previews">
                              {deps.filter((departure) => departure.route_id === rid).map((departure) => {
                                const minutes = times[s.id]?.minutes_from_start ?? 0;
                                const arrival = addMinutesToTime(departure.time, minutes);
                                return <div className="service-web-preview" key={`${departure.id ?? 'new'}-${departure.time}`}>
                                  {departure.time} + {minutes} min = <b>llegada {arrival}</b>
                                </div>;
                              })}
                            </div>
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
          <div className="row">
            <button type="submit">Guardar servicio</button>
            <button type="button" className="secondary" onClick={() => setEditing(null)}>Cancelar</button>
          </div>
        </form>
      )}
      <div className="row" style={{ flexWrap: 'wrap', gap: 8 }} role="tablist" aria-label="Carpetas por tipo de día">
        {DAY_TYPES.map((t) => (
          <button key={t} role="tab" aria-selected={t === folder} className={t === folder ? '' : 'secondary'} onClick={() => setFolder(t)}>
            {DAY_TYPE_LABEL[t]} ({countIn(t)})
          </button>
        ))}
      </div>
      <div className="card table-wrap">
        <FilterBox value={q} onChange={setQ} placeholder="Buscar servicio" />
        {services.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Servicio</th><th>Salidas de {DAY_TYPE_LABEL[folder].toLowerCase()} (letras: H hábil, S sábado, D domingo, F feriado)</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {folderServices.filter((s) => matches(q, s.code)).length === 0 && <tr><td colSpan={4} className="muted">No hay servicios con salidas de {DAY_TYPE_LABEL[folder].toLowerCase()}.</td></tr>}
              {folderServices.filter((s) => matches(q, s.code)).map((s) => (
                <tr key={s.id}>
                  <td><b>{s.code}</b></td>
                  <td>{summary(s)}</td>
                  <td>{s.active ? <span className="pill ok">Activo</span> : <span className="pill warn">Pausado</span>}</td>
                  <td>{canEdit && <div className="row"><button className="secondary" onClick={() => openEdit(s)}>Editar</button><button className="secondary" onClick={() => toggle(s)}>{s.active ? 'Pausar' : 'Activar'}</button><button className="danger" disabled={removing === s.id} onClick={() => remove(s)}>{removing === s.id ? 'Eliminando...' : 'Eliminar'}</button></div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
