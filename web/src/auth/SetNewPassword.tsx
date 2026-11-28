import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { Notice } from '../ui';
import { useAuth } from './AuthProvider';

// Pantalla a la que se llega desde el enlace de "olvidé mi contraseña": se elige la contraseña nueva y se sigue.
export function SetNewPassword() {
  const { finishRecovery } = useAuth();
  const [pass, setPass] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (pass.length < 8) { setError('La contraseña debe tener al menos 8 caracteres.'); return; }
    setBusy(true);
    const { error: err } = await supabase.auth.updateUser({ password: pass });
    setBusy(false);
    if (err) setError(friendly(err)); else finishRecovery();
  };

  return (
    <main className="driver-app login-app">
      <form className="panel login-form" onSubmit={submit}>
        <div className="login-heading"><h1>Contraseña nueva</h1><p className="muted">Elegí la contraseña con la que vas a ingresar.</p></div>
        {error && <Notice>{error}</Notice>}
        <label>Contraseña nueva<input type="password" autoComplete="new-password" minLength={8} value={pass} onChange={(e) => setPass(e.target.value)} required /></label>
        <button className="primary login-submit" type="submit" disabled={busy}>{busy ? 'Guardando...' : 'Guardar y entrar'}</button>
      </form>
    </main>
  );
}
