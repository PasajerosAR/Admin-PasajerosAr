import { supabase } from './supabase';
import { friendly } from './errors';

export type UserMsg = { kind: 'error' | 'ok'; text: string };
interface Who { id: string; full_name: string; username?: string | null }

// Pide el usuario de ingreso y lo guarda (vacío = sin usuario). Devuelve el aviso a mostrar, o null si se canceló.
export async function changeUsername(u: Who): Promise<UserMsg | null> {
  const value = window.prompt(`Usuario de ${u.full_name} (letras, números, punto, guion o guion bajo; sin espacios; vacío para quitarlo):`, u.username ?? '');
  if (value === null) return null;
  const { error } = await supabase.rpc('set_username', { p_profile: u.id, p_username: value });
  return error ? { kind: 'error', text: friendly(error) } : { kind: 'ok', text: 'Usuario actualizado.' };
}

// Pide una contraseña nueva y se la pone al usuario (la elige quien administra; después se la pasa a la persona).
export async function changePasswordFor(u: Who): Promise<UserMsg | null> {
  const value = window.prompt(`Contraseña nueva para ${u.full_name} (mínimo 8 caracteres):`);
  if (value === null) return null;
  if (value.length < 8) return { kind: 'error', text: 'La contraseña debe tener al menos 8 caracteres.' };
  const { data, error } = await supabase.functions.invoke('set-user-password', { body: { user_id: u.id, password: value } });
  const serverError = (data as { error?: string } | null)?.error;
  return error || serverError ? { kind: 'error', text: serverError ?? friendly(error) } : { kind: 'ok', text: 'Contraseña cambiada. Pasásela a la persona.' };
}
