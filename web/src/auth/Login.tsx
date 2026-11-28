import { useState, type FormEvent } from 'react';
import { useAuth } from './AuthProvider';
import { Notice } from '../ui';
import { supabase } from '../lib/supabase';
import { DriverThemeToggle } from './DriverTheme';

const COMPANY_KEY = 'pasajerosar-company-code';

export function Login() {
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [company, setCompany] = useState(() => { try { return localStorage.getItem(COMPANY_KEY) ?? ''; } catch { return ''; } });
  const needsCompany = email.trim() !== '' && !email.includes('@');   // con usuario hace falta el código de la empresa
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [info, setInfo] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const err = await signIn(email.trim(), password, company.trim());
    if (!err && needsCompany) { try { localStorage.setItem(COMPANY_KEY, company.trim()); } catch { /* sin almacenamiento */ } }
    setError(err);
    setBusy(false);
  };

  // La recuperación es por correo: si ingresó un usuario, no se sabe el correo, así que pide escribirlo.
  const forgot = async () => {
    setError(null); setInfo(null);
    const mail = email.trim();
    if (!mail.includes('@')) { setError('Escribí tu correo en el primer campo y volvé a tocar “Olvidé mi contraseña”.'); return; }
    await supabase.auth.resetPasswordForEmail(mail, { redirectTo: window.location.origin + window.location.pathname });
    setInfo('Si el correo está registrado, te enviamos un enlace para elegir una contraseña nueva.');
  };

  return (
    <main className="driver-app login-app">
      <header className="driver-company" aria-label="Pasajeros.ar, admin">
        <div className="driver-company-mark" aria-hidden="true">
          <svg width="26" height="26" viewBox="0 0 30 30" fill="none">
            <path d="M4.5 10.5h21v11h-21z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/>
            <path d="m8 10.5 3-4h8l3 4M8 16h14" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/>
            <circle cx="9" cy="22" r="2" fill="currentColor"/>
            <circle cx="21" cy="22" r="2" fill="currentColor"/>
          </svg>
        </div>
        <div className="driver-company-info">
          <strong className="driver-brand-title">PASAJEROS<span>.AR</span></strong>
          <span className="driver-company-label">#Admin</span>
        </div>
        <DriverThemeToggle />
      </header>
      <form className="panel login-form" onSubmit={submit}>
        <div className="login-heading">
          <h1>Ingresar</h1>
          <p className="muted">Accedé al panel de administración</p>
        </div>
        {error && <Notice>{error}</Notice>}
        {info && <Notice kind="ok">{info}</Notice>}
        <label>Usuario o correo<input autoComplete="username" autoCapitalize="none" spellCheck={false} maxLength={120} value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        {needsCompany && <label>Código de empresa<input autoCapitalize="none" spellCheck={false} maxLength={80} value={company} onChange={(e) => setCompany(e.target.value)} required /></label>}
        <label>Contraseña<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        <button className="primary login-submit" type="submit" disabled={busy}>{busy ? 'Ingresando...' : 'Ingresar'}</button>
        <button type="button" className="driver-text-button" onClick={() => void forgot()}>Olvidé mi contraseña</button>
      </form>
    </main>
  );
}
