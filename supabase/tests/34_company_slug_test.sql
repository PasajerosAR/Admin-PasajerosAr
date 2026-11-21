\set ON_ERROR_STOP on
-- enlace corto de empresa
insert into public.companies (name) values ('Transporte Emanuel'), ('Transporte  Emanuel!'), ('Ñandú Viajes S.A.'), ('***');
select t.expect_eq((select slug from public.companies where name = 'Transporte Emanuel'), 'Transporte_Emanuel', 'slug desde el nombre');
select t.expect_eq((select slug from public.companies where name = 'Transporte  Emanuel!'), 'Transporte_Emanuel_2', 'no se repite');
select t.expect_eq((select slug from public.companies where name = 'Ñandú Viajes S.A.'), 'Nandu_Viajes_S_A', 'sin tildes ni simbolos');
select t.expect_eq((select slug from public.companies where name = '***'), 'Empresa', 'nombre sin letras');
select t.expect_fail($q$insert into public.companies (name, slug) values ('Otra', 'transporte_emanuel')$q$, 'duplicate key');
select t.expect_eq((select count(*) from public.passenger_companies() where slug = 'Transporte_Emanuel'), 1::bigint, 'el directorio publico trae el slug');
select 'PRUEBAS DE ENLACE DE EMPRESA PASARON';
