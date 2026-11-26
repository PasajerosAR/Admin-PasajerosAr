import { useState, type FormEvent } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { must, useQuery } from '../../lib/useQuery';
import { FilterBox, Loading, Notice, PageHead, matches } from '../../ui';
import { useAuth } from '../../auth/AuthProvider';
import type { Profile } from '../../lib/types';

const EMPTY = { full_name: '', legajo: '', dni: '', email: '', phone: '', password: '', role: 'seller' as 'seller' | 'company_admin' };

export function CompanyUsersPage() {
  const [q, setQ] = useState('');
  const { profile } = useAuth();
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg]   = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const users = useQuery(async () =>
    must(await supabase
      .from('profiles')
      .select('*')
      .in('role', ['company_admin', 'seller'])
      .order('full_name')
    ) as Profile[], []);

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) =>
    setForm({ ...form, [k]: e.target.value });

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    const { error, data } = await supabase.functions.invoke('create-company-user', { body: form });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Usuario creado. Pasale el correo y la contraseña inicial.' });
    setForm(EMPTY);
    users.reload();
  };

  const toggleActive = async (u: Profile) => {
    if (u.id === profile?.id) {
      setMsg({ kind: 'error', text: 'No podés desactivar tu propio usuario.' });
      return;
    }
    const { error } = await supabase.from('profiles').update({ active: !u.active }).eq('id', u.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else users.reload();
  };

  const roleLabel = (r: Profile['role']) =>
    r === 'company_admin' ? 'Administrador' : r === 'seller' ? 'Vendedor' : r;

  return (
    <>
      <PageHead title="Usuarios internos" />
      <p className="muted">
        Administradores y vendedores de tu empresa. Los vendedores tienen acceso completo
        a ventas, devoluciones y QR de cortesía. Todo queda registrado para auditoría.
      </p>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <form className="card stack" onSubmit={create}>
        <h2>Agregar usuario</h2>
        <div className="row">
          <label>Nombre y apellido<input value={form.full_name} onChange={set('full_name')} required /></label>
          <label>Legajo<input value={form.legajo} onChange={set('legajo')} maxLength={20} /></label>
          <label>DNI<input value={form.dni} onChange={set('dni')} inputMode="numeric" required /></label>
          <label>Teléfono<input value={form.phone} onChange={set('phone')} inputMode="tel" required /></label>
        </div>
        <div className="row">
          <label>Correo (usuario)<input type="email" value={form.email} onChange={set('email')} required /></label>
          <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
          <label>
            Rol
            <select value={form.role} onChange={(e) => setForm({ ...form, role: e.target.value as typeof form.role })}>
              <option value="seller">Vendedor</option>
              <option value="company_admin">Administrador</option>
            </select>
          </label>
          <button type="submit" disabled={busy}>{busy ? 'Creando...' : 'Crear usuario'}</button>
        </div>
      </form>

      <div className="card table-wrap">
        <FilterBox value={q} onChange={setQ} placeholder="Buscar por nombre, DNI o correo" />
        {users.loading ? <Loading /> : (
          <table>
            <thead>
              <tr><th>Nombre</th><th>DNI</th><th>Teléfono</th><th>Correo</th><th>Rol</th><th>Estado</th><th /></tr>
            </thead>
            <tbody>
              {(users.data ?? []).filter((u) => matches(q, u.full_name, u.dni, u.legajo, u.phone)).length === 0 && (
                <tr><td colSpan={7} className="muted">{(users.data ?? []).length === 0 ? 'Todavía no hay usuarios internos.' : 'Ningún usuario coincide.'}</td></tr>
              )}
              {(users.data ?? []).filter((u) => matches(q, u.full_name, u.dni, u.legajo, u.phone)).map((u) => (
                <tr key={u.id}>
                  <td><b>{u.full_name}</b>{u.id === profile?.id && <span className="muted"> (vos)</span>}</td>
                  <td>{u.dni ?? '-'}</td>
                  <td>{u.phone ?? '-'}</td>
                  <td className="muted" style={{ fontSize: 12 }}>{/* email no está en profiles, se gestiona via auth */}—</td>
                  <td>
                    <span className={`pill ${u.role === 'company_admin' ? 'info' : 'ok'}`}>
                      {roleLabel(u.role)}
                    </span>
                  </td>
                  <td>
                    {u.active
                      ? <span className="pill ok">Activo</span>
                      : <span className="pill warn">Inactivo</span>
                    }
                  </td>
                  <td>
                    {u.id !== profile?.id && (
                      <button className="secondary" onClick={() => toggleActive(u)}>
                        {u.active ? 'Desactivar' : 'Activar'}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
