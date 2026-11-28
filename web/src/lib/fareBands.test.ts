import { describe, expect, it } from 'vitest';
import { bandsTag, gridFromRows, type FareBand } from './fareBands';

const b = (code: string, name: string): FareBand => ({ id: code, code, name, color: '#000000', is_default: false, sort: 1 });
const bands = [b('weekday', 'Día hábil'), b('nocturno', 'Nocturno')];

describe('franjas', () => {
  it('no marca nada si el abono vale en todas las franjas', () => {
    expect(bandsTag(['nocturno', 'weekday'], bands)).toBe('');
    expect(bandsTag(null, bands)).toBe('');
  });
  it('nombra las franjas cuando vale solo en algunas', () => {
    expect(bandsTag(['nocturno'], bands)).toBe(' · días Nocturno');
  });
  it('arma la grilla semanal con un relleno por defecto', () => {
    const g = gridFromRows([{ dow: 2, hour: 5, code: 'nocturno' }], 'weekday');
    expect(g.length).toBe(7);
    expect(g[1][5]).toBe('nocturno');
    expect(g[0][0]).toBe('weekday');
  });
});
