\set ON_ERROR_STOP on

select t.login('f1000000-0000-0000-0000-000000000001');
select t.expect_fail(
  $q$insert into storage.objects (bucket_id, name)
     values ('company-logos', 'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp')$q$,
  'row-level security'
);
select t.expect_fail(
  $q$select public.save_company_logo(
       'aaaaaaaa-0000-0000-0000-000000000001',
       'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp'
     )$q$,
  'FORBIDDEN'
);
select t.logout();

insert into public.platform_permissions (profile_id, section, can_edit, granted_by)
values (
  'f1000000-0000-0000-0000-000000000001',
  'companies',
  true,
  'f0000000-0000-0000-0000-000000000001'
);

select t.login('f1000000-0000-0000-0000-000000000001');
insert into storage.objects (bucket_id, name)
values (
  'company-logos',
  'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp'
);
select public.save_company_logo(
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp'
);
select t.expect_eq(
  (select logo_path from public.companies where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001/11111111-2222-3333-4444-555555555555.webp',
  'el colaborador con permiso puede subir un logo'
);
select t.logout();

\echo 'PRUEBAS DE PERMISOS DE LOGOS PASARON'
