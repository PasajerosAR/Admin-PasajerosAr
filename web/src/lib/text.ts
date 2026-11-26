/** Texto para comparar al buscar: sin acentos, sin mayúsculas y sin espacios en los extremos ("PARANA" = "Paraná"). */
export const fold = (value: unknown): string =>
  String(value ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLocaleLowerCase('es-AR').trim();
