import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice, PageHead } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import { ZoneMap } from './ZoneMap';

interface Zone { id: string; name: string; lat: number; lng: number; radius_m: number; active: boolean }
interface Settings { clock_out_of_zone: 'block' | 'review'; clock_photo_days: number }

const EMPTY = { id: '', name: '', lat: null as number | null, lng: null as number | null, radius: '100' };

// Zonas de marcaje de la empresa (galpones, terminales) y qué hacer con un marcaje fuera de zona.
export function ClockZonesPage() {
  const { profile } = useAuth();
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const zones = useQuery(async () => must(await supabase.from('clock_zones').select('id,name,lat,lng,radius_m,active').order('name')) as Zone[], []);
  const settings = useQuery(async () => must(await supabase.from('companies').select('clock_out_of_zone,clock_photo_days').eq('id', profile?.company_id ?? '').single()) as Settings, [profile?.company_id]);
  const [mode, setMode] = useState<'block' | 'review' | null>(null);
  const [days, setDays] = useState<string | null>(null);
  const curMode = mode ?? settings.data?.clock_out_of_zone ?? 'block';
  const curDays = days ?? String(settings.data?.clock_photo_days ?? 30);

  const saveSettings = async () => {
    const { error } = await supabase.rpc('save_clock_settings', { p_mode: curMode, p_photo_days: Number(curDays) });
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: 'Configuración guardada.' }); setMode(null); setDays(null); settings.reload(); }
  };

  const edit = (z: Zone) => { setForm({ id: z.id, name: z.name, lat: z.lat, lng: z.lng, radius: String(z.radius_m) }); setMsg(null); window.scrollTo({ top: 0, behavior: 'smooth' }); };

  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (!profile?.company_id) return;
    if (form.lat === null || form.lng === null) { setMsg({ kind: 'error', text: 'Ubicá el galpón en el mapa.' }); return; }
    const row = { name: form.name.trim(), lat: form.lat, lng: form.lng, radius_m: Number(form.radius) };
    setBusy(true);
    const { error } = form.id
      ? await supabase.from('clock_zones').update(row).eq('id', form.id)
      : await supabase.from('clock_zones').insert({ ...row, company_id: profile.company_id });
    setBusy(false);
    if (error) {
      setMsg({ kind: 'error', text: error.code === '23505' ? 'Ya hay una zona con ese nombre.' : /check/i.test(error.message) ? 'El radio tiene que estar entre 20 y 5000 metros.' : friendly(error) });
      return;
    }
    setMsg({ kind: 'ok', text: form.id ? 'Zona actualizada.' : 'Zona agregada. Desde ahora los conductores de la empresa inician y cierran la jornada marcando con foto y ubicación.' });
    setForm(EMPTY); zones.reload();
  };

  const toggle = async (z: Zone) => {
    const { error } = await supabase.from('clock_zones').update({ active: !z.active }).eq('id', z.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else zones.reload();
  };
  const remove = async (z: Zone) => {
    if (!window.confirm(`¿Quitar la zona "${z.name}"? Los marcajes ya hechos conservan el nombre.`)) return;
    const { error } = await supabase.from('clock_zones').delete().eq('id', z.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else { zones.reload(); if (form.id === z.id) setForm(EMPTY); }
  };

  const radius = Number(form.radius);
  const others = (zones.data ?? []).filter((z) => z.id !== form.id && z.active);
  const active = (zones.data ?? []).filter((z) => z.active).length;
  return (
    <>
      <PageHead title="Zonas de marcaje" subtitle="Administrá los lugares habilitados para iniciar y cerrar la jornada." actions={<button className="secondary compact" onClick={() => { zones.reload(); settings.reload(); }}>Actualizar</button>} />
      {zones.data && active === 0 && <Notice kind="warn">Sin zonas activas el marcaje está desactivado: los conductores inician y cierran la jornada como siempre. Al activar la primera zona pasan a marcar con foto y ubicación.</Notice>}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {zones.error && <Notice>{zones.error}</Notice>}
      <div className="gps-cards zone-summary" aria-label="Resumen de zonas">
        <div className="gps-card"><b>{(zones.data ?? []).length}</b><span>Zonas configuradas</span></div>
        <div className="gps-card"><b>{active}</b><span>Activas</span></div>
      </div>
      <div className="gps-layout zone-layout">
        <div className="gps-left">
          <section className="card zone-list">
            <h2>Zonas</h2>
            {zones.loading ? <Loading /> : (zones.data ?? []).length === 0
              ? <p className="muted">Todavía no hay zonas. Creá la primera desde el formulario.</p>
              : (zones.data ?? []).map((z) => <article className="zone-row" key={z.id}>
                <div><b>{z.name}</b><span className="muted">{z.radius_m} m · {z.active ? 'Activa' : 'Inactiva'}</span></div>
                <div className="row zone-actions">
                  <button type="button" className="secondary compact" onClick={() => edit(z)}>Editar</button>
                  <button type="button" className="secondary compact" onClick={() => void toggle(z)}>{z.active ? 'Desactivar' : 'Activar'}</button>
                  <button type="button" className="secondary compact" onClick={() => void remove(z)}>Quitar</button>
                </div>
              </article>)}
          </section>
          <details className="card zone-settings">
            <summary><b>Configuración de marcajes</b><span className="muted">Excepciones y conservación de fotos</span></summary>
            <div className="stack">
              <label>Si marca fuera de la zona
                <select value={curMode} onChange={(e) => setMode(e.target.value as 'block' | 'review')}>
                  <option value="block">Bloquear el marcaje</option><option value="review">Permitir y señalar para revisión</option>
                </select>
              </label>
              <label>Conservar las fotos (días)<input type="number" min={7} max={365} value={curDays} onChange={(e) => setDays(e.target.value)} /></label>
              <p className="muted">Después se borran las fotos; se conservan la hora, ubicación y resultado.</p>
              <button type="button" onClick={() => void saveSettings()} disabled={settings.loading}>Guardar configuración</button>
            </div>
          </details>
        </div>
        <div className="gps-right">
          <form className="card stack zone-editor" onSubmit={save}>
            <h2>{form.id ? 'Editar zona' : 'Nueva zona'}</h2>
            <div className="row">
              <label>Nombre<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Ej.: Galpón Paraná" maxLength={80} required /></label>
              <label className="zone-radius">Radio (m)<input type="number" min={20} max={5000} value={form.radius} onChange={(e) => setForm({ ...form, radius: e.target.value })} required /></label>
            </div>
            <ZoneMap lat={form.lat} lng={form.lng} radius={Number.isFinite(radius) && radius > 0 ? radius : 100} others={others}
              onPick={(lat, lng) => setForm((f) => ({ ...f, lat, lng }))} />
            <p className="muted zone-hint">Tocá el mapa o arrastrá el pin para elegir la ubicación.</p>
            <div className="row">
              <button type="submit" disabled={busy}>{form.id ? 'Guardar cambios' : 'Agregar zona'}</button>
              {form.id && <button type="button" className="secondary" onClick={() => setForm(EMPTY)}>Cancelar edición</button>}
            </div>
          </form>
        </div>
      </div>
    </>
  );
}
