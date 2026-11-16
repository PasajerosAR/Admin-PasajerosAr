alter table public.companies add column logo_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'company-logos',
  'company-logos',
  true,
  3145728,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy company_logos_public_read on storage.objects
  for select to public using (bucket_id = 'company-logos');

create policy company_logos_company_admin_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'company-logos'
    and (
      public.is_platform_admin()
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

create policy company_logos_company_admin_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'company-logos'
    and (
      public.is_platform_admin()
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  )
  with check (
    bucket_id = 'company-logos'
    and (
      public.is_platform_admin()
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

create policy company_logos_company_admin_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'company-logos'
    and (
      public.is_platform_admin()
      or (
        public.is_company_admin()
        and split_part(name, '/', 1) = public.current_company_id()::text
      )
    )
  );

create function public.save_company_logo(p_company uuid, p_logo_path text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_file_name text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not public.is_platform_admin()
     and not (public.is_company_admin() and public.current_company_id() = p_company) then
    raise exception 'FORBIDDEN';
  end if;
  if p_company is null then raise exception 'COMPANY_INVALID'; end if;

  if p_logo_path is not null then
    v_file_name := split_part(p_logo_path, '/', 2);
    if split_part(p_logo_path, '/', 1) <> p_company::text
       or array_length(string_to_array(p_logo_path, '/'), 1) <> 2
       or v_file_name !~* '^[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then
      raise exception 'LOGO_PATH_INVALID';
    end if;
  end if;

  update public.companies
     set logo_path = p_logo_path
   where id = p_company;
  if not found then raise exception 'COMPANY_NOT_FOUND'; end if;
end
$$;
revoke all on function public.save_company_logo(uuid, text) from public, anon;
grant execute on function public.save_company_logo(uuid, text) to authenticated;

create function public.passenger_companies()
returns table (company_id uuid, company_name text, logo_path text)
language sql stable security definer set search_path = public as $$
  select company.id, company.name, company.logo_path
    from public.companies company
   where company.active
   order by company.name;
$$;
revoke all on function public.passenger_companies() from public;
grant execute on function public.passenger_companies() to anon, authenticated;

create function public.save_passenger_profile(
  p_first_name text, p_last_name text, p_dni text, p_birth_date date
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
begin
  if v_user_id is null then raise exception 'UNAUTHENTICATED'; end if;
  if length(trim(coalesce(p_first_name, ''))) not between 2 and 80
     or length(trim(coalesce(p_last_name, ''))) not between 2 and 80
     or coalesce(p_dni, '') !~ '^[0-9]{7,10}$'
     or p_birth_date is null
     or p_birth_date > current_date
     or p_birth_date < date '1900-01-01' then
    raise exception 'PASSENGER_PROFILE_INVALID';
  end if;

  select lower(trim(users.email)) into v_email
    from auth.users users
   where users.id = v_user_id and users.email is not null;
  if v_email is null then raise exception 'PASSENGER_EMAIL_REQUIRED'; end if;

  insert into public.passenger_profiles (user_id, first_name, last_name, dni, birth_date, email)
  values (
    v_user_id, trim(p_first_name), trim(p_last_name), p_dni, p_birth_date, v_email
  )
  on conflict (user_id) do update
    set first_name = excluded.first_name,
        last_name = excluded.last_name,
        dni = excluded.dni,
        birth_date = excluded.birth_date,
        email = excluded.email;
end
$$;
revoke all on function public.save_passenger_profile(text, text, text, date) from public, anon;
grant execute on function public.save_passenger_profile(text, text, text, date) to authenticated;

drop function public.public_search_trips(uuid, uuid, date);
create function public.public_search_trips(
  p_from_place uuid, p_to_place uuid, p_date date, p_company uuid default null
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_from_place is null or p_to_place is null or p_from_place = p_to_place then
    raise exception 'PLACES_INVALID: elegí un origen y un destino distintos';
  end if;
  if p_date is null or p_date < (now() at time zone 'America/Argentina/Buenos_Aires')::date
     or p_date > (now() at time zone 'America/Argentina/Buenos_Aires')::date + 180 then
    raise exception 'DATE_INVALID: la fecha debe estar dentro de los próximos 180 días';
  end if;

  return query
  select trip.id, company.name, service.code, route.name,
         trip.service_date, trip.scheduled_departure,
         segment.from_stop_id, from_place.name, segment.to_stop_id, to_place.name,
         fare.price,
         greatest(coalesce(capacity.seats, 0) - coalesce(reserved.count, 0), 0)::int
    from public.trips trip
    join public.companies company on company.id = trip.company_id and company.active
    join public.services service on service.id = trip.service_id and service.active
    join public.service_departures departure
      on departure.id = trip.departure_id and departure.active
    join public.routes route
      on route.id = departure.route_id and route.active and route.company_id = trip.company_id
    join public.places from_place on from_place.id = p_from_place
    join public.places to_place on to_place.id = p_to_place
    join lateral (
      select from_stop.id as from_stop_id, from_stop.position as from_position,
             to_stop.id as to_stop_id, to_stop.position as to_position
        from public.route_stops from_stop
        join public.route_stops to_stop
          on to_stop.route_id = from_stop.route_id
         and to_stop.place_id = p_to_place
         and from_stop.position < to_stop.position
        left join lateral (
          select min(ticket_price.price) as price
            from public.ticket_prices ticket_price
           where ticket_price.company_id = trip.company_id
             and ticket_price.route_id = route.id
             and ticket_price.from_pos = from_stop.position
             and ticket_price.to_pos = to_stop.position
             and ticket_price.active
        ) pair_fare on true
       where from_stop.route_id = route.id
         and from_stop.place_id = p_from_place
       order by (pair_fare.price is null), pair_fare.price,
                from_stop.position, to_stop.position desc
       limit 1
    ) segment on true
    left join lateral (
      select count(*) as seats
        from public.layout_cells cell
       where cell.layout_id = trip.layout_id and cell.kind = 'seat'
         and not cell.blocked and not cell.unusable
    ) capacity on true
    left join lateral (
      select count(distinct occupied.seat_label) as count
        from (
          select ticket.seat_label
            from public.sale_tickets ticket
            join public.route_stops booked_from on booked_from.id = ticket.from_stop_id
            join public.route_stops booked_to on booked_to.id = ticket.to_stop_id
           where ticket.trip_id = trip.id and ticket.status in ('valid', 'boarded')
             and booked_from.position < segment.to_position
             and booked_to.position > segment.from_position
          union
          select item.seat_label
            from public.passenger_checkout_order_tickets item
            join public.passenger_checkout_orders hold on hold.id = item.order_id
            join public.route_stops held_from on held_from.id = item.from_stop_id
            join public.route_stops held_to on held_to.id = item.to_stop_id
           where item.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
          union
          select hold.seat_label
            from public.passenger_checkout_orders hold
            join public.route_stops held_from on held_from.id = hold.from_stop_id
            join public.route_stops held_to on held_to.id = hold.to_stop_id
           where hold.trip_id = trip.id and hold.status = 'pending'
             and hold.expires_at > now()
             and held_from.position < segment.to_position
             and held_to.position > segment.from_position
             and not exists (
               select 1 from public.passenger_checkout_order_tickets item
                where item.order_id = hold.id
             )
        ) occupied
    ) reserved on true
    left join lateral (
      select min(ticket_price.price) as price
        from public.route_stops fare_from
        join public.route_stops fare_to
          on fare_to.route_id = fare_from.route_id
         and fare_to.position > fare_from.position
        join public.ticket_prices ticket_price
          on ticket_price.company_id = trip.company_id
         and ticket_price.route_id = route.id
         and ticket_price.from_pos = fare_from.position
         and ticket_price.to_pos = fare_to.position
         and ticket_price.active
       where fare_from.route_id = route.id
         and fare_from.place_id = p_from_place
         and fare_to.place_id = p_to_place
    ) fare on true
   where trip.service_date = p_date
     and trip.status = 'scheduled'
     and trip.scheduled_departure > now()
     and public.day_type_of(trip.service_date) = any (departure.day_types)
     and coalesce(capacity.seats, 0) > coalesce(reserved.count, 0)
     and (p_company is null or trip.company_id = p_company)
   order by trip.scheduled_departure, company.name;
end
$$;
revoke all on function public.public_search_trips(uuid, uuid, date, uuid) from public;
grant execute on function public.public_search_trips(uuid, uuid, date, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
