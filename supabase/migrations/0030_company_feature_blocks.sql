-- Bloqueo de funciones por empresa.
-- El administrador general puede bloquear funciones a cada empresa (al darla de alta o después). Una empresa sin bloqueos
-- funciona igual que hasta ahora. Para sumar un bloqueo nuevo más adelante alcanza con agregar su clave en
-- known_company_features() y aplicar company_feature_enabled() donde corresponda: no hace falta tocar la tabla.
--
-- Claves:
--   web        la empresa no aparece en la web de venta de pasajes (ni en búsquedas, ni se puede comprar, ni ver su unidad)
--   gps        sin seguimiento GPS (no se guarda la posición, no aparece en el mapa del admin ni en la web)
--   scanner    sin lector de QR ni pasajes de prueba en la app del conductor
--   fares      sin tarifas ni ventas (ventanilla / venta a bordo)
--   incidents  sin incidencias en la app del conductor
--   counter    sin contador manual de pasajeros (suben / bajan)
--
-- Las funciones del servidor se envuelven: la original se renombra a _<nombre>_impl (sin permisos para nadie) y una función
-- nueva con el mismo nombre y firma comprueba el bloqueo antes de llamarla. Así no se copia ni se altera su lógica.

alter table public.companies add column blocked_features text[] not null default '{}';

create function public.known_company_features() returns text[]
language sql immutable as $$
  select array['web', 'gps', 'scanner', 'fares', 'incidents', 'counter'];
$$;

-- true si la empresa tiene habilitada la función (sin bloqueo). Una empresa inexistente cuenta como habilitada.
create function public.company_feature_enabled(p_company uuid, p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select p_feature = any (company.blocked_features) from public.companies company where company.id = p_company), false);
$$;

create function public.trip_feature_enabled(p_trip uuid, p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.company_feature_enabled((select trip.company_id from public.trips trip where trip.id = p_trip), p_feature);
$$;

create function public._require_trip_feature(p_trip uuid, p_feature text, p_message text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.trip_feature_enabled(p_trip, p_feature) then
    raise exception 'FEATURE_BLOCKED: %', p_message;
  end if;
end;
$$;

revoke all on function public.known_company_features() from public, anon, authenticated;
revoke all on function public.company_feature_enabled(uuid, text) from public, anon, authenticated;
revoke all on function public.trip_feature_enabled(uuid, text) from public, anon, authenticated;
revoke all on function public._require_trip_feature(uuid, text, text) from public;
grant execute on function public.known_company_features() to authenticated;
grant execute on function public.company_feature_enabled(uuid, text) to anon, authenticated;
grant execute on function public.trip_feature_enabled(uuid, text) to anon, authenticated;

-- Solo el administrador general cambia los bloqueos (el service role de las Edge Functions no tiene auth.uid()).
create function public.guard_company_blocked_features() returns trigger
language plpgsql set search_path = public as $$
declare
  v_unknown text[];
begin
  if tg_op = 'UPDATE' and new.blocked_features is not distinct from old.blocked_features then
    return new;
  end if;
  select coalesce(array_agg(feature), '{}') into v_unknown
    from unnest(new.blocked_features) feature
   where not (feature = any (public.known_company_features()));
  if array_length(v_unknown, 1) > 0 then
    raise exception 'FEATURE_UNKNOWN: función desconocida: %', array_to_string(v_unknown, ', ');
  end if;
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'FORBIDDEN: solo el administrador general puede cambiar las funciones de una empresa';
  end if;
  new.blocked_features := coalesce((select array_agg(distinct feature order by feature) from unnest(new.blocked_features) feature), '{}');
  return new;
end;
$$;
create trigger companies_blocked_features_guard
  before insert or update on public.companies
  for each row execute function public.guard_company_blocked_features();

-- ---------------------------------------------------------------- app del conductor

alter function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz)
  rename to _scan_ticket_impl;
revoke all on function public._scan_ticket_impl(uuid, text, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
create function public.scan_ticket(
  p_trip uuid, p_code text, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'scanner', 'el lector de pasajes no está habilitado para esta empresa');
  return public._scan_ticket_impl(p_trip, p_code, p_event, p_lat, p_lng, p_accuracy_m, p_fix_at);
end;
$$;
revoke all on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

alter function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz)
  rename to _override_ticket_boarding_impl;
revoke all on function public._override_ticket_boarding_impl(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
create function public.override_ticket_boarding(
  p_trip uuid, p_code text, p_stop uuid, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'scanner', 'el lector de pasajes no está habilitado para esta empresa');
  return public._override_ticket_boarding_impl(p_trip, p_code, p_stop, p_event, p_lat, p_lng, p_accuracy_m, p_fix_at);
end;
$$;
revoke all on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

alter function public.create_test_tickets(uuid, int) rename to _create_test_tickets_impl;
revoke all on function public._create_test_tickets_impl(uuid, int) from public, anon, authenticated;
create function public.create_test_tickets(p_trip uuid, p_count int default 8) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'scanner', 'el lector de pasajes no está habilitado para esta empresa');
  return public._create_test_tickets_impl(p_trip, p_count);
end;
$$;
revoke all on function public.create_test_tickets(uuid, int) from public, anon, authenticated;
grant execute on function public.create_test_tickets(uuid, int) to authenticated;

alter function public.report_incident(uuid, text, text) rename to _report_incident_impl;
revoke all on function public._report_incident_impl(uuid, text, text) from public, anon, authenticated;
create function public.report_incident(p_trip uuid, p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'incidents', 'las incidencias no están habilitadas para esta empresa');
  return public._report_incident_impl(p_trip, p_kind, p_note);
end;
$$;
revoke all on function public.report_incident(uuid, text, text) from public, anon, authenticated;
grant execute on function public.report_incident(uuid, text, text) to authenticated;

alter function public.register_count(uuid, public.count_kind, int, uuid, uuid) rename to _register_count_impl;
revoke all on function public._register_count_impl(uuid, public.count_kind, int, uuid, uuid) from public, anon, authenticated;
create function public.register_count(
  p_trip uuid, p_kind public.count_kind, p_quantity int, p_stop uuid, p_event uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'counter', 'el contador de pasajeros no está habilitado para esta empresa');
  return public._register_count_impl(p_trip, p_kind, p_quantity, p_stop, p_event);
end;
$$;
revoke all on function public.register_count(uuid, public.count_kind, int, uuid, uuid) from public, anon, authenticated;
grant execute on function public.register_count(uuid, public.count_kind, int, uuid, uuid) to authenticated;

alter function public.update_trip_live_position(uuid, double precision, double precision, real, real, timestamptz)
  rename to _update_trip_live_position_impl;
revoke all on function public._update_trip_live_position_impl(uuid, double precision, double precision, real, real, timestamptz) from public, anon, authenticated;
create function public.update_trip_live_position(
  p_trip uuid, p_latitude double precision, p_longitude double precision,
  p_accuracy_m real, p_heading real, p_recorded_at timestamptz
) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'gps', 'el seguimiento GPS no está habilitado para esta empresa');
  perform public._update_trip_live_position_impl(p_trip, p_latitude, p_longitude, p_accuracy_m, p_heading, p_recorded_at);
end;
$$;
revoke all on function public.update_trip_live_position(uuid, double precision, double precision, real, real, timestamptz) from public, anon, authenticated;
grant execute on function public.update_trip_live_position(uuid, double precision, double precision, real, real, timestamptz) to authenticated;

-- ---------------------------------------------------------------- panel de administración

alter function public.admin_live_trips(uuid) rename to _admin_live_trips_impl;
revoke all on function public._admin_live_trips_impl(uuid) from public, anon, authenticated;
create function public.admin_live_trips(p_company_id uuid default null)
returns table (
  trip_id uuid, company_id uuid, company_name text, service_code text, service_date date,
  scheduled_departure timestamptz, started_at timestamptz, route_id uuid, route_name text,
  route_path jsonb, vehicle_number text, vehicle_plate text, driver_name text, latitude double precision,
  longitude double precision, accuracy_m real, heading real, location_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select live.* from public._admin_live_trips_impl(p_company_id) live
   where public.company_feature_enabled(live.company_id, 'gps');
$$;
revoke all on function public.admin_live_trips(uuid) from public, anon, authenticated;
grant execute on function public.admin_live_trips(uuid) to authenticated;

alter function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) rename to _create_sale_with_tickets_impl;
revoke all on function public._create_sale_with_tickets_impl(uuid, public.payment_method, text, jsonb) from public, anon, authenticated;
create function public.create_sale_with_tickets(
  p_trip uuid, p_payment_method public.payment_method, p_notes text, p_passengers jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'fares', 'las tarifas y ventas no están habilitadas para esta empresa');
  return public._create_sale_with_tickets_impl(p_trip, p_payment_method, p_notes, p_passengers);
end;
$$;
revoke all on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_sale_with_tickets(uuid, public.payment_method, text, jsonb) to authenticated;

alter function public.save_ticket_price(uuid, int, int, numeric, text) rename to _save_ticket_price_impl;
revoke all on function public._save_ticket_price_impl(uuid, int, int, numeric, text) from public, anon, authenticated;
create function public.save_ticket_price(
  p_route uuid, p_from_pos int, p_to_pos int, p_price numeric, p_seat_class text
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if public.current_company_id() is not null and not public.company_feature_enabled(public.current_company_id(), 'fares') then
    raise exception 'FEATURE_BLOCKED: las tarifas y ventas no están habilitadas para esta empresa';
  end if;
  return public._save_ticket_price_impl(p_route, p_from_pos, p_to_pos, p_price, p_seat_class);
end;
$$;
revoke all on function public.save_ticket_price(uuid, int, int, numeric, text) from public, anon, authenticated;
grant execute on function public.save_ticket_price(uuid, int, int, numeric, text) to authenticated;

-- ---------------------------------------------------------------- web de venta de pasajes

alter function public.passenger_companies() rename to _passenger_companies_impl;
revoke all on function public._passenger_companies_impl() from public, anon, authenticated;
create function public.passenger_companies()
returns table (company_id uuid, company_name text, logo_path text)
language sql stable security definer set search_path = public as $$
  select listed.* from public._passenger_companies_impl() listed
   where public.company_feature_enabled(listed.company_id, 'web');
$$;
revoke all on function public.passenger_companies() from public, anon, authenticated;
grant execute on function public.passenger_companies() to anon, authenticated;

alter function public.public_search_trips(uuid, uuid, date, uuid) rename to _public_search_trips_impl;
revoke all on function public._public_search_trips_impl(uuid, uuid, date, uuid) from public, anon, authenticated;
create function public.public_search_trips(
  p_from_place uuid, p_to_place uuid, p_date date, p_company uuid default null
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int
)
language sql stable security definer set search_path = public as $$
  select found.* from public._public_search_trips_impl(p_from_place, p_to_place, p_date, p_company) found
   where public.trip_feature_enabled(found.trip_id, 'web');
$$;
revoke all on function public.public_search_trips(uuid, uuid, date, uuid) from public, anon, authenticated;
grant execute on function public.public_search_trips(uuid, uuid, date, uuid) to anon, authenticated;

alter function public.public_company_trips(uuid, uuid, uuid, date, integer, integer) rename to _public_company_trips_impl;
revoke all on function public._public_company_trips_impl(uuid, uuid, uuid, date, integer, integer) from public, anon, authenticated;
create function public.public_company_trips(
  p_company uuid,
  p_from_place uuid default null,
  p_to_place uuid default null,
  p_date date default null,
  p_page integer default 1,
  p_page_size integer default 10
)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text,
  service_date date, scheduled_departure timestamptz, from_stop_id uuid,
  from_stop_name text, to_stop_id uuid, to_stop_name text, price numeric,
  available_seats int, origin_place_id uuid, destination_place_id uuid,
  total_count bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.company_feature_enabled(p_company, 'web') then
    return;
  end if;
  return query select * from public._public_company_trips_impl(p_company, p_from_place, p_to_place, p_date, p_page, p_page_size);
end;
$$;
revoke all on function public.public_company_trips(uuid, uuid, uuid, date, integer, integer) from public, anon, authenticated;
grant execute on function public.public_company_trips(uuid, uuid, uuid, date, integer, integer) to anon, authenticated;

alter function public.public_trip_seats(uuid, uuid, uuid) rename to _public_trip_seats_impl;
revoke all on function public._public_trip_seats_impl(uuid, uuid, uuid) from public, anon, authenticated;
create function public.public_trip_seats(p_trip uuid, p_from_stop uuid, p_to_stop uuid)
returns table (
  cell_id uuid, floor int, row_idx int, col_idx int, seat_label text,
  seat_class text, available boolean, price numeric, cell_kind text
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'web', 'esta empresa no vende pasajes por la web');
  return query select * from public._public_trip_seats_impl(p_trip, p_from_stop, p_to_stop);
end;
$$;
revoke all on function public.public_trip_seats(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.public_trip_seats(uuid, uuid, uuid) to anon, authenticated;

alter function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) rename to _begin_passenger_checkout_impl;
revoke all on function public._begin_passenger_checkout_impl(uuid, uuid, uuid, uuid, jsonb, text) from public, anon, authenticated;
create function public.begin_passenger_checkout(
  p_user uuid, p_trip uuid, p_from_stop uuid, p_to_stop uuid, p_tickets jsonb, p_phone text
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_trip_feature(p_trip, 'web', 'esta empresa no vende pasajes por la web');
  return public._begin_passenger_checkout_impl(p_user, p_trip, p_from_stop, p_to_stop, p_tickets, p_phone);
end;
$$;
revoke all on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) from public, anon, authenticated;
-- como la original: la llama la Edge Function con el service role
grant execute on function public.begin_passenger_checkout(uuid, uuid, uuid, uuid, jsonb, text) to service_role;

alter function public.public_trip_live_position(uuid) rename to _public_trip_live_position_impl;
revoke all on function public._public_trip_live_position_impl(uuid) from public, anon, authenticated;
create function public.public_trip_live_position(p_trip uuid)
returns table (
  trip_id uuid, company_name text, service_code text, route_name text, route_path jsonb,
  scheduled_departure timestamptz, latitude double precision, longitude double precision,
  accuracy_m real, heading real, location_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select live.* from public._public_trip_live_position_impl(p_trip) live
   where public.trip_feature_enabled(p_trip, 'web') and public.trip_feature_enabled(p_trip, 'gps');
$$;
revoke all on function public.public_trip_live_position(uuid) from public, anon, authenticated;
grant execute on function public.public_trip_live_position(uuid) to anon, authenticated;
