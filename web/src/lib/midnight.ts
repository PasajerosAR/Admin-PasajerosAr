// Servicios que pasan las 00:00: sale 21:00 y vuelve 00:45 (del día siguiente).
// El inicio del servicio es el horario que sigue a la pausa más larga entre salidas (la noche en que no circula);
// las salidas de madrugada anteriores a ese inicio son del día siguiente. Es una sugerencia: el admin puede corregirla.
const mins = (hhmm: string) => { const [h, m] = hhmm.split(':').map(Number); return h * 60 + m; };

export function suggestNextDay(times: string[]): Record<string, boolean> {
  const valid = [...new Set(times.filter((t) => /^([01]\d|2[0-3]):[0-5]\d$/.test(t)))].sort();
  const out: Record<string, boolean> = Object.fromEntries(valid.map((t) => [t, false]));
  if (valid.length < 2) return out;
  const m = valid.map(mins);
  // pausa que sigue a cada horario (la última da la vuelta al día siguiente)
  const gaps = m.map((v, i) => (i === m.length - 1 ? m[0] + 1440 - v : m[i + 1] - v));
  const max = Math.max(...gaps);
  if (gaps.filter((g) => g === max).length > 1) return out;
  const startIdx = (gaps.indexOf(max) + 1) % m.length;
  if (startIdx === 0 || m[startIdx] < 18 * 60) return out;
  valid.forEach((t, i) => { if (i < startIdx && m[i] < 6 * 60) out[t] = true; });
  return out;
}
