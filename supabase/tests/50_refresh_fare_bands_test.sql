\set ON_ERROR_STOP on
begin;
update public.companies set blocked_features = '{}';
-- un viaje futuro sin ventas toma la franja de una excepción nueva; con ventas la conserva
insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type, published_at)
select d.company_id, d.service_id, d.id, current_date + 40, public.departure_ts(current_date + 40, d.departure_time, d.next_day), 'weekday', null
  from public.service_departures d join public.services s on s.id = d.service_id
 where d.company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and 'weekday' = any (d.day_types) and s.active and d.active
 order by d.id limit 1;
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_fare_band(null, 'Especial', null);
select t.expect_eq((select count(*)::int from public.trips where service_date = current_date + 40 and fare_band = 'weekday'), 1, 'el viaje arranca en su franja base');
select public.save_fare_exception(current_date + 40, 0, 24, (select id from public.fare_bands where code = 'especial' and company_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select t.expect_eq((select count(*)::int from public.trips where service_date = current_date + 40 and fare_band = 'especial'), 1, 'la excepción nueva actualiza el viaje sin ventas');
select public.delete_fare_exception((select id from public.fare_band_exceptions where on_date = current_date + 40));
select t.expect_eq((select count(*)::int from public.trips where service_date = current_date + 40 and fare_band = 'weekday'), 1, 'al quitar la excepción vuelve a la franja base');
select t.logout();
rollback;
select 'PRUEBAS DE ACTUALIZACION DE FRANJAS PASARON';
