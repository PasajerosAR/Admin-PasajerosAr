\set ON_ERROR_STOP on
-- La busqueda web usa la fecha real de salida: una salida 00:45 de un servicio del viernes aparece al buscar el sabado.
create temp table rd as
select t.id, t.departure_id, d.route_id,
       (select x::date from generate_series((now() at time zone 'America/Argentina/Buenos_Aires')::date + 2,
                                             (now() at time zone 'America/Argentina/Buenos_Aires')::date + 20, interval '1 day') x
         where public.day_type_of(x::date) = any (d.day_types) order by x limit 1) as svc_day
  from public.trips t
  join public.service_departures d on d.id = t.departure_id
 where t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and t.layout_id is not null and t.published_at is not null
   and t.status = 'scheduled'
 order by t.created_at desc limit 1;
grant all on rd to authenticated;
alter table public.trips disable trigger user;
update public.trips set service_date = (select svc_day from rd) + 4000
 where departure_id = (select departure_id from rd) and id <> (select id from rd) and service_date = (select svc_day from rd);
update public.trips set service_date = (select svc_day from rd),
  scheduled_departure = (((select svc_day from rd) + 1)::timestamp + time '00:45') at time zone 'America/Argentina/Buenos_Aires',
  status = 'scheduled', published_at = now()
 where id = (select id from rd);
alter table public.trips enable trigger user;
create temp table rdp as
select (select place_id from public.route_stops where route_id = (select route_id from rd) order by position limit 1) as from_p,
       (select place_id from public.route_stops where route_id = (select route_id from rd) order by position desc limit 1) as to_p;
grant all on rdp to authenticated;

select t.expect_eq((select count(*) from public._public_search_trips_impl((select from_p from rdp), (select to_p from rdp), (select svc_day + 1 from rd)) where trip_id = (select id from rd)),
  1::bigint, 'buscar el dia calendario siguiente encuentra la salida de las 00:45');
select t.expect_eq((select count(*) from public._public_search_trips_impl((select from_p from rdp), (select to_p from rdp), (select svc_day from rd)) where trip_id = (select id from rd)),
  0::bigint, 'buscar el dia del servicio ya no la muestra (sale el dia siguiente)');
select t.expect_eq((select count(*) from public._public_company_trips_impl('aaaaaaaa-0000-0000-0000-000000000001', null, null, (select svc_day + 1 from rd), 1, 20) where trip_id = (select id from rd)),
  1::bigint, 'el listado de la empresa tambien usa la fecha real');
select t.expect_eq((select count(*) from public._public_company_trips_impl('aaaaaaaa-0000-0000-0000-000000000001', null, null, (select svc_day from rd), 1, 20) where trip_id = (select id from rd)),
  0::bigint, 'el listado de la empresa no la muestra el dia del servicio');
\echo 'PRUEBAS DE BUSQUEDA POR FECHA REAL PASARON'
