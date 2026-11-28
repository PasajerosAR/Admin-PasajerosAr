import { supabase } from './supabase';
import { must, useQuery } from './useQuery';
import { useAuth } from '../auth/AuthProvider';

// Franjas horarias de precio de la empresa. Las tarifas y los abonos guardan el código de la franja.
export interface FareBand { id: string; code: string; name: string; color: string; is_default: boolean; sort: number }

export function useFareBands() {
  const { profile } = useAuth();
  const q = useQuery(async () => profile?.company_id
    ? must(await supabase.from('fare_bands').select('id,code,name,color,is_default,sort').eq('company_id', profile.company_id).order('sort').order('name')) as FareBand[]
    : [], [profile?.company_id]);
  return { bands: q.data ?? [], loading: q.loading, error: q.error, reload: q.reload };
}

export const bandName = (bands: FareBand[], code: string | null | undefined): string => bands.find((b) => b.code === code)?.name ?? code ?? '';

// " · días Nocturno, Sábado" cuando el abono no vale en todas las franjas (vacío si vale en todas)
export function bandsTag(codes: string[] | null | undefined, bands: FareBand[]): string {
  if (!codes || bands.length === 0 || bands.every((b) => codes.includes(b.code))) return '';
  return ` · días ${bands.filter((b) => codes.includes(b.code)).map((b) => b.name).join(', ')}`;
}

// semana base: 7 días (lunes a domingo) × 24 horas de códigos de franja
export const WEEK_DAYS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
export function gridFromRows(rows: { dow: number; hour: number; code: string }[], fallback: string): string[][] {
  const g = Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => fallback));
  for (const r of rows) if (r.dow >= 1 && r.dow <= 7 && r.hour >= 0 && r.hour <= 23) g[r.dow - 1][r.hour] = r.code;
  return g;
}
