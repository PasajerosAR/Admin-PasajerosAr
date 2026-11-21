\set ON_ERROR_STOP on
-- viaje en curso visible en la web: cada parada se vende hasta 5 min antes de que la unidad pase;
-- el viaje desaparece al finalizar o 15 min despues de la llegada programada a la ultima parada
create temp table sv5 as
select t.id, t.service_id, d.route_id from public.trips t
 join public.service_departures d on d.id = t.departure_id
 where t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and t.layout_id is not null and t.published_at is not null
   and public.day_type_of((now() at time zone 'America/Argentina/Buenos_Aires')::date) = any (d.day_types)
   and exists (select 1 from public.ticket_prices p where p.company_id = t.company_id and p.active)
 order by t.created_at desc limit 1;
grant all on sv5 to authenticated;
-- tiempos del servicio: origen 0, ultima parada a los 100 min -> se oculta a los 115 min de la salida programada
insert into public.service_stops (service_id, route_stop_id, company_id, minutes_from_start)
select (select service_id from sv5), rs.id, 'aaaaaaaa-0000-0000-0000-000000000001',
       case when rs.position = (select min(position) from public.route_stops where route_id = (select route_id from sv5)) then 0 else 100 end
  from public.route_stops rs
 where rs.route_id = (select route_id from sv5)
   and rs.position in ((select min(position) from public.route_stops where route_id = (select route_id from sv5)),
                       (select max(position) from public.route_stops where route_id = (select route_id from sv5)))
on conflict (service_id, route_stop_id) do update set minutes_from_start = excluded.minutes_from_start;
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now(), driver_id = null,
  service_date = (now() at time zone 'America/Argentina/Buenos_Aires')::date,
  scheduled_departure = now() + interval '10 minutes'
 where id = (select id from sv5);
-- faltan 10 min: se ve, se puede comprar
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5) and not in_transit),
  1::bigint, 'iniciado pero faltan 10 min: se ve y se puede comprar');
-- faltan 3 min: sigue visible pero solo "en viaje"
update public.trips set scheduled_departure = now() + interval '3 minutes' where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5) and in_transit),
  1::bigint, 'faltan menos de 5 min: sigue visible como en viaje');
select t.expect_eq((select count(*) from public.public_trip_seats((select id from sv5),
  (select from_stop_id from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)),
  (select to_stop_id from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)))),
  0::bigint, 'no se venden asientos desde una parada que ya pasa');
-- salio hace 60 min: sigue visible (llega a los 100 min)
update public.trips set scheduled_departure = now() - interval '60 minutes' where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5) and in_transit),
  1::bigint, 'en ruta: visible hasta llegar');
-- 15 min despues de la llegada programada: ya no se ve
update public.trips set scheduled_departure = now() - interval '116 minutes' where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)),
  0::bigint, '15 min despues de la llegada programada desaparece');
-- finalizado: no se ve
update public.trips set scheduled_departure = now() - interval '60 minutes', status = 'completed', ended_at = now() where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)),
  0::bigint, 'viaje finalizado: no se ve');
alter table public.trips enable trigger user;
select 'PRUEBAS DE VENTA HASTA 5 MIN PASARON';
