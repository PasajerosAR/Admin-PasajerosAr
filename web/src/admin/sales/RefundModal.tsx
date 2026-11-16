import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { Notice } from '../../ui';

interface Props {
  ticketId: string;
  onClose: () => void;
  onSuccess: () => void;
}

export function RefundModal({ ticketId, onClose, onSuccess }: Props) {
  const [reason, setReason] = useState('');
  const [busy, setBusy]     = useState(false);
  const [err, setErr]       = useState<string | null>(null);

  const confirm = async () => {
    if (!reason.trim() || reason.trim().length < 5) {
      setErr('El motivo debe tener al menos 5 caracteres.');
      return;
    }
    setBusy(true);
    setErr(null);
    const { data, error } = await supabase.functions.invoke('cancel-ticket', {
      body: { ticket_id: ticketId, cancel_reason: reason.trim() }
    });
    setBusy(false);
    const serverErr = (data as { error?: string } | null)?.error;
    if (error || serverErr) { setErr(serverErr ?? friendly(error)); return; }
    onSuccess();
  };

  return (
    <div style={{
      position: 'fixed', inset: 0, background: '#0008',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      zIndex: 1000, padding: 16
    }}>
      <div className="card stack" style={{ maxWidth: 480, width: '100%' }}>
        <h2>Cancelar pasaje</h2>
        <p className="muted">
          Esta acción cancela el pasaje y queda registrada con tu usuario.
          El reembolso al pasajero es manual y debe gestionarse por separado.
        </p>
        {err && <Notice kind="error">{err}</Notice>}
        <label>
          Motivo de cancelación (obligatorio)
          <textarea
            rows={3}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="ej: El pasajero solicitó la devolución por cambio de planes"
            style={{
              width: '100%', border: '1px solid #c9d1db', borderRadius: 10,
              padding: '8px 10px', font: 'inherit', resize: 'vertical', minHeight: 80
            }}
          />
        </label>
        <div className="row">
          <button onClick={confirm} className="danger" disabled={busy}>
            {busy ? 'Cancelando...' : 'Confirmar cancelación'}
          </button>
          <button className="secondary" onClick={onClose} disabled={busy}>Volver</button>
        </div>
      </div>
    </div>
  );
}
