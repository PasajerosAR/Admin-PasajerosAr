\set ON_ERROR_STOP on
begin;
select t.expect_eq((select login_code ~ '^[0-9]+$' from public.companies where id = 'aaaaaaaa-0000-0000-0000-000000000001'), true, 'la empresa tiene un código automático');
insert into public.companies (name) values ('Empresa Nueva Codigo');
select t.expect_eq((select count(distinct login_code) from public.companies), (select count(*) from public.companies), 'los códigos no se repiten');
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.set_company_login_code('aaaaaaaa-0000-0000-0000-000000000001', 'X1')$q$, 'FORBIDDEN');
select t.logout();
select t.login('f0000000-0000-0000-0000-000000000001');
select public.set_company_login_code('aaaaaaaa-0000-0000-0000-000000000001', 'Emanuel');
select t.expect_fail($q$select public.set_company_login_code('aaaaaaaa-0000-0000-0000-000000000001', 'con espacio')$q$, 'CODE_INVALID');
select t.expect_fail($q$select public.set_company_login_code((select id from public.companies where name = 'Empresa Nueva Codigo'), 'EMANUEL')$q$, 'CODE_TAKEN');
select t.logout();
rollback;
select 'PRUEBAS DE CODIGO DE EMPRESA PASARON';
