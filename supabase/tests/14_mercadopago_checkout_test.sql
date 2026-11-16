\set ON_ERROR_STOP on

select t.expect_eq(
  has_table_privilege('anon', 'public.mp_company_connections', 'select'),
  false,
  'las credenciales OAuth no se exponen al rol anon'
);
select t.expect_eq(
  has_table_privilege('authenticated', 'public.passenger_checkout_orders', 'select'),
  false,
  'los datos personales de una reserva no se consultan directamente'
);
select t.expect_eq(
  has_table_privilege('authenticated', 'public.passenger_checkout_order_tickets', 'select'),
  false,
  'los datos de pasajeros adicionales no se consultan directamente'
);
select t.expect_eq(
  has_function_privilege('authenticated', 'public.begin_passenger_checkout(uuid,uuid,uuid,uuid,jsonb,text)', 'execute'),
  false,
  'solo la Edge Function de servidor inicia reservas'
);
select t.expect_eq(
  has_function_privilege('service_role', 'public.begin_passenger_checkout(uuid,uuid,uuid,uuid,jsonb,text)', 'execute'),
  true,
  'el servidor puede iniciar la reserva'
);
select t.expect_eq(
  has_function_privilege('anon', 'public.finalize_passenger_checkout(uuid,text,numeric,text)', 'execute'),
  false,
  'el retorno del navegador no puede emitir pasajes'
);
select t.expect_eq(
  (select count(*) = 1 from pg_trigger
    where tgname = 'reject_ticket_for_held_seat' and not tgisinternal),
  true,
  'una venta de mostrador no puede tomar un asiento reservado en el checkout'
);
select t.expect_eq(
  (select is_nullable from information_schema.columns
    where table_schema = 'public' and table_name = 'sales' and column_name = 'seller_id'),
  'YES',
  'las ventas web pueden no tener vendedor de mostrador'
);
select t.expect_eq(
  (select column_default is not null from information_schema.columns
    where table_schema = 'public' and table_name = 'sales' and column_name = 'channel'),
  true,
  'las ventas existentes conservan el canal de mostrador por defecto'
);

\echo 'PRUEBAS DE MERCADO PAGO PASARON'
