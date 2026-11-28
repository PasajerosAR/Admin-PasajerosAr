import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { FilterBox, Loading, Notice, PageHead } from '../ui';
import { fold } from '../lib/text';
import type { Company } from '../lib/types';
import { useAuth } from '../auth/AuthProvider';
import { COMPANY_FEATURES, featureLabel } from '../lib/features';
import { changePasswordFor, changeUsername } from '../lib/userAdmin';

const EMPTY = { company_name: '', full_name: '', legajo: '', username: '', email: '', password: '' };

// Casillas de funciones bloqueadas: tildar una función la bloquea para la empresa.
function FeatureChecks({ blocked, onChange }: { blocked: string[]; onChange: (next: string[]) => void }) {
  return (
    <fieldset className="feature-box">
      <legend>Funciones bloqueadas <span className="muted">· tildá las que esta empresa NO va a usar</span></legend>
      <div className="feature-list">
        {COMPANY_FEATURES.map((f) => {
          const isBlocked = blocked.includes(f.key);
          return (
            <label key={f.key} className={`feature-item${isBlocked ? ' is-blocked' : ''}`} title={f.help}>
              <input type="checkbox" checked={isBlocked}
                onChange={(e) => onChange(e.target.checked ? [...blocked, f.key] : blocked.filter((k) => k !== f.key))} />
              <span><b>{f.label}</b><small>{f.help}</small></span>
            </label>
          );
        })}
      </div>
    </fieldset>
  );
}

export function CompaniesPage() {
  const { profile } = useAuth();
  const [form, setForm] = useState(EMPTY);
  const [newBlocked, setNewBlocked] = useState<string[]>([]);
  const [editing, setEditing] = useState<{ id: string; blocked: string[] } | null>(null);
  const [busy, setBusy] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<'all' | 'active' | 'suspended'>('all');
  const [uploadingLogoFor, setUploadingLogoFor] = useState('');
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const companies = useQuery(async () => must(await supabase.from('companies').select('*').is('deleted_at', null).order('name')) as Company[], []);
  const canCreate = profile?.role === 'platform_admin';
  const selectedCompanyId = (companies.data ?? []).find((c) => c.id === selectedId)?.id ?? '';
  const admins = useQuery(async () => canCreate && selectedCompanyId
    ? must(await supabase.from('profiles').select('id,full_name,username').eq('company_id', selectedCompanyId).eq('role', 'company_admin').order('full_name')) as { id: string; full_name: string; username: string | null }[]
    : [], [canCreate, selectedCompanyId]);
  const actOn = async (p: Promise<{ kind: 'error' | 'ok'; text: string } | null>) => { const m = await p; if (m) { setMsg(m); if (m.kind === 'ok') admins.reload(); } };
  const permission = useQuery<{ can_edit: boolean } | null>(async () => profile?.role === 'platform_staff'
    ? must(await supabase.from('platform_permissions').select('can_edit')
      .or('section.eq.companies,section.eq.all').order('can_edit', { ascending: false }).limit(1).maybeSingle()) as { can_edit: boolean } | null
    : null, [profile?.role]);
  const canEdit = canCreate || permission.data?.can_edit === true;

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error, data } = await supabase.functions.invoke('create-company-admin', { body: { ...form, blocked_features: newBlocked } });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Empresa creada. Pasale al administrador su correo y la contraseña inicial.' });
    setForm(EMPTY); setNewBlocked([]); companies.reload();
  };

  const saveFeatures = async () => {
    if (!editing) return;
    setBusy(true);
    const { error } = await supabase.from('companies').update({ blocked_features: editing.blocked }).eq('id', editing.id);
    setBusy(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Funciones de la empresa actualizadas.' });
    setEditing(null); companies.reload();
  };

  const toggle = async (c: Company) => {
    const { error } = await supabase.from('companies').update({ active: !c.active }).eq('id', c.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else companies.reload();
  };

  const remove = async (c: Company) => {
    if (!window.confirm(`Eliminar la empresa ${c.name}? Desaparece de la lista y de la web; sus viajes, ventas y registros se conservan. Sus viajes futuros se cancelan.`)) return;
    const { error } = await supabase.rpc('remove_company', { p_company: c.id });
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: `Empresa ${c.name} eliminada.` }); setSelectedId(null); companies.reload(); }
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

  const needle = fold(search);
  const list = (companies.data ?? []).filter((c) => (status === 'all' || (status === 'active') === c.active)
    && (!needle || fold(c.name).includes(needle)));
  const selected = (companies.data ?? []).find((c) => c.id === selectedId) ?? null;

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <PageHead title="Empresas" />
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canCreate && (
        <form className="card" onSubmit={create}>
          <div className="card-head"><h2>Nueva empresa</h2></div>
          <div className="form-grid">
            <label>Nombre de la empresa<input value={form.company_name} onChange={set('company_name')} required /></label>
            <label>Administrador: nombre completo<input value={form.full_name} onChange={set('full_name')} required /></label>
            <label>Legajo<input value={form.legajo} onChange={set('legajo')} maxLength={20} /></label>
            <label>Usuario (opcional)<input value={form.username} onChange={set('username')} maxLength={30} autoCapitalize="none" spellCheck={false} /></label>
            <label>Correo<input type="email" value={form.email} onChange={set('email')} required /></label>
            <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
            <div className="span-12"><FeatureChecks blocked={newBlocked} onChange={setNewBlocked} /></div>
            <div className="form-actions"><button type="submit" disabled={busy}>Crear empresa</button></div>
          </div>
        </form>
      )}
      <div className="card list-card">
        <div className="list-head">
          <FilterBox value={search} onChange={setSearch} placeholder="Buscar empresa" />
          <label className="inline">Estado
            <select value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
              <option value="all">Todas</option><option value="active">Activas</option><option value="suspended">Suspendidas</option>
            </select>
          </label>
          <span className="list-head-spacer" />
        </div>
        {companies.loading ? <Loading /> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Empresa</th><th>Funciones</th><th>Alta</th><th>Estado</th><th /></tr></thead>
              <tbody>
                {list.length === 0 && <tr><td colSpan={5} className="muted">{(companies.data ?? []).length === 0 ? 'Todavía no hay empresas.' : 'Ninguna empresa coincide.'}</td></tr>}
                {list.map((c) => (
                  <tr key={c.id} className={selectedId === c.id ? 'row-selected' : ''}>
                    <td><b>{c.name}</b></td>
                    <td>{(c.blocked_features ?? []).length === 0 ? <span className="pill ok">Todas</span> : <span className="pill warn">{(c.blocked_features ?? []).length} bloqueada(s)</span>}</td>
                    <td>{new Date(c.created_at).toLocaleDateString('es-AR')}</td>
                    <td>{c.active ? <span className="pill ok">Activa</span> : <span className="pill warn">Suspendida</span>}</td>
                    <td className="td-actions"><button className="secondary compact" onClick={() => { setSelectedId(selectedId === c.id ? null : c.id); setEditing(null); }}>{selectedId === c.id ? 'Cerrar ficha' : 'Abrir ficha'}</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {selected && (
        <div className="card company-file">
          <div className="company-file-head">
            <div className="company-file-title">
              <h2>{selected.name}</h2>
              {selected.active ? <span className="pill ok">Activa</span> : <span className="pill warn">Suspendida</span>}
              <span className="muted">Alta: {new Date(selected.created_at).toLocaleDateString('es-AR')}</span>
            </div>
          </div>

          <div className="company-file-grid">
            <div className="company-file-col">
              <h3>Logo</h3>
              <div className="company-logo-row">
                {selected.logo_path
                  ? <img className="company-logo-preview"
                    src={supabase.storage.from('company-logos').getPublicUrl(selected.logo_path).data.publicUrl}
                    alt={`Logo de ${selected.name}`} />
                  : <div className="company-logo-empty">Sin logo</div>}
                {canEdit && <label className="file-pick">
                  <span className="secondary button-like compact">{selected.logo_path ? 'Cambiar imagen' : 'Subir imagen'}</span>
                  <input type="file" accept="image/jpeg,image/png,image/webp" hidden disabled={uploadingLogoFor === selected.id}
                    onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ''; void uploadLogo(selected, file); }} />
                </label>}
                {uploadingLogoFor === selected.id && <span className="muted">Subiendo...</span>}
              </div>
            </div>

            <div className="company-file-col">
              <div className="company-features-head">
                <h3>Funciones</h3>
                {canCreate && (
                  <button type="button" className="compact" disabled={busy || editing?.id !== selected.id} onClick={saveFeatures}>
                    Guardar funciones
                  </button>
                )}
              </div>
              {canCreate ? (
                <FeatureChecks blocked={editing?.id === selected.id ? editing.blocked : selected.blocked_features ?? []}
                  onChange={(next) => setEditing({ id: selected.id, blocked: next })} />
              ) : (
                <div className="pill-list">
                  {(selected.blocked_features ?? []).length === 0
                    ? <span className="pill ok">Todas habilitadas</span>
                    : (selected.blocked_features ?? []).map((k) => <span key={k} className="pill warn">Sin {featureLabel(k).toLowerCase()}</span>)}
                </div>
              )}
            </div>

            {canCreate && (
              <div className="company-file-col">
                <h3>Administradores</h3>
                <p className="muted">Código de empresa para ingresar con usuario: <b>{selected.slug}</b></p>
                {(admins.data ?? []).map((a) => (
                  <div key={a.id} className="row" style={{ alignItems: 'center' }}>
                    <span>{a.full_name}{a.username ? ` · ${a.username}` : ''}</span>
                    <button type="button" className="secondary compact" onClick={() => void actOn(changeUsername(a))}>Usuario</button>
                    <button type="button" className="secondary compact" onClick={() => void actOn(changePasswordFor(a))}>Clave</button>
                  </div>
                ))}
              </div>
            )}

            {canEdit && (
              <div className="company-file-col company-file-actions">
                <h3>Estado</h3>
                <div className="company-state-btns">
                  <button className="secondary compact" onClick={() => toggle(selected)}>{selected.active ? 'Suspender' : 'Activar'}</button>
                  <button className="danger compact" onClick={async () => { await remove(selected); }}>Eliminar empresa</button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </>
  );
}
