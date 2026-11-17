\set ON_ERROR_STOP on

-- viaje con disposición y tarifa (misma preparación que la prueba de ventas)
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 3, 2500, null);
select public.generate_trips(date '2026-11-21', 'saturday');
select t.logout();
update public.trips
   set vehicle_id = '22222222-0000-0000-0000-000000000001',
       layout_id = '11111111-0000-0000-0000-000000000001',
       driver_id = 'a2000000-0000-0000-0000-000000000001'
 where departure_id = (select id from public.service_departures
    where service_id = (select id from public.services where code = '218') and departure_time = time '05:00')
   and service_date = date '2026-11-21';
-- el viaje usa una copia de la disposición: se asegura que tenga el asiento 2
alter table public.layout_cells disable trigger user;
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, seat_class)
select t.layout_id, t.company_id, 1, 0, 2, 'seat', '2', 'Común' from public.trips t
 where t.driver_id = 'a2000000-0000-0000-0000-000000000001' and t.layout_id is not null and t.service_date = date '2026-11-21'
   and not exists (select 1 from public.layout_cells c where c.layout_id = t.layout_id and c.label = '2');
alter table public.layout_cells enable trigger user;
create temp table tq as
select t.id from public.trips t where t.service_date = date '2026-11-21'
  and t.departure_id = (select id from public.service_departures
    where service_id = (select id from public.services where code = '218') and departure_time = time '05:00');
grant all on tq to authenticated;


-- el chofer reserva y vende (sin nombre/DNI no se emite)

select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((select public.taquilla_hold_seats((select id from tq),
  '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003"}]'::jsonb) is not null),
  true, 'el chofer reserva un asiento');
select t.expect_eq((select count(*) from public.taquilla_seat_status((select id from tq)) where kind = 'hold' and mine), 1::bigint,
  'la reserva propia aparece como propia');
select t.expect_fail(format($q$select public.taquilla_sell(%L, 'mp', '[]'::jsonb)$q$, (select id from tq)), 'PAYMENT_INVALID');
select t.expect_fail(format($q$select public.taquilla_sell(%L, 'cash', '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003"}]'::jsonb)$q$, (select id from tq)), 'PASSENGER_INVALID');
create temp table tq_sale as
select public.taquilla_sell((select id from tq), 'cash',
  '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Juan Perez","passenger_dni":"30111222"}]'::jsonb) as r;
grant all on tq_sale to authenticated;
select t.expect_eq((select r->>'total' from tq_sale), '2500.00', 'la taquilla cobra la tarifa del tramo');
select t.expect_eq((select passenger_name || ' ' || passenger_dni from public.sale_tickets where sale_id = (select (r->>'sale_id')::uuid from tq_sale)), 'Juan Perez 30111222', 'queda registrado nombre y DNI');
select t.expect_eq((select count(*) from public.taquilla_seat_status((select id from tq)) where kind = 'sold'), 1::bigint,
  'la venta aparece como vendida');
select t.expect_eq((select count(*) from public.taquilla_seat_status((select id from tq)) where kind = 'hold'), 0::bigint,
  'al vender se libera la reserva');
select t.expect_fail(format($q$select public.taquilla_sell(%L, 'transfer', '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Otro Pasajero","passenger_dni":"30111223"}]'::jsonb)$q$,
  (select id from tq)), 'SEAT_TAKEN');
select t.logout();

-- reserva del chofer sobre otro asiento: la ventanilla no puede vender ese asiento
select t.login('a2000000-0000-0000-0000-000000000001');
select public.taquilla_hold_seats((select id from tq),
  '[{"seat_label":"2","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003"}]'::jsonb);
select t.logout();
select t.login('c1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.create_sale_with_tickets(%L, 'cash', null, %L::jsonb)$q$, (select id from tq),
  (select jsonb_build_array(jsonb_build_object('passenger_name','Pasajero Dos','passenger_dni','12345678',
    'passenger_email','p@test.com','passenger_phone','1122334455',
    'from_stop_id','44444444-0000-0000-0000-000000000001','to_stop_id','44444444-0000-0000-0000-000000000003',
    'layout_cell_id',(select c.id from public.layout_cells c join public.trips x on x.layout_id = c.layout_id where x.id = (select id from tq) and c.label = '2')))::text)),
  'SEAT_TAKEN');
select t.logout();

-- vencida la reserva, queda libre
update public.seat_holds set expires_at = now() - interval '1 minute';
select t.login('c1000000-0000-0000-0000-000000000001');
select t.expect_eq((select (public.create_sale_with_tickets((select id from tq), 'cash', null,
  jsonb_build_array(jsonb_build_object('passenger_name','Pasajero Dos','passenger_dni','12345678',
    'passenger_email','p@test.com','passenger_phone','1122334455',
    'from_stop_id','44444444-0000-0000-0000-000000000001','to_stop_id','44444444-0000-0000-0000-000000000003',
    'layout_cell_id',(select c.id from public.layout_cells c join public.trips x on x.layout_id = c.layout_id where x.id = (select id from tq) and c.label = '2'))))) ->> 'total') is not null,
  true, 'con la reserva vencida la ventanilla puede vender');
select t.logout();

-- bloqueo de tarifas, ventas y taquilla (una sola clave)
update public.companies set blocked_features = array['fares'] where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.taquilla_hold_seats(%L, '[]'::jsonb)$q$, (select id from tq)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select * from public.taquilla_seat_status(%L)$q$, (select id from tq)), 'FEATURE_BLOCKED');
select t.logout();
select 'PRUEBAS DE TAQUILLA Y RESERVAS PASARON';
