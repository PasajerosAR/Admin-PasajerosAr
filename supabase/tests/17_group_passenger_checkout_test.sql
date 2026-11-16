\set ON_ERROR_STOP on

insert into public.mp_company_connections (
  company_id, mp_user_id, test_mode, access_token_encrypted, refresh_token_encrypted,
  token_expires_at, connected_by
) values (
  'aaaaaaaa-0000-0000-0000-000000000001', 'mp-test-account', true, 'encrypted-access',
  'encrypted-refresh', now() + interval '1 day', 'a1000000-0000-0000-0000-000000000001'
);

select set_config('test.uid', 'd1000000-0000-0000-0000-000000000001', false);
select set_config('test.role', 'service_role', false);

create temp table group_checkout as
select public.begin_passenger_checkout(
  'd1000000-0000-0000-0000-000000000001',
  (select id from public.trips
    where service_date = date '2026-11-21'
      and departure_id = (
        select id from public.service_departures
         where service_id = (select id from public.services where code = '218')
           and departure_time = time '05:00'
      )),
  '44444444-0000-0000-0000-000000000001',
  '44444444-0000-0000-0000-000000000003',
  jsonb_build_array(
    jsonb_build_object(
      'layout_cell_id', (select id from public.layout_cells
        where layout_id = '11111111-0000-0000-0000-000000000001' and label = '2')
    ),
    jsonb_build_object(
      'layout_cell_id', (select id from public.layout_cells
        where layout_id = '11111111-0000-0000-0000-000000000001' and label = '3'),
      'passenger_name', 'Acompañante Dos',
      'passenger_dni', '87654321',
      'passenger_email', 'acompanante@test.com'
    )
  ),
  '1122334455'
) as result;

select t.expect_eq((select (result->>'price')::numeric = 4600 from group_checkout), true,
  'el checkout suma las tarifas de todos los pasajeros');
select t.expect_eq(
  (select count(*) = 2 from public.passenger_checkout_order_tickets
    where order_id = (select (result->>'order_id')::uuid from group_checkout)),
  true,
  'la compra reserva los asientos de todos los pasajeros'
);
select t.expect_eq(
  (select not available
     from public.public_trip_seats(
       (select trip_id from public.passenger_checkout_orders
         where id = (select (result->>'order_id')::uuid from group_checkout)),
       '44444444-0000-0000-0000-000000000001',
       '44444444-0000-0000-0000-000000000003'
     )
    where seat_label = '2'),
  true,
  'el primer asiento queda reservado mientras se paga'
);

create temp table group_finalized as
select public.finalize_passenger_checkout(
  (select (result->>'order_id')::uuid from group_checkout),
  'test-payment-group-1',
  4600,
  'ARS'
) as result;

select t.expect_eq((select result->>'status' from group_finalized), 'approved',
  'el pago aprobado finaliza la compra grupal');
select t.expect_eq(
  (select count(*) = 2 from public.sale_tickets
    where sale_id = (select (result->>'sale_id')::uuid from group_finalized)),
  true,
  'un pago aprobado emite un pasaje por cada pasajero');
select t.expect_eq(
  (select count(distinct passenger_name) = 2 from public.sale_tickets
    where sale_id = (select (result->>'sale_id')::uuid from group_finalized)),
  true,
  'cada pasaje conserva los datos de su pasajero');

\echo 'PRUEBAS DE COMPRA GRUPAL PASARON'
