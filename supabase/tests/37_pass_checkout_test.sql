\set ON_ERROR_STOP on
-- compra online de abonos: catalogo, pedido, aprobacion y duplicados
update public.companies set blocked_features = '{}';
insert into public.mp_company_connections (company_id, mp_user_id, test_mode, access_token_encrypted, refresh_token_encrypted, token_expires_at, connected_by)
values ('aaaaaaaa-0000-0000-0000-000000000001', '123', true, 'x', 'y', now() + interval '1 day', 'a1000000-0000-0000-0000-000000000001')
on conflict (company_id) do update set active = true;
insert into public.pass_products (id, company_id, place_a, place_b, trips, price, valid_days)
values ('c2000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        least('77777777-0000-0000-0000-0000000000a1'::text, '77777777-0000-0000-0000-0000000000a2'::text)::uuid,
        greatest('77777777-0000-0000-0000-0000000000a1'::text, '77777777-0000-0000-0000-0000000000a2'::text)::uuid, 15, 9000, 30);
select t.expect_eq((select count(*) from public.passenger_pass_catalog() where product_id = 'c2000000-0000-0000-0000-000000000001'), 1::bigint, 'el catalogo publico muestra el abono');
update public.companies set blocked_features = array['web'];
select t.expect_eq((select count(*) from public.passenger_pass_catalog() where product_id = 'c2000000-0000-0000-0000-000000000001'), 0::bigint, 'empresa sin web no aparece');
update public.companies set blocked_features = '{}';

select t.login('a9000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.begin_pass_checkout('a9000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001')$q$, 'permission denied');
select t.logout();
select set_config('test.role', 'service_role', false);
create temp table ord as select public.begin_pass_checkout('a9000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001') as r;
grant all on ord to authenticated;
select t.expect_eq((select (r->>'price')::numeric from ord), 9000::numeric, 'el pedido toma el precio del producto');
select t.expect_fail($q$select public.finalize_pass_checkout((select (r->>'order_id')::uuid from ord), 'pay-1', 100, 'ARS')$q$, 'PAYMENT_AMOUNT_INVALID');
select public.finalize_pass_checkout((select (r->>'order_id')::uuid from ord), 'pay-1', 9000, 'ARS');
select t.expect_eq((select status from public.pass_checkout_orders where id = (select (r->>'order_id')::uuid from ord)), 'approved', 'pedido aprobado');
-- el aviso llega dos veces: no duplica el abono
select public.finalize_pass_checkout((select (r->>'order_id')::uuid from ord), 'pay-1', 9000, 'ARS');
select t.expect_eq((select count(*) from public.passes where holder_dni = (select dni from public.passenger_profiles where user_id = 'a9000000-0000-0000-0000-000000000001') and payment_method = 'mp'), 1::bigint, 'un solo abono por pago');
select set_config('test.role', '', false);
select t.login('a9000000-0000-0000-0000-000000000001');
select t.expect_eq((select trips_left from public.passenger_my_passes() where trips_total = 15 limit 1), 15, 'el pasajero ve el abono comprado');
select t.expect_eq((select status from public.pass_checkout_status((select (r->>'order_id')::uuid from ord))), 'approved', 'estado del pedido');
select t.logout();
-- un pedido cancelado que luego se paga pide devolucion
select set_config('test.role', 'service_role', false);
create temp table ord2 as select public.begin_pass_checkout('a9000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001') as r;
select public.fail_pass_checkout((select (r->>'order_id')::uuid from ord2));
select t.expect_eq((public.finalize_pass_checkout((select (r->>'order_id')::uuid from ord2), 'pay-2', 9000, 'ARS'))->>'status', 'refund_required', 'pago de un pedido cancelado se devuelve');
select set_config('test.role', '', false);
select 'PRUEBAS DE COMPRA ONLINE DE ABONOS PASARON';
