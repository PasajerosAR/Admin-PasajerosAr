\set ON_ERROR_STOP on
-- Calendario de feriados de la empresa y generacion de varios dias.
create temp table hr as select ((now() at time zone 'America/Argentina/Buenos_Aires')::date + 170) as d;
grant all on hr to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');
insert into public.company_holidays (company_id, holiday_date, name) values (public.current_company_id(), (select d + 1 from hr), 'Feriado de prueba');
select t.expect_eq((select (jsonb_path_query_first(public.day_types_for_range((select d from hr), 3), '$[1].day_type') #>> '{}')), 'holiday', 'una fecha del calendario toma tipo feriado');
select t.expect_eq((select (jsonb_path_query_first(public.day_types_for_range((select d from hr), 3), '$[1].holiday') #>> '{}')), 'Feriado de prueba', 'se informa el nombre del feriado');
select t.expect_fail($q$select public.day_types_for_range(current_date, 61)$q$, 'RANGE_INVALID');
-- generar 3 dias de una vez, cada uno con su tipo
select t.expect_eq((select jsonb_array_length(public.generate_trips_range(array[(select d from hr), (select d + 1 from hr), (select d + 2 from hr)],
     array[public.day_type_of((select d from hr)), 'holiday', public.day_type_of((select d + 2 from hr))]))::text), '3', 'devuelve un resultado por fecha');
select t.expect_eq((select count(distinct day_type)::text from public.trips where company_id = public.current_company_id() and service_date = (select d + 1 from hr)), '1', 'el dia feriado tiene un solo tipo');
-- regenerar el feriado como otro tipo sin confirmar: se saltea y se informa
select t.expect_eq((select (public.generate_trips_range(array[(select d + 1 from hr)], array['sunday'])->0->>'status')), 'replace_required', 'sin confirmar no reemplaza');
select t.expect_eq((select (public.generate_trips_range(array[(select d + 1 from hr)], array['sunday'], true)->0->>'status')), 'ok', 'confirmado reemplaza');
select t.expect_fail($q$select public.generate_trips_range(array[current_date], array['weekday','sunday'])$q$, 'RANGE_INVALID');
-- publicar todo el rango
select t.expect_eq((select (public.publish_trips_range((select d from hr), (select d + 2 from hr)) > 0)::text), 'true', 'publica los tres dias');
-- otra empresa no ve ni carga feriados ajenos
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*)::text from public.company_holidays where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'), '0', 'otra empresa no ve los feriados');
select t.expect_fail($q$insert into public.company_holidays (company_id, holiday_date, name) values ('aaaaaaaa-0000-0000-0000-000000000001', current_date, 'x')$q$, 'row-level security');
select t.logout();
\echo 'PRUEBAS DE FERIADOS Y RANGO PASARON'
