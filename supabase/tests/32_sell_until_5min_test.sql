\set ON_ERROR_STOP on
-- la web lista un viaje aunque este iniciado, hasta 5 minutos antes de la salida
create temp table sv5 as
select t.id from public.trips t
 join public.service_departures d on d.id = t.departure_id
 where t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and t.layout_id is not null and t.published_at is not null
   and public.day_type_of((now() at time zone 'America/Argentina/Buenos_Aires')::date) = any (d.day_types)
   and exists (select 1 from public.ticket_prices p where p.company_id = t.company_id and p.active)
 order by t.created_at desc limit 1;
grant all on sv5 to authenticated;
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now(), driver_id = null,
  service_date = (now() at time zone 'America/Argentina/Buenos_Aires')::date,
  scheduled_departure = now() + interval '10 minutes'
 where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)),
  1::bigint, 'iniciado pero faltan 10 min: sigue en la web');
update public.trips set scheduled_departure = now() + interval '3 minutes' where id = (select id from sv5);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 20) where trip_id = (select id from sv5)),
  0::bigint, 'faltan menos de 5 min: ya no se vende');
alter table public.trips enable trigger user;
select 'PRUEBAS DE VENTA HASTA 5 MIN PASARON';
