import { describe, expect, it } from 'vitest';
import { dayTypeOf, dayTypesText } from './dayType';


describe('tipo de día', () => {
  it('lunes a viernes = hábil, sábado, domingo', () => {
    expect(dayTypeOf(new Date(2026, 10, 16))).toBe('weekday'); // lunes
    expect(dayTypeOf(new Date(2026, 10, 20))).toBe('weekday'); // viernes
    expect(dayTypeOf(new Date(2026, 10, 14))).toBe('saturday');
    expect(dayTypeOf(new Date(2026, 10, 15))).toBe('sunday');
  });
  it('texto en orden fijo', () => {
    expect(dayTypesText(['holiday', 'weekday'])).toBe('Día hábil, Feriado');
  });
});
