import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice, todayLocal } from '../ui';
import { useAuth } from '../auth/AuthProvider';

interface Holiday { holiday_date: string; name: string }

const longDate = (value: string) => new Date(`${value}T12:00:00`).toLocaleDateString('es-AR', { weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric' });

// Calendario de feriados de la empresa: al generar viajes, esa fecha toma el tipo "Feriado".
export function HolidaysPage() {
  const { profile } = useAuth();
  const [date, setDate] = useState('');
  const [name, setName] = useState('');
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [showPast, setShowPast] = useState(false);
  const holidays = useQuery(async () => must(await supabase.from('company_holidays').select('holiday_date,name').order('holiday_date')) as Holiday[], []);

  const add = async (e: FormEvent) => {
    e.preventDefault();
    if (!profile?.company_id) return;
    const { error } = await supabase.from('company_holidays').insert({ company_id: profile.company_id, holiday_date: date, name: name.trim() });
    if (error) {
      setMsg({ kind: 'error', text: error.code === '23505' ? 'Esa fecha ya está cargada como feriado.' : friendly(error) });
      return;
    }
    setMsg({ kind: 'ok', text: 'Feriado agregado. Los viajes ya generados de esa fecha no cambian: regeneralos si hace falta.' });
    setDate(''); setName(''); holidays.reload();
  };
  const remove = async (h: Holiday) => {
    if (!window.confirm(`¿Quitar el feriado "${h.name}" del ${longDate(h.holiday_date)}?`)) return;
    const { error } = await supabase.from('company_holidays').delete().eq('holiday_date', h.holiday_date);
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: 'Feriado quitado.' }); holidays.reload(); }
  };

  const today = todayLocal();
  const shown = (holidays.data ?? []).filter((h) => showPast || h.holiday_date >= today);
  return (
    <>
      <h1>Feriados</h1>
      <p className="muted">Cargá los feriados y días no laborables de tu empresa. Al generar viajes, esas fechas toman el tipo de día "Feriado" y se publican los horarios de feriado.</p>
      <form className="card row" onSubmit={add}>
        <label style={{ flex: '0 0 200px' }}>Fecha<input type="date" value={date} onChange={(e) => setDate(e.target.value)} required /></label>
        <label>Nombre<input value={name} onChange={(e) => setName(e.target.value)} placeholder="Ej.: Día de la Soberanía Nacional" maxLength={80} required /></label>
        <button type="submit">Agregar feriado</button>
      </form>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {holidays.error && <Notice>{holidays.error}</Notice>}
      {holidays.loading && <Loading />}
      <div className="card table-wrap">
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 8 }}>
          <input type="checkbox" checked={showPast} onChange={(e) => setShowPast(e.target.checked)} style={{ width: 'auto' }} /> Mostrar también los pasados
        </label>
        <table>
          <thead><tr><th>Fecha</th><th>Nombre</th><th /></tr></thead>
          <tbody>
            {shown.map((h) => (
              <tr key={h.holiday_date}>
                <td>{longDate(h.holiday_date)}</td>
                <td>{h.name}</td>
                <td><button className="secondary" onClick={() => void remove(h)}>Quitar</button></td>
              </tr>
            ))}
            {!holidays.loading && shown.length === 0 && <tr><td colSpan={3} className="muted">No hay feriados próximos cargados.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
