\set ON_ERROR_STOP on

select t.login('a1000000-0000-0000-0000-000000000001');
select public.generate_trips(date '2026-12-05', 'saturday');
select t.expect_eq((select count(*) from public.trips where service_date = date '2026-12-05' and published_at is not null), 0::bigint, 'los viajes generados quedan sin publicar');
select t.expect_eq((select count(*) from public.trips where service_date = date '2026-12-05' and published_at is null) > 0, true, 'hay viajes borrador');
select t.logout();

-- la web de compra no los ve
select t.login(null);
select t.expect_eq((select count(*) from public.public_company_trips('aaaaaaaa-0000-0000-0000-000000000001', null, null, date '2026-12-05', 1, 10)), 0::bigint, 'el listado por empresa no muestra borradores');
select t.logout();

-- publicar
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select public.publish_trips(date '2026-12-05') > 0), true, 'publicar devuelve la cantidad publicada');
select t.expect_eq((select count(*) from public.trips where service_date = date '2026-12-05' and published_at is null), 0::bigint, 'no quedan borradores');
select t.expect_eq((select public.publish_trips(date '2026-12-05')), 0, 'publicar dos veces no hace nada');
select t.logout();

-- un conductor no publica
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.publish_trips(date '2026-12-05')$q$, 'FORBIDDEN');
select t.logout();
select 'PRUEBAS DE PUBLICAR VIAJES PASARON';
