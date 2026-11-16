\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'vendedor.a@test'),
  ('f1000000-0000-0000-0000-000000000001', 'colaborador@test');
insert into auth.users (id, email, raw_user_meta_data)
values (
  'd1000000-0000-0000-0000-000000000001',
  'pasajero@test.com',
  jsonb_build_object(
    'account_type', 'passenger', 'first_name', 'Pasajero', 'last_name', 'Seguro',
    'dni', '12345678', 'birth_date', '1990-01-02'
  )
);
insert into public.profiles (id, company_id, role, full_name) values
  ('c1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'seller', 'Vendedor A'),
  ('f1000000-0000-0000-0000-000000000001', null, 'platform_staff', 'Colaborador');
insert into public.platform_permissions (profile_id, section, can_edit, granted_by)
values ('f1000000-0000-0000-0000-000000000001', 'reports', false, 'f0000000-0000-0000-0000-000000000001');

select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_ticket_price(
  '33333333-0000-0000-0000-000000000001', 1, 3, 2500, null
);
select public.save_ticket_price(
  '33333333-0000-0000-0000-000000000001', 1, 3, 2300, 'Comun'
);
select public.save_ticket_price(
  '33333333-0000-0000-0000-000000000001', 1, 3, 2300, 'Común'
);
select t.expect_eq(
  (select count(*) = 1
     from public.ticket_prices
    where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'
      and route_id = '33333333-0000-0000-0000-000000000001'
      and from_pos = 1 and to_pos = 3
      and public.normalize_seat_class(seat_class) = 'comun'),
  true,
  'guardar la misma clase con o sin tilde actualiza la tarifa existente'
);
select public.generate_trips(date '2026-11-21', 'saturday');
select t.logout();

update public.trips
   set vehicle_id = '22222222-0000-0000-0000-000000000001',
       layout_id = '11111111-0000-0000-0000-000000000001'
 where departure_id = (
   select id from public.service_departures
    where service_id = (select id from public.services where code = '218')
      and departure_time = time '05:00'
 ) and service_date = date '2026-11-21';
update public.route_stops set place_id = case id
  when '44444444-0000-0000-0000-000000000001' then '77777777-0000-0000-0000-000000000001'::uuid
  when '44444444-0000-0000-0000-000000000003' then '77777777-0000-0000-0000-000000000003'::uuid
  else place_id end
 where id in ('44444444-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000003');

create temp table sale_result as
select public.create_sale_with_tickets(
  (select id from public.trips where service_date = date '2026-11-21'
    and departure_id = (select id from public.service_departures
      where service_id = (select id from public.services where code = '218')
        and departure_time = time '05:00')),
  'cash',
  'Prueba de venta segura',
  jsonb_build_array(jsonb_build_object(
    'passenger_name', 'Pasajero Seguro',
    'passenger_dni', '12345678',
    'passenger_email', 'pasajero@test.com',
    'passenger_phone', '1122334455',
    'from_stop_id', '44444444-0000-0000-0000-000000000001',
    'to_stop_id', '44444444-0000-0000-0000-000000000003',
    'layout_cell_id', (select id from public.layout_cells
      where layout_id = '11111111-0000-0000-0000-000000000001' and label = '1'),
    'seat_label', 'ASIENTO-FALSO',
    'price', 0.01
  ))
) as result;
grant all on sale_result to authenticated;

select t.login('c1000000-0000-0000-0000-000000000001');
select t.expect_eq((select result->>'total' from sale_result), '2300',
  'el servidor aplica la tarifa de clase aunque la tilde sea distinta a la del asiento');
select t.expect_eq((select st.seat_label from public.sale_tickets st
  where st.sale_id = (select (result->>'sale_id')::uuid from sale_result)), '1',
  'el servidor obtiene la etiqueta del asiento desde el diseño');
select t.expect_fail(format(
  $q$select public.create_sale_with_tickets(%L, 'cash', null, %L::jsonb)$q$,
  (select trip_id from public.sales where id = (select (result->>'sale_id')::uuid from sale_result)),
  (select jsonb_build_array(jsonb_build_object(
    'passenger_name', 'Otro Pasajero', 'passenger_dni', '87654321',
    'passenger_email', 'otro@test.com', 'passenger_phone', '1199887766',
    'from_stop_id', '44444444-0000-0000-0000-000000000001',
    'to_stop_id', '44444444-0000-0000-0000-000000000003',
    'layout_cell_id', (select id from public.layout_cells
      where layout_id = '11111111-0000-0000-0000-000000000001' and label = '1')
  )))
), 'SEAT_TAKEN');

select public.cancel_sale_ticket(
  (select (ticket->>'id')::uuid from sale_result, jsonb_array_elements(result->'tickets') ticket),
  'Solicitud del pasajero'
);
select t.expect_eq((select status::text from public.sale_tickets
  where sale_id = (select (result->>'sale_id')::uuid from sale_result)), 'cancelled',
  'la cancelación se registra de forma transaccional');
select t.expect_eq((select status::text from public.sales
  where id = (select (result->>'sale_id')::uuid from sale_result)), 'refunded',
  'la venta pasa a devuelta cuando se cancelan todos sus pasajes');
select t.logout();

select t.login('d1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.passenger_my_tickets()), 1::bigint,
  'el pasajero encuentra sus pasajes asociados por DNI y correo');
select t.expect_eq((select count(*) from public.sale_tickets), 1::bigint,
  'el pasajero solo puede ver su pasaje asociado');
select t.expect_eq((select count(*) > 0 from public.public_search_trips(
  '77777777-0000-0000-0000-000000000001',
  '77777777-0000-0000-0000-000000000003',
  date '2026-11-21'
)), true, 'la búsqueda pública muestra viajes disponibles');
select t.logout();

select t.login('f1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.platform_permissions), 1::bigint,
  'el colaborador solo puede leer sus permisos asignados');
select t.expect_eq(public.has_platform_permission('reports'), true,
  'el permiso de lectura se reconoce');
select t.expect_eq(public.has_platform_permission('reports', true), false,
  'el permiso de solo lectura no habilita edición');
select t.expect_eq((select count(*) from public.companies), 0::bigint,
  'el colaborador no obtiene acceso a empresas sin permiso');
select t.logout();

\echo 'PRUEBAS DE VENTAS, PASAJEROS Y PERMISOS PASARON'
