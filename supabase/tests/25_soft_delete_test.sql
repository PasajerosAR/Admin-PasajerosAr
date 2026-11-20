\set ON_ERROR_STOP on
-- servicio con viajes: se oculta, conserva viajes y libera el número
select t.login('a1000000-0000-0000-0000-000000000001');
create temp table sv as select s.id, s.code from public.services s
 where s.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and exists (select 1 from public.trips x where x.service_id = s.id) limit 1;
grant all on sv to authenticated;
select t.expect_eq((select count(*) from sv), 1::bigint, 'hay un servicio con viajes');
select t.logout();
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress' where id = (select id from public.trips where service_id = (select id from sv) order by service_date desc limit 1);
alter table public.trips enable trigger user;
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.remove_service((select id from sv))$q$, 'SERVICE_IN_PROGRESS');
select t.logout();
alter table public.trips disable trigger user;
update public.trips set status = 'completed' where service_id = (select id from sv) and status = 'in_progress';
alter table public.trips enable trigger user;
select t.login('a1000000-0000-0000-0000-000000000001');
select public.remove_service((select id from sv));
select t.expect_eq((select deleted_at is not null and not active from public.services where id = (select id from sv)), true, 'queda oculto y pausado');
select t.expect_eq((select count(*) > 0 from public.trips where service_id = (select id from sv)), true, 'los viajes se conservan');
select t.expect_eq((select count(*) from public.trips where service_id = (select id from sv) and status = 'scheduled' and service_date >= current_date), 0::bigint, 'los viajes futuros se cancelan');
select t.expect_fail($q$select public.remove_service((select id from sv))$q$, 'NOT_FOUND');
select t.logout();
-- empresa: solo el administrador general
select t.login('f0000000-0000-0000-0000-000000000001');
select public.remove_company('bbbbbbbb-0000-0000-0000-000000000001');
select t.expect_eq((select deleted_at is not null and not active from public.companies where id = 'bbbbbbbb-0000-0000-0000-000000000001'), true, 'empresa eliminada y suspendida');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.remove_company('aaaaaaaa-0000-0000-0000-000000000001')$q$, 'FORBIDDEN');
select t.logout();
select 'PRUEBAS DE ELIMINAR SERVICIOS Y EMPRESAS PASARON';
