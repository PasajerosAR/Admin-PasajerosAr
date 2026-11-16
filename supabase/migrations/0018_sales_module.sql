-- Modulo de ventas comerciales.
-- Agrega roles seller y platform_staff, permisos de plataforma configurables,
-- tarifas por tramo, cabecera de venta y pasajes comerciales reales.
-- Los tickets de prueba existentes (is_test = true) no se modifican.

-- ---------------------------------------------------------------- nuevos roles
-- Los enum en Postgres no se pueden modificar dentro de una transaccion
-- que ya ejecuto DDL. Se usa ADD VALUE IF NOT EXISTS para idempotencia.
alter type public.user_role add value if not exists 'seller';
alter type public.user_role add value if not exists 'platform_staff';

-- ---------------------------------------------------------------- helpers actualizados
-- Incluye seller en las funciones que necesitan saber si el usuario es de empresa.
create or replace function public.is_company_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    public.current_user_role()::text in ('company_admin', 'seller', 'support'),
    false
  )
$$;

-- ---------------------------------------------------------------- permisos de plataforma
-- Permite al platform_admin configurar que secciones puede ver/editar
-- cada colaborador de plataforma (platform_staff).
create table public.platform_permissions (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles (id) on delete cascade,
  section     text not null
              check (section in ('companies','routes','places','gps','reports','all')),
  can_edit    boolean not null default false,
  granted_by  uuid not null references public.profiles (id),
  created_at  timestamptz not null default now(),
  unique (profile_id, section)
);
create index platform_permissions_profile_idx on public.platform_permissions (profile_id);

alter table public.platform_permissions enable row level security;

-- Solo platform_admin puede gestionar estos permisos.
create policy pp_select on public.platform_permissions for select to authenticated
  using (public.is_platform_admin());
create policy pp_insert on public.platform_permissions for insert to authenticated
  with check (public.is_platform_admin());
create policy pp_update on public.platform_permissions for update to authenticated
  using (public.is_platform_admin());
create policy pp_delete on public.platform_permissions for delete to authenticated
  using (public.is_platform_admin());

revoke all on public.platform_permissions from anon, authenticated;
grant select, insert, update, delete on public.platform_permissions to authenticated;

-- ---------------------------------------------------------------- tarifas por tramo
create table public.ticket_prices (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  route_id    uuid not null references public.routes (id) on delete cascade,
  from_pos    int  not null check (from_pos >= 1),   -- position de route_stops
  to_pos      int  not null check (to_pos >= 1),
  price       numeric(10, 2) not null check (price >= 0),
  seat_class  text,                                  -- null = aplica a todos
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint ticket_prices_direction check (from_pos < to_pos),
  unique (company_id, route_id, from_pos, to_pos, seat_class)
);
create index ticket_prices_company_route_idx on public.ticket_prices (company_id, route_id);

alter table public.ticket_prices enable row level security;

create policy tp_select on public.ticket_prices for select to authenticated
  using (company_id = public.current_company_id() or public.is_platform_admin());
create policy tp_insert on public.ticket_prices for insert to authenticated
  with check (company_id = public.current_company_id() and public.is_company_admin());
create policy tp_update on public.ticket_prices for update to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());
create policy tp_delete on public.ticket_prices for delete to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());

revoke all on public.ticket_prices from anon, authenticated;
grant select, insert, update, delete on public.ticket_prices to authenticated;

-- ---------------------------------------------------------------- ventas (cabecera)
create type public.payment_method as enum
  ('cash', 'debit', 'credit', 'transfer', 'mp', 'complimentary');
create type public.sale_status as enum
  ('completed', 'refunded', 'partial_refund');

create table public.sales (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies (id),
  seller_id       uuid not null references public.profiles (id),
  trip_id         uuid not null references public.trips (id),
  payment_method  public.payment_method not null,
  mp_payment_id   text,
  total           numeric(10, 2) not null check (total >= 0),
  status          public.sale_status not null default 'completed',
  notes           text,
  created_at      timestamptz not null default now(),
  refunded_at     timestamptz,
  refunded_by     uuid references public.profiles (id)
);
create index sales_company_trip_idx on public.sales (company_id, trip_id);
create index sales_company_seller_idx on public.sales (company_id, seller_id);
create index sales_created_idx on public.sales (company_id, created_at desc);

alter table public.sales enable row level security;

-- company_admin y seller pueden crear ventas y verlas dentro de su empresa.
create policy sales_select on public.sales for select to authenticated
  using (company_id = public.current_company_id()
         and public.current_user_role()::text in ('company_admin', 'seller', 'support'));
create policy sales_insert on public.sales for insert to authenticated
  with check (company_id = public.current_company_id()
              and public.current_user_role()::text in ('company_admin', 'seller'));
-- Solo company_admin puede actualizar (ej: marcar como devuelta).
-- seller puede marcar devoluciones: ampliamos a seller tambien.
create policy sales_update on public.sales for update to authenticated
  using (company_id = public.current_company_id()
         and public.current_user_role()::text in ('company_admin', 'seller'));

revoke all on public.sales from anon, authenticated;
grant select, insert, update on public.sales to authenticated;

-- ---------------------------------------------------------------- pasajes comerciales
create type public.ticket_status as enum ('valid', 'boarded', 'cancelled');

create table public.sale_tickets (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies (id),
  sale_id             uuid not null references public.sales (id) on delete cascade,
  trip_id             uuid not null references public.trips (id),
  seat_label          text,
  layout_cell_id      uuid references public.layout_cells (id),
  from_stop_id        uuid not null references public.route_stops (id),
  to_stop_id          uuid not null references public.route_stops (id),
  passenger_name      text not null check (length(trim(passenger_name)) between 2 and 150),
  passenger_dni       text not null check (length(trim(passenger_dni)) >= 6),
  passenger_email     text not null check (passenger_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  passenger_phone     text not null check (length(trim(passenger_phone)) >= 7),
  price               numeric(10, 2) not null check (price >= 0),
  qr_code             text not null unique,          -- UUID en formato texto
  is_complimentary    boolean not null default false,
  status              public.ticket_status not null default 'valid',
  boarded_at          timestamptz,
  cancelled_at        timestamptz,
  cancelled_by        uuid references public.profiles (id),
  cancel_reason       text,
  created_at          timestamptz not null default now(),
  constraint cancelled_state_check check (
    (status <> 'cancelled' and cancelled_at is null and cancelled_by is null and cancel_reason is null)
    or (status = 'cancelled' and cancelled_at is not null and cancelled_by is not null and cancel_reason is not null)
  ),
  constraint boarded_state_check check (
    (status <> 'boarded' and boarded_at is null)
    or (status = 'boarded' and boarded_at is not null)
  )
);
create index sale_tickets_company_trip_idx on public.sale_tickets (company_id, trip_id);
create index sale_tickets_sale_idx on public.sale_tickets (sale_id);
create index sale_tickets_qr_idx on public.sale_tickets (qr_code);
create index sale_tickets_dni_idx on public.sale_tickets (company_id, passenger_dni);
create index sale_tickets_created_idx on public.sale_tickets (company_id, created_at desc);

alter table public.sale_tickets enable row level security;

-- company_admin y seller ven todos los pasajes de su empresa.
create policy st_select on public.sale_tickets for select to authenticated
  using (company_id = public.current_company_id()
         and public.current_user_role()::text in ('company_admin', 'seller', 'support'));
create policy st_insert on public.sale_tickets for insert to authenticated
  with check (company_id = public.current_company_id()
              and public.current_user_role()::text in ('company_admin', 'seller'));
-- Cancelaciones: seller y company_admin pueden cancelar.
create policy st_update on public.sale_tickets for update to authenticated
  using (company_id = public.current_company_id()
         and public.current_user_role()::text in ('company_admin', 'seller'));
-- El conductor puede ver los pasajes de su viaje activo para validar QR.
create policy st_driver_select on public.sale_tickets for select to authenticated
  using (
    public.current_user_role() = 'driver'
    and company_id = public.current_company_id()
    and exists (
      select 1 from public.trips t
       where t.id = sale_tickets.trip_id and t.driver_id = auth.uid()
    )
  );

revoke all on public.sale_tickets from anon, authenticated;
grant select, insert, update on public.sale_tickets to authenticated;

-- ---------------------------------------------------------------- vista util: ocupacion por viaje
create view public.trip_seat_summary with (security_invoker = true) as
select
  t.id as trip_id,
  t.company_id,
  count(st.id) filter (where st.status = 'valid')    as sold,
  count(st.id) filter (where st.status = 'boarded')  as boarded,
  count(st.id) filter (where st.status = 'cancelled') as cancelled_count,
  count(st.id) as total_issued
from public.trips t
left join public.sale_tickets st on st.trip_id = t.id
group by t.id, t.company_id;

-- ---------------------------------------------------------------- vista util: resumen de ventas por dia
create view public.daily_sales_summary with (security_invoker = true) as
select
  s.company_id,
  date_trunc('day', s.created_at at time zone 'America/Argentina/Buenos_Aires') as sale_date,
  s.payment_method,
  count(s.id)      as sale_count,
  sum(s.total)     as total_amount,
  count(s.id) filter (where s.status = 'refunded')       as refunded_count,
  count(st.id) filter (where st.is_complimentary)        as complimentary_count
from public.sales s
left join public.sale_tickets st on st.sale_id = s.id
group by s.company_id, date_trunc('day', s.created_at at time zone 'America/Argentina/Buenos_Aires'), s.payment_method;

notify pgrst, 'reload schema';
