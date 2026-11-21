\set ON_ERROR_STOP on
-- Seguimiento: viaje en curso del recorrido de prueba (Parana 0 min, Colonia Avellaneda 20, Santa Fe 100)
update public.companies set blocked_features = '{}';
create temp table tk as
select t.id as trip_id, t.service_id, t.company_id from public.trips t
 join public.service_departures d on d.id = t.departure_id
 where t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and d.route_id = '33333333-0000-0000-0000-000000000001'
 order by t.created_at desc limit 1;
grant all on tk to authenticated;
-- tiempos del servicio para las 3 paradas
insert into public.service_stops (service_id, route_stop_id, company_id, minutes_from_start)
select (select service_id from tk), rs.id, (select company_id from tk),
       case rs.position when 1 then 0 when 2 then 20 else 100 end
  from public.route_stops rs where rs.route_id = '33333333-0000-0000-0000-000000000001'
on conflict (service_id, route_stop_id) do update set minutes_from_start = excluded.minutes_from_start;
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now(), published_at = now(),
  scheduled_departure = now() - interval '20 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
-- viaje programado (todavia no salio): el seguimiento responde sin posicion
alter table public.trips disable trigger user;
update public.trips set status = 'scheduled', started_at = null, scheduled_departure = now() + interval '30 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'viaje programado: seguimiento sin posicion');
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now() where id = (select trip_id from tk);
alter table public.trips enable trigger user;
-- ---- regla de posicion ANTES de la salida: solo en la parada 1 (200 m) y desde 15 min antes ----
alter table public.trips disable trigger user;
update public.trips set scheduled_departure = now() + interval '30 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
-- la unidad esta en Colonia Avellaneda (parada 2), no en el origen
insert into public.trip_live_positions (trip_id, company_id, driver_id, latitude, longitude, accuracy_m, recorded_at)
values ((select trip_id from tk), (select company_id from tk), 'a2000000-0000-0000-0000-000000000001', -31.70, -60.45, 10, now())
on conflict (trip_id) do update set latitude = excluded.latitude, longitude = excluded.longitude, recorded_at = now();
select t.expect_eq((public.trip_tracking((select trip_id from tk)))->>'origin_name', 'Parana', 'origen = primera parada');
select t.expect_eq((public.trip_tracking((select trip_id from tk)))->>'destination_name', 'Santa Fe Terminal', 'destino = ultima parada');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->0) ? 'place_name', true, 'las paradas traen la localidad');
select t.expect_eq((public.trip_tracking((select trip_id from tk))) ? 'origin_place', true, 'trae la localidad de origen');
select t.expect_eq(jsonb_array_length((public.trip_tracking((select trip_id from tk)))->'stops'), 3, 'lista las 3 paradas');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'antes de la salida y fuera de la parada 1: sin posicion');
-- en la parada 1 pero faltan 30 min (mas de 15): sin posicion
update public.trip_live_positions set latitude = -31.73, longitude = -60.52, recorded_at = now() where trip_id = (select trip_id from tk);
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'en la parada 1 pero faltan mas de 15 min: sin posicion');
-- en la parada 1 y faltan 10 min: se muestra
alter table public.trips disable trigger user;
update public.trips set scheduled_departure = now() + interval '10 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, true, 'en la parada 1 y faltan 10 min: se muestra');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->0->>'passed')::boolean, false, 'en el origen todavia no paso la primera parada');
-- a 300 m de la parada 1 (faltan 10 min): sin posicion
update public.trip_live_positions set latitude = -31.7327, recorded_at = now() where trip_id = (select trip_id from tk);
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'a mas de 200 m de la parada 1: sin posicion');
-- sin senal reciente
update public.trip_live_positions set latitude = -31.73, recorded_at = now() - interval '5 minutes' where trip_id = (select trip_id from tk);
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'posicion vieja = sin senal');
-- ---- DESPUES de la salida: seguimiento normal (lo ve quien tiene pasaje) ----
update public.sale_tickets set trip_id = (select trip_id from tk), passenger_user_id = 'a2000000-0000-0000-0000-000000000001'
 where id = (select id from public.sale_tickets where regexp_replace(passenger_dni,'\D','','g') = '28999111' order by created_at desc limit 1);
alter table public.trips disable trigger user;
update public.trips set scheduled_departure = now() - interval '6 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
update public.trip_live_positions set latitude = -31.70, longitude = -60.45, recorded_at = now() where trip_id = (select trip_id from tk);
select t.login('a2000000-0000-0000-0000-000000000001');
-- el publico ya no lo ve (corte de 5 min) pero si el pasajero con pasaje
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, true, 'pasada la hora de salida: se muestra la posicion');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->0->>'passed')::boolean, true, 'la primera parada ya fue pasada');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->2->>'eta_at') is not null, true, 'la ultima parada tiene hora estimada');
-- adelanto real: en la parada 2 (programada a +20) con la salida hace 6 min -> 14 min antes
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'delay_minutes')::int, -14, 'llega 14 min antes de lo programado');
select t.logout();
-- empresa sin GPS: sin seguimiento
update public.companies set blocked_features = array['gps'] where id = (select company_id from tk);
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq(public.trip_tracking((select trip_id from tk)) is null, true, 'empresa con GPS bloqueado: sin seguimiento');
select t.logout();
update public.companies set blocked_features = '{}' where id = (select company_id from tk);
select 'PRUEBAS DE SEGUIMIENTO PASARON';
