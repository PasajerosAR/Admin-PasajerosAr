\set ON_ERROR_STOP on
update public.companies set blocked_features = '{}';
-- legajo: unico por empresa
select t.login('a1000000-0000-0000-0000-000000000001');
select public.set_legajo('a2000000-0000-0000-0000-000000000001', '214');
select t.expect_fail($q$select public.set_legajo('a3000000-0000-0000-0000-000000000001', '214')$q$, 'LEGAJO_DUPLICATE');
select t.expect_fail($q$select public.set_legajo('b1000000-0000-0000-0000-000000000001', '1')$q$, 'FORBIDDEN');
select t.logout();
-- mensajes: el admin envia, el conductor lee y marca leido
select t.login('a1000000-0000-0000-0000-000000000001');
create temp table m as select public.send_driver_message('Corte en Av. Ramírez', 'important', null) as id;
grant all on m to authenticated;
select t.expect_fail($q$select public.send_driver_message('', 'info', null)$q$, 'BODY_REQUIRED');
select t.expect_fail($q$select public.send_driver_message('x', 'raro', null)$q$, 'LEVEL_INVALID');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.driver_messages where id = (select id from m)), 1::bigint, 'el conductor lee el mensaje de su empresa');
select t.expect_fail($q$select public.send_driver_message('hola', 'info', null)$q$, 'FORBIDDEN');
select public.mark_messages_read(array[(select id from m)]);
select t.expect_eq((select count(*) from public.driver_message_reads where message_id = (select id from m)), 1::bigint, 'queda marcado como leido');
select t.logout();
-- otra empresa no ve el mensaje
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.driver_messages), 0::bigint, 'otra empresa no ve los mensajes');
select t.logout();
-- funcion GPS bloqueada
update public.companies set blocked_features = '{gps}' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.send_driver_message('hola', 'info', null)$q$, 'FEATURE_BLOCKED');
select t.logout();
update public.companies set blocked_features = '{}';
select 'PRUEBAS DE LEGAJO Y MENSAJES PASARON';
