import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useAuth } from '../auth/AuthProvider';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';

const ROLE: Record<string, string> = {
  platform_admin: 'Administrador general', platform_staff: 'Equipo de plataforma', company_admin: 'Administrador de empresa',
  seller: 'Vendedor', support: 'Atención al cliente', driver: 'Conductor'
};

// Perfil arriba a la derecha: Mis datos, cambiar contraseña y cerrar sesión.
export function ProfileMenu() {
  const { profile, signOut } = useAuth();
  const [open, setOpen] = useState(false);
  const [changing, setChanging] = useState(false);
  const [pass, setPass] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  if (!profile) return null;
  const initials = profile.full_name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('');

  const changePassword = async (e: FormEvent) => {
    e.preventDefault();
    const { error } = await supabase.auth.updateUser({ password: pass });
    if (error) setMsg({ ok: false, text: friendly(error) });
    else { setMsg({ ok: true, text: 'Contraseña actualizada.' }); setPass(''); setChanging(false); }
  };

  return (
    <div className="profile-menu" ref={box}>
      <button type="button" className="profile-avatar" aria-label="Mi perfil" aria-expanded={open} onClick={() => setOpen((v) => !v)}>{initials || '?'}</button>
      {open && (
        <div className="profile-panel" role="dialog" aria-label="Mis datos">
          <div className="profile-head">
            <span className="profile-head-avatar" aria-hidden="true">{initials || '?'}</span>
            <div>
              <h3>{profile.full_name}</h3>
              <p className="muted">{ROLE[profile.role] ?? profile.role}</p>
            </div>
          </div>
          <dl>
            <dt>Legajo</dt><dd>{profile.legajo ?? 'Sin asignar'}</dd>
            {profile.dni && <><dt>DNI</dt><dd>{profile.dni}</dd></>}
            {profile.phone && <><dt>Teléfono</dt><dd>{profile.phone}</dd></>}
          </dl>
          {msg && <p className={msg.ok ? 'muted' : 'error-text'}>{msg.text}</p>}
          {changing ? (
            <form className="stack" onSubmit={changePassword}>
              <label>Nueva contraseña<input type="password" minLength={8} value={pass} onChange={(e) => setPass(e.target.value)} required /></label>
              <div className="row"><button type="submit">Guardar</button><button type="button" className="secondary" onClick={() => setChanging(false)}>Cancelar</button></div>
            </form>
          ) : <button type="button" className="secondary" onClick={() => { setChanging(true); setMsg(null); }}>Cambiar contraseña</button>}
          <button type="button" className="danger" onClick={() => void signOut()}>Cerrar sesión</button>
        </div>
      )}
    </div>
  );
}
