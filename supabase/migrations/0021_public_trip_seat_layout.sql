drop function if exists public.public_trip_seats(uuid, uuid, uuid);

create function public.public_trip_seats(
  p_trip uuid, p_from_stop uuid, p_to_stop uuid
) returns table (
  cell_id uuid, floor int, row_idx int, col_idx int, seat_label text,
  seat_class text, available boolean, price numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_route uuid;
  v_layout uuid;
  v_company uuid;
  v_from_pos int;
  v_to_pos int;
begin
  select d.route_id, t.layout_id, t.company_id into v_route, v_layout, v_company
    from public.trips t join public.service_departures d on d.id = t.departure_id
   where t.id = p_trip and t.status = 'scheduled' and t.scheduled_departure > now();
  if not found or v_layout is null then return; end if;
  select position into v_from_pos from public.route_stops where id = p_from_stop and route_id = v_route;
  select position into v_to_pos from public.route_stops where id = p_to_stop and route_id = v_route;
  if v_from_pos is null or v_to_pos is null or v_from_pos >= v_to_pos then
    raise exception 'STOPS_INVALID';
  end if;
  return query
  select cell.id, cell.floor, cell.row_idx, cell.col_idx, cell.label, cell.seat_class,
         not exists (
           select 1
             from public.sale_tickets st
             join public.route_stops booked_from on booked_from.id = st.from_stop_id
             join public.route_stops booked_to on booked_to.id = st.to_stop_id
            where st.trip_id = p_trip and st.seat_label = cell.label
              and st.status in ('valid', 'boarded')
              and booked_from.position < v_to_pos and booked_to.position > v_from_pos
         ) as available,
         coalesce(class_fare.price, base_fare.price) as price
    from public.layout_cells cell
    left join lateral (
      select tp.price from public.ticket_prices tp
       where tp.company_id = v_company and tp.route_id = v_route
         and tp.from_pos = v_from_pos and tp.to_pos = v_to_pos
         and tp.seat_class = cell.seat_class and tp.active
       order by tp.created_at desc limit 1
    ) class_fare on true
    left join lateral (
      select tp.price from public.ticket_prices tp
       where tp.company_id = v_company and tp.route_id = v_route
         and tp.from_pos = v_from_pos and tp.to_pos = v_to_pos
         and tp.seat_class is null and tp.active
       order by tp.created_at desc limit 1
    ) base_fare on true
   where cell.layout_id = v_layout and cell.kind = 'seat' and not cell.blocked and not cell.unusable
   order by cell.floor, cell.row_idx, cell.col_idx;
end
$$;

revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
