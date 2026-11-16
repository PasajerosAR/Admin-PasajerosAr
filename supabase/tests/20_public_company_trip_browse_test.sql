\set ON_ERROR_STOP on

select t.expect_eq(
  (select count(*) = 1
     from public.public_company_trips(
       'aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 1
     )),
  true,
  'el listado paginado respeta el tamaño de página'
);
select t.expect_eq(
  (select total_count > 1
     from public.public_company_trips(
       'aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 1
     )),
  true,
  'el listado informa el total de salidas de la empresa'
);
select t.expect_eq(
  (select first_page.trip_id <> second_page.trip_id
     from public.public_company_trips(
       'aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 1, 1
     ) first_page
     cross join public.public_company_trips(
       'aaaaaaaa-0000-0000-0000-000000000001', null, null, null, 2, 1
     ) second_page),
  true,
  'las páginas consecutivas no repiten salidas'
);
select t.expect_eq(
  (select count(*) > 0
     from public.public_company_trips(
       'aaaaaaaa-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000003',
       date '2026-11-21',
       1,
       10
     )),
  true,
  'el listado permite filtrar la empresa por tramo y fecha'
);

\echo 'PRUEBAS DE LISTADO PAGINADO POR EMPRESA PASARON'
