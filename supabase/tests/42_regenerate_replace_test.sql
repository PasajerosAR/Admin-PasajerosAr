\set ON_ERROR_STOP on
-- Regenerar un dia con otro tipo reemplaza los viajes anteriores (con aviso) y la web ve el tipo real del viaje.
create temp table rg as select ((now() at time zone 'America/Argentina/Buenos_Aires')::date + 120) as d;
grant all on rg to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '742', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"10:00","day_types":["weekday","holiday"]},
    {"route_id":"33333333-0000-0000-0000-000000000001","time":"15:00","day_types":["weekday","holiday"]}]'::jsonb,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select public.generate_trips((select d from rg), 'weekday');
select t.expect_eq((select (public.generate_trips_preview((select d from rg), 'holiday')->>'other_type')), (select count(*)::text from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and service_date = (select d from rg) and day_type = 'weekday'), 'el aviso cuenta los viajes de otro tipo');
select t.expect_fail($q$select public.generate_trips((select d from rg), 'holiday')$q$, 'REPLACE_REQUIRED');
select public.generate_trips((select d from rg), 'holiday', true);
select t.expect_eq((select count(*)::text from public.trips tr join public.services s on s.id = tr.service_id where s.code = '742' and tr.service_date = (select d from rg) and tr.day_type = 'weekday'), '0', 'los viajes habiles desaparecen');
select t.expect_eq((select count(*)::text from public.trips tr join public.services s on s.id = tr.service_id where s.code = '742' and tr.service_date = (select d from rg) and tr.day_type = 'holiday'), '2', 'quedan solo los de feriado');
-- con un viaje que ya tiene conductor no se reemplaza
update public.trips set driver_id = 'a3000000-0000-0000-0000-000000000001'
 where id = (select tr.id from public.trips tr join public.services s on s.id = tr.service_id where s.code = '742' and tr.service_date = (select d from rg) limit 1);
select t.expect_fail($q$select public.generate_trips((select d from rg), 'weekday', true)$q$, 'TRIPS_BLOCKED');
select t.expect_eq((select count(*)::text from public.trips tr join public.services s on s.id = tr.service_id where s.code = '742' and tr.service_date = (select d from rg)), '2', 'ante el bloqueo no se borra nada');
select t.logout();
-- la web ve el tipo real: viaje de feriado publicado en un dia habil
alter table public.trips disable trigger user;
update public.trips set driver_id = null, published_at = now(),
  layout_id = (select layout_id from public.trips where layout_id is not null limit 1)
 where service_id = (select id from public.services where code = '742') and service_date = (select d from rg);
alter table public.trips enable trigger user;
select t.expect_eq((select count(*)::text from public._public_company_trips_impl('aaaaaaaa-0000-0000-0000-000000000001', null, null, (select d from rg), 1, 20)
   where service_code = '742'), '2', 'la web muestra los viajes generados como feriado aunque la fecha sea dia habil');
\echo 'PRUEBAS DE REEMPLAZO AL REGENERAR PASARON'
