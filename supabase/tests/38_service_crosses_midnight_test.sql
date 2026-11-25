\set ON_ERROR_STOP on
-- Servicio nocturno: sale 21:00 y vuelve 00:45 (del dia siguiente).
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '230', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"21:00","day_types":["saturday"]},
    {"route_id":"33333333-0000-0000-0000-000000000001","time":"00:45","next_day":true,"day_types":["saturday"]}]'::jsonb,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select public.generate_trips(date '2026-11-14', 'saturday');
select t.logout();
create temp table mv as
select s.id as service_id,
       (select d.id from public.service_departures d where d.service_id = s.id and d.departure_time = time '21:00') as late,
       (select d.id from public.service_departures d where d.service_id = s.id and d.departure_time = time '00:45') as after
  from public.services s where s.code = '230';
grant all on mv to authenticated;

select t.expect_eq((select next_day::text from public.service_departures where id = (select after from mv)), 'true', 'la salida 00:45 queda marcada como del dia siguiente');
select t.expect_eq((select next_day::text from public.service_departures where id = (select late from mv)), 'false', 'la salida 21:00 es del mismo dia');
select t.expect_eq((select to_char(scheduled_departure at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI') from public.trips where departure_id = (select late from mv)), '2026-11-14 21:00', 'el viaje de las 21:00 sale el mismo dia');
select t.expect_eq((select to_char(scheduled_departure at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI') from public.trips where departure_id = (select after from mv)), '2026-11-15 00:45', 'el viaje de las 00:45 sale el dia calendario siguiente');
select t.expect_eq((select service_date::text from public.trips where departure_id = (select after from mv)), '2026-11-14', 'el viaje sigue siendo del dia del servicio');

-- el conductor inicia las 21:00 y pasa a las 00:45 (posterior a las 21:00)
alter table public.trips disable trigger user;
update public.trips set status = 'completed', ended_at = now() where driver_id = 'a3000000-0000-0000-0000-000000000001' and status = 'in_progress';
alter table public.trips enable trigger user;
select t.login('a3000000-0000-0000-0000-000000000001');
select public.start_service((select service_id from mv), (select late from mv), 'saturday',
  '22222222-0000-0000-0000-000000000002', 'Inicio de prueba', date '2026-11-14');
select public.advance_service_trip((select id from public.trips where departure_id = (select late from mv) and service_date = date '2026-11-14'),
  (select after from mv), false, true);
select t.expect_eq((select status::text from public.trips where departure_id = (select after from mv)), 'in_progress', 'avanza de las 21:00 a las 00:45 del dia siguiente');
select t.logout();

-- sin la marca, la 00:45 no seria posterior y el cambio se rechaza
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '231', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"21:00","day_types":["saturday"]},
    {"route_id":"33333333-0000-0000-0000-000000000001","time":"00:45","day_types":["saturday"]}]'::jsonb,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
-- al marcarla despues de guardar, el viaje todavia sin iniciar acompaña el cambio
select public.generate_trips(date '2026-11-21', 'saturday');
select public.save_service((select id from public.services where code = '231'), '231', true,
  (select jsonb_agg(jsonb_build_object('id', d.id, 'route_id', d.route_id, 'time', to_char(d.departure_time, 'HH24:MI'),
     'next_day', d.departure_time = time '00:45', 'day_types', to_jsonb(d.day_types)))
     from public.service_departures d where d.service_id = (select id from public.services where code = '231')),
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select t.expect_eq((select to_char(t2.scheduled_departure at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI')
  from public.trips t2 join public.service_departures d on d.id = t2.departure_id
  where d.service_id = (select id from public.services where code = '231') and d.departure_time = time '00:45'), '2026-11-22 00:45', 'marcar la salida mueve el viaje pendiente al dia siguiente');
select t.logout();
\echo 'PRUEBAS DE SERVICIO QUE PASA LAS 00:00 PASARON'
