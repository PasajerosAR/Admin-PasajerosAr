\set ON_ERROR_STOP on
-- "Publicar todos": publica todos los borradores de la empresa desde hoy, de cualquier fecha.
create temp table pa as select ((now() at time zone 'America/Argentina/Buenos_Aires')::date + 200) as d;
grant all on pa to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');
select public.generate_trips_range(array[(select d from pa), (select d + 1 from pa)], array['weekday','weekday']);
select t.expect_eq((select count(*)::text from public.trips where company_id = public.current_company_id() and service_date between (select d from pa) and (select d + 1 from pa) and published_at is null), (select count(*)::text from public.trips where company_id = public.current_company_id() and service_date between (select d from pa) and (select d + 1 from pa)), 'quedan como borrador');
select public.publish_all_trips();
select t.expect_eq((select count(*)::text from public.trips where company_id = public.current_company_id() and service_date >= current_date and status = 'scheduled' and published_at is null), '0', 'no queda ningun borrador futuro');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*)::text from public.trips where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and published_at is null and service_date >= current_date), '0', 'otra empresa no ve borradores ajenos');
select t.logout();
\echo 'PRUEBAS DE PUBLICAR TODOS PASARON'
