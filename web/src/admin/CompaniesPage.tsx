import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import type { Company } from '../lib/types';
import { useAuth } from '../auth/AuthProvider';

const EMPTY = { company_name: '', full_name: '', email: '', password: '' };

export function CompaniesPage() {
  const { profile } = useAuth();
  const [form, setForm] = useState(EMPTY);
  const [busy, setBusy] = useState(false);
  const [uploadingLogoFor, setUploadingLogoFor] = useState('');
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const companies = useQuery(async () => must(await supabase.from('companies').select('*').order('name')) as Company[], []);
  const canCreate = profile?.role === 'platform_admin';
  const permission = useQuery<{ can_edit: boolean } | null>(async () => profile?.role === 'platform_staff'
    ? must(await supabase.from('platform_permissions').select('can_edit')
      .or('section.eq.companies,section.eq.all').order('can_edit', { ascending: false }).limit(1).maybeSingle()) as { can_edit: boolean } | null
    : null, [profile?.role]);
  const canEdit = canCreate || permission.data?.can_edit === true;

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error, data } = await supabase.functions.invoke('create-company-admin', { body: form });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Empresa creada. Pasale al administrador su correo y la contraseña inicial.' });
    setForm(EMPTY); companies.reload();
  };

  const toggle = async (c: Company) => {
    const { error } = await supabase.from('companies').update({ active: !c.active }).eq('id', c.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else companies.reload();
  };

  const uploadLogo = async (company: Company, file?: File) => {
    if (!file) return;
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 3 * 1024 * 1024) {
      setMsg({ kind: 'error', text: 'Elegí una imagen JPG, PNG o WebP de hasta 3 MB.' });
      return;
    }
    const extension = file.type === 'image/jpeg' ? 'jpg' : file.type === 'image/png' ? 'png' : 'webp';
    const path = `${company.id}/${crypto.randomUUID()}.${extension}`;
    setUploadingLogoFor(company.id);
    setMsg(null);
    const { error: uploadError } = await supabase.storage.from('company-logos').upload(path, file, {
      cacheControl: '3600',
      contentType: file.type,
      upsert: false
    });
    if (uploadError) {
      setUploadingLogoFor('');
      setMsg({ kind: 'error', text: friendly(uploadError) });
      return;
    }
    const { error: saveError } = await supabase.rpc('save_company_logo', {
      p_company: company.id,
      p_logo_path: path
    });
    if (saveError) {
      const { error: cleanupError } = await supabase.storage.from('company-logos').remove([path]);
      setUploadingLogoFor('');
      setMsg({
        kind: 'error',
        text: cleanupError
          ? `${friendly(saveError)} No se pudo limpiar el archivo que se había subido.`
          : friendly(saveError)
      });
      return;
    }
    let success = 'Logo actualizado.';
    if (company.logo_path) {
      const { error: removeError } = await supabase.storage.from('company-logos').remove([company.logo_path]);
      if (removeError) success = 'Logo actualizado; quedó una copia anterior en el almacenamiento.';
    }
    setUploadingLogoFor('');
    setMsg({ kind: 'ok', text: success });
    companies.reload();
  };

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <h1>Empresas</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canCreate && (
        <form className="card stack" onSubmit={create}>
          <h2>Nueva empresa</h2>
          <div className="row">
            <label>Nombre de la empresa<input value={form.company_name} onChange={set('company_name')} required /></label>
            <label>Administrador: nombre completo<input value={form.full_name} onChange={set('full_name')} required /></label>
          </div>
          <div className="row">
            <label>Correo<input type="email" value={form.email} onChange={set('email')} required /></label>
            <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
          </div>
          <button type="submit" disabled={busy} style={{ alignSelf: 'flex-start' }}>Crear empresa</button>
        </form>
      )}
      <div className="card table-wrap">
        {companies.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Empresa</th><th>Logo</th><th>Alta</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {(companies.data ?? []).length === 0 && <tr><td colSpan={5} className="muted">Todavía no hay empresas.</td></tr>}
              {(companies.data ?? []).map((c) => (
                <tr key={c.id}>
                  <td><b>{c.name}</b></td>
                  <td>
                    {c.logo_path && <img
                      src={supabase.storage.from('company-logos').getPublicUrl(c.logo_path).data.publicUrl}
                      alt={`Logo de ${c.name}`}
                      style={{ width: 72, height: 42, objectFit: 'contain', display: 'block', marginBottom: 6 }}
                    />}
                    {canEdit && <label>
                      <span className="muted">{c.logo_path ? 'Cambiar imagen' : 'Subir imagen'}</span>
                      <input
                        type="file"
                        accept="image/jpeg,image/png,image/webp"
                        disabled={uploadingLogoFor === c.id}
                        onChange={(event) => {
                          const file = event.target.files?.[0];
                          event.target.value = '';
                          void uploadLogo(c, file);
                        }}
                      />
                    </label>}
                    {uploadingLogoFor === c.id && <span className="muted">Subiendo...</span>}
                  </td>
                  <td>{new Date(c.created_at).toLocaleDateString('es-AR')}</td>
                  <td>{c.active ? <span className="pill ok">Activa</span> : <span className="pill warn">Suspendida</span>}</td>
                  <td>{canEdit && <button className="secondary" onClick={() => toggle(c)}>{c.active ? 'Suspender' : 'Activar'}</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
