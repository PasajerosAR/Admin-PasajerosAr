import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import type { Profile, PlatformPermission } from '../lib/types';

type Section = PlatformPermission['section'];
const ALL_SECTIONS: { key: Section; label: string }[] = [
  { key: 'companies', label: 'Empresas' },
  { key: 'routes',    label: 'Recorridos' },
  { key: 'places',    label: 'Localidades' },
  { key: 'gps',       label: 'Seguimiento GPS' },
  { key: 'reports',   label: 'Reportes globales' },
];

const EMPTY_FORM = { full_name: '', email: '', password: '' };
type PermState = Record<Section, { view: boolean; edit: boolean }>;
function emptyPerms(): PermState {
  const r = {} as PermState;
  for (const s of ALL_SECTIONS) r[s.key] = { view: false, edit: false };
  return r;
}

interface StaffWithPerms extends Profile {
  permissions: PlatformPermission[];
}

export function PlatformStaffPage() {
  const [form, setForm]       = useState(EMPTY_FORM);
  const [perms, setPerms]     = useState<PermState>(emptyPerms());
  const [msg, setMsg]         = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy]       = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [editPerms, setEditPerms] = useState<PermState>(emptyPerms());

  const staff = useQuery(async () => {
    const profiles = must(
      await supabase.from('profiles').select('*').eq('role', 'platform_staff').order('full_name')
    ) as Profile[];
    const permsAll = profiles.length
      ? must(await supabase.from('platform_permissions').select('*')
          .in('profile_id', profiles.map((p) => p.id))) as PlatformPermission[]
      : [];
    return profiles.map((p) => ({
      ...p,
      permissions: permsAll.filter((pp) => pp.profile_id === p.id)
    })) as StaffWithPerms[];
  }, []);

  const set = (k: keyof typeof EMPTY_FORM) => (e: { target: { value: string } }) =>
    setForm({ ...form, [k]: e.target.value });

  const togglePerm = (ps: PermState, setter: (p: PermState) => void, key: Section, type: 'view' | 'edit') => {
    const cur = ps[key];
    const next = { ...cur };
    if (type === 'view') {
      next.view = !cur.view;
      if (!next.view) next.edit = false; // quitar edicion si se quita vista
    } else {
      next.edit = !cur.edit;
      if (next.edit) next.view = true; // edicion implica vista
    }
    setter({ ...ps, [key]: next });
  };

  const permsToPayload = (ps: PermState) =>
    ALL_SECTIONS
      .filter((s) => ps[s.key].view || ps[s.key].edit)
      .map((s) => ({ section: s.key, can_edit: ps[s.key].edit }));

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    const payload = { ...form, permissions: permsToPayload(perms) };
    const { error, data } = await supabase.functions.invoke('create-platform-staff', { body: payload });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Colaborador creado. Pasale el correo y la contraseña inicial.' });
    setForm(EMPTY_FORM);
    setPerms(emptyPerms());
    staff.reload();
  };

  const startEdit = (s: StaffWithPerms) => {
    const ps = emptyPerms();
    for (const pp of s.permissions) {
      ps[pp.section] = { view: true, edit: pp.can_edit };
    }
    setEditPerms(ps);
    setEditing(s.id);
  };

  const savePerms = async (profileId: string) => {
    setBusy(true);
    setMsg(null);
    // Borrar y reemplazar permisos
    const { error: delErr } = await supabase
      .from('platform_permissions').delete().eq('profile_id', profileId);
    if (delErr) { setMsg({ kind: 'error', text: friendly(delErr) }); setBusy(false); return; }

    const rows = permsToPayload(editPerms).map((p) => ({ ...p, profile_id: profileId }));
    if (rows.length > 0) {
      const { error: insErr } = await supabase.from('platform_permissions').insert(rows);
      if (insErr) { setMsg({ kind: 'error', text: friendly(insErr) }); setBusy(false); return; }
    }
    setBusy(false);
    setEditing(null);
    setMsg({ kind: 'ok', text: 'Permisos actualizados.' });
    staff.reload();
  };

  const toggleActive = async (s: StaffWithPerms) => {
    const { error } = await supabase.from('profiles').update({ active: !s.active }).eq('id', s.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else staff.reload();
  };

  return (
    <>
      <h1>Equipo de plataforma</h1>
      <p className="muted">Creá colaboradores con acceso limitado al panel general. Podés ajustar los permisos en cualquier momento.</p>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <form className="card stack" onSubmit={create}>
        <h2>Agregar colaborador</h2>
        <div className="row">
          <label>Nombre y apellido<input value={form.full_name} onChange={set('full_name')} required /></label>
          <label>Correo (usuario)<input type="email" value={form.email} onChange={set('email')} required /></label>
          <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
        </div>
        <div>
          <h2>Permisos de acceso</h2>
          <table>
            <thead>
              <tr>
                <th>Sección</th>
                <th style={{ textAlign: 'center' }}>Ver</th>
                <th style={{ textAlign: 'center' }}>Editar</th>
              </tr>
            </thead>
            <tbody>
              {ALL_SECTIONS.map((s) => (
                <tr key={s.key}>
                  <td>{s.label}</td>
                  <td style={{ textAlign: 'center' }}>
                    <input type="checkbox" checked={perms[s.key].view}
                      onChange={() => togglePerm(perms, setPerms, s.key, 'view')} />
                  </td>
                  <td style={{ textAlign: 'center' }}>
                    <input type="checkbox" checked={perms[s.key].edit}
                      onChange={() => togglePerm(perms, setPerms, s.key, 'edit')} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="row">
          <button type="submit" disabled={busy}>{busy ? 'Creando...' : 'Crear colaborador'}</button>
        </div>
      </form>

      <div className="card table-wrap">
        <h2>Colaboradores actuales</h2>
        {staff.loading ? <Loading /> : (
          <table>
            <thead>
              <tr><th>Nombre</th><th>Secciones con acceso</th><th>Estado</th><th /></tr>
            </thead>
            <tbody>
              {(staff.data ?? []).length === 0 && (
                <tr><td colSpan={4} className="muted">Todavía no hay colaboradores de plataforma.</td></tr>
              )}
              {(staff.data ?? []).map((s) => (
                <>
                  <tr key={s.id}>
                    <td><b>{s.full_name}</b></td>
                    <td>
                      {s.permissions.length === 0
                        ? <span className="muted">Sin acceso</span>
                        : s.permissions.map((p) => (
                          <span key={p.section} className={`pill ${p.can_edit ? 'warn' : 'info'}`} style={{ marginRight: 4 }}>
                            {ALL_SECTIONS.find((x) => x.key === p.section)?.label ?? p.section}
                            {p.can_edit ? ' ✎' : ' 👁'}
                          </span>
                        ))
                      }
                    </td>
                    <td>
                      {s.active
                        ? <span className="pill ok">Activo</span>
                        : <span className="pill warn">Inactivo</span>
                      }
                    </td>
                    <td>
                      <div className="row" style={{ gap: 8, justifyContent: 'flex-end' }}>
                        <button className="secondary" onClick={() => editing === s.id ? setEditing(null) : startEdit(s)}>
                          {editing === s.id ? 'Cancelar' : 'Permisos'}
                        </button>
                        <button className="secondary" onClick={() => toggleActive(s)}>
                          {s.active ? 'Desactivar' : 'Activar'}
                        </button>
                      </div>
                    </td>
                  </tr>
                  {editing === s.id && (
                    <tr key={`edit-${s.id}`}>
                      <td colSpan={4}>
                        <div className="card stack" style={{ margin: '8px 0' }}>
                          <h2>Editar permisos de {s.full_name}</h2>
                          <table>
                            <thead>
                              <tr><th>Sección</th><th style={{ textAlign: 'center' }}>Ver</th><th style={{ textAlign: 'center' }}>Editar</th></tr>
                            </thead>
                            <tbody>
                              {ALL_SECTIONS.map((sec) => (
                                <tr key={sec.key}>
                                  <td>{sec.label}</td>
                                  <td style={{ textAlign: 'center' }}>
                                    <input type="checkbox" checked={editPerms[sec.key].view}
                                      onChange={() => togglePerm(editPerms, setEditPerms, sec.key, 'view')} />
                                  </td>
                                  <td style={{ textAlign: 'center' }}>
                                    <input type="checkbox" checked={editPerms[sec.key].edit}
                                      onChange={() => togglePerm(editPerms, setEditPerms, sec.key, 'edit')} />
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                          <div className="row">
                            <button onClick={() => savePerms(s.id)} disabled={busy}>
                              {busy ? 'Guardando...' : 'Guardar permisos'}
                            </button>
                            <button className="secondary" onClick={() => setEditing(null)}>Cancelar</button>
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                </>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
