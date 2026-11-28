import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
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
      <h1>Zonas de marcaje</h1>
      <p className="muted">Ubicá los lugares donde se puede marcar la entrada y la salida (galpones, terminales) y el radio permitido en metros. El servidor valida la distancia con la ubicación que informa el teléfono: es una evidencia, no una prueba infalible (el GPS puede tener error o ser manipulado).</p>
      {zones.data && active === 0 && <Notice kind="warn">Sin zonas activas el marcaje está desactivado: los conductores inician y cierran la jornada como siempre. Al activar la primera zona pasan a marcar con foto y ubicación.</Notice>}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <div className="card stack">
        <h2 style={{ margin: 0 }}>Fuera de la zona</h2>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="radio" name="mode" style={{ width: 'auto' }} checked={curMode === 'block'} onChange={() => setMode('block')} /> Bloquear el marcaje (el conductor no puede iniciar ni cerrar la jornada)</label>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="radio" name="mode" style={{ width: 'auto' }} checked={curMode === 'review'} onChange={() => setMode('review')} /> Registrarlo para revisión (el conductor marca y queda señalado en Marcajes)</label>
        <label style={{ maxWidth: 320 }}>Conservar las fotos (días)
          <input type="number" min={7} max={365} value={curDays} onChange={(e) => setDays(e.target.value)} />
        </label>
        <p className="muted" style={{ margin: 0 }}>Pasado ese plazo se borran las fotos; la hora, la ubicación y el resultado del marcaje se conservan.</p>
        <div><button type="button" onClick={() => void saveSettings()} disabled={settings.loading}>Guardar configuración</button></div>
      </div>

      <form className="card stack" onSubmit={save}>
        <h2 style={{ margin: 0 }}>{form.id ? 'Editar zona' : 'Nueva zona'}</h2>
        <div className="row">
          <label>Nombre<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Ej.: Galpón Paraná" maxLength={80} required /></label>
          <label style={{ flex: '0 0 200px' }}>Radio (metros)<input type="number" min={20} max={5000} value={form.radius} onChange={(e) => setForm({ ...form, radius: e.target.value })} required /></label>
        </div>
        <ZoneMap lat={form.lat} lng={form.lng} radius={Number.isFinite(radius) && radius > 0 ? radius : 100} others={others}
          onPick={(lat, lng) => setForm((f) => ({ ...f, lat, lng }))} />
        <div className="row">
          <button type="submit" disabled={busy}>{form.id ? 'Guardar cambios' : 'Agregar zona'}</button>
          {form.id && <button type="button" className="secondary" onClick={() => setForm(EMPTY)}>Cancelar</button>}
        </div>
      </form>

      {zones.error && <Notice>{zones.error}</Notice>}
      {zones.loading && <Loading />}
      <div className="card table-wrap">
        <table>
          <thead><tr><th>Zona</th><th>Radio</th><th>Estado</th><th /></tr></thead>
          <tbody>
            {(zones.data ?? []).map((z) => (
              <tr key={z.id}>
                <td>{z.name}</td><td>{z.radius_m} m</td><td>{z.active ? 'Activa' : 'Inactiva'}</td>
                <td className="row" style={{ gap: 6 }}>
                  <button type="button" className="secondary" onClick={() => edit(z)}>Editar</button>
                  <button type="button" className="secondary" onClick={() => void toggle(z)}>{z.active ? 'Desactivar' : 'Activar'}</button>
                  <button type="button" className="secondary" onClick={() => void remove(z)}>Quitar</button>
                </td>
              </tr>
            ))}
            {!zones.loading && (zones.data ?? []).length === 0 && <tr><td colSpan={4} className="muted">Todavía no hay zonas.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
