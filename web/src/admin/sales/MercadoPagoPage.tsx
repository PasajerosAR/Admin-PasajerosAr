import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { friendly } from '../../lib/errors';
import { Loading, Notice, PageHead, formatDateTime } from '../../ui';

interface ConnectionStatus {
  connected: boolean;
  mp_user_id: string | null;
  connected_at: string | null;
  test_mode: boolean;
}

const CALLBACK_MESSAGES: Record<string, string> = {
  authorization: 'Se canceló la autorización. Podés volver a intentarlo.',
  state: 'La autorización venció o ya fue utilizada. Iniciá la conexión nuevamente.',
  token: 'Mercado Pago no pudo autorizar la cuenta de prueba. Verificá que uses un usuario vendedor de prueba.',
  save: 'La cuenta se autorizó, pero no se pudo guardar la conexión. Intentá nuevamente.',
  configuration: 'No se pudo completar la conexión. Revisá la configuración de Mercado Pago en Supabase.'
};

export function MercadoPagoPage() {
  const [connection, setConnection] = useState<ConnectionStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ kind: 'error' | 'ok' | 'warn'; text: string } | null>(null);

  const refresh = async () => {
    setLoading(true);
    const { data, error } = await supabase.functions.invoke('mp-company-connection-status', { body: {} });
    setLoading(false);
    if (error) {
      setNotice({ kind: 'error', text: friendly(error) });
      return;
    }
    setConnection(data as ConnectionStatus);
  };

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    if (query.get('connected') === '1') {
      setNotice({ kind: 'ok', text: 'La cuenta de prueba de Mercado Pago quedó conectada.' });
    } else if (query.has('connection_error')) {
      const code = query.get('connection_error') ?? '';
      setNotice({ kind: 'error', text: CALLBACK_MESSAGES[code] ?? 'No se pudo conectar la cuenta de Mercado Pago.' });
    }
    if (query.has('connected') || query.has('connection_error')) {
      window.history.replaceState(null, '', window.location.pathname);
    }
    void refresh();
  }, []);

  const connect = async () => {
    setBusy(true);
    setNotice(null);
    const { data, error } = await supabase.functions.invoke('mp-oauth-start', { body: {} });
    setBusy(false);
    if (error) {
      setNotice({ kind: 'error', text: friendly(error) });
      return;
    }
    if (typeof data?.authorization_url !== 'string') {
      setNotice({ kind: 'error', text: 'No se recibió el enlace de autorización.' });
      return;
    }
    window.location.assign(data.authorization_url);
  };

  const disconnect = async () => {
    if (!window.confirm('¿Desconectar la cuenta de prueba de Mercado Pago?')) return;
    setBusy(true);
    setNotice(null);
    const { error } = await supabase.functions.invoke('mp-disconnect-company', { body: {} });
    setBusy(false);
    if (error) {
      setNotice({ kind: 'error', text: friendly(error) });
      return;
    }
    setNotice({ kind: 'ok', text: 'La cuenta de prueba quedó desconectada.' });
    await refresh();
  };

  return (
    <>
      <PageHead title="Mercado Pago" />
      <p className="muted">Conectá la cuenta vendedora de prueba de esta empresa. El checkout no aceptará pagos reales.</p>
      {notice && <Notice kind={notice.kind}>{notice.text}</Notice>}

      <div className="card stack">
        <h2>Estado de la conexión</h2>
        {loading ? <Loading /> : connection?.connected
          ? <>
            <Notice kind="ok">Conectada en modo de prueba · Usuario vendedor {connection.mp_user_id}</Notice>
            <p className="muted">Conectada el {formatDateTime(connection.connected_at ?? '')}.</p>
            <button type="button" className="danger" onClick={disconnect} disabled={busy}>
              {busy ? 'Procesando...' : 'Desconectar cuenta de prueba'}
            </button>
          </>
          : <>
            <Notice kind="warn">Todavía no hay una cuenta de prueba conectada.</Notice>
            <button type="button" onClick={connect} disabled={busy}>
              {busy ? 'Abriendo Mercado Pago...' : 'Conectar cuenta de prueba'}
            </button>
          </>}
      </div>

      <div className="card stack">
        <h2>Antes de conectar</h2>
        <ol>
          <li>Creá una aplicación en Mercado Pago Developers.</li>
          <li>Creá o elegí una cuenta vendedora de prueba de Argentina para esta empresa.</li>
          <li>Conectá esa cuenta acá y usá la cuenta compradora de prueba para simular una compra.</li>
        </ol>
        <p className="muted">Las credenciales privadas y la clave de firma se configuran como secretos de Supabase; nunca las ingreses en esta pantalla ni en el sitio público.</p>
      </div>
    </>
  );
}
