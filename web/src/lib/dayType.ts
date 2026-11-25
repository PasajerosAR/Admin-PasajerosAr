// Tipos de día de un servicio. No hay calendario de feriados: lo elige quien inicia el servicio o genera los viajes.
export type DayType = 'weekday' | 'saturday' | 'sunday' | 'holiday';

export const DAY_TYPES: DayType[] = ['weekday', 'saturday', 'sunday', 'holiday'];
export const DAY_TYPE_LABEL: Record<DayType, string> = { weekday: 'Día hábil', saturday: 'Sábado', sunday: 'Domingo', holiday: 'Feriado' };
export const DAY_TYPE_LETTER: Record<DayType, string> = { weekday: 'H', saturday: 'S', sunday: 'D', holiday: 'F' };

// Igual que public.day_type_of() en la base: lunes a viernes = hábil. El feriado se elige a mano.
export function dayTypeOf(d: Date): DayType {
  const wd = d.getDay(); // 0 domingo ... 6 sábado
  return wd === 0 ? 'sunday' : wd === 6 ? 'saturday' : 'weekday';
}

// " · H S D" cuando no vale los cuatro tipos de día (vacío si vale todos), para listas y menús
export function daysTag(types: DayType[] | null | undefined): string {
  if (!types || DAY_TYPES.every((t) => types.includes(t))) return '';
  return ` · días ${DAY_TYPES.filter((t) => types.includes(t)).map((t) => DAY_TYPE_LETTER[t]).join(' ')}`;
}

export function dayTypesText(types: DayType[]): string {
  return DAY_TYPES.filter((t) => types.includes(t)).map((t) => DAY_TYPE_LABEL[t]).join(', ');
}
