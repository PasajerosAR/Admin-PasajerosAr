\set ON_ERROR_STOP on
update public.companies set blocked_features = '{}';
create temp table vt as select t.id from public.trips t where t.service_date = date '2026-11-21' and t.driver_id = 'a2000000-0000-0000-0000-000000000001' limit 1;
grant all on vt to authenticated;
alter table public.layout_cells disable trigger user;
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, seat_class)
select t.layout_id, t.company_id, 1, 0, 8, 'seat', '9', 'Común' from public.trips t where t.id = (select id from vt)
   and not exists (select 1 from public.layout_cells c where c.layout_id = t.layout_id and c.label = '9');
alter table public.layout_cells enable trigger user;
-- ventanilla: el admin vende con debito y deja el correo del pasajero
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.taquilla_sell(%L, 'debit', '[{"seat_label":"9","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Ana Gomez","passenger_dni":"28999111","passenger_email":"no-es-correo"}]'::jsonb)$q$, (select id from vt)), 'PASSENGER_INVALID');
create temp table vs as
select public.taquilla_sell((select id from vt), 'debit',
  '[{"seat_label":"9","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Ana Gomez","passenger_dni":"28999111","passenger_email":"Ana@Mail.com"}]'::jsonb) as r;
grant all on vs to authenticated;
select t.expect_eq((select passenger_email from public.sale_tickets where sale_id = (select (r->>'sale_id')::uuid from vs)), 'ana@mail.com', 'guarda el correo del pasajero');
select t.expect_eq((select notes from public.sales where id = (select (r->>'sale_id')::uuid from vs)), 'Venta en ventanilla', 'queda marcada como venta de ventanilla');
select t.expect_eq((select source from public.ventanilla_find_passenger('28.999.111')), 'historial', 'encuentra al pasajero por DNI');
select t.expect_eq((select email from public.ventanilla_find_passenger('28999111')), 'ana@mail.com', 'devuelve el correo guardado');
select t.expect_eq((select sum(collected) > 0 from public.cash_close(now() - interval '1 year', now() + interval '1 year', null) where payment_method = 'debit'), true, 'el cierre de caja suma el debito');
select t.logout();
-- el conductor no cobra con debito
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.taquilla_sell(%L, 'debit', '[]'::jsonb)$q$, (select id from vt)), 'PAYMENT_INVALID');
select t.expect_fail($q$select * from public.cash_close(now() - interval '1 day', now(), null)$q$, 'FORBIDDEN');
select t.logout();
select 'PRUEBAS DE VENTANILLA PASARON';
