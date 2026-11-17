\set ON_ERROR_STOP on

-- Estado inicial: ninguna empresa tiene bloqueos y todo sigue funcionando como antes.
select t.expect_eq((select blocked_features from public.companies where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  '{}'::text[], 'por defecto una empresa no tiene bloqueos');
select t.expect_eq((select count(*) > 0 from public.passenger_companies() where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  true, 'sin bloqueos la empresa aparece en la web de venta');

select t.login('f0000000-0000-0000-0000-000000000001');
select t.expect_fail(
  $q$update public.companies set blocked_features = array['gps', 'inventada'] where id = 'aaaaaaaa-0000-0000-0000-000000000001'$q$,
  'FEATURE_UNKNOWN');
update public.companies
   set blocked_features = array['web', 'gps', 'scanner', 'fares', 'incidents', 'counter', 'web']
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.expect_eq((select blocked_features from public.companies where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  array['counter', 'fares', 'gps', 'incidents', 'scanner', 'web'], 'los bloqueos se guardan ordenados y sin repetir');
select t.expect_eq((select count(*) from public.admin_live_trips(null) where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0::bigint, 'con GPS bloqueado la empresa no aparece en el mapa del admin');
select t.logout();

-- web de venta
select t.expect_eq((select count(*) from public.passenger_companies() where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0::bigint, 'con web bloqueada la empresa no aparece en el listado');
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 10)),
  0::bigint, 'con web bloqueada no se listan sus viajes');
select t.expect_fail(format($q$select * from public.public_trip_seats(%L, null, null)$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select public.begin_passenger_checkout(gen_random_uuid(), %L, null, null, '[]'::jsonb, null)$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_eq((select count(*) from public.public_trip_live_position(
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1))),
  0::bigint, 'con web o GPS bloqueados no se ve la unidad en la web');

-- app del conductor
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.report_incident(%L, 'delay')$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select public.register_count(%L, 'board', 1, null, gen_random_uuid())$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select public.create_test_tickets(%L, 2)$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select public.scan_ticket(%L, 'x', gen_random_uuid(), null, null, null, null)$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail(format($q$select public.update_trip_live_position(%L, -31.7, -60.5, 10, null, now())$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.logout();

-- ventas y tarifas
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.create_sale_with_tickets(%L, 'cash', null, '[]'::jsonb)$q$,
  (select id from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' limit 1)), 'FEATURE_BLOCKED');
select t.expect_fail($q$select public.save_ticket_price(gen_random_uuid(), 1, 2, 100, 'standard')$q$, 'FEATURE_BLOCKED');
select t.logout();

-- otra empresa no se ve afectada
select t.expect_eq((select count(*) from public.passenger_companies() where company_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  1::bigint, 'los bloqueos de una empresa no afectan a otra');

-- se pueden volver a habilitar
select t.login('f0000000-0000-0000-0000-000000000001');
update public.companies set blocked_features = '{}' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.logout();
select t.expect_eq((select count(*) > 0 from public.passenger_companies() where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  true, 'al quitar los bloqueos la empresa vuelve a aparecer');
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 10)),
  (select count(*) from public._public_company_trips_impl('aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 10)),
  'y vuelven a listarse sus viajes (igual que la función original)');

\echo 'PRUEBAS DE BLOQUEO DE FUNCIONES POR EMPRESA PASARON'
