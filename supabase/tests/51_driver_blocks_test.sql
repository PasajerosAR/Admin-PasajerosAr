\set ON_ERROR_STOP on
begin;
update public.companies set blocked_features = '{}';
insert into auth.users (id, email) values ('a7000000-0000-0000-0000-000000000051', 'chofer.bloqueos@test');
insert into public.profiles (id, company_id, role, full_name) values ('a7000000-0000-0000-0000-000000000051', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer bloqueos');
-- el administrador general puede bloquear las funciones nuevas
select t.login('f0000000-0000-0000-0000-000000000001');
update public.companies set blocked_features = array['pay_cash', 'pay_transfer', 'pay_qr', 'clock'] where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.expect_eq((select array_length(blocked_features, 1) from public.companies where id = 'aaaaaaaa-0000-0000-0000-000000000001'), 4, 'se pueden bloquear las cuatro funciones nuevas');
select t.logout();
-- con el marcaje bloqueado no se exige marcar aunque haya zonas, y marcar falla
select t.expect_eq(public._clock_required('aaaaaaaa-0000-0000-0000-000000000001'), false, 'sin marcaje no se exige marcar');
select t.login('a7000000-0000-0000-0000-000000000051');
select t.expect_fail($q$select public.punch_shift('in', gen_random_uuid(), -31.7, -60.5, 10, now())$q$, 'FEATURE_BLOCKED');
-- la taquilla del conductor no cobra en efectivo ni por transferencia
select t.expect_fail($q$select public.taquilla_sell(gen_random_uuid(), 'cash', '[{"seat_label":"1"}]'::jsonb)$q$, 'FEATURE_BLOCKED');
select t.expect_fail($q$select public.taquilla_sell(gen_random_uuid(), 'transfer', '[{"seat_label":"1"}]'::jsonb)$q$, 'FEATURE_BLOCKED');
select t.logout();
rollback;
select 'PRUEBAS DE BLOQUEOS DEL CONDUCTOR PASARON';
