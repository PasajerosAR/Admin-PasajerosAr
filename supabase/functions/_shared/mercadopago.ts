import { createClient, type SupabaseClient, type User } from 'https://esm.sh/@supabase/supabase-js@2';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

export const redirect = (url: string) => new Response(null, { status: 303, headers: { Location: url } });

export function adminClient(): SupabaseClient {
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) throw new Error('SUPABASE_CONFIGURATION_MISSING');
  return createClient(url, serviceKey);
}

export async function authenticatedUser(req: Request): Promise<User> {
  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const authorization = req.headers.get('Authorization');
  if (!url || !anonKey || !authorization) throw new Error('UNAUTHENTICATED');
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data, error } = await caller.auth.getUser();
  if (error || !data.user) throw new Error('UNAUTHENTICATED');
  return data.user;
}

export async function companyAdmin(req: Request) {
  const user = await authenticatedUser(req);
  const admin = adminClient();
  const { data: profile, error } = await admin.from('profiles')
    .select('id,company_id,role,active')
    .eq('id', user.id)
    .maybeSingle();
  if (error) throw new Error('PROFILE_LOOKUP_FAILED');
  if (!profile || profile.role !== 'company_admin' || !profile.active || !profile.company_id) {
    throw new Error('FORBIDDEN');
  }
  return { admin, user, profile };
}

export function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
}

export function testMode(): boolean {
  if (Deno.env.get('MP_TEST_MODE') !== 'true') throw new Error('MERCADOPAGO_TEST_MODE_REQUIRED');
  return true;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

async function encryptionKey(): Promise<CryptoKey> {
  const secret = requiredEnv('MP_TOKEN_ENCRYPTION_KEY');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret));
  return crypto.subtle.importKey('raw', digest, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

export async function encryptToken(value: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    await encryptionKey(),
    new TextEncoder().encode(value)
  );
  return `${bytesToBase64(iv)}.${bytesToBase64(new Uint8Array(ciphertext))}`;
}

export async function decryptToken(value: string): Promise<string> {
  const [encodedIv, encodedCiphertext] = value.split('.');
  if (!encodedIv || !encodedCiphertext) throw new Error('MERCADOPAGO_TOKEN_CORRUPT');
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: base64ToBytes(encodedIv) },
      await encryptionKey(),
      base64ToBytes(encodedCiphertext)
    );
    return new TextDecoder().decode(plaintext);
  } catch {
    throw new Error('MERCADOPAGO_TOKEN_DECRYPT_FAILED');
  }
}

export interface MpConnection {
  company_id: string;
  mp_user_id: string;
  test_mode: boolean;
  active: boolean;
  access_token_encrypted: string;
  refresh_token_encrypted: string;
  token_expires_at: string;
}

export async function accessToken(admin: SupabaseClient, connection: MpConnection): Promise<string> {
  if (!connection.active || !connection.test_mode) throw new Error('MERCADOPAGO_CONNECTION_INACTIVE');
  const expiresAt = new Date(connection.token_expires_at).getTime();
  if (expiresAt > Date.now() + 5 * 60 * 1000) {
    return await decryptToken(connection.access_token_encrypted);
  }

  const clientId = requiredEnv('MP_CLIENT_ID');
  const clientSecret = requiredEnv('MP_CLIENT_SECRET');
  const refreshToken = await decryptToken(connection.refresh_token_encrypted);
  const response = await fetch('https://api.mercadopago.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: 'refresh_token',
      refresh_token: refreshToken
    })
  });
  if (!response.ok) throw new Error('MERCADOPAGO_REAUTHORIZE_REQUIRED');
  const tokens = await response.json() as {
    access_token?: string; refresh_token?: string; expires_in?: number; user_id?: number | string
  };
  if (!tokens.access_token || !tokens.refresh_token || !tokens.expires_in) {
    throw new Error('MERCADOPAGO_TOKEN_RESPONSE_INVALID');
  }

  const { error } = await admin.from('mp_company_connections').update({
    access_token_encrypted: await encryptToken(tokens.access_token),
    refresh_token_encrypted: await encryptToken(tokens.refresh_token),
    token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
    ...(tokens.user_id ? { mp_user_id: String(tokens.user_id) } : {})
  }).eq('company_id', connection.company_id);
  if (error) throw new Error('MERCADOPAGO_TOKEN_SAVE_FAILED');
  return tokens.access_token;
}

export async function mpRequest<T>(
  path: string,
  token: string,
  init: RequestInit = {}
): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set('Authorization', `Bearer ${token}`);
  headers.set('Content-Type', 'application/json');
  const response = await fetch(`https://api.mercadopago.com${path}`, {
    ...init,
    headers
  });
  if (!response.ok) throw new Error(`MERCADOPAGO_API_HTTP_${response.status}`);
  return await response.json() as T;
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}
