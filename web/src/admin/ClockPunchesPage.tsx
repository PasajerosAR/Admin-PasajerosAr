import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { DateInput, Loading, Notice, todayLocal } from '../ui';
import { useAuth } from '../auth/AuthProvider';

interface Review { decision: 'approved' | 'rejected'; note: string | null; created_at: string }
interface Punch {
  id: string; driver_id: string; kind: 'in' | 'out'; server_at: string; captured_at: string | null;
  lat: number; lng: number; accuracy_m: number | null; zone_name: string | null; distance_m: number | null;
  inside: boolean; low_accuracy: boolean; delayed: boolean; photo_path: string; photo_purged_at: string | null;
  profiles: { full_name: string; legajo: string | null } | null;
  punch_reviews: Review[];
}
interface Driver { id: string; full_name: string }

const TZ = 'America/Argentina/Buenos_Aires';
const when = (iso: string) => new Date(iso).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23', timeZone: TZ });
const LIMIT = 200;
const lastReview = (p: Punch) => [...p.punch_reviews].sort((a, b) => b.created_at.localeCompare(a.created_at))[0] ?? null;
const needsReview = (p: Punch) => !p.inside || p.low_accuracy;

function dayStart(date: string) { return `${date}T00:00:00-03:00`; }
function nextDay(date: string) { const d = new Date(`${date}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); }

// Historial de marcajes de entrada y salida. El registro original no se modifica: la revisión se guarda aparte.
export function ClockPunchesPage() {
  const { profile } = useAuth();
  const [driver, setDriver] = useState('');
  const [from, setFrom] = useState(() => { const d = new Date(); d.setDate(d.getDate() - 7); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); });
  const [to, setTo] = useState(todayLocal());
  const [onlyReview, setOnlyReview] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const drivers = useQuery(async () => must(await supabase.from('profiles').select('id,full_name').eq('role', 'driver').order('full_name')) as Driver[], []);
  const punches = useQuery(async () => {
    let q = supabase.from('shift_punches')
      .select('id,driver_id,kind,server_at,captured_at,lat,lng,accuracy_m,zone_name,distance_m,inside,low_accuracy,delayed,photo_path,photo_purged_at,profiles(full_name,legajo),punch_reviews(decision,note,created_at)')
      .order('server_at', { ascending: false }).limit(LIMIT);
    if (driver) q = q.eq('driver_id', driver);
    if (from) q = q.gte('server_at', dayStart(from));
    if (to) q = q.lt('server_at', dayStart(nextDay(to)));
    if (onlyReview) q = q.or('inside.eq.false,low_accuracy.eq.true');
    return must(await q) as unknown as Punch[];
  }, [driver, from, to, onlyReview]);

  if (profile?.role !== 'company_admin') return null;
  const rows = punches.data ?? [];
  const groups = Array.from(rows.reduce((result, punch) => {
    const key = punch.driver_id;
    const label = punch.profiles?.full_name ?? 'Conductor sin nombre';
    const group = result.get(key) ?? { key, label, legajo: punch.profiles?.legajo, punches: [] as Punch[] };
    group.punches.push(punch);
    result.set(key, group);
    return result;
  }, new Map<string, { key: string; label: string; legajo: string | null | undefined; punches: Punch[] }>()).values());
  return (
    <>
      <h1>Marcajes</h1>
      <p className="muted">Entradas y salidas de los conductores con la hora del servidor, la ubicación y la foto. La ubicación es la que informó el teléfono con su precisión: sirve como evidencia, no como prueba definitiva.</p>
      <div className="card row" style={{ alignItems: 'flex-end' }}>
        <label>Conductor
          <select value={driver} onChange={(e) => setDriver(e.target.value)}>
            <option value="">Todos</option>
            {(drivers.data ?? []).map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
          </select>
        </label>
        <label style={{ flex: '0 0 170px' }}>Desde<DateInput value={from} onChange={setFrom} /></label>
        <label style={{ flex: '0 0 170px' }}>Hasta<DateInput value={to} onChange={setTo} /></label>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', flex: '0 0 auto' }}>
          <input type="checkbox" checked={onlyReview} onChange={(e) => setOnlyReview(e.target.checked)} style={{ width: 'auto' }} /> Solo para revisar
        </label>
      </div>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {punches.error && <Notice>{punches.error}</Notice>}
      {punches.loading && <Loading />}
      {rows.length >= LIMIT && <Notice kind="warn">Se muestran los {LIMIT} más recientes. Acotá el período o elegí un conductor para ver el resto.</Notice>}
      <div className="clock-punch-groups">
        {!punches.loading && rows.length === 0 && <div className="card"><p className="muted">No hay marcajes en ese período.</p></div>}
        {groups.map((group) => <details key={group.key} className="operation-group"
          open={openGroups[group.key] ?? false}
          onToggle={(event) => {
            const isOpen = event.currentTarget.open;
            setOpenGroups((current) => current[group.key] === isOpen ? current : { ...current, [group.key]: isOpen });
          }}>
          <summary><b>{group.label}</b>{group.legajo && <span className="punch-group-legajo">Legajo {group.legajo}</span>}<span>{group.punches.length} {group.punches.length === 1 ? 'marcaje' : 'marcajes'}</span></summary>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Fecha y hora</th><th>Marcaje</th><th>Zona</th><th>Estado</th><th /></tr></thead>
              <tbody>{group.punches.map((p) => <FragmentRow key={p.id} p={p} review={lastReview(p)} isOpen={open === p.id}
                onToggle={() => setOpen(open === p.id ? null : p.id)}
                onReviewed={(text) => { setMsg({ kind: 'ok', text }); punches.reload(); }}
                onError={(text) => setMsg({ kind: 'error', text })} />)}</tbody>
            </table>
          </div>
        </details>)}
      </div>
    </>
  );
}

function FragmentRow({ p, review, isOpen, onToggle, onReviewed, onError }: {
  p: Punch; review: Review | null; isOpen: boolean; onToggle: () => void; onReviewed: (text: string) => void; onError: (text: string) => void;
}) {
  return (
    <>
      <tr className={isOpen ? 'sel-row' : undefined}>
        <td>{when(p.server_at)}</td>
        <td>{p.kind === 'in' ? 'Entrada' : 'Salida'}</td>
        <td>{p.zone_name ?? '—'}</td>
        <td>
          {p.inside ? 'Dentro de zona' : `Fuera de zona${p.distance_m ? ` (a ${p.distance_m} m del borde)` : ''}`}
          {p.low_accuracy && ' · Baja precisión'}{p.delayed && ' · Enviado con demora'}
          {review ? ` · ${review.decision === 'approved' ? 'Aprobado' : 'Rechazado'}` : needsReview(p) ? ' · Sin revisar' : ''}
        </td>
        <td><button type="button" className="secondary" onClick={onToggle}>{isOpen ? 'Cerrar' : 'Ver'}</button></td>
      </tr>
      {isOpen && <tr><td colSpan={5}><Detail p={p} review={review} onReviewed={onReviewed} onError={onError} /></td></tr>}
    </>
  );
}

function Detail({ p, review, onReviewed, onError }: { p: Punch; review: Review | null; onReviewed: (text: string) => void; onError: (text: string) => void }) {
  const [url, setUrl] = useState<string | null>(null);
  const [photoMsg, setPhotoMsg] = useState<string | null>(p.photo_purged_at ? 'La foto venció y se borró según el plazo de la empresa.' : 'Cargando foto...');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (p.photo_purged_at) return;
    let alive = true;
    void supabase.storage.from('punch-photos').createSignedUrl(p.photo_path, 120).then(({ data, error }) => {
      if (!alive) return;
      if (error || !data) setPhotoMsg('No se pudo cargar la foto.'); else { setUrl(data.signedUrl); setPhotoMsg(null); }
    });
    return () => { alive = false; };
  }, [p.photo_path, p.photo_purged_at]);

  const decide = async (decision: 'approved' | 'rejected') => {
    setBusy(true);
    const { error } = await supabase.rpc('review_punch', { p_punch: p.id, p_decision: decision, p_note: note });
    setBusy(false);
    if (error) onError(friendly(error)); else onReviewed(decision === 'approved' ? 'Marcaje aprobado. El registro original no cambió.' : 'Marcaje rechazado. El registro original no cambió.');
  };

  return (
    <div className="row" style={{ alignItems: 'flex-start' }}>
      <div style={{ flex: '0 0 220px' }}>
        {url ? <img src={url} alt={`Foto del marcaje de ${p.profiles?.full_name ?? 'conductor'}`} style={{ width: 220, borderRadius: 8 }} /> : <p className="muted">{photoMsg}</p>}
      </div>
      <div className="stack" style={{ flex: 1, gap: 6 }}>
        <div><b>Hora oficial (servidor):</b> {when(p.server_at)}</div>
        {p.captured_at && <div><b>Hora del teléfono al capturar:</b> {when(p.captured_at)} <span className="muted">(solo informativa)</span></div>}
        <div><b>Ubicación:</b> {p.lat.toFixed(6)}, {p.lng.toFixed(6)} · precisión informada: {p.accuracy_m === null ? 'sin dato' : `${Math.round(p.accuracy_m)} m`}
          {' · '}<a href={`https://www.openstreetmap.org/?mlat=${p.lat}&mlon=${p.lng}#map=18/${p.lat}/${p.lng}`} target="_blank" rel="noreferrer">Ver en el mapa</a></div>
        {review && <div><b>Revisión:</b> {review.decision === 'approved' ? 'Aprobado' : 'Rechazado'}{review.note ? ` — ${review.note}` : ''} <span className="muted">({when(review.created_at)})</span></div>}
        {needsReview(p) && (
          <div className="stack" style={{ gap: 6 }}>
            <label>Nota de la revisión (opcional)<input value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} /></label>
            <div className="row" style={{ gap: 6 }}>
              <button type="button" disabled={busy} onClick={() => void decide('approved')}>Aprobar</button>
              <button type="button" className="secondary" disabled={busy} onClick={() => void decide('rejected')}>Rechazar</button>
            </div>
            <span className="muted">La revisión se guarda aparte: el marcaje original no se modifica.</span>
          </div>
        )}
      </div>
    </div>
  );
}
