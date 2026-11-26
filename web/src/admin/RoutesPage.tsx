import { useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { FilterBox, Loading, Notice, matches } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Company, Locality, Route, RouteStop } from '../lib/types';
import type { Maneuver } from '../lib/turnGuide';
import { buildWaypoints, nearestSegment, routeByStreets, sortVia, type LatLng, type Via } from '../lib/routePath';
import { StopMap } from './StopMap';

interface StopForm { name: string; lat: string; lng: string; place_id: string }
const blankStop = (): StopForm => ({ name: '', lat: '', lng: '', place_id: '' });
const blankStops = (): StopForm[] => [blankStop(), blankStop()];
type Trace = 'idle' | 'tracing' | 'ok' | 'error';

// El catalogo de recorridos lo administra la plataforma; las empresas solo lo consultan.
export function RoutesPage() {
  const { profile } = useAuth();
  const permissions = useQuery(async () => profile?.role === 'platform_staff'
    ? must(await supabase.from('platform_permissions').select('section,can_edit')
      .or('section.eq.routes,section.eq.all')) as { section: string; can_edit: boolean }[]
    : [], [profile?.role]);
  const canEdit = profile?.role === 'platform_admin'
    || Boolean(permissions.data?.some((permission) => permission.can_edit));
  const [editing, setEditing] = useState<string | null>(null); // id o 'nuevo'
  const [name, setName] = useState('');
  const [companyId, setCompanyId] = useState('');
  const [stops, setStops] = useState<StopForm[]>(blankStops());
  const [sel, setSel] = useState<number | null>(0);
  const [inUse, setInUse] = useState(false); // el recorrido ya tiene servicios: el orden de paradas no se puede cambiar
  const [via, setVia] = useState<Via[]>([]);
  const [path, setPath] = useState<LatLng[] | null>(null);
  const [maneuvers, setManeuvers] = useState<Maneuver[] | null>(null);
  const [trace, setTrace] = useState<Trace>('idle');
  const [mode, setMode] = useState<'stop' | 'via'>('stop');
  const [retryN, setRetryN] = useState(0);
  const tracedKey = useRef('');   // trazado ya calculado (o cargado) para estas paradas y puntos de paso
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const routes = useQuery(async () => must(await supabase.from('routes').select('*').order('name')) as Route[], []);
  const companies = useQuery(async () => canEdit ? must(await supabase.from('companies').select('*').is('deleted_at', null).order('name')) as Company[] : [], [canEdit]);
  const companyName = (id: string | null) => companies.data?.find((c) => c.id === id)?.name ?? 'Sin asignar';
  const places = useQuery(async () => must(await supabase.from('places').select('*').order('name')) as Locality[], []);
  const placeName = (id: string | null) => places.data?.find((p) => p.id === id)?.name ?? null;
  const allStops = useQuery(async () => must(await supabase.from('route_stops').select('*').order('position')) as RouteStop[], []);
  const stopsOf = (id: string) => (allStops.data ?? []).filter((s) => s.route_id === id);

  const open = (r: Route | null) => {
    setMsg(null);
    setMode('stop');
    if (!r) {
      setEditing('nuevo'); setName(''); setCompanyId(''); setStops(blankStops()); setSel(0); setInUse(false);
      setVia([]); setPath(null); setManeuvers(null); setTrace('idle'); tracedKey.current = ''; return;
    }
    const loaded = stopsOf(r.id).map((s) => ({ name: s.name, lat: s.lat?.toString() ?? '', lng: s.lng?.toString() ?? '', place_id: s.place_id ?? '' }));
    setEditing(r.id); setName(r.name); setCompanyId(r.company_id ?? ''); setSel(0); setInUse(true);
    void supabase.from('service_departures').select('id', { count: 'exact', head: true }).eq('route_id', r.id)
      .then(({ count }) => setInUse((count ?? 0) > 0));
    setStops(loaded); setVia(r.via ?? []); setPath(r.path); setManeuvers(r.maneuvers);
    setTrace(r.path && r.maneuvers ? 'ok' : 'idle');
    tracedKey.current = r.path && r.maneuvers ? JSON.stringify(buildWaypoints(loaded, r.via ?? [])) : '';
  };

  // Traza por calles cada vez que cambian las paradas o los puntos de paso (con una pausa para no consultar en cada arrastre).
  const waypoints = buildWaypoints(stops, via);
  const wpKey = JSON.stringify(waypoints);
  useEffect(() => {
    if (!editing || !canEdit) return;
    if (!waypoints) { tracedKey.current = ''; setPath(null); setManeuvers(null); setTrace('idle'); return; }
    if (wpKey === tracedKey.current) return;
    setTrace('tracing');
    let cancelled = false;
    const t = setTimeout(async () => {
      try {
        const result = await routeByStreets(waypoints);
        if (cancelled) return;
        tracedKey.current = wpKey; setPath(result.path); setManeuvers(result.maneuvers); setTrace('ok');
      } catch { if (!cancelled) { setPath(null); setTrace('error'); } }
    }, 900);
    return () => { cancelled = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wpKey, editing, retryN]);

  const retrace = () => { tracedKey.current = ''; setRetryN((n) => n + 1); };

  const save = async () => {
    const clean = stops.filter((s) => s.name.trim()).map((s) => ({ name: s.name, lat: s.lat.trim(), lng: s.lng.trim(), place_id: s.place_id }));
    if (trace === 'tracing') { setMsg({ kind: 'error', text: 'Esperá un momento: se está trazando el recorrido por las calles.' }); return; }
    const { data: savedId, error } = await supabase.rpc('save_route', {
      p_route: editing === 'nuevo' ? null : editing, p_name: name, p_active: true, p_stops: clean, p_company: companyId || null,
      p_path: trace === 'ok' ? path : null, p_via: via
    });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    if (typeof savedId !== 'string') {
      setMsg({ kind: 'error', text: 'El recorrido se guardó, pero no se recibió su identificador para guardar las indicaciones de giro.' });
      return;
    }
    const { error: maneuverError } = await supabase.rpc('save_route_maneuvers', {
      p_route: savedId, p_maneuvers: trace === 'ok' ? maneuvers : null
    });
    if (maneuverError) {
      setEditing(savedId);
      routes.reload(); allStops.reload();
      setMsg({ kind: 'error', text: `El recorrido se guardó, pero no se pudieron guardar sus indicaciones de giro: ${friendly(maneuverError)}` });
      return;
    }
    setMsg({ kind: 'ok', text: 'Recorrido guardado.' });
    setEditing(null); routes.reload(); allStops.reload();
  };

  // Los puntos de paso se guardan por tramo; si se quita una parada, se descartan para no dejar tramos mal asignados.
  const addVia = (lat: number, lng: number) => setVia(sortVia(stops, [...via, { seg: nearestSegment(stops, [lat, lng]), lat, lng }]));
  const [q, setQ] = useState('');
  const moveVia = (i: number, lat: number, lng: number) => setVia(sortVia(stops, via.map((v, j) => (j === i ? { ...v, lat, lng } : v))));
  const removeVia = (i: number) => setVia(via.filter((_, j) => j !== i));
  // Subir/bajar una parada (los puntos de paso se guardan por tramo, por eso se descartan al reordenar).
  const moveStop = (i: number, to: number) => {
    if (inUse || to < 0 || to >= stops.length) return;
    const next = [...stops];
    [next[i], next[to]] = [next[to], next[i]];
    setStops(next); setVia([]); setSel(to);
  };
  const patch = (i: number, p: Partial<StopForm>) => setStops(stops.map((s, j) => (j === i ? { ...s, ...p } : s)));

  return (
    <>
      <div className="row page-heading" style={{ alignItems: 'center' }}>
        <h1>Recorridos</h1>
        {canEdit && <button onClick={() => open(null)}>+ Nuevo recorrido</button>}
      </div>
      {!canEdit && <p className="muted">Estos son los recorridos de tu empresa; los carga la plataforma. Si necesitás uno nuevo o una corrección, pedilo al administrador general.</p>}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      {editing && (
        <section className="card route-editor" aria-label="Editar recorrido">
          <div className="route-editor-header">
            <h2>{editing === 'nuevo' ? 'Nuevo recorrido' : 'Editar recorrido'}</h2>
          </div>

          {/* Campos principales en fila compacta */}
          <div className="row" style={{ alignItems: 'flex-end', gap: 10 }}>
            <label style={{ flex: '1 1 240px', maxWidth: 320 }}>Empresa
              <select value={companyId} onChange={(e) => setCompanyId(e.target.value)} required>
                <option value="">Elegir empresa…</option>
                {(companies.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </label>
            <label style={{ flex: '1 1 240px', maxWidth: 360 }}>Nombre del recorrido
              <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Paraná - Santa Fe" />
            </label>
          </div>

          {inUse && editing !== 'nuevo' && (
            <p className="muted route-locked-notice">
              <span>⚠</span> Este recorrido ya tiene servicios: solo se pueden corregir nombres, localidades y coordenadas.
            </p>
          )}

          {/* Tabla de paradas */}
          <div className="table-wrap">
            <table className="stops-table">
              <thead>
                <tr>
                  <th style={{ width: 32 }}>#</th>
                  <th>Parada</th>
                  <th style={{ width: 160 }}>Localidad</th>
                  <th style={{ width: 110 }}>Latitud</th>
                  <th style={{ width: 110 }}>Longitud</th>
                  <th style={{ width: 100 }} />
                </tr>
              </thead>
              <tbody>
                {stops.map((s, i) => (
                  <tr key={i} className={sel === i ? 'sel-row' : ''} onClick={() => setSel(i)}>
                    <td style={{ color: 'var(--muted)', fontWeight: 700, fontSize: 12 }}>{i + 1}</td>
                    <td>
                      <input aria-label={`Parada ${i + 1}`} value={s.name} onChange={(e) => patch(i, { name: e.target.value })}
                        placeholder={i === 0 ? 'Terminal de origen…' : i === stops.length - 1 ? 'Terminal de destino…' : 'Parada intermedia…'} />
                      <span className="stop-role-badge">
                        {i === 0 ? 'Origen' : i === stops.length - 1 ? 'Destino' : 'Intermedia'}
                      </span>
                    </td>
                    <td>
                      <select aria-label={`Localidad de la parada ${i + 1}`} value={s.place_id} onChange={(e) => patch(i, { place_id: e.target.value })}>
                        <option value="">Sin localidad</option>
                        {(places.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                      </select>
                    </td>
                    <td><input aria-label="Latitud" inputMode="decimal" value={s.lat} onChange={(e) => patch(i, { lat: e.target.value })} placeholder="-31.7333" /></td>
                    <td><input aria-label="Longitud" inputMode="decimal" value={s.lng} onChange={(e) => patch(i, { lng: e.target.value })} placeholder="-60.5236" /></td>
                    <td>
                      <div className="stop-actions">
                        <button type="button" className="secondary compact" aria-label={`Subir parada ${i + 1}`} title="Subir" disabled={inUse || i === 0}
                          onClick={(e) => { e.stopPropagation(); moveStop(i, i - 1); }}>↑</button>
                        <button type="button" className="secondary compact" aria-label={`Bajar parada ${i + 1}`} title="Bajar" disabled={inUse || i === stops.length - 1}
                          onClick={(e) => { e.stopPropagation(); moveStop(i, i + 1); }}>↓</button>
                        <button type="button" className="danger compact" disabled={stops.length <= 2}
                          onClick={() => { setStops(stops.filter((_, j) => j !== i)); setVia([]); setSel(null); }}>✕</button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Barra de herramientas del mapa */}
          <div className="map-toolbar">
            <div className="map-toolbar-left">
              <button type="button" className={mode === 'stop' ? '' : 'secondary'} aria-pressed={mode === 'stop'} onClick={() => setMode('stop')}>
                📍 Ubicar paradas
              </button>
              <button type="button" className="secondary" onClick={() => { setStops([...stops, blankStop()]); setSel(stops.length); setMode('stop'); }}>
                + Agregar parada
              </button>
              <button type="button" className={mode === 'via' ? '' : 'secondary'} aria-pressed={mode === 'via'} onClick={() => setMode('via')}>
                〰 Puntos de paso
              </button>
              {via.length > 0 && (
                <button type="button" className="secondary compact" onClick={() => setVia([])}>
                  Quitar {via.length === 1 ? 'punto' : `${via.length} puntos`}
                </button>
              )}
            </div>
            <span className={`trace-status trace-${trace}`} role="status">
              {trace === 'tracing' && '⏳ Trazando…'}
              {trace === 'ok' && '✓ Trazado por calles'}
              {trace === 'error' && '✕ No se pudo trazar'}
              {trace === 'idle' && !waypoints && 'Ubicá todas las paradas para trazar'}
            </span>
            {trace === 'error' && <button type="button" className="secondary compact" onClick={retrace}>Reintentar</button>}
          </div>

          <StopMap stops={stops} selected={sel} onPick={(i, lat, lng) => patch(i, { lat: String(lat), lng: String(lng) })}
            path={path} via={via} mode={mode} onAddVia={addVia} onMoveVia={moveVia} onRemoveVia={removeVia} />

          <div className="route-editor-footer">
            <div className="row" style={{ gap: 8, flexWrap: 'nowrap' }}>
              <button onClick={save}>Guardar recorrido</button>
              <button className="secondary" onClick={() => setEditing(null)}>Cancelar</button>
            </div>
            <p className="muted" style={{ margin: 0, fontSize: 12 }}>
              Primera parada = origen · Última = destino · Intermedias = paradas de paso. Los tiempos los define la empresa en sus servicios.
            </p>
          </div>
        </section>
      )}

      <div className="card table-wrap">
        <div className="routes-list-header">
          <FilterBox value={q} onChange={setQ} placeholder="Buscar recorrido…" />
        </div>
        {routes.loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Recorrido</th>
                {canEdit && <th>Empresa</th>}
                <th>Origen → Destino</th>
                <th>Paradas</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {(routes.data ?? []).filter((r) => matches(q, r.name)).length === 0 && (
                <tr><td colSpan={5} className="muted">{(routes.data ?? []).length === 0 ? 'Todavía no hay recorridos.' : 'Ningún recorrido coincide.'}</td></tr>
              )}
              {(routes.data ?? []).filter((r) => matches(q, r.name)).map((r) => (
                <tr key={r.id}>
                  <td><b>{r.name}</b></td>
                  {canEdit && <td>{r.company_id ? <span className="pill info">{companyName(r.company_id)}</span> : <span className="pill warn">Sin asignar</span>}</td>}
                  <td>{r.origin_place_id
                    ? <span className="route-od">{placeName(r.origin_place_id) ?? '-'} <span className="route-arrow">→</span> {placeName(r.destination_place_id) ?? '-'}</span>
                    : <span className="pill warn">Falta localidad</span>}
                  </td>
                  <td className="stops-preview">{stopsOf(r.id).map((s) => s.name).join(' › ')}</td>
                  <td>{canEdit && <button className="secondary compact" onClick={() => open(r)}>Editar</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
