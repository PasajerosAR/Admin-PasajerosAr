import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  try {
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const authorization = req.headers.get('Authorization');
    if (!url || !anonKey || !authorization) return json({ error: 'No autenticado.' }, 401);

    const client = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data: who, error: authError } = await client.auth.getUser();
    if (authError || !who.user) return json({ error: 'No autenticado.' }, 401);

    const body = await req.json();
    const ticketId = String(body.ticket_id ?? '');
    const reason = String(body.cancel_reason ?? '').trim();
    if (!ticketId) return json({ error: 'Falta el ID del pasaje.' }, 400);
    if (reason.length < 5) return json({ error: 'El motivo debe tener al menos 5 caracteres.' }, 400);

    const { data, error } = await client.rpc('cancel_sale_ticket', {
      p_ticket: ticketId,
      p_reason: reason
    });
    if (error) {
      const forbidden = /FORBIDDEN/i.test(error.message);
      return json({ error: error.message }, forbidden ? 403 : 400);
    }

    return json(data);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
