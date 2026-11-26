import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice, PageHead, formatTime, todayLocal } from '../ui';
import { fold } from '../lib/text';
import { useAuth } from '../auth/AuthProvider';
import { INCIDENT_LABEL, STATUS_LABEL, type IncidentKind, type Profile, type TripStatus, type Vehicle } from '../lib/types';
import { DAY_TYPES, DAY_TYPE_LABEL, dayTypeOf, type DayType } from '../lib/dayType';

interface IncidentRow {
  id: string; kind: IncidentKind; note: string | null; created_at: string;
  trips: { services: { code: string } | null } | null; profiles: { full_name: string } | null;
}

interface StaleTrip {
  id: string; service_date: string; scheduled_departure: string; started_at: string | null;
  services: { code: string } | null; service_departures: { routes: { name: string } | null } | null;
}

// "YYYY-MM-DDTHH:mm" en hora local, el formato de <input type="datetime-local">
const toLocalInput = (value: Date) => {
  const shifted = new Date(value.getTime() - value.getTimezoneOffset() * 60_000);
  return shifted.toISOString().slice(0, 16);
};

interface TripRow {
  id: string; service_id: string; layout_id: string | null; status: TripStatus; scheduled_departure: string; vehicle_id: string | null; driver_id: string | null;
  started_at: string | null; started_manually: boolean; day_type: DayType; published_at: string | null;
  services: { code: string } | null;
  service_departures: { routes: { name: string } | null } | null;
}

export function TripsPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [date, setDate] = useState(todayLocal());
  const [typeOverride, setTypeOverride] = useState<DayType | null>(null);
  const dayType = typeOverride ?? dayTypeOf(new Date(`${date}T12:00:00`));
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [groupBy, setGroupBy] = useState<'service' | 'route' | 'none'>('service');
  const [sortBy, setSortBy] = useState<'service' | 'departure'>('service');
  const [statusFilter, setStatusFilter] = useState<TripStatus | 'all'>('all');
  const [assignmentFilter, setAssignmentFilter] = useState<'all' | 'pending'>('all');
  const [search, setSearch] = useState('');
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({});

  const trips = useQuery(async () => must(await supabase.from('trips')
    .select('id,service_id,layout_id,status,scheduled_departure,vehicle_id,driver_id,started_at,started_manually,day_type,published_at,services(code),service_departures(routes(name))')
    .eq('service_date', date).neq('status', 'cancelled').order('scheduled_departure')) as unknown as TripRow[], [date]);
  const incidents = useQuery(async () => {
    const from = new Date(`${date}T00:00:00`), to = new Date(from.getTime() + 24 * 3600 * 1000);
    return must(await supabase.from('incidents').select('id,kind,note,created_at,trips(services(code)),profiles!driver_id(full_name)')
      .gte('created_at', from.toISOString()).lt('created_at', to.toISOString()).order('created_at', { ascending: false })) as unknown as IncidentRow[];
  }, [date]);
  const vehicles = useQuery(async () => must(await supabase.from('vehicles').select('*').order('internal_number')) as Vehicle[], []);
  const drivers = useQuery(async () => must(await supabase.from('profiles').select('*').eq('role', 'driver').eq('active', true).is('deleted_at', null).order('full_name')) as Profile[], []);
  // disposiciones (una opción por grupo, su última versión) y unidades que tiene cada servicio con disposición
  const layouts = useQuery(async () => must(await supabase.from('seat_layouts').select('id,group_id,version,name').order('name').order('version', { ascending: false })) as { id: string; group_id: string; version: number; name: string }[], []);
  const compat = useQuery(async () => must(await supabase.rpc('service_layout_vehicles')) as Record<string, string[]>, []);
  // viajes en curso de días anteriores: se pueden finalizar a mano desde cualquier fecha
  const stale = useQuery(async () => must(await supabase.from('trips')
    .select('id,service_date,scheduled_departure,started_at,services(code),service_departures(routes(name))')
    .eq('status', 'in_progress').lt('service_date', todayLocal()).order('scheduled_departure')) as unknown as StaleTrip[], []);
  const [ending, setEnding] = useState<{ id: string; label: string; value: string; min: string; reason: string } | null>(null);

  const run = async (fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) => {
    const { error } = await fn();
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: ok }); trips.reload(); }
  };

  const generate = async () => {
    // si el día ya tiene viajes de otro tipo (ej. feriado y ahora hábil), se avisa y se reemplazan
    const { data: preview, error } = await supabase.rpc('generate_trips_preview', { p_date: date, p_day_type: dayType });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    const other = Number(preview?.other_type ?? 0);
    const blocked = Number(preview?.blocked ?? 0);
    const names = ((preview?.types ?? []) as DayType[]).map((t) => DAY_TYPE_LABEL[t]?.toLowerCase() ?? t).join(' y ');
    if (blocked > 0) {
      setMsg({ kind: 'error', text: `Ese día ya tiene ${other} viajes generados como ${names} y ${blocked} no se pueden reemplazar porque tienen ventas, conductor o ya iniciaron.` });
      return;
    }
    if (other > 0 && !window.confirm(`Ese día ya tiene ${other} viajes generados como ${names}. Se van a borrar y reemplazar por los de ${DAY_TYPE_LABEL[dayType].toLowerCase()}. ¿Continuar?`)) return;
    await run(() => supabase.rpc('generate_trips', { p_date: date, p_day_type: dayType, p_replace: other > 0 }), `Viajes generados para ${DAY_TYPE_LABEL[dayType].toLowerCase()}. Todavía no están publicados: revisalos y tocá "Publicar".`);
  };
  const publish = async () => {
    if (!window.confirm(`¿Publicar ${drafts} viajes del día? Desde ese momento los pasajeros pueden verlos y comprar.`)) return;
    const { data, error } = await supabase.rpc('publish_trips', { p_date: date });
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: `${data as number} viajes publicados.` }); trips.reload(); }
  };
  const assignGroup = (ids: string[], vehicle: string) =>
    run(() => supabase.from('trips').update({ vehicle_id: vehicle || null }).in('id', ids), 'Vehículo asignado a todas las vueltas.');
  const assign = (id: string, patch: { vehicle_id?: string | null; driver_id?: string | null }) =>
    run(() => supabase.from('trips').update(patch).eq('id', id), 'Asignación guardada.');
  const layoutGroup = (id: string | null) => (layouts.data ?? []).find((l) => l.id === id)?.group_id ?? null;
  const layoutOptions = (layouts.data ?? []).filter((l, i, all) => all.findIndex((x) => x.group_id === l.group_id) === i);
  // unidades que sirven para el viaje: si el servicio tiene disposición, solo las que la tienen (más la ya asignada)
  const vehiclesFor = (trip: TripRow) => {
    const restricted = compat.data?.[trip.service_id];
    if (!restricted) return vehicles.data ?? [];
    const group = layoutGroup(trip.layout_id);
    return (vehicles.data ?? []).filter((v) => v.id === trip.vehicle_id
      || (group ? layoutGroup(v.layout_id) === group : restricted.includes(v.id)));
  };
  const vehiclesForService = (serviceId: string) => {
    const restricted = compat.data?.[serviceId];
    return restricted ? (vehicles.data ?? []).filter((v) => restricted.includes(v.id)) : vehicles.data ?? [];
  };
  const setLayout = (id: string, layout: string) =>
    run(() => supabase.rpc('admin_set_trip_layout', { p_trip: id, p_layout: layout }), 'Disposición del viaje cambiada.');

  const openEnding = async (trip: { id: string; started_at: string | null; scheduled_departure: string; services: { code: string } | null }) => {
    const { data } = await supabase.rpc('trip_expected_arrival', { p_trip: trip.id });
    const started = trip.started_at ? new Date(trip.started_at) : new Date(trip.scheduled_departure);
    const expected = data ? new Date(data as string) : new Date();
    const proposal = new Date(Math.min(Math.max(expected.getTime(), started.getTime()), Date.now()));
    setEnding({
      id: trip.id, label: `#${trip.services?.code ?? '-'} · ${formatTime(trip.scheduled_departure)}`,
      value: toLocalInput(proposal), min: toLocalInput(started), reason: ''
    });
  };
  const confirmEnding = async () => {
    if (!ending) return;
    const { error } = await supabase.rpc('admin_end_trip', { p_trip: ending.id, p_ended_at: new Date(ending.value).toISOString(), p_reason: ending.reason });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setEnding(null); setMsg({ kind: 'ok', text: 'Viaje finalizado manualmente.' }); trips.reload(); stale.reload();
  };

  const startManually = (id: string) => {
    const reason = window.prompt('Motivo del inicio manual (queda registrado):');
    if (reason === null) return;
    void run(() => supabase.rpc('admin_start_trip', { p_trip: id, p_reason: reason }), 'Viaje iniciado manualmente.');
  };
  const cancel = (id: string) => {
    if (!window.confirm('¿Cancelar este viaje?')) return;
    void run(() => supabase.from('trips').update({ status: 'cancelled' }).eq('id', id), 'Viaje cancelado.');
  };

  const drafts = (trips.data ?? []).filter((t) => t.status === 'scheduled' && !t.published_at).length;
  const now = Date.now();
  const alerts = (trips.data ?? []).filter((t) => t.status === 'scheduled' && new Date(t.scheduled_departure).getTime() < now);
  const collator = new Intl.Collator('es-AR', { numeric: true, sensitivity: 'base' });
  const filteredTrips = (trips.data ?? []).filter((trip) => {
    if (statusFilter !== 'all' && trip.status !== statusFilter) return false;
    if (assignmentFilter === 'pending' && trip.vehicle_id && trip.driver_id) return false;
    const needle = fold(search);
    return !needle || [trip.services?.code, trip.service_departures?.routes?.name]
      .some((value) => fold(value).includes(needle));
  }).sort((a, b) => sortBy === 'service'
    ? collator.compare(a.services?.code ?? '', b.services?.code ?? '') || a.scheduled_departure.localeCompare(b.scheduled_departure)
    : a.scheduled_departure.localeCompare(b.scheduled_departure) || collator.compare(a.services?.code ?? '', b.services?.code ?? ''));
  const groups = groupBy === 'none'
    ? [{ key: 'all', label: '', trips: filteredTrips }]
    : Array.from(filteredTrips.reduce((result, trip) => {
      const label = groupBy === 'service' ? trip.services?.code ?? 'Sin servicio' : trip.service_departures?.routes?.name ?? 'Sin recorrido';
      const key = groupBy === 'service' ? trip.services?.code ?? 'missing' : trip.service_departures?.routes?.name ?? 'missing';
      const group = result.get(key) ?? { key, label, trips: [] as TripRow[] };
      group.trips.push(trip);
      result.set(key, group);
      return result;
    }, new Map<string, { key: string; label: string; trips: TripRow[] }>()).values())
      .sort((a, b) => sortBy === 'service'
        ? collator.compare(a.label, b.label)
        : a.trips[0].scheduled_departure.localeCompare(b.trips[0].scheduled_departure));

  return (
    <>
      <PageHead
        title="Operación del día"
        actions={
          canEdit && (
            <>
              <button className="secondary" onClick={() => { trips.reload(); stale.reload(); compat.reload(); }}>Actualizar</button>
              <button className="secondary" onClick={generate}>Generar viajes del día</button>
              <button onClick={publish} disabled={drafts === 0}>{drafts > 0 ? `Publicar ${drafts} viajes` : 'Publicar'}</button>
            </>
          )
        }
      />
      <div className="toolbar">
        <label>Fecha<input type="date" value={date} onChange={(e) => { setDate(e.target.value); setTypeOverride(null); }} /></label>
        {canEdit && (
          <label>Tipo de día
            <select value={dayType} onChange={(e) => setTypeOverride(e.target.value as DayType)}>
              {DAY_TYPES.map((d) => <option key={d} value={d}>{DAY_TYPE_LABEL[d]}</option>)}
            </select>
          </label>
        )}
        <span className="toolbar-spacer" />
      </div>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && drafts > 0 && <Notice kind="warn">Hay {drafts} viajes sin publicar: los pasajeros todavía no los ven.</Notice>}
      {trips.error && <Notice>{trips.error}</Notice>}
      {canEdit && (stale.data ?? []).length > 0 && (
        <div className="card">
          <div className="card-head">
            <h2>Viajes en curso de días anteriores</h2>
          </div>
          <p className="muted">Siguen "en curso" porque nadie los finalizó. Finalizalos a mano para que dejen de verse.</p>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Servicio</th><th>Fecha</th><th>Recorrido</th><th>Salida</th><th /></tr></thead>
              <tbody>
                {(stale.data ?? []).map((t) => (
                  <tr key={t.id}>
                    <td><b>#{t.services?.code}</b></td>
                    <td>{new Date(`${t.service_date}T12:00:00`).toLocaleDateString('es-AR')}</td>
                    <td>{t.service_departures?.routes?.name}</td>
                    <td>{formatTime(t.scheduled_departure)}</td>
                    <td className="td-actions"><button className="secondary" onClick={() => openEnding(t)}>Finalizar manual</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {canEdit && ending && (
        <div className="card" role="dialog" aria-label="Finalizar viaje manualmente">
          <div className="card-head"><h2>Finalizar viaje {ending.label}</h2></div>
          <p className="muted">Se propone la hora de llegada prevista. Quedan registrados la hora, el motivo y que se cerró a mano.</p>
          <div className="form-grid">
            <label>Hora de fin<input type="datetime-local" value={ending.value} min={ending.min} max={toLocalInput(new Date())} onChange={(e) => setEnding({ ...ending, value: e.target.value })} /></label>
            <label className="span-12">Motivo<input value={ending.reason} onChange={(e) => setEnding({ ...ending, reason: e.target.value })} placeholder="Ej.: el conductor no finalizó el viaje" /></label>
            <div className="form-actions">
              <button disabled={!ending.value || ending.reason.trim().length < 3} onClick={confirmEnding}>Finalizar viaje</button>
              <button className="secondary" onClick={() => setEnding(null)}>Cancelar</button>
            </div>
          </div>
        </div>
      )}
      {alerts.length > 0 && (
        <Notice kind="warn">{alerts.length === 1 ? '1 salida no inició' : `${alerts.length} salidas no iniciaron`} pasada la hora programada: {alerts.map((trip) => `#${trip.services?.code ?? '-'} · ${formatTime(trip.scheduled_departure)} · ${trip.service_departures?.routes?.name ?? 'sin recorrido'}`).join(' | ')}.</Notice>
      )}
      <div className="card list-card">
        <div className="list-head">
          <input className="filter-box" type="search" placeholder="Buscar servicio o recorrido" aria-label="Buscar servicio o recorrido" value={search} onChange={(event) => setSearch(event.target.value)} />
          <label className="inline">Estado
            <select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as TripStatus | 'all')}>
              <option value="all">Todos</option>
              {(Object.keys(STATUS_LABEL) as TripStatus[]).filter((status) => status !== 'cancelled').map((status) => <option key={status} value={status}>{STATUS_LABEL[status]}</option>)}
            </select>
          </label>
          <label className="inline">Asignación
            <select value={assignmentFilter} onChange={(event) => setAssignmentFilter(event.target.value as 'all' | 'pending')}>
              <option value="all">Todas</option>
              <option value="pending">Falta unidad o conductor</option>
            </select>
          </label>
          <label className="inline">Agrupar por
            <select value={groupBy} onChange={(event) => setGroupBy(event.target.value as 'service' | 'route' | 'none')}>
              <option value="service">Servicio</option>
              <option value="route">Recorrido</option>
              <option value="none">Sin agrupar</option>
            </select>
          </label>
          <label className="inline">Orden
            <select value={sortBy} onChange={(event) => setSortBy(event.target.value as 'service' | 'departure')}>
              <option value="service">Servicio menor a mayor</option>
              <option value="departure">Hora de salida</option>
            </select>
          </label>
          <span className="list-head-spacer" />
        </div>
        {trips.loading ? <Loading /> : (
          groups.length === 0
            ? <div className="empty">{(trips.data ?? []).length === 0 ? 'No hay viajes para esta fecha. Generá los viajes del día y después publicalos.' : 'No hay salidas que coincidan con los filtros.'}</div>
            : groups.map((group) => (
              <details key={group.key} className="operation-group"
                open={openGroups[group.key] ?? (groupBy === 'none')}
                onToggle={(event) => {
                  const isOpen = event.currentTarget.open;
                  setOpenGroups((current) => current[group.key] === isOpen ? current : { ...current, [group.key]: isOpen });
                }}>
                {groupBy !== 'none' && (
                  <summary>
                    <b>{groupBy === 'service' ? `Servicio #${group.label}` : group.label}</b>
                    <span>{group.trips.length} {group.trips.length === 1 ? 'salida' : 'salidas'}</span>
                  </summary>
                )}
                {canEdit && groupBy === 'service' && (() => {
                  const ids = group.trips.filter((t) => t.status === 'scheduled').map((t) => t.id);
                  if (ids.length === 0) return null;
                  const vs = new Set(group.trips.filter((t) => t.status === 'scheduled').map((t) => t.vehicle_id ?? ''));
                  return (
                    <div className="group-vehicle">
                      <label>Vehículo para todas las vueltas del servicio
                        <select value={vs.size === 1 ? [...vs][0] : ''} onChange={(e) => assignGroup(ids, e.target.value)}>
                          <option value="">{vs.size > 1 ? 'Varios vehículos' : 'Sin asignar'}</option>
                          {vehiclesForService(group.trips[0].service_id).map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                        </select>
                        <span className="muted">Si se rompe, el conductor inicia el viaje con otra unidad.</span>
                      </label>
                    </div>
                  );
                })()}
                <div className="table-wrap">
                  <table>
                    <thead><tr><th>Servicio</th><th>Recorrido</th><th>Salida</th><th>Estado</th><th>Disposición</th><th>Vehículo</th><th>Conductor</th><th /></tr></thead>
                    <tbody>
                      {group.trips.map((t) => {
                        const editable = canEdit && t.status === 'scheduled';
                        return (
                          <tr key={t.id}>
                            <td><b>#{t.services?.code}</b><br /><span className="muted">{DAY_TYPE_LABEL[t.day_type]}</span></td>
                            <td>{t.service_departures?.routes?.name}</td>
                            <td>{formatTime(t.scheduled_departure)}</td>
                            <td>
                              <span className={`pill ${t.status === 'in_progress' ? 'info' : t.status === 'completed' ? 'ok' : t.status === 'cancelled' ? 'bad' : 'warn'}`}>{STATUS_LABEL[t.status]}</span>
                              {t.status === 'scheduled' && !t.published_at && <span className="pill warn"> Sin publicar</span>}
                              {t.started_manually && <span className="muted"> (manual)</span>}
                            </td>
                            <td>
                              {editable && compat.data?.[t.service_id]
                                ? (
                                  <select aria-label={`Disposición del servicio ${t.services?.code ?? ''} ${formatTime(t.scheduled_departure)}`}
                                    value={layoutOptions.find((l) => l.group_id === layoutGroup(t.layout_id))?.id ?? ''} onChange={(e) => e.target.value && setLayout(t.id, e.target.value)}>
                                    {!t.layout_id && <option value="">Sin disposición</option>}
                                    {layoutOptions.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                                  </select>
                                )
                                : <span className="muted">{layoutOptions.find((l) => l.group_id === layoutGroup(t.layout_id))?.name ?? '-'}</span>}
                            </td>
                            <td>
                              <select aria-label={`Vehículo del servicio ${t.services?.code ?? ''} ${formatTime(t.scheduled_departure)}`} disabled={!editable} value={t.vehicle_id ?? ''} onChange={(e) => assign(t.id, { vehicle_id: e.target.value || null })}>
                                <option value="">Sin asignar</option>
                                {vehiclesFor(t).map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                              </select>
                            </td>
                            <td>
                              <select aria-label={`Conductor del servicio ${t.services?.code ?? ''} ${formatTime(t.scheduled_departure)}`} disabled={!editable} value={t.driver_id ?? ''} onChange={(e) => assign(t.id, { driver_id: e.target.value || null })}>
                                <option value="">Sin asignar</option>
                                {(drivers.data ?? []).map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                              </select>
                            </td>
                            <td className="td-actions">
                              {canEdit && t.status === 'in_progress' && (
                                <button className="secondary" onClick={() => openEnding({ id: t.id, started_at: t.started_at, scheduled_departure: t.scheduled_departure, services: t.services })}>Finalizar manual</button>
                              )}
                              {editable && (
                                <>
                                  <button className="secondary" disabled={!t.vehicle_id} onClick={() => startManually(t.id)}>Iniciar manual</button>
                                  <button className="danger" onClick={() => cancel(t.id)}>Cancelar</button>
                                </>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </details>
            ))
        )}
        <p className="list-foot">Las salidas "Sin publicar" no se ven en la web ni en la app del conductor.</p>
      </div>
      {(incidents.data ?? []).length > 0 && (
        <div className="card">
          <div className="card-head"><h2>Incidencias del día</h2></div>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Hora</th><th>Servicio</th><th>Conductor</th><th>Tipo</th><th>Detalle</th></tr></thead>
              <tbody>
                {(incidents.data ?? []).map((i) => (
                  <tr key={i.id}>
                    <td>{formatTime(i.created_at)}</td><td><b>{i.trips?.services?.code}</b></td><td>{i.profiles?.full_name}</td>
                    <td>{INCIDENT_LABEL[i.kind]}</td><td>{i.note ?? '-'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </>
  );
}
