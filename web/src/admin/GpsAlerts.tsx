import { useEffect, useRef, useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Notice, formatTime } from '../ui';
import { INCIDENT_LABEL, type IncidentKind } from '../lib/types';

export interface AutoAlert { key: string; kind: 'bad' | 'warn' | 'info'; text: string }
interface IncidentRow {
  id: string; kind: IncidentKind; note: string | null; created_at: string;
  trips: { services: { code: string } | null } | null; profiles: { full_name: string; legajo: string | null } | null;
}
interface MessageRow { id: string; level: string; body: string; trip_id: string | null; created_at: string; driver_message_reads: { driver_id: string }[] }

const LEVEL_LABEL: Record<string, string> = { info: 'Informativo', important: 'Importante', urgent: 'Urgente' };

// Sonido leve de aviso (si el navegador lo permite).
function beep() {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    const ctx = new Ctx(); const osc = ctx.createOscillator(); const gain = ctx.createGain();
    osc.frequency.value = 660; gain.gain.value = 0.05;
    osc.connect(gain); gain.connect(ctx.destination);
    osc.start(); osc.stop(ctx.currentTime + 0.25);
    window.setTimeout(() => void ctx.close(), 400);
  } catch { /* sin audio */ }
}

// Avisos del panel GPS: incidencias de los conductores, avisos automáticos y envío de mensajes (solo empresa).
export function GpsAlerts({ alerts, selectedTripId, selectedLabel, tick }: {
  alerts: AutoAlert[]; selectedTripId: string | null; selectedLabel: string; tick: number;
}) {
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [sound, setSound] = useState(() => { try { return window.localStorage.getItem('gps.sound') !== 'off'; } catch { return true; } });
  const [form, setForm] = useState({ body: '', level: 'info', target: 'all' });
  const [busy, setBusy] = useState(false);
  const seen = useRef<Set<string> | null>(null);

  const incidents = useQuery(async () => {
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    return must(await supabase.from('incidents').select('id,kind,note,created_at,trips(services(code)),profiles(full_name,legajo)')
      .is('resolved_at', null).gte('created_at', since).order('created_at', { ascending: false })) as unknown as IncidentRow[];
  }, [tick]);
  const messages = useQuery(async () => must(await supabase.from('driver_messages')
    .select('id,level,body,trip_id,created_at,driver_message_reads(driver_id)').order('created_at', { ascending: false }).limit(5)) as unknown as MessageRow[], [tick]);

  useEffect(() => {
    if (!incidents.data) return;
    const ids = new Set(incidents.data.map((i) => i.id));
    if (seen.current && sound && [...ids].some((id) => !seen.current!.has(id))) beep();
    seen.current = ids;
  }, [incidents.data, sound]);

  const toggleSound = () => {
    const next = !sound; setSound(next);
    try { window.localStorage.setItem('gps.sound', next ? 'on' : 'off'); } catch { /* sin almacenamiento */ }
    if (next) beep();
  };
  const resolve = async (id: string) => {
    const { error } = await supabase.rpc('resolve_incident', { p_incident: id });
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else incidents.reload();
  };
  const send = async (e: FormEvent) => {
    e.preventDefault(); setBusy(true); setMsg(null);
    const { error } = await supabase.rpc('send_driver_message', {
      p_body: form.body, p_level: form.level, p_trip: form.target === 'trip' ? selectedTripId : null
    });
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Mensaje enviado.' }); setForm({ ...form, body: '' }); messages.reload();
  };

  const list = incidents.data ?? [];
  return (
    <div className="gps-alerts">
      <div className="card stack">
        <div className="row" style={{ alignItems: 'center', justifyContent: 'space-between' }}>
          <h2 style={{ margin: 0 }}>Avisos {list.length + alerts.length > 0 && <span className="pill warn">{list.length + alerts.length}</span>}</h2>
          <button type="button" className="secondary compact" onClick={toggleSound}>{sound ? 'Sonido: sí' : 'Sonido: no'}</button>
        </div>
        {incidents.error && <Notice>{incidents.error}</Notice>}
        {list.length === 0 && alerts.length === 0 && <p className="muted">Sin avisos por ahora.</p>}
        {list.map((i) => (
          <div key={i.id} className={`alert-row ${i.kind === 'panic' ? 'bad' : 'warn'}`}>
            <div>
              <b>{INCIDENT_LABEL[i.kind]}</b> · Servicio #{i.trips?.services?.code ?? '-'} · {formatTime(i.created_at)}<br />
              <small>{i.profiles?.full_name ?? 'Conductor'}{i.profiles?.legajo ? ` (legajo ${i.profiles.legajo})` : ''}{i.note ? ` — ${i.note}` : ''}</small>
            </div>
            <button type="button" className="secondary compact" onClick={() => resolve(i.id)}>Resuelta</button>
          </div>
        ))}
        {alerts.map((a) => <div key={a.key} className={`alert-row ${a.kind}`}><div>{a.text}<br /><small>Aviso automático</small></div></div>)}
      </div>

      <form className="card stack" onSubmit={send}>
        <h2 style={{ margin: 0 }}>Enviar mensaje a conductores</h2>
        {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
        <div className="row">
          <label>Para
            <select value={form.target} onChange={(e) => setForm({ ...form, target: e.target.value })}>
              <option value="all">Todos los conductores</option>
              <option value="trip" disabled={!selectedTripId}>{selectedTripId ? `Solo ${selectedLabel}` : 'Un servicio (elegí uno)'}</option>
            </select>
          </label>
          <label>Importancia
            <select value={form.level} onChange={(e) => setForm({ ...form, level: e.target.value })}>
              {Object.entries(LEVEL_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </label>
        </div>
        <label>Mensaje<textarea rows={3} maxLength={500} value={form.body} onChange={(e) => setForm({ ...form, body: e.target.value })} placeholder="Ej.: Corte en Av. Ramírez, desviar por Churruarín" required /></label>
        <button type="submit" disabled={busy} style={{ alignSelf: 'flex-start' }}>{busy ? 'Enviando...' : 'Enviar'}</button>
        {(messages.data ?? []).length > 0 && (
          <div className="stack">
            <b>Últimos enviados</b>
            {(messages.data ?? []).map((m) => (
              <div key={m.id} className="alert-row info">
                <div>{m.body}<br /><small>{LEVEL_LABEL[m.level]} · {formatTime(m.created_at)} · {m.trip_id ? 'un servicio' : 'todos'} · leído por {m.driver_message_reads.length}</small></div>
              </div>
            ))}
          </div>
        )}
      </form>
    </div>
  );
}
