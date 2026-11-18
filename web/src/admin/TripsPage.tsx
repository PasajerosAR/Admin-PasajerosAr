import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice, formatTime, todayLocal } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import { INCIDENT_LABEL, STATUS_LABEL, type IncidentKind, type Profile, type TripStatus, type Vehicle } from '../lib/types';
import { DAY_TYPES, DAY_TYPE_LABEL, dayTypeOf, type DayType } from '../lib/dayType';

interface IncidentRow {
  id: string; kind: IncidentKind; note: string | null; created_at: string;
  trips: { services: { code: string } | null } | null; profiles: { full_name: string } | null;
}

interface TripRow {
  id: string; status: TripStatus; scheduled_departure: string; vehicle_id: string | null; driver_id: string | null;
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
    .select('id,status,scheduled_departure,vehicle_id,driver_id,started_at,started_manually,day_type,published_at,services(code),service_departures(routes(name))')
    .eq('service_date', date).neq('status', 'cancelled').order('scheduled_departure')) as unknown as TripRow[], [date]);
  const incidents = useQuery(async () => {
    const from = new Date(`${date}T00:00:00`), to = new Date(from.getTime() + 24 * 3600 * 1000);
    return must(await supabase.from('incidents').select('id,kind,note,created_at,trips(services(code)),profiles!driver_id(full_name)')
      .gte('created_at', from.toISOString()).lt('created_at', to.toISOString()).order('created_at', { ascending: false })) as unknown as IncidentRow[];
  }, [date]);
  const vehicles = useQuery(async () => must(await supabase.from('vehicles').select('*').order('internal_number')) as Vehicle[], []);
  const drivers = useQuery(async () => must(await supabase.from('profiles').select('*').eq('role', 'driver').eq('active', true).order('full_name')) as Profile[], []);

  const run = async (fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) => {
    const { error } = await fn();
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: ok }); trips.reload(); }
  };

  const generate = () => run(() => supabase.rpc('generate_trips', { p_date: date, p_day_type: dayType }), `Viajes generados para ${DAY_TYPE_LABEL[dayType].toLowerCase()}. Todavía no están publicados: revisalos y tocá "Publicar".`);
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
    const needle = search.trim().toLocaleLowerCase('es-AR');
    return !needle || [trip.services?.code, trip.service_departures?.routes?.name]
      .some((value) => value?.toLocaleLowerCase('es-AR').includes(needle));
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
      <h1>Operación del día</h1>
      <div className="row">
        <label style={{ flex: '0 0 200px' }}>Fecha<input type="date" value={date} onChange={(e) => { setDate(e.target.value); setTypeOverride(null); }} /></label>
        {canEdit && (
          <label style={{ flex: '0 0 200px' }}>Tipo de día
            <select value={dayType} onChange={(e) => setTypeOverride(e.target.value as DayType)}>
              {DAY_TYPES.map((d) => <option key={d} value={d}>{DAY_TYPE_LABEL[d]}</option>)}
            </select>
          </label>
        )}
        {canEdit && <button className="secondary" onClick={generate}>Generar viajes del día</button>}
        {canEdit && <button onClick={publish} disabled={drafts === 0}>{drafts > 0 ? `Publicar ${drafts} viajes` : 'Publicar'}</button>}
      </div>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && drafts > 0 && <Notice kind="warn">Hay {drafts} viajes sin publicar: los pasajeros todavía no los ven.</Notice>}
      {trips.error && <Notice>{trips.error}</Notice>}
      {alerts.length > 0 && (
        <Notice kind="warn">{alerts.length === 1 ? '1 salida no inició' : `${alerts.length} salidas no iniciaron`} pasada la hora programada: {alerts.map((trip) => `#${trip.services?.code ?? '-'} · ${formatTime(trip.scheduled_departure)} · ${trip.service_departures?.routes?.name ?? 'sin recorrido'}`).join(' | ')}.</Notice>
      )}
      <div className="row operation-filters">
        <label>Buscar servicio o recorrido<input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Ej.: 201 o Paraná - Santa Fe" /></label>
        <label>Estado
          <select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as TripStatus | 'all')}>
            <option value="all">Todos</option>
            {(Object.keys(STATUS_LABEL) as TripStatus[]).filter((status) => status !== 'cancelled').map((status) => <option key={status} value={status}>{STATUS_LABEL[status]}</option>)}
          </select>
        </label>
        <label>Asignación
          <select value={assignmentFilter} onChange={(event) => setAssignmentFilter(event.target.value as 'all' | 'pending')}>
            <option value="all">Todas</option>
            <option value="pending">Falta unidad o conductor</option>
          </select>
        </label>
        <label>Agrupar por
          <select value={groupBy} onChange={(event) => setGroupBy(event.target.value as 'service' | 'route' | 'none')}>
            <option value="service">Servicio</option>
            <option value="route">Recorrido</option>
            <option value="none">Sin agrupar</option>
          </select>
        </label>
        <label>Orden
          <select value={sortBy} onChange={(event) => setSortBy(event.target.value as 'service' | 'departure')}>
            <option value="service">Servicio menor a mayor</option>
            <option value="departure">Hora de salida</option>
          </select>
        </label>
      </div>
      <div className="card">
        {trips.loading ? <Loading /> : (
          groups.length === 0
            ? <p className="muted">{(trips.data ?? []).length === 0 ? 'No hay viajes para esta fecha. Generá los viajes del día y después publicalos.' : 'No hay salidas que coincidan con los filtros.'}</p>
            : groups.map((group) => (
              <details key={group.key} className="operation-group"
                open={openGroups[group.key] ?? (groupBy === 'none' || group.trips.some((trip) => trip.status === 'in_progress' || (trip.status === 'scheduled' && new Date(trip.scheduled_departure).getTime() < now)))}
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
                    <label className="group-vehicle">Vehículo para todas las vueltas del servicio
                      <select value={vs.size === 1 ? [...vs][0] : ''} onChange={(e) => assignGroup(ids, e.target.value)}>
                        <option value="">{vs.size > 1 ? 'Varios vehículos' : 'Sin asignar'}</option>
                        {(vehicles.data ?? []).map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                      </select>
                      <span className="muted">Si se rompe, el conductor inicia el viaje con otra unidad.</span>
                    </label>
                  );
                })()}
                <div className="table-wrap">
                  <table>
                    <thead><tr><th>Servicio</th><th>Recorrido</th><th>Salida</th><th>Estado</th><th>Vehículo</th><th>Conductor</th><th /></tr></thead>
                    <tbody>
                      {group.trips.map((t) => {
                        const editable = canEdit && t.status === 'scheduled';
                        return (
                          <tr key={t.id}>
                            <td><b>#{t.services?.code}</b><br /><span className="muted" style={{ fontSize: 12 }}>{DAY_TYPE_LABEL[t.day_type]}</span></td>
                            <td>{t.service_departures?.routes?.name}</td>
                            <td>{formatTime(t.scheduled_departure)}</td>
                            <td>
                              <span className={`pill ${t.status === 'in_progress' ? 'info' : t.status === 'completed' ? 'ok' : t.status === 'cancelled' ? 'bad' : 'warn'}`}>{STATUS_LABEL[t.status]}</span>
                              {t.status === 'scheduled' && !t.published_at && <span className="pill warn"> Sin publicar</span>}
                              {t.started_manually && <span className="muted"> (manual)</span>}
                            </td>
                            <td>
                              <select aria-label={`Vehículo del servicio ${t.services?.code ?? ''} ${formatTime(t.scheduled_departure)}`} disabled={!editable} value={t.vehicle_id ?? ''} onChange={(e) => assign(t.id, { vehicle_id: e.target.value || null })}>
                                <option value="">Sin asignar</option>
                                {(vehicles.data ?? []).map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                              </select>
                            </td>
                            <td>
                              <select aria-label={`Conductor del servicio ${t.services?.code ?? ''} ${formatTime(t.scheduled_departure)}`} disabled={!editable} value={t.driver_id ?? ''} onChange={(e) => assign(t.id, { driver_id: e.target.value || null })}>
                                <option value="">Sin asignar</option>
                                {(drivers.data ?? []).map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                              </select>
                            </td>
                            <td>
                              {editable && (
                                <div className="row">
                                  <button className="secondary" disabled={!t.vehicle_id} onClick={() => startManually(t.id)}>Iniciar manual</button>
                                  <button className="danger" onClick={() => cancel(t.id)}>Cancelar</button>
                                </div>
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
      </div>
      {(incidents.data ?? []).length > 0 && (
        <div className="card table-wrap">
          <h2>Incidencias del día</h2>
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
      )}
    </>
  );
}
