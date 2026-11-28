\set ON_ERROR_STOP on
begin;
-- usuario: único por empresa, sin distinguir mayúsculas; el mismo puede existir en otra empresa
select t.login('a1000000-0000-0000-0000-000000000001');
select public.set_username('a2000000-0000-0000-0000-000000000001', 'V001');
select t.expect_fail($q$select public.set_username('a3000000-0000-0000-0000-000000000001', 'v001')$q$, 'USERNAME_TAKEN');
select t.expect_fail($q$select public.set_username('a3000000-0000-0000-0000-000000000001', 'con espacio')$q$, 'USERNAME_INVALID');
select t.expect_fail($q$select public.set_username('a3000000-0000-0000-0000-000000000001', 'a@b')$q$, 'USERNAME_INVALID');
select public.set_username('a3000000-0000-0000-0000-000000000001', '6');
select t.expect_fail($q$select public.set_username('b1000000-0000-0000-0000-000000000001', 'X1')$q$, 'FORBIDDEN');
select t.logout();
-- otra empresa puede usar el mismo nombre
select t.login('b1000000-0000-0000-0000-000000000001');
select public.set_username('b1000000-0000-0000-0000-000000000001', 'v001');
select t.expect_eq((select username from public.profiles where id = 'b1000000-0000-0000-0000-000000000001'), 'v001', 'otra empresa usa el mismo usuario');
select t.logout();
-- un conductor no cambia usuarios
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.set_username('a2000000-0000-0000-0000-000000000001', 'otro')$q$, 'FORBIDDEN');
select t.logout();
-- quitar el usuario
select t.login('a1000000-0000-0000-0000-000000000001');
select public.set_username('a3000000-0000-0000-0000-000000000001', '');
select t.expect_eq((select username from public.profiles where id = 'a3000000-0000-0000-0000-000000000001'), null::text, 'se puede quitar el usuario');
select t.logout();
rollback;
select 'PRUEBAS DE USUARIO PASARON';
