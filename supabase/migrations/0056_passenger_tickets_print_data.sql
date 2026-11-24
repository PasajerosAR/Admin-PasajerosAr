-- "Mis pasajes": agrega los datos de la compra (comprobante, punto de venta, medio de pago, emisión) y las localidades del recorrido,
-- para imprimir el mismo pasaje A4 que emite la ventanilla
drop function if exists public.passenger_my_tickets();
create function public.passenger_my_tickets()
returns table (
  ticket_id uuid, trip_id uuid, trip_status public.trip_status, service_code text, company_name text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop text, to_stop text,
  seat_label text, price numeric, passenger_name text, passenger_dni text,
  passenger_email text, qr_code text, ticket_status public.ticket_status,
  sale_id uuid, created_at timestamptz, pass_id uuid,
  route_origin text, route_destination text, receipt_number bigint, sales_channel text, payment_method text, issued_at timestamptz
)
language plpgsql security definer set search_path = public as $$
declare
  v_passenger public.passenger_profiles;
begin
  select * into v_passenger
    from public.passenger_profiles
   where passenger_profiles.user_id = auth.uid();
  if not found then return; end if;

  update public.sale_tickets as ticket
     set passenger_user_id = auth.uid()
   where ticket.passenger_user_id is null
     and lower(ticket.passenger_email) = lower(v_passenger.email)
     and regexp_replace(trim(ticket.passenger_dni), '[^0-9]', '', 'g') = v_passenger.dni;

  return query
  select ticket.id, trip.id, trip.status, service.code, company.name, route.name,
         trip.service_date, trip.scheduled_departure, from_stop.name, to_stop.name,
         ticket.seat_label, ticket.price, ticket.passenger_name, ticket.passenger_dni,
         ticket.passenger_email, ticket.qr_code, ticket.status, ticket.sale_id, ticket.created_at, ticket.pass_id,
         origin_place.name, destination_place.name, sale.receipt_number::bigint, sale.channel::text, sale.payment_method::text, sale.created_at
    from public.sale_tickets ticket
    join public.trips trip on trip.id = ticket.trip_id
    join public.services service on service.id = trip.service_id
    join public.companies company on company.id = trip.company_id
    join public.service_departures departure on departure.id = trip.departure_id
    join public.routes route on route.id = departure.route_id
    join public.places origin_place on origin_place.id = route.origin_place_id
    join public.places destination_place on destination_place.id = route.destination_place_id
    join public.sales sale on sale.id = ticket.sale_id
    join public.route_stops from_stop on from_stop.id = ticket.from_stop_id
    join public.route_stops to_stop on to_stop.id = ticket.to_stop_id
   where ticket.passenger_user_id = auth.uid()
      or ticket.pass_id in (select p.id from public.passes p where p.holder_dni = v_passenger.dni)
   order by ticket.created_at desc;
end
$$;
revoke all on function public.passenger_my_tickets() from public, anon;
grant execute on function public.passenger_my_tickets() to authenticated;

notify pgrst, 'reload schema';
