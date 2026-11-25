\set ON_ERROR_STOP on
-- abonos por tipo de dia (H/S/D/F): el abono solo vale en los tipos de dia tildados
create temp table pt as
select t.id as trip_id, d.route_id from public.trips t join public.service_departures d on d.id = t.departure_id
 where t.service_date = date '2027-06-08' and t.layout_id is not null and t.company_id = 'aaaaaaaa-0000-0000-0000-000000000001'
 order by t.scheduled_departure limit 1;
grant all on pt to authenticated;
create temp table ps as
select (select id from public.route_stops where route_id = (select route_id from pt) order by position limit 1) as first_stop,
       (select id from public.route_stops where route_id = (select route_id from pt) order by position desc limit 1) as last_stop;
grant all on ps to authenticated;

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select cardinality(day_types) from public.pass_products where id = 'c1000000-0000-0000-0000-000000000001'), 4, 'los abonos existentes valen todos los dias');
insert into public.pass_products (id, company_id, place_a, place_b, trips, price, valid_days, day_types)
values ('c1000000-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-0000000000a1', '77777777-0000-0000-0000-0000000000a2', 5, 4000, 365, '{sunday,saturday,sunday}');
select t.expect_eq((select array_to_string(day_types, ',') from public.pass_products where id = 'c1000000-0000-0000-0000-000000000002'), 'saturday,sunday', 'los dias se guardan ordenados y sin repetir');
select t.expect_fail($q$insert into public.pass_products (company_id, place_a, place_b, trips, price, day_types) values ('aaaaaaaa-0000-0000-0000-000000000001', '77777777-0000-0000-0000-0000000000a1', '77777777-0000-0000-0000-0000000000a2', 5, 1, '{saturday,sunday}')$q$, 'pass_products_unique');
insert into public.pass_products (id, company_id, place_a, place_b, trips, price, valid_days, day_types)
values ('c1000000-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-0000000000a1', '77777777-0000-0000-0000-0000000000a2', 5, 3000, 365, '{weekday}');
select t.expect_fail($q$insert into public.pass_products (company_id, place_a, place_b, trips, price, day_types) values ('aaaaaaaa-0000-0000-0000-000000000001', '77777777-0000-0000-0000-0000000000a1', '77777777-0000-0000-0000-0000000000a2', 5, 1, '{}')$q$, 'day_types');

create temp table sold as
select public.pass_sell('c1000000-0000-0000-0000-000000000002', '30111222', 'Ana Gomez', null, 'cash') as fin,
       public.pass_sell('c1000000-0000-0000-0000-000000000003', '30111222', 'Ana Gomez', null, 'cash') as hab;
grant all on sold to authenticated;
select t.expect_eq((select count(*) from public.staff_find_passes('30111222') where day_types = '{saturday,sunday}'), 1::bigint, 'ventanilla ve los dias del abono');
-- el viaje del 2027-06-08 es dia habil
select t.expect_fail(format($q$select public.pass_redeem_counter(%L, %L, %L, %L, '5')$q$, (select fin->>'pass_id' from sold), (select trip_id from pt), (select first_stop from ps), (select last_stop from ps)), 'PASS_DAY_MISMATCH');
select t.expect_eq((select trips_left from public.staff_find_passes('30111222') where day_types = '{saturday,sunday}'), 5, 'el uso rechazado no descuenta viajes');
select public.pass_redeem_counter((hab->>'pass_id')::uuid, (select trip_id from pt), (select first_stop from ps), (select last_stop from ps), '1') from sold;
select t.expect_eq((select trips_left from public.staff_find_passes('30111222') where day_types = '{weekday}'), 4, 'el abono de dias habiles se usa un dia habil');
select t.expect_eq(public.trip_day_type((select trip_id from pt)), 'weekday', 'la web conoce el tipo de dia del viaje publicado');
select t.logout();
\echo 'PRUEBAS DE ABONOS POR TIPO DE DIA PASARON'
