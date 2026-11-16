-- Checkout Pro en modo test para ventas del portal de pasajeros.

alter table public.sales alter column seller_id drop not null;
alter table public.sales
  add column channel text not null default 'counter'
  check (channel in ('counter', 'web'));
create unique index sales_mp_payment_unique
  on public.sales (mp_payment_id) where mp_payment_id is not null;

create table public.mp_company_connections (
  company_id uuid primary key references public.companies (id) on delete cascade,
  mp_user_id text not null,
  test_mode boolean not null check (test_mode),
  access_token_encrypted text not null,
  refresh_token_encrypted text not null,
  token_expires_at timestamptz not null,
  connected_by uuid not null references public.profiles (id),
  connected_at timestamptz not null default now(),
  active boolean not null default true
);
alter table public.mp_company_connections enable row level security;
revoke all on public.mp_company_connections from public, anon, authenticated;
grant all on public.mp_company_connections to service_role;

create table public.mp_oauth_states (
  state_hash text primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  initiated_by uuid not null references public.profiles (id) on delete cascade,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.mp_oauth_states enable row level security;
revoke all on public.mp_oauth_states from public, anon, authenticated;
grant all on public.mp_oauth_states to service_role;

create table public.passenger_checkout_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  mp_connection_id uuid not null references public.mp_company_connections (company_id),
  passenger_user_id uuid not null references auth.users (id) on delete cascade,
  trip_id uuid not null references public.trips (id),
  from_stop_id uuid not null references public.route_stops (id),
  to_stop_id uuid not null references public.route_stops (id),
  layout_cell_id uuid not null references public.layout_cells (id),
  seat_label text not null,
  passenger_name text not null,
  passenger_dni text not null,
  passenger_email text not null,
  passenger_phone text not null,
  price numeric(10, 2) not null check (price > 0),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'cancelled', 'expired', 'refund_required')),
  refund_status text check (refund_status in ('pending', 'refunded', 'failed')),
  preference_id text,
  checkout_url text,
  mp_payment_id text unique,
  sale_id uuid references public.sales (id) on delete set null,
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  created_at timestamptz not null default now(),
  constraint passenger_checkout_stops_distinct check (from_stop_id <> to_stop_id)
);
create index passenger_checkout_trip_hold_idx
  on public.passenger_checkout_orders (trip_id, seat_label, expires_at)
  where status = 'pending';
create index passenger_checkout_passenger_idx
  on public.passenger_checkout_orders (passenger_user_id, created_at desc);
alter table public.passenger_checkout_orders enable row level security;
revoke all on public.passenger_checkout_orders from public, anon, authenticated;
grant all on public.passenger_checkout_orders to service_role;

create function public.reject_ticket_for_held_seat()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_route_id uuid;
  v_from_pos int;
  v_to_pos int;
  v_channel text;
begin
  if new.seat_label is null then return new; end if;
  select channel into v_channel from public.sales where id = new.sale_id;
  if v_channel = 'web' then return new; end if;

  select route_id into v_route_id from public.service_departures
   where id = (select departure_id from public.trips where id = new.trip_id);
  select position into v_from_pos from public.route_stops
   where id = new.from_stop_id and route_id = v_route_id;
  select position into v_to_pos from public.route_stops
   where id = new.to_stop_id and route_id = v_route_id;
  if exists (
    select 1 from public.passenger_checkout_orders held
      join public.route_stops held_from on held_from.id = held.from_stop_id
      join public.route_stops held_to on held_to.id = held.to_stop_id
     where held.trip_id = new.trip_id and held.seat_label = new.seat_label
       and held.status = 'pending' and held.expires_at > clock_timestamp()
       and held_from.position < v_to_pos and held_to.position > v_from_pos
  ) then raise exception 'SEAT_RESERVED: el asiento está reservado durante un pago web'; end if;
  return new;
end
$$;
revoke all on function public.reject_ticket_for_held_seat() from public, anon, authenticated;
create trigger reject_ticket_for_held_seat
  before insert on public.sale_tickets
  for each row execute function public.reject_ticket_for_held_seat();

create function public.mp_company_connection_status()
returns table (connected boolean, mp_user_id text, connected_at timestamptz, test_mode boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.current_user_role() is distinct from 'company_admin' then raise exception 'FORBIDDEN'; end if;
  return query
  select coalesce(connection.active, false), connection.mp_user_id,
         connection.connected_at, coalesce(connection.test_mode, true)
    from (select public.current_company_id() as company_id) company
    left join public.mp_company_connections connection
      on connection.company_id = company.company_id and connection.active;
end
$$;
revoke all on function public.mp_company_connection_status() from public, anon;
grant execute on function public.mp_company_connection_status() to authenticated;

create function public.begin_passenger_checkout(
  p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_layout_cell uuid, p_phone text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_passenger public.passenger_profiles;
  v_company_id uuid;
  v_route_id uuid;
  v_route_name text;
  v_service_code text;
  v_from_pos int;
  v_to_pos int;
  v_seat_label text;
  v_seat_class text;
  v_price numeric(10, 2);
  v_order_id uuid;
  v_expires_at timestamptz;
  v_from_name text;
  v_to_name text;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  if p_user is null or p_trip is null or p_from_stop is null or p_to_stop is null
     or p_layout_cell is null or length(trim(coalesce(p_phone, ''))) < 7 then
    raise exception 'CHECKOUT_INVALID';
  end if;

  select * into v_passenger from public.passenger_profiles where user_id = p_user;
  if not found then raise exception 'PASSENGER_PROFILE_REQUIRED'; end if;

  select * into v_trip from public.trips
   where id = p_trip and status = 'scheduled' and scheduled_departure > clock_timestamp()
   for update;
  if not found then raise exception 'TRIP_UNAVAILABLE'; end if;
  v_company_id := v_trip.company_id;
  if not exists (
    select 1 from public.mp_company_connections
     where company_id = v_company_id and active and test_mode
  ) then raise exception 'MERCADOPAGO_NOT_CONNECTED'; end if;

  select departure.route_id, route.name, service.code
    into v_route_id, v_route_name, v_service_code
    from public.service_departures departure
    join public.routes route on route.id = departure.route_id
    join public.services service on service.id = v_trip.service_id
   where departure.id = v_trip.departure_id
     and departure.service_id = v_trip.service_id
     and departure.company_id = v_company_id;
  if not found or v_trip.layout_id is null then raise exception 'TRIP_UNAVAILABLE'; end if;

  select position, name into v_from_pos, v_from_name
    from public.route_stops where id = p_from_stop and route_id = v_route_id;
  if not found then raise exception 'STOP_INVALID'; end if;
  select position, name into v_to_pos, v_to_name
    from public.route_stops where id = p_to_stop and route_id = v_route_id;
  if not found or v_from_pos >= v_to_pos then raise exception 'STOP_INVALID'; end if;

  select label, seat_class into v_seat_label, v_seat_class
    from public.layout_cells
   where id = p_layout_cell and layout_id = v_trip.layout_id
     and kind = 'seat' and not blocked and not unusable;
  if not found or v_seat_label is null then raise exception 'SEAT_UNAVAILABLE'; end if;

  select price into v_price from public.ticket_prices
   where company_id = v_company_id and route_id = v_route_id
     and from_pos = v_from_pos and to_pos = v_to_pos and active
     and (seat_class is null or seat_class = v_seat_class)
   order by (seat_class is not null) desc, created_at desc
   limit 1;
  if not found or v_price <= 0 then raise exception 'FARE_NOT_FOUND'; end if;

  update public.passenger_checkout_orders
     set status = 'expired'
   where trip_id = p_trip and status = 'pending' and expires_at <= clock_timestamp();

  if exists (
    select 1 from public.sale_tickets ticket
      join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
      join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
     where ticket.trip_id = p_trip and ticket.seat_label = v_seat_label
       and ticket.status in ('valid', 'boarded')
       and booked_from.position < v_to_pos and booked_to.position > v_from_pos
  ) or exists (
    select 1 from public.passenger_checkout_orders order_row
      join public.route_stops booked_from on booked_from.id = order_row.from_stop_id
      join public.route_stops booked_to on booked_to.id = order_row.to_stop_id
     where order_row.trip_id = p_trip and order_row.seat_label = v_seat_label
       and order_row.status = 'pending' and order_row.expires_at > clock_timestamp()
       and booked_from.position < v_to_pos and booked_to.position > v_from_pos
  ) then
    raise exception 'SEAT_TAKEN';
  end if;

  insert into public.passenger_checkout_orders (
    company_id, mp_connection_id, passenger_user_id, trip_id, from_stop_id, to_stop_id,
    layout_cell_id, seat_label, passenger_name, passenger_dni, passenger_email,
    passenger_phone, price
  ) values (
    v_company_id, v_company_id, p_user, p_trip, p_from_stop, p_to_stop,
    p_layout_cell, v_seat_label,
    trim(v_passenger.first_name || ' ' || v_passenger.last_name),
    v_passenger.dni, v_passenger.email, trim(p_phone), v_price
  ) returning id, expires_at into v_order_id, v_expires_at;

  return jsonb_build_object(
    'order_id', v_order_id, 'company_id', v_company_id, 'price', v_price,
    'service_code', v_service_code, 'route_name', v_route_name,
    'service_date', v_trip.service_date, 'seat_label', v_seat_label,
    'from_stop', v_from_name, 'to_stop', v_to_name, 'expires_at', v_expires_at
  );
end
$$;
revoke all on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, uuid, text)
  to service_role;

create function public.fail_passenger_checkout(p_order uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  update public.passenger_checkout_orders
     set status = 'cancelled'
   where id = p_order and status = 'pending' and mp_payment_id is null;
end
$$;
revoke all on function public.fail_passenger_checkout(uuid) from public, anon, authenticated;
grant execute on function public.fail_passenger_checkout(uuid) to service_role;

create function public.finalize_passenger_checkout(
  p_order uuid, p_payment_id text, p_amount numeric, p_currency text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order public.passenger_checkout_orders;
  v_trip public.trips;
  v_route_id uuid;
  v_from_pos int;
  v_to_pos int;
  v_sale_id uuid;
  v_ticket_id uuid;
  v_qr text;
begin
  if auth.role() <> 'service_role' then raise exception 'FORBIDDEN'; end if;
  select * into v_order from public.passenger_checkout_orders
   where id = p_order for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status = 'approved' then
    if v_order.mp_payment_id <> p_payment_id then raise exception 'PAYMENT_ID_CONFLICT'; end if;
    return jsonb_build_object('status', 'approved', 'sale_id', v_order.sale_id);
  end if;
  if p_payment_id is null or p_amount <> v_order.price or p_currency <> 'ARS' then
    raise exception 'PAYMENT_AMOUNT_INVALID';
  end if;
  if v_order.status in ('expired', 'cancelled') then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;
  if v_order.status <> 'pending' then
    return jsonb_build_object('status', v_order.status);
  end if;

  if v_order.expires_at <= clock_timestamp() then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;

  select * into v_trip from public.trips where id = v_order.trip_id for update;
  select route_id into v_route_id from public.service_departures
   where id = v_trip.departure_id and service_id = v_trip.service_id;
  select position into v_from_pos from public.route_stops
   where id = v_order.from_stop_id and route_id = v_route_id;
  select position into v_to_pos from public.route_stops
   where id = v_order.to_stop_id and route_id = v_route_id;
  if exists (
    select 1 from public.sale_tickets ticket
      join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
      join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
     where ticket.trip_id = v_order.trip_id and ticket.seat_label = v_order.seat_label
       and ticket.status in ('valid', 'boarded')
       and booked_from.position < v_to_pos and booked_to.position > v_from_pos
  ) then
    update public.passenger_checkout_orders
       set status = 'refund_required', mp_payment_id = p_payment_id
     where id = v_order.id;
    return jsonb_build_object('status', 'refund_required');
  end if;

  insert into public.sales (
    company_id, seller_id, trip_id, payment_method, mp_payment_id, total, notes, channel
  ) values (
    v_order.company_id, null, v_order.trip_id, 'mp', p_payment_id,
    v_order.price, 'Checkout web Mercado Pago', 'web'
  ) returning id into v_sale_id;
  v_qr := gen_random_uuid()::text;
  insert into public.sale_tickets (
    company_id, sale_id, trip_id, seat_label, layout_cell_id,
    from_stop_id, to_stop_id, passenger_name, passenger_dni, passenger_email,
    passenger_phone, price, qr_code, passenger_user_id, status
  ) values (
    v_order.company_id, v_sale_id, v_order.trip_id, v_order.seat_label, v_order.layout_cell_id,
    v_order.from_stop_id, v_order.to_stop_id, v_order.passenger_name, v_order.passenger_dni,
    v_order.passenger_email, v_order.passenger_phone, v_order.price, v_qr,
    v_order.passenger_user_id, 'valid'
  ) returning id into v_ticket_id;

  update public.passenger_checkout_orders
     set status = 'approved', mp_payment_id = p_payment_id, sale_id = v_sale_id
   where id = v_order.id;
  return jsonb_build_object('status', 'approved', 'sale_id', v_sale_id, 'ticket_id', v_ticket_id);
end
$$;
revoke all on function public.finalize_passenger_checkout(uuid, text, numeric, text)
  from public, anon, authenticated;
grant execute on function public.finalize_passenger_checkout(uuid, text, numeric, text)
  to service_role;

create function public.passenger_checkout_status(p_order uuid)
returns table (status text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  update public.passenger_checkout_orders as order_row
     set status = 'expired'
   where order_row.id = p_order and order_row.passenger_user_id = auth.uid()
     and order_row.status = 'pending' and order_row.expires_at <= clock_timestamp();
  return query
  select order_row.status, order_row.expires_at
    from public.passenger_checkout_orders order_row
   where order_row.id = p_order and order_row.passenger_user_id = auth.uid();
end
$$;
revoke all on function public.passenger_checkout_status(uuid) from public, anon;
grant execute on function public.passenger_checkout_status(uuid) to authenticated;

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
         ) and not exists (
           select 1
             from public.passenger_checkout_orders held
             join public.route_stops booked_from on booked_from.id = held.from_stop_id
             join public.route_stops booked_to on booked_to.id = held.to_stop_id
            where held.trip_id = p_trip and held.seat_label = cell.label
              and held.status = 'pending' and held.expires_at > now()
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
