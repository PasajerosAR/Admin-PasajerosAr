import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { FilterBox, Loading, Notice, PageHead, matches } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Profile } from '../lib/types';
import { changePasswordFor, changeUsername } from '../lib/userAdmin';
import { BulkBar, HeadCheck, RowCheck, confirmDelete, useBulk } from './bulk';

const EMPTY = { full_name: '', legajo: '', username: '', email: '', password: '', dni: '', phone: '' };

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
    const { data: pending } = await supabase.from('trips').select('id,status').eq('driver_id', d.id).in('status', ['scheduled', 'in_progress']);
    const live = (pending ?? []).filter((t) => t.status === 'in_progress').length;
    const next = (pending ?? []).length - live;
    const aviso = live + next > 0
      ? `\n\nAtención: tiene ${live ? `${live} viaje en curso` : ''}${live && next ? ' y ' : ''}${next ? `${next} programado${next > 1 ? 's' : ''}` : ''}. Quedarán sin conductor y tendrás que cubrirlos.`
      : '';
    if (!window.confirm(`¿Eliminar a ${d.full_name}? Deja de aparecer y no puede ingresar. Su historial se conserva.${aviso}`)) return;
    const { data, error } = await supabase.rpc('remove_driver', { p_driver: d.id });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    const sinChofer = (data as { trips_without_driver?: number } | null)?.trips_without_driver ?? 0;
    setMsg({ kind: 'ok', text: `${d.full_name} eliminado.${sinChofer ? ` ${sinChofer} viaje${sinChofer > 1 ? 's' : ''} quedó sin conductor: asignalo en Viajes.` : ''}` });
    drivers.reload();
  };

  const act = async (p: Promise<{ kind: 'error' | 'ok'; text: string } | null>) => { const m = await p; if (m) { setMsg(m); if (m.kind === 'ok') drivers.reload(); } };

  const editLegajo = async (d: Profile) => {
    const value = window.prompt(`Legajo de ${d.full_name}:`, d.legajo ?? '');
    if (value === null) return;
    const { error } = await supabase.rpc('set_legajo', { p_profile: d.id, p_legajo: value });
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else drivers.reload();
  };

  const [q, setQ] = useState('');
  const visible = (drivers.data ?? []).filter((d) => matches(q, d.full_name, d.legajo, d.username, d.dni, d.phone));

  const bulk = useBulk(visible.map((d) => d.id));
  const [bulkBusy, setBulkBusy] = useState(false);
  const removeSelected = async () => {
    const { data: pending } = await supabase.from('trips').select('id').in('driver_id', bulk.selected).in('status', ['scheduled', 'in_progress']);
    const n = (pending ?? []).length;
    const aviso = n > 0 ? `Atención: ${n} viaje${n > 1 ? 's' : ''} programado${n > 1 ? 's' : ''} o en curso quedarán sin conductor y tendrás que cubrirlos. ` : '';
    if (!confirmDelete(bulk.count, 'conductor', 'conductores', `${aviso}Dejan de aparecer y no pueden ingresar. Su historial se conserva.`)) return;
    setBulkBusy(true);
    let done = 0; let without = 0; let failed = '';
    for (const id of bulk.selected) {
      const { data, error } = await supabase.rpc('remove_driver', { p_driver: id });
      if (error) { failed = friendly(error); break; }
      done += 1; without += (data as { trips_without_driver?: number } | null)?.trips_without_driver ?? 0;
    }
    setBulkBusy(false);
    const tail = without ? ` ${without} viaje${without > 1 ? 's' : ''} quedó sin conductor: asignalo en Viajes.` : '';
    setMsg(failed ? { kind: 'error', text: `Se eliminaron ${done} de ${bulk.count}. ${failed}` } : { kind: 'ok', text: `${done === 1 ? 'Conductor eliminado.' : `${done} conductores eliminados.`}${tail}` });
    bulk.clear(); drivers.reload();
  };


  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <PageHead title="Conductores" />
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && (
        <form className="card" onSubmit={create}>
          <div className="card-head"><h2>Agregar conductor</h2></div>
          <div className="form-grid">
            <label>Nombre y apellido<input value={form.full_name} onChange={set('full_name')} required /></label>
            <label>Legajo<input value={form.legajo} onChange={set('legajo')} maxLength={20} /></label>
            <label>Usuario (opcional)<input value={form.username} onChange={set('username')} maxLength={30} autoCapitalize="none" spellCheck={false} /></label>
            <label>DNI<input value={form.dni} onChange={set('dni')} inputMode="numeric" /></label>
            <label>Teléfono<input value={form.phone} onChange={set('phone')} inputMode="tel" /></label>
            <label>Correo (usuario)<input type="email" value={form.email} onChange={set('email')} required /></label>
            <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
            <div className="form-actions"><button type="submit" disabled={busy}>{busy ? 'Creando...' : 'Crear conductor'}</button></div>
          </div>
        </form>
      )}
      <div className="card list-card">
        <div className="list-head">
          <FilterBox value={q} onChange={setQ} placeholder="Buscar por nombre, legajo o DNI" />
        </div>
        {canEdit && <BulkBar bulk={bulk} one="conductor" many="conductores" busy={bulkBusy} onDelete={() => void removeSelected()} />}
        <div className="table-wrap">
          {drivers.loading ? <Loading /> : (
            <table>
              <thead><tr>{canEdit && <HeadCheck bulk={bulk} />}<th>Nombre</th><th>Legajo</th><th>Usuario</th><th>DNI</th><th>Teléfono</th><th>Estado</th><th /></tr></thead>
              <tbody>
                {visible.length === 0 && <tr><td colSpan={8} className="muted">{(drivers.data ?? []).length === 0 ? 'Todavía no hay conductores.' : 'Ningún conductor coincide.'}</td></tr>}
                {visible.map((d) => (
                  <tr key={d.id}>
                    {canEdit && <RowCheck bulk={bulk} id={d.id} />}
                    <td><b>{d.full_name}</b></td><td>{d.legajo ?? '-'}</td><td>{d.username ?? '-'}</td><td>{d.dni ?? '-'}</td><td>{d.phone ?? '-'}</td>
                    <td>{d.active ? <span className="pill ok">Activo</span> : <span className="pill warn">Inactivo</span>}</td>
                    <td className="td-actions">{canEdit && <><button className="secondary" onClick={() => editLegajo(d)}>Legajo</button><button className="secondary" onClick={() => void act(changeUsername(d))}>Usuario</button><button className="secondary" onClick={() => void act(changePasswordFor(d))}>Clave</button><button className="secondary" onClick={() => toggle(d)}>{d.active ? 'Desactivar' : 'Activar'}</button><button className="danger" onClick={() => remove(d)}>Eliminar</button></>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
