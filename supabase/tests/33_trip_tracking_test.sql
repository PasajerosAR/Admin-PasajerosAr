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
-- la unidad esta justo en Colonia Avellaneda (parada 2, programada a los 20 min): va a tiempo
insert into public.trip_live_positions (trip_id, company_id, driver_id, latitude, longitude, accuracy_m, recorded_at)
values ((select trip_id from tk), (select company_id from tk), 'a2000000-0000-0000-0000-000000000001', -31.70, -60.45, 10, now())
on conflict (trip_id) do update set latitude = excluded.latitude, longitude = excluded.longitude, recorded_at = now();
-- salida a las ahora-20min: ya pasaron los 5 min previos, el publico no lo ve
select t.expect_eq(public.trip_tracking((select trip_id from tk)) is null, true, 'el publico no ve el seguimiento despues del corte de 5 min');
-- salida futura (30 min): visible para el publico
alter table public.trips disable trigger user;
update public.trips set scheduled_departure = now() + interval '30 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
select t.expect_eq((public.trip_tracking((select trip_id from tk)))->>'origin_name', 'Parana', 'origen = primera parada');
select t.expect_eq((public.trip_tracking((select trip_id from tk)))->>'destination_name', 'Santa Fe Terminal', 'destino = ultima parada');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, true, 'hay senal');
-- esta en la parada 2 (que programa a los +20 min) pero la salida es en 30 min: va 20 min adelantado... pero no menos que ahora
select t.expect_eq(jsonb_array_length((public.trip_tracking((select trip_id from tk)))->'stops'), 3, 'lista las 3 paradas');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->0->>'passed')::boolean, true, 'la primera parada ya fue pasada');
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->2->>'eta_at') is not null, true, 'la ultima parada tiene hora estimada');
-- atraso: salida programada hace 20 min, la unidad esta en el origen -> ya llegaria tarde? (esperando en el origen no se adelanta)
update public.trip_live_positions set latitude = -31.73, longitude = -60.52, recorded_at = now() where trip_id = (select trip_id from tk);
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->'stops'->0->>'passed')::boolean, false, 'en el origen todavia no pasó la primera parada');
-- adelanto real: la unidad esta en la parada 2 (programada a los +20 min) y la salida es en 6 min -> 26 min antes de lo programado
update public.trip_live_positions set latitude = -31.70, longitude = -60.45, recorded_at = now() where trip_id = (select trip_id from tk);
alter table public.trips disable trigger user;
update public.trips set scheduled_departure = now() + interval '6 minutes' where id = (select trip_id from tk);
alter table public.trips enable trigger user;
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'delay_minutes')::int, -26, 'llega 26 min antes de lo programado');
-- sin senal reciente
update public.trip_live_positions set recorded_at = now() - interval '5 minutes' where trip_id = (select trip_id from tk);
select t.expect_eq(((public.trip_tracking((select trip_id from tk)))->>'signal')::boolean, false, 'posicion vieja = sin senal');
-- empresa sin GPS: sin seguimiento
update public.companies set blocked_features = array['gps'] where id = (select company_id from tk);
select t.expect_eq(public.trip_tracking((select trip_id from tk)) is null, true, 'empresa con GPS bloqueado: sin seguimiento');
update public.companies set blocked_features = '{}' where id = (select company_id from tk);
select 'PRUEBAS DE SEGUIMIENTO PASARON';
