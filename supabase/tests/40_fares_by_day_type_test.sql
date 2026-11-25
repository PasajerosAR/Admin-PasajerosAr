\set ON_ERROR_STOP on
-- tarifas por tipo de dia: cada tramo/clase tiene un precio por dia habil, sabado, domingo y feriado
create temp table fx as
select (select id from public.routes r where r.id = '33333333-0000-0000-0000-000000000001') as route_id;
grant all on fx to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');
-- tramo de prueba 1-2 con clase propia para no pisar otras pruebas
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 2, 3000, 'zeta', 'weekday');
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 2, 3500, 'zeta', 'saturday');
select t.expect_eq((select price from public.ticket_prices where route_id = (select route_id from fx) and from_pos = 1 and to_pos = 2 and seat_class = 'zeta' and day_type = 'weekday' and active), 3000::numeric, 'precio de dia habil');
select t.expect_eq((select price from public.ticket_prices where route_id = (select route_id from fx) and from_pos = 1 and to_pos = 2 and seat_class = 'zeta' and day_type = 'saturday' and active), 3500::numeric, 'precio de sabado distinto');
select t.expect_eq((select count(*) from public.ticket_prices where route_id = (select route_id from fx) and from_pos = 1 and to_pos = 2 and seat_class = 'zeta' and active), 2::bigint, 'domingo y feriado sin precio: no se venden');
-- repetir actualiza, no duplica
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 2, 3100, 'zeta', 'weekday');
select t.expect_eq((select count(*) from public.ticket_prices where route_id = (select route_id from fx) and from_pos = 1 and to_pos = 2 and seat_class = 'zeta' and day_type = 'weekday'), 1::bigint, 'al repetir se actualiza el precio del mismo dia');
-- dos tarifas activas del mismo tramo, clase y dia se rechazan
select t.expect_fail($q$insert into public.ticket_prices (company_id, route_id, from_pos, to_pos, price, seat_class, day_type) values ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 1, 2, 1, 'zeta', 'weekday')$q$, 'ticket_prices_active_unique');
select t.expect_fail($q$select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 2, 10, 'zeta', 'lunes')$q$, 'PRICE_INVALID');
-- precio vacio: ese dia deja de venderse
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 2, null, 'zeta', 'saturday');
select t.expect_eq((select count(*) from public.ticket_prices where route_id = (select route_id from fx) and from_pos = 1 and to_pos = 2 and seat_class = 'zeta' and day_type = 'saturday' and active), 0::bigint, 'sin precio el dia deja de venderse');
-- aplicar a todos solo en los dias elegidos
select public.apply_price_to_all('33333333-0000-0000-0000-000000000001', 777, 'omega', array['sunday', 'holiday']);
select t.expect_eq((select array_agg(distinct day_type order by day_type)::text from public.ticket_prices where route_id = (select route_id from fx) and seat_class = 'omega' and active), '{holiday,sunday}', 'aplicar a todos respeta los dias elegidos');
-- el generador de abonos recibe un precio por tipo de dia
select t.expect_eq((select day_type || ':' || base_price::int from public.pass_fare_pairs() where seat_class = 'zeta'), 'weekday:3100', 'el generador de abonos recibe el precio por tipo de dia');
select t.logout();
\echo 'PRUEBAS DE TARIFAS POR TIPO DE DIA PASARON'
