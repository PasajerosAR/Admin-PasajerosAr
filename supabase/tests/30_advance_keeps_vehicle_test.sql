\set ON_ERROR_STOP on
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '220', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"09:00","day_types":["saturday"]},
    {"route_id":"33333333-0000-0000-0000-000000000001","time":"10:00","day_types":["saturday"]}]'::jsonb,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select public.generate_trips(date '2026-11-14', 'saturday');
select t.logout();
create temp table kv as
select s.id as service_id,
       (select d.id from public.service_departures d where d.service_id = s.id and d.departure_time = time '09:00') as cur,
       (select d.id from public.service_departures d where d.service_id = s.id and d.departure_time = time '10:00') as nxt
  from public.services s where s.code = '220';
grant all on kv to authenticated;
alter table public.trips disable trigger user;
update public.trips set status = 'completed', ended_at = now() where driver_id = 'a3000000-0000-0000-0000-000000000001' and status = 'in_progress';
-- el admin dejo asignada otra unidad a la vuelta
update public.trips set vehicle_id = '22222222-0000-0000-0000-0000000000f1' where departure_id = (select nxt from kv) and service_date = date '2026-11-14';
alter table public.trips enable trigger user;
select t.login('a3000000-0000-0000-0000-000000000001');
select public.start_service((select service_id from kv), (select cur from kv), 'saturday',
  '22222222-0000-0000-0000-000000000002', 'Inicio de prueba', date '2026-11-14');
select public.advance_service_trip((select id from public.trips where departure_id = (select cur from kv) and service_date = date '2026-11-14'),
  (select nxt from kv), false, true);
select t.expect_eq((select vehicle_id::text from public.trips where departure_id = (select nxt from kv) and service_date = date '2026-11-14'),
  '22222222-0000-0000-0000-000000000002', 'el viaje siguiente sigue con la unidad que se esta usando');
select t.expect_eq((select status::text from public.trips where departure_id = (select nxt from kv) and service_date = date '2026-11-14'), 'in_progress', 'el cambio no se frena por la unidad asignada');
select t.logout();
\echo 'PRUEBAS DE UNIDAD EN EL CAMBIO PASARON'
