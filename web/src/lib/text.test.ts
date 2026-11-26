import { describe, expect, it } from 'vitest';
import { fold } from './text';
import { matches } from '../ui';

describe('búsqueda sin acentos ni mayúsculas', () => {
  it('Parana, parana y PARANA encuentran Paraná', () => {
    for (const q of ['Parana', 'parana', 'PARANA', ' paraná ']) expect(matches(q, 'Paraná')).toBe(true);
  });
  it('también al revés y con otras vocales', () => {
    expect(matches('Concepcion', 'Concepción del Uruguay')).toBe(true);
    expect(matches('ñandú', 'NANDU')).toBe(true);
    expect(fold(null)).toBe('');
  });
  it('lo que no coincide sigue sin coincidir', () => {
    expect(matches('santa fe', 'Paraná')).toBe(false);
  });
});
