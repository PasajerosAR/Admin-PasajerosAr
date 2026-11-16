\set ON_ERROR_STOP on

select t.expect_eq(
  public.normalize_seat_class('Comun'),
  public.normalize_seat_class('Común'),
  'comun',
  'las clases de tarifa coinciden aunque difieran los acentos'
);
select t.expect_eq(
  (select count(*) = count(distinct trip_id)
     from public.public_search_trips(
       '77777777-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000003',
       date '2026-11-21'
     )),
  true,
  'la búsqueda devuelve cada viaje una sola vez aunque existan varias paradas en la localidad'
);
select t.expect_eq(
  (select count(*) > 0
     from public.public_search_trips(
       '77777777-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000003',
       date '2026-11-21'
     )
    where price = 2300),
  true,
  'la búsqueda muestra tarifas activas configuradas para el tramo y localidad'
);
select t.expect_eq(
  (select count(*) >= 2 and bool_and(place_id in (
       '77777777-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000003'
     ))
     from public.public_trip_city_stops(
       (select trip_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1),
       '77777777-0000-0000-0000-000000000001',
       '77777777-0000-0000-0000-000000000003'
     )),
  true,
  'las paradas disponibles pertenecen únicamente a las localidades elegidas y al viaje'
);
select t.expect_eq(
  (select seat.col_idx = layout.col_idx + 1
          and seat.cell_kind = layout.kind::text
     from public.public_trip_seats(
       (select trip_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1),
       (select from_stop_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1),
       (select to_stop_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1)
     ) seat
     join public.layout_cells layout on layout.id = seat.cell_id
    where layout.kind = 'seat'
    order by layout.floor, layout.row_idx, layout.col_idx
    limit 1),
  true,
  'el plano público conserva las coordenadas de la grilla de asientos'
);
select t.expect_eq(
  (select count(*) > 0
     from public.public_trip_seats(
       (select trip_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1),
       (select from_stop_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000001',
         '77777777-0000-0000-0000-000000000003',
         date '2026-11-21'
       ) limit 1),
       (select to_stop_id from public.public_search_trips(
         '77777777-0000-0000-0000-000000000003',
         '77777777-0000-0000-0000-000000000001',
         date '2026-11-21'
       ) limit 1)
     )
    where cell_kind = 'seat' and price = 2300),
  true,
  'el precio coincide con la clase del asiento aun si la tarifa se guardó sin acento'
);

\echo 'PRUEBAS DE BÚSQUEDA POR LOCALIDAD PASARON'
