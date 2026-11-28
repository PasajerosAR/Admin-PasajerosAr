\set ON_ERROR_STOP on
-- solo pruebas locales: la tabla auth.users simulada no trae banned_until
alter table auth.users add column if not exists banned_until timestamptz;
-- disposicion por servicio, unidades compatibles, cierre manual y baja de conductor
create temp table sx as
select s.id as service_id, d.id as dep from public.services s join public.service_departures d on d.service_id = s.id
 where s.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and d.active and s.active
   and (select count(*) from public.service_departures x where x.service_id = s.id and x.active) = 1
 order by s.code limit 1;
grant all on sx to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');
-- primera disposicion y su unidad
insert into public.seat_layouts (id, company_id, name) values ('11111111-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'Combi 2');
insert into public.layout_floors (layout_id, company_id, floor, rows, cols) values ('11111111-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 1, 3);
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label) values
  ('11111111-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 0, 'seat', '1'),
  ('11111111-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 2, 'seat', '2'),
  ('11111111-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 1, 'seat', '3');
insert into public.vehicles (id, company_id, kind, internal_number, plate, layout_id)
 values ('22222222-0000-0000-0000-0000000000b1', 'aaaaaaaa-0000-0000-0000-000000000001', 'combi', '98', 'YY000YY', '11111111-0000-0000-0000-0000000000a1');
-- segunda disposicion (otra) y segunda unidad con ella
insert into public.seat_layouts (id, company_id, name) values ('11111111-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 'Minibus 2');
insert into public.layout_floors (layout_id, company_id, floor, rows, cols) values ('11111111-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 1, 2);
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label) values
  ('11111111-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 0, 'seat', '1'),
  ('11111111-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 1, 'seat', '2');
insert into public.vehicles (id, company_id, kind, internal_number, plate, layout_id)
 values ('22222222-0000-0000-0000-0000000000b2', 'aaaaaaaa-0000-0000-0000-000000000001', 'combi', '99', 'ZZ000ZZ', '11111111-0000-0000-0000-0000000000a2');
-- sin disposicion: el servicio no aparece en el mapa de compatibilidad
select t.expect_eq(public.service_layout_vehicles() ? (select service_id::text from sx), false, 'servicio sin disposicion: acepta cualquier unidad');
select public.set_service_layout((select service_id from sx), '11111111-0000-0000-0000-0000000000a1');
select t.expect_eq(jsonb_array_length(public.service_layout_vehicles()->(select service_id::text from sx)), 1, 'solo la unidad con esa disposicion');
-- el viaje nace con la disposicion del servicio, sin unidad ni conductor
select public.generate_trips(date '2027-06-07', 'weekday');
select t.expect_eq((select layout_id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1),
  '11111111-0000-0000-0000-0000000000a1'::uuid, 'el viaje nace con la disposicion del servicio');
select t.expect_eq((select vehicle_id is null and driver_id is null from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), true, 'sin unidad ni conductor');
select public.publish_trips(date '2027-06-07');
-- unidad con otra disposicion: no
select t.expect_fail($q$update public.trips set vehicle_id = '22222222-0000-0000-0000-0000000000b2' where service_id = (select service_id from sx) and service_date = date '2027-06-07'$q$, 'VEHICLE_LAYOUT_MISMATCH');
-- unidad compatible: si
update public.trips set vehicle_id = '22222222-0000-0000-0000-0000000000b1' where service_id = (select service_id from sx) and service_date = date '2027-06-07';
select t.expect_eq((select layout_id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1),
  '11111111-0000-0000-0000-0000000000a1'::uuid, 'la unidad compatible mantiene la disposicion');
-- cambiar la disposicion del viaje libera la unidad que ya no sirve
select public.admin_set_trip_layout((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), '11111111-0000-0000-0000-0000000000a2');
select t.expect_eq((select vehicle_id is null from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), true, 'cambiar la disposicion libera la unidad incompatible');
update public.trips set vehicle_id = '22222222-0000-0000-0000-0000000000b2' where service_id = (select service_id from sx) and service_date = date '2027-06-07';
select t.logout();

insert into auth.users (id, email) values ('a2000000-0000-0000-0000-0000000000d1', 'nuevo2@test');
insert into public.profiles (id, company_id, role, full_name) values ('a2000000-0000-0000-0000-0000000000d1', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer libre');
-- el conductor inicia con una unidad: la incompatible se rechaza, la compatible inicia
select t.login('a2000000-0000-0000-0000-0000000000d1');
select public.start_shift();
select t.expect_fail($q$select public.start_service((select service_id from sx), (select dep from sx), 'weekday', '22222222-0000-0000-0000-0000000000b1', 'prueba', date '2027-06-07')$q$, 'VEHICLE_LAYOUT_MISMATCH');
select public.start_service((select service_id from sx), (select dep from sx), 'weekday', '22222222-0000-0000-0000-0000000000b2', 'prueba', date '2027-06-07');
select t.expect_eq((select status::text from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), 'in_progress', 'el conductor inicia con la unidad compatible');
select t.expect_eq(jsonb_typeof(public.service_layout_vehicles()->(select service_id::text from sx)), 'array', 'el conductor ve las unidades compatibles');
select t.logout();

-- cierre manual de un viaje en curso colgado
select t.logout();
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now() - interval '5 days', scheduled_departure = now() - interval '5 days'
 where service_id = (select service_id from sx) and service_date = date '2027-06-07';
alter table public.trips enable trigger user;
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.admin_end_trip((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), now(), '')$q$, 'REASON_REQUIRED');
select t.expect_fail($q$select public.admin_end_trip((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), now() + interval '2 days', 'motivo')$q$, 'END_IN_FUTURE');
select t.expect_fail($q$select public.admin_end_trip((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), now() - interval '9 days', 'motivo')$q$, 'END_BEFORE_START');
select t.expect_eq(public.trip_expected_arrival((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1)) is not null, true, 'llegada prevista');
select public.admin_end_trip((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), now() - interval '4 days', 'quedo colgado');
select t.expect_eq((select status::text from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), 'completed', 'viaje finalizado a mano');
select t.expect_eq((select ended_manually from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), true, 'queda marcado como manual');
select t.expect_fail($q$select public.admin_end_trip((select id from public.trips where service_id = (select service_id from sx) and service_date = date '2027-06-07' limit 1), now(), 'otra vez')$q$, 'INVALID_STATE');
select t.logout();

-- baja de conductor: con historial se oculta, sin actividad se borra
insert into auth.users (id, email) values ('a2000000-0000-0000-0000-0000000000c9', 'nuevo@test');
insert into public.profiles (id, company_id, role, full_name) values ('a2000000-0000-0000-0000-0000000000c9', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer sin actividad');
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((public.remove_driver('a2000000-0000-0000-0000-0000000000c9'))->>'kept_history', 'false', 'sin actividad: se borra');
select t.expect_eq((select count(*) from public.profiles where id = 'a2000000-0000-0000-0000-0000000000c9'), 0::bigint, 'ya no existe');
-- 0051: con viaje en curso o jornada abierta también se elimina
select t.expect_eq((public.remove_driver('a2000000-0000-0000-0000-000000000001'))->>'deleted', 'true', 'con viaje en curso: se elimina');
select t.expect_eq((select count(*) from public.trips where driver_id = 'a2000000-0000-0000-0000-000000000001' and status in ('scheduled','in_progress')), 0::bigint, 'sus viajes pendientes y en curso quedan sin conductor');
select t.expect_eq((select count(*) >= 1 from public.trips where status = 'in_progress' and driver_id is null), true, 'el viaje en curso sigue en curso, sin conductor');
select t.expect_eq((public.remove_driver('a2000000-0000-0000-0000-0000000000d1'))->>'kept_history', 'true', 'con historial: se oculta');
select t.expect_eq((select deleted_at is not null and not active from public.profiles where id = 'a2000000-0000-0000-0000-0000000000d1'), true, 'queda oculto e inactivo');
select t.expect_eq((select count(*) from public.shifts where driver_id = 'a2000000-0000-0000-0000-0000000000d1' and ended_at is null), 0::bigint, 'su jornada abierta se cerró');
select t.logout();
select t.expect_eq((select email from auth.users where id = 'a2000000-0000-0000-0000-0000000000d1') like 'eliminado-%', true, 'se libera el correo');
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.remove_driver('a3000000-0000-0000-0000-000000000001')$q$, 'NOT_FOUND');
select t.logout();
select 'PRUEBAS DE DISPOSICION POR SERVICIO PASARON';
