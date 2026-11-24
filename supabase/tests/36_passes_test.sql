\set ON_ERROR_STOP on
-- abonos: productos, venta, uso en ventanilla y web, cancelacion que devuelve el viaje
update public.companies set blocked_features = '{}';
insert into public.places (id, name) values
  ('77777777-0000-0000-0000-0000000000a1', 'Origen Abono'), ('77777777-0000-0000-0000-0000000000a2', 'Destino Abono');
select t.login('a1000000-0000-0000-0000-000000000001');
select public.generate_trips(date '2027-06-08', 'weekday');
select public.publish_trips(date '2027-06-08');
select t.logout();
create temp table pt as
select t.id as trip_id, d.route_id from public.trips t join public.service_departures d on d.id = t.departure_id
 where t.service_date = date '2027-06-08' and t.layout_id is not null and t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001'
 order by t.scheduled_departure limit 1;
grant all on pt to authenticated;
create temp table ps as
select (select id from public.route_stops where route_id = (select route_id from pt) order by position limit 1) as first_stop,
       (select id from public.route_stops where route_id = (select route_id from pt) order by position offset 1 limit 1) as mid_stop,
       (select id from public.route_stops where route_id = (select route_id from pt) order by position desc limit 1) as last_stop,
       (select count(*) from public.route_stops where route_id = (select route_id from pt)) as n;
grant all on ps to authenticated;
update public.route_stops set place_id = '77777777-0000-0000-0000-0000000000a1' where id = (select first_stop from ps);
update public.route_stops set place_id = '77777777-0000-0000-0000-0000000000a2' where id = (select last_stop from ps);
insert into public.ticket_prices (company_id, route_id, from_pos, to_pos, price)
select 'aaaaaaaa-0000-0000-0000-000000000001', (select route_id from pt), f.position, l.position, 1000
  from public.route_stops f, public.route_stops l where f.id = (select first_stop from ps) and l.id = (select last_stop from ps);

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select base_price >= 1000 from public.pass_fare_pairs() where place_a_name = 'Origen Abono' and seat_class is null), true, 'el generador ve la tarifa del tramo');
insert into public.pass_products (id, company_id, place_a, place_b, trips, price, valid_days)
values ('c1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-0000000000a1', '77777777-0000-0000-0000-0000000000a2', 10, 9000, 365);
select t.expect_fail($q$insert into public.pass_products (company_id, place_a, place_b, trips, price) values ('aaaaaaaa-0000-0000-0000-000000000001', '77777777-0000-0000-0000-0000000000a2', '77777777-0000-0000-0000-0000000000a1', 5, 1)$q$, 'pass_products_pair');
select t.expect_fail($q$select public.pass_sell('c1000000-0000-0000-0000-000000000001', '123', 'X', null, 'cash')$q$, 'PASSENGER_INVALID');
select t.expect_fail($q$select public.pass_sell('c1000000-0000-0000-0000-000000000001', '30222111', 'Luis Perez', null, 'mp')$q$, 'PAYMENT_INVALID');
create temp table sold as select public.pass_sell('c1000000-0000-0000-0000-000000000001', '30.222.111', 'Luis Perez', null, 'cash') as r;
grant all on sold to authenticated;
select t.expect_eq((select count(*) from public.staff_find_passes('30222111')), 1::bigint, 'ventanilla encuentra el abono por DNI');
select t.expect_eq((select trips_left from public.staff_find_passes('30222111')), 10, 'abono nuevo con los 10 viajes');
select t.expect_eq((select collected from public.pass_cash_close(now() - interval '1 day', now() + interval '1 day', null) where payment_method = 'cash'), 9000::numeric, 'el cierre de caja suma el abono');
-- usar en ventanilla
create temp table used as
select public.pass_redeem_counter((r->>'pass_id')::uuid, (select trip_id from pt), (select first_stop from ps), (select last_stop from ps), '1') as r from sold;
grant all on used to authenticated;
select t.expect_eq((select trips_left from public.staff_find_passes('30222111')), 9, 'usar descuenta un viaje');
select t.expect_eq((select price from public.sale_tickets where id = (select (r->>'ticket_id')::uuid from used)), 0::numeric, 'el pasaje con abono sale con precio 0');
select t.expect_eq((select payment_method::text from public.sales where id = (select (r->>'sale_id')::uuid from used)), 'pass', 'la venta queda como abono');
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '1')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'SEAT_TAKEN');
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '2')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select mid_stop from ps)), 'PASS_ROUTE_MISMATCH');
-- ida y vuelta: el tramo inverso (otra salida) usa las mismas localidades; aca se prueba el orden de la regla con un pasaje cancelado
select public.cancel_sale_ticket((select (r->>'ticket_id')::uuid from used), 'prueba de abono');
select t.expect_eq((select trips_left from public.staff_find_passes('30222111')), 10, 'cancelar con anticipacion devuelve el viaje');
select t.logout();
-- web: el pasajero usa su abono
insert into auth.users (id, email) values ('a9000000-0000-0000-0000-000000000001', 'luis@test.com'), ('a9000000-0000-0000-0000-000000000002', 'otro@test.com');
insert into public.passenger_profiles (user_id, first_name, last_name, dni, birth_date, email) values
  ('a9000000-0000-0000-0000-000000000001', 'Luis', 'Perez', '30222111', date '1990-01-01', 'luis@test.com'),
  ('a9000000-0000-0000-0000-000000000002', 'Otro', 'Pasajero', '30999888', date '1990-01-01', 'otro@test.com');
select t.login('a9000000-0000-0000-0000-000000000001');
select t.expect_eq((select usable from public.passenger_my_passes()), true, 'el pasajero ve su abono');
create temp table wused as
select public.pass_redeem_web((r->>'pass_id')::uuid, (select trip_id from pt), (select first_stop from ps), (select last_stop from ps), '2') as r from sold;
grant all on wused to authenticated;
select t.expect_eq((select trips_left from public.passenger_my_passes()), 9, 'reservar por web descuenta un viaje');
select t.expect_eq((select count(*) from public.passenger_my_tickets() where pass_id is not null and ticket_status = 'valid'), 1::bigint, 'el pasaje con abono aparece en Mis pasajes');
select t.expect_eq((select payment_method from public.passenger_my_tickets() where pass_id is not null limit 1), 'pass', 'Mis pasajes trae el medio de pago');
select t.expect_eq((select (receipt_number is not null and route_origin is not null and issued_at is not null) from public.passenger_my_tickets() where pass_id is not null limit 1), true, 'Mis pasajes trae comprobante, recorrido y emision');
select t.expect_eq((public.pass_cancel_ticket((select (r->>'ticket_id')::uuid from wused)))->>'returned', 'true', 'el pasajero cancela con anticipacion');
select t.expect_eq((select trips_left from public.passenger_my_passes()), 10, 'vuelve el viaje al saldo');
select t.expect_fail(format($q$select public.pass_cancel_ticket(%L)$q$, (select (r->>'ticket_id') from wused)), 'ALREADY_CANCELLED');
select t.logout();
select t.login('a9000000-0000-0000-0000-000000000002');
select t.expect_eq((select count(*) from public.passenger_my_passes()), 0::bigint, 'otro pasajero no ve abonos ajenos');
select t.expect_fail(format($q$select public.pass_redeem_web(%L, %L, %L, %L, '3')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'PASS_NOT_FOUND');
select t.logout();
-- vence antes de la salida del viaje
update public.passes set expires_at = timestamptz '2027-06-01' where id = (select (r->>'pass_id')::uuid from sold);
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '3')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'PASS_EXPIRES_BEFORE_TRIP');
select t.logout();
-- vencido
update public.passes set expires_at = now() - interval '1 hour' where id = (select (r->>'pass_id')::uuid from sold);
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '3')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'PASS_EXPIRED');
update public.passes set expires_at = now() + interval '365 days' where id = (select (r->>'pass_id')::uuid from sold);
select public.pass_void((select (r->>'pass_id')::uuid from sold), 'prueba de baja');
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '3')$q$, (select (r->>'pass_id') from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'PASS_NOT_FOUND');
select t.logout();
select 'PRUEBAS DE ABONOS PASARON';
