\set ON_ERROR_STOP on
-- Franjas horarias: franjas iniciales, semana base, excepciones, tipo de día elegido a mano, precio del viaje por franja, abonos.
-- Se corre justo después de la 46 (mientras existe el servicio 218) y se deshace al final.
begin;
update public.companies set blocked_features = '{}' where id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- cada empresa tiene sus cuatro franjas y la semana base completa
select t.expect_eq((select count(*)::int from public.fare_bands where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 4, 'cuatro franjas iniciales');
select t.expect_eq((select count(*)::int from public.fare_band_weekly where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 168, 'semana base completa');

-- el administrador crea "Nocturno" y pinta de lunes a jueves 21:00 a 04:59
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_fare_band(null, 'Nocturno', '#1d4ed8');
select t.expect_fail($q$select public.save_fare_band(null, ' nocturno ', null)$q$, 'BAND_DUPLICATE');
select t.expect_eq((select code from public.fare_bands where name = 'Nocturno'), 'nocturno', 'el código sale del nombre');
select public.save_fare_week((
  select jsonb_agg(day) from (
    select d, (select jsonb_agg(case when d <= 4 and (h >= 21 or h <= 4) then 'nocturno'
                                      when d = 6 then 'saturday' when d = 7 then 'sunday' else 'weekday' end order by h)
                 from generate_series(0, 23) h) as day
      from generate_series(1, 7) d order by d) x));
select t.expect_fail($q$select public.save_fare_week('[[1]]'::jsonb)$q$, 'GRID_INVALID');
select t.logout();

-- qué franja le toca a una salida (2027-06-07 es lunes)
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-08 22:00-03'), 'nocturno', 'martes 22:00 nocturno');
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-09 02:00-03'), 'nocturno', 'miércoles 02:00 nocturno');
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-08 10:00-03'), 'weekday', 'martes 10:00 hábil');
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-11 22:00-03'), 'weekday', 'viernes 22:00 hábil (no se pintó)');
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-12 10:00-03'), 'saturday', 'sábado');
-- un lunes que se trabaja como feriado usa la franja del tipo elegido
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-14 10:00-03', date '2027-06-14', 'holiday'), 'holiday', 'tipo elegido a mano');
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-14 10:00-03', date '2027-06-14', 'weekday'), 'weekday', 'tipo normal: manda la semana');

-- excepción por fecha
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_fare_exception(date '2027-06-09', 0, 24, (select id from public.fare_bands where code = 'sunday' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select t.expect_fail($q$select public.save_fare_exception(date '2027-06-09', 10, 12, (select id from public.fare_bands where code = 'sunday' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001'))$q$, 'EXCEPTION_OVERLAP');
select t.expect_fail($q$select public.save_fare_exception(date '2027-06-10', 12, 10, (select id from public.fare_bands where code = 'sunday' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001'))$q$, 'EXCEPTION_INVALID');
select t.logout();
select t.expect_eq(public.fare_band_for('aaaaaaaa-0000-0000-0000-000000000001', timestamptz '2027-06-09 02:00-03'), 'sunday', 'la excepción pisa la semana base');

-- tarifas por franja: una franja inexistente se rechaza
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 3, 2500, null, d) from unnest(array['weekday', 'saturday', 'sunday', 'holiday']) d;
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 3, 3100, null, 'nocturno');
select t.expect_fail($q$select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 3, 100, null, 'zzz')$q$, 'PRICE_INVALID');
select public.generate_trips(date '2027-06-19', 'saturday');
select t.logout();

-- el viaje que sale de noche guarda la franja nocturna y la taquilla cobra su precio
update public.trips
   set scheduled_departure = timestamptz '2027-06-22 22:00-03',
       vehicle_id = '22222222-0000-0000-0000-000000000001',
       layout_id = '11111111-0000-0000-0000-000000000001',
       driver_id = 'a2000000-0000-0000-0000-000000000001'
 where service_date = date '2027-06-19'
   and departure_id = (select id from public.service_departures
    where service_id = (select id from public.services where code = '218') and departure_time = time '05:00');
create temp table fbt as
select t.id, t.fare_band from public.trips t where t.service_date = date '2027-06-19' and t.driver_id = 'a2000000-0000-0000-0000-000000000001';
grant all on fbt to authenticated;
select t.expect_eq((select fare_band from fbt), 'nocturno', 'el viaje de las 22:00 es nocturno');
select t.login('a2000000-0000-0000-0000-000000000001');
create temp table fbs as
select public.taquilla_sell((select id from fbt), 'cash',
  '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Rita Sosa","passenger_dni":"30222001"}]'::jsonb) as r;
grant all on fbs to authenticated;
select t.expect_eq((select r->>'total' from fbs), '3100.00', 'la taquilla cobra la franja nocturna');
select t.logout();
-- con pasajes vendidos, la franja del viaje no cambia aunque se cambie el horario
update public.trips set scheduled_departure = timestamptz '2027-06-22 10:00-03' where id = (select id from fbt);
select t.expect_eq((select fare_band from public.trips where id = (select id from fbt)), 'nocturno', 'con ventas la franja no se recalcula');

-- abonos por franja y bajas protegidas
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$insert into public.pass_products (company_id, place_a, place_b, trips, valid_days, price, day_types)
  select 'aaaaaaaa-0000-0000-0000-000000000001', a.id, b.id, 5, 30, 1000, array['zzz']
  from (select id from public.places order by id limit 1) a, (select id from public.places order by id desc limit 1) b$q$, 'PASS_INVALID');
select t.expect_eq(public.pass_days_short(array['nocturno', 'weekday']), ' · días H·Nocturno', 'resumen de franjas del abono');
select t.expect_fail(format($q$select public.delete_fare_band(%L)$q$, (select id from public.fare_bands where code = 'nocturno' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001')), 'BAND_IN_USE');
select t.expect_fail(format($q$select public.delete_fare_band(%L)$q$, (select id from public.fare_bands where code = 'weekday' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001')), 'BAND_IN_USE');
select public.save_fare_band(null, 'Sin usar', null);
select public.delete_fare_band((select id from public.fare_bands where code = 'sin-usar' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select t.expect_eq((select count(*)::int from public.fare_bands where code = 'sin-usar'), 0, 'una franja sin uso se puede quitar');
select t.logout();

-- el conductor no edita franjas; otra empresa no ve las de esta
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.save_fare_band(null, 'Mia', null)$q$, 'FORBIDDEN');
select t.expect_fail($q$select public.delete_fare_exception(gen_random_uuid())$q$, 'FORBIDDEN');
select t.logout();
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*)::int from public.fare_band_weekly where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 0, 'otra empresa no ve la semana base');
select t.expect_eq((select count(*)::int from public.fare_band_exceptions), 0, 'ni las excepciones');
select t.logout();
rollback;
\echo 'PRUEBAS DE FRANJAS PASARON'
