import { describe, expect, it } from 'vitest';
import { suggestNextDay } from './midnight';

describe('suggestNextDay', () => {
  it('marca la vuelta de las 00:45 de un servicio que sale 21:00', () => {
    expect(suggestNextDay(['21:00', '00:45'])).toEqual({ '21:00': false, '00:45': true });
    expect(suggestNextDay(['00:45', '23:15', '21:00', '02:00'])).toEqual({ '21:00': false, '23:15': false, '00:45': true, '02:00': true });
  });
  it('no toca los servicios diurnos ni los de grilla pareja', () => {
    expect(suggestNextDay(['06:00', '12:00', '18:00'])).toEqual({ '06:00': false, '12:00': false, '18:00': false });
    expect(suggestNextDay(['08:00'])).toEqual({ '08:00': false });
    expect(suggestNextDay(['06:00', '18:00'])).toEqual({ '06:00': false, '18:00': false });
  });
  it('un servicio que empieza de madrugada no se corre', () => {
    expect(suggestNextDay(['00:30', '01:30', '03:00'])).toEqual({ '00:30': false, '01:30': false, '03:00': false });
  });
});
