\set ON_ERROR_STOP on

insert into public.companies (id, name, active)
values
  ('cccccccc-0000-0000-0000-000000000001', 'Empresa Sin Viajes', true),
  ('dddddddd-0000-0000-0000-000000000001', 'Empresa Suspendida', false);

select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_company_logo(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp'
);
select t.expect_eq(
  (select logo_path from public.passenger_companies()
    where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp',
  'el catálogo público incluye el logo de la empresa activa'
);
select t.logout();

insert into auth.users (id, email, raw_user_meta_data)
values ('d2000000-0000-0000-0000-000000000001', 'nuevo.pasajero@test.com', '{}'::jsonb);
select t.login('d2000000-0000-0000-0000-000000000001');
select public.save_passenger_profile('Pasajera', 'Nueva', '12345679', date '2000-01-02');
select t.expect_eq(
  (select first_name || ' ' || last_name || '|' || dni || '|' || email
     from public.passenger_profiles where user_id = auth.uid()),
  'Pasajera Nueva|12345679|nuevo.pasajero@test.com',
  'el pasajero puede completar un perfil faltante sin elegir otro correo'
);
select t.expect_fail(
  $q$select public.save_passenger_profile('A', 'Nueva', '12345679', date '2000-01-02')$q$,
  'PASSENGER_PROFILE_INVALID'
);
select t.logout();

select t.expect_eq(
  (select count(*) > 0 from public.public_search_trips(
    '77777777-0000-0000-0000-000000000001',
    '77777777-0000-0000-0000-000000000003',
    date '2026-11-21',
    'aaaaaaaa-0000-0000-0000-000000000001'
  )),
  true,
  'el filtro de empresa encuentra sus propios servicios'
);
select t.expect_eq(
  (select count(*) = 0 from public.public_search_trips(
    '77777777-0000-0000-0000-000000000001',
    '77777777-0000-0000-0000-000000000003',
    date '2026-11-21',
    'cccccccc-0000-0000-0000-000000000001'
  )),
  true,
  'el filtro de empresa no devuelve servicios de otras empresas'
);
select t.expect_eq(
  (select count(*) = 1 from public.passenger_companies()
    where company_id = 'cccccccc-0000-0000-0000-000000000001'),
  true,
  'el directorio lista las empresas activas'
);
select t.expect_eq(
  (select count(*) = 0 from public.passenger_companies()
    where company_id = 'dddddddd-0000-0000-0000-000000000001'),
  true,
  'el directorio oculta las empresas suspendidas'
);

\echo 'PRUEBAS DE PERFIL Y DIRECTORIO DE EMPRESAS PASARON'
