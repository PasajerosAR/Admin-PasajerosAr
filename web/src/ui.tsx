import type { ReactNode } from 'react';
import { fold } from './lib/text';

export function Notice({ kind = 'error', children }: { kind?: 'error' | 'warn' | 'ok'; children: ReactNode }) {
  return <div className={`notice ${kind}`} role={kind === 'error' ? 'alert' : 'status'}>{children}</div>;
}

// Pantalla de carga completa (al abrir la app o iniciar sesión). Usa el tema elegido por el conductor.
export function SplashLoading() {
  let theme = 'dark';
  try { theme = window.localStorage.getItem('transporte.driverTheme') === 'light' ? 'light' : 'dark'; } catch { /* sin almacenamiento: tema oscuro */ }
  return (
    <div className="splash" data-theme={theme} role="status" aria-live="polite">
      <span className="splash-spinner" aria-hidden="true" />
      <span>Cargando</span>
    </div>
  );
}

export function Loading() {
  return <p className="muted">Cargando...</p>;
}

// siempre 24 hs (00:00 a 23:59); hourCycle evita el "24:05" que da hour12:false en algunos navegadores
export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: 'America/Argentina/Buenos_Aires' });
}

export const formatDateTime = (iso: string): string =>
  new Date(iso).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: 'America/Argentina/Buenos_Aires' });

/** Hora HH:MM en 24 hs. Reemplaza a <input type="time">, que muestra AM/PM según el celular. */
export function TimeInput({ value, onChange, required, ariaLabel }: { value: string; onChange: (v: string) => void; required?: boolean; ariaLabel?: string }) {
  const clean = (raw: string) => {
    const digits = raw.replace(/\D/g, '').slice(0, 4);
    return digits.length > 2 ? `${digits.slice(0, 2)}:${digits.slice(2)}` : digits;
  };
  const valid = (v: string) => /^([01]\d|2[0-3]):[0-5]\d$/.test(v);
  return (
    <input type="text" className="time-input" inputMode="numeric" placeholder="HH:MM" maxLength={5} pattern="([01][0-9]|2[0-3]):[0-5][0-9]" title="Hora en formato 24 hs, por ejemplo 21:30"
      aria-label={ariaLabel} required={required} value={value} onChange={(e) => onChange(clean(e.target.value))}
      onBlur={() => { if (value && !valid(value)) onChange(''); }} />
  );
}

export function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** Caja de búsqueda para listados: filtra por cualquier texto de la fila. */
export function FilterBox({ value, onChange, placeholder = 'Buscar...' }: { value: string; onChange: (v: string) => void; placeholder?: string }) {
  return <input className="filter-box" type="search" placeholder={placeholder} aria-label={placeholder} value={value} onChange={(e) => onChange(e.target.value)} />;
}

/** Encabezado de página: título (+ subtítulo) a la izquierda, acciones a la derecha. */
export function PageHead({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <header className="page-head">
      <div className="page-head-text">
        <h1>{title}</h1>
        {subtitle && <p className="page-sub">{subtitle}</p>}
      </div>
      {actions && <div className="page-actions">{actions}</div>}
    </header>
  );
}
export const matches = (needle: string, ...fields: (string | number | null | undefined)[]): boolean => {
  const n = fold(needle);
  return !n || fields.some((f) => fold(f).includes(n));
};
