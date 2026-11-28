\set ON_ERROR_STOP on
-- Se corre justo después de la prueba 22 (mientras el servicio 218 existe) y se deshace al final para no alterar las siguientes.
begin;
update public.companies set blocked_features = '{}' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
-- La venta en taquilla del chofer (viaje en curso) suma al pasajero a bordo; la de ventanilla no.
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_ticket_price('33333333-0000-0000-0000-000000000001', 1, 3, 2500, null, d) from unnest(array['weekday', 'saturday', 'sunday', 'holiday']) d;
select public.generate_trips(current_date + 5, 'saturday');
select t.logout();
update public.trips
   set vehicle_id = '22222222-0000-0000-0000-000000000001',
       layout_id = '11111111-0000-0000-0000-000000000001',
       driver_id = 'a2000000-0000-0000-0000-000000000001'
 where departure_id = (select id from public.service_departures
    where service_id = (select id from public.services where code = '218') and departure_time = time '05:00')
   and service_date = current_date + 5;
alter table public.layout_cells disable trigger user;
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, seat_class)
select t.layout_id, t.company_id, 1, 0, 2, 'seat', '2', 'Común' from public.trips t
 where t.driver_id = 'a2000000-0000-0000-0000-000000000001' and t.layout_id is not null and t.service_date = current_date + 5
   and not exists (select 1 from public.layout_cells c where c.layout_id = t.layout_id and c.label = '2');
alter table public.layout_cells enable trigger user;
create temp table tb as
select t.id from public.trips t where t.service_date = current_date + 5 and t.driver_id = 'a2000000-0000-0000-0000-000000000001';
grant all on tb to authenticated;

-- viaje sin iniciar: se vende pero nadie sube todavía
select t.login('a2000000-0000-0000-0000-000000000001');
select public.taquilla_sell((select id from tb), 'cash',
  '[{"seat_label":"1","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Ana Gomez","passenger_dni":"30111001"}]'::jsonb);
select t.expect_eq((select status from public.sale_tickets where passenger_dni = '30111001'), 'valid', 'sin iniciar: queda valido');
select t.expect_eq(public.trip_onboard((select id from tb)), 0, 'sin iniciar: nadie a bordo');
select t.logout();

-- viaje en curso: el chofer vende y el pasajero queda a bordo
alter table public.trips disable trigger user;
update public.trips set status = 'in_progress', started_at = now() where id = (select id from tb);
alter table public.trips enable trigger user;
select t.login('a2000000-0000-0000-0000-000000000001');
create temp table tb_sale as
select public.taquilla_sell((select id from tb), 'cash',
  '[{"seat_label":"2","from_stop_id":"44444444-0000-0000-0000-000000000001","to_stop_id":"44444444-0000-0000-0000-000000000003","passenger_name":"Luis Diaz","passenger_dni":"30111002"}]'::jsonb) as r;
grant all on tb_sale to authenticated;
select t.expect_eq((select status from public.sale_tickets where passenger_dni = '30111002'), 'boarded', 'en curso: queda abordado');
select t.expect_eq(public.trip_onboard((select id from tb)), 1, 'en curso: suma a bordo');
select t.expect_eq((select (r->'tickets'->0->>'boarded')::boolean from tb_sale), true, 'la respuesta avisa que subio');
select t.expect_eq((select count(*)::int from public.passenger_counts where trip_id = (select id from tb) and kind = 'board'), 1, 'un solo ascenso registrado');
select t.expect_eq((select boarding_override from public.sale_tickets where passenger_dni = '30111002'), false, 'no es una autorizacion especial');
select t.logout();

rollback;
\echo 'PRUEBAS DE TAQUILLA A BORDO PASARON'
