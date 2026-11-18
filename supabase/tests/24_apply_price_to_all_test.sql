\set ON_ERROR_STOP on
update public.companies set blocked_features = '{}';
-- el recorrido de prueba pasa por dos localidades: las primeras paradas en Paraná y la última en Santa Fe
update public.route_stops set place_id = '77777777-0000-0000-0000-000000000003'
 where route_id = (select r.id from public.routes r join public.service_departures d on d.route_id = r.id
                    where d.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by r.name limit 1)
   and position = (select max(position) from public.route_stops where route_id = (select r.id from public.routes r join public.service_departures d on d.route_id = r.id
                    where d.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by r.name limit 1));
-- aplicar un mismo precio a todos los tramos del recorrido de la empresa
select t.login('a1000000-0000-0000-0000-000000000001');
create temp table ap as
select public.apply_price_to_all((select r.id from public.routes r join public.service_departures d on d.route_id = r.id
  where d.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by r.name limit 1), 100, null) as n;
grant all on ap to authenticated;
select t.expect_eq((select n > 0 from ap), true, 'aplica el precio a todos los tramos');
select t.expect_eq((select count(*) from public.ticket_prices where price = 100 and seat_class is null and active) >= (select n from ap), true, 'quedan cargadas las tarifas');
-- repetir actualiza y no duplica
select public.apply_price_to_all((select r.id from public.routes r join public.service_departures d on d.route_id = r.id
  where d.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by r.name limit 1), 120, null);
select t.expect_eq((select count(*) from public.ticket_prices where price = 100), 0::bigint, 'al repetir se actualiza el precio, no se duplica');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.apply_price_to_all(gen_random_uuid(), 100, null)$q$, 'FORBIDDEN');
select t.logout();
select 'PRUEBAS DE APLICAR PRECIO A TODOS PASARON';
