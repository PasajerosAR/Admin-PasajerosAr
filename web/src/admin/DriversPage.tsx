import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { FilterBox, Loading, Notice, matches } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Profile } from '../lib/types';

const EMPTY = { full_name: '', legajo: '', email: '', password: '', dni: '', phone: '' };

export function DriversPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const drivers = useQuery(async () => must(await supabase.from('profiles').select('*').eq('role', 'driver').is('deleted_at', null).order('full_name')) as Profile[], []);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error, data } = await supabase.functions.invoke('create-driver', { body: form });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Conductor creado. Pasale el correo y la contraseña inicial.' });
    setForm(EMPTY); drivers.reload();
  };

  const toggle = async (d: Profile) => {
    const { error } = await supabase.from('profiles').update({ active: !d.active }).eq('id', d.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else drivers.reload();
  };

  const remove = async (d: Profile) => {
    if (!window.confirm(`¿Eliminar a ${d.full_name}? Si ya tiene viajes, ventas o jornadas, deja de aparecer y no puede ingresar, pero su historial se conserva. Si nunca tuvo actividad, se borra del todo.`)) return;
    const { data, error } = await supabase.rpc('remove_driver', { p_driver: d.id });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: (data as { kept_history?: boolean } | null)?.kept_history ? `${d.full_name} eliminado. Su historial se conserva.` : `${d.full_name} eliminado.` });
    drivers.reload();
  };

  const editLegajo = async (d: Profile) => {
    const value = window.prompt(`Legajo de ${d.full_name}:`, d.legajo ?? '');
    if (value === null) return;
    const { error } = await supabase.rpc('set_legajo', { p_profile: d.id, p_legajo: value });
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else drivers.reload();
  };

  const [q, setQ] = useState('');
  const visible = (drivers.data ?? []).filter((d) => matches(q, d.full_name, d.legajo, d.dni, d.phone));

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <h1>Conductores</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && (
        <form className="card stack" onSubmit={create}>
          <h2>Agregar conductor</h2>
          <div className="row">
            <label>Nombre y apellido<input value={form.full_name} onChange={set('full_name')} required /></label>
            <label>Legajo<input value={form.legajo} onChange={set('legajo')} maxLength={20} /></label>
            <label>DNI<input value={form.dni} onChange={set('dni')} inputMode="numeric" /></label>
            <label>Teléfono<input value={form.phone} onChange={set('phone')} inputMode="tel" /></label>
          </div>
          <div className="row">
            <label>Correo (usuario)<input type="email" value={form.email} onChange={set('email')} required /></label>
            <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
            <button type="submit" disabled={busy}>{busy ? 'Creando...' : 'Crear conductor'}</button>
          </div>
        </form>
      )}
      <div className="card table-wrap">
        <FilterBox value={q} onChange={setQ} placeholder="Buscar por nombre, legajo o DNI" />
        {drivers.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Nombre</th><th>Legajo</th><th>DNI</th><th>Teléfono</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {visible.length === 0 && <tr><td colSpan={6} className="muted">{(drivers.data ?? []).length === 0 ? 'Todavía no hay conductores.' : 'Ningún conductor coincide.'}</td></tr>}
              {visible.map((d) => (
                <tr key={d.id}>
                  <td><b>{d.full_name}</b></td><td>{d.legajo ?? '-'}</td><td>{d.dni ?? '-'}</td><td>{d.phone ?? '-'}</td>
                  <td>{d.active ? <span className="pill ok">Activo</span> : <span className="pill warn">Inactivo</span>}</td>
                  <td>{canEdit && <div className="row"><button className="secondary" onClick={() => editLegajo(d)}>Legajo</button><button className="secondary" onClick={() => toggle(d)}>{d.active ? 'Desactivar' : 'Activar'}</button><button className="danger" onClick={() => remove(d)}>Eliminar</button></div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
