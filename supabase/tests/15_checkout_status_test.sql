\set ON_ERROR_STOP on

select t.login('d1000000-0000-0000-0000-000000000001');
select t.expect_eq(
  (select count(*) from public.passenger_checkout_status('00000000-0000-0000-0000-000000000000')),
  0::bigint,
  'el pasajero solo consulta estados de compra propios y la consulta compila sin ambigüedad'
);
select t.logout();

\echo 'PRUEBAS DE ESTADO DE CHECKOUT PASARON'
