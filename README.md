# Plataforma de transporte multiempresa

Stack: TypeScript + React (Vite) + Supabase (Postgres, Auth, Edge Functions).

## Que incluye

- **Base de datos** (`supabase/migrations`): empresas, perfiles y roles, flota, disposiciones de asientos
  versionadas, recorridos, servicios, viajes, jornadas, contador de pasajeros, QR de prueba y auditoria. Aislamiento
  entre empresas con RLS; la logica critica esta en funciones del servidor.
- **Panel admin** (`/admin`): operacion del dia, servicios, recorridos, flota, editor visual de
  disposiciones de asientos, conductores y seguimiento GPS en vivo.
- **App del conductor**: es un proyecto aparte (app Android); usa este mismo backend de Supabase. Las funciones y migraciones de conductor (jornada, viajes, QR de prueba, avance automatico) siguen aca porque son parte de la base compartida.
- **Ventas administrativas** (`/admin/ventas`): tarifas por tramo y clase, venta de mostrador, pasajes con QR,
  cancelaciones auditadas, resumen y reportes. La venta y sus pasajes se crean en una transaccion en PostgreSQL;
  el servidor calcula el precio y valida el tramo y la disponibilidad del asiento. `/admin/ventas/mercadopago`
  conecta una cuenta vendedora de prueba por empresa.
- **Portal de pasajeros** (`D:\00 Pasajeros.ar\PasajerosAr`): aplicación web independiente y adaptable a móviles para crear cuenta,
  buscar viajes, consultar pasajes vinculados por DNI y correo y seguir una unidad en curso. Los PDF se adjuntan
  al correo de confirmación de las ventas administrativas cuando Resend está configurado.
- Los servicios se eliminan por completo solo si no tienen viajes asociados; el inicio del conductor permite elegir la fecha, incluso para salidas de medianoche.

**Puntualidad:** el horario a cumplir es el de la carga del servicio (salida programada + minutos de cada parada).
Antes de la salida se muestra la cuenta regresiva (+11, +10 ... 0). Desde la hora programada el adelanto (+) o atraso (-)
lo calcula el GPS del telefono contra ese horario. La hora en que el chofer se conecto es solo referencia. No hay horas
estimadas. Para seguimiento administrativo solo se conserva la ultima ubicacion del viaje activo (se actualiza cada 15
segundos y se elimina al finalizarlo o cambiar de conductor); no se guarda un historial GPS.

**Checkout del portal:** Mercado Pago Checkout Pro opera en modo de prueba. Cada empresa conecta su cuenta
vendedora mediante OAuth; el portal permite comprar hasta cuatro pasajes en una sola operación, reserva
todos los asientos durante 10 minutos y crea la preferencia solo en el servidor. Un webhook con firma valida
el pago consultándolo a Mercado Pago y recién entonces emite los pasajes. Los retornos del navegador no
confirman pagos; los pasajes de prueba del conductor siguen separados de los pasajes comerciales.

## Puesta en marcha

1. Crear un proyecto en Supabase.
2. Aplicar en orden las migraciones `0001_core.sql` a `0029_public_company_trip_browse.sql` de `supabase/migrations` (SQL Editor o `supabase db push`). No usar `supabase/setup_completo.sql`: es un instalador legado. Las migraciones `0018` a `0029` agregan ventas, colaboradores con permisos limitados, el portal de pasajeros, la disposición pública de asientos, el checkout de Mercado Pago en modo test y el directorio de empresas. La `0022` agrega reservas temporales, conexión OAuth cifrada por empresa y emisión de pasajes únicamente tras validar el pago desde el webhook. La `0023` corrige consultas ambiguas del portal y checkout. La `0024` limita las localidades a recorridos activos, evita duplicar viajes por paradas de una misma localidad, filtra las paradas del pasaje por localidad elegida y publica el plano conservando sus celdas y coordenadas. La `0025` normaliza la comparación de clases de asiento en tarifas y ventas para que las diferencias de tildes no oculten los precios. La `0026` permite pagar una compra de hasta cuatro pasajeros con un solo checkout y reserva todos los asientos elegidos hasta confirmar el pago. La `0027` permite completar el perfil del pasajero y filtrar viajes por empresa; la `0028` habilita cargar logos a colaboradores de plataforma con permiso de edición; la `0029` publica las próximas salidas por empresa con filtros y paginación. El GPS del teléfono puede falsificarse y no es una prueba criptográfica. Las migraciones conservan los pasajes de prueba existentes.
3. Desplegar las funciones existentes y nuevas:
   ```powershell
   supabase functions deploy create-driver
   supabase functions deploy create-company-admin
   supabase functions deploy create-platform-staff
   supabase functions deploy email-tickets
   supabase functions deploy cancel-ticket
   supabase functions deploy mp-oauth-start
   supabase functions deploy mp-company-connection-status
   supabase functions deploy mp-disconnect-company
   supabase functions deploy create-passenger-checkout
   supabase functions deploy mercadopago-oauth-callback
   supabase functions deploy mercadopago-webhook
   ```
4. Crear una aplicación en Mercado Pago Developers y configurar como URL de retorno OAuth
   `https://idouvlxykkmuxzgdpflg.supabase.co/functions/v1/mercadopago-oauth-callback`. Guardar como secretos de
   Supabase `MP_TEST_MODE=true`, `MP_CLIENT_ID`, `MP_CLIENT_SECRET`, `MP_REDIRECT_URI` (esa URL exacta),
   `MP_WEBHOOK_SECRET` (firma de Webhooks en modo test), `MP_TOKEN_ENCRYPTION_KEY` (clave aleatoria privada),
   `PASSENGER_WEB_URL` (URL pública HTTPS del portal) y `ADMIN_WEB_URL` (URL del panel). No usar tokens ni
   credenciales productivas. En Mercado Pago, configurar Webhooks de prueba para el evento `payment`.
   Desde PowerShell, en la carpeta `D:\00 Pasajeros.ar\transporte`, cargá los valores privados directamente en
   Supabase con `supabase secrets set MP_TEST_MODE=true MP_CLIENT_ID=... MP_CLIENT_SECRET=... MP_REDIRECT_URI=... MP_WEBHOOK_SECRET=... MP_TOKEN_ENCRYPTION_KEY=... PASSENGER_WEB_URL=... ADMIN_WEB_URL=...`. Generá `MP_TOKEN_ENCRYPTION_KEY` con un generador criptográfico local; nunca la pegues en el chat ni la guardes en Git o en el frontend. Crear una cuenta vendedora de prueba para cada empresa y usar una cuenta compradora de prueba para simular el pago.
5. Para adjuntar PDF del pasaje en el correo, configurar `RESEND_API_KEY` y `TICKETS_FROM_EMAIL` como secretos
   de Supabase Functions. No guardar la clave en el repositorio ni en el frontend.
6. Copiar `web/.env.example` a `web/.env.local` y completar URL y anon key.
7. Crear el administrador general (una sola vez): crear el usuario en Authentication > Users y en el SQL Editor:
   ```sql
   insert into profiles (id, company_id, role, full_name)
   values ('<id del usuario>', null, 'platform_admin', 'Tu nombre');
   ```
   Desde ahi, las empresas y sus administradores se crean en el panel (`/admin`, seccion Empresas).
8. `cd web && npm install && npm run dev`.
9. Para ejecutar el portal público en forma independiente, abrir PowerShell en `D:\00 Pasajeros.ar\PasajerosAr`, ejecutar `npm install`, copiar `.env.example` a `.env.local`, completar URL y anon key de Supabase y ejecutar `npm run dev`. No reutiliza la sesión ni las rutas del panel administrativo.

## Quien hace que

- Administrador general (vos): crea empresas y su administrador, carga las localidades (origen/destino que elige el pasajero) y los recorridos (paradas con localidad y coordenadas, trazado por calles y puntos de paso), cada uno asignado en exclusiva a una empresa. En seguimiento GPS ve solo viajes activos y su ultima ubicacion.
- Administrador de empresa: crea flota, disposiciones, conductores y servicios. Cada servicio (por ejemplo "214") agrupa varias salidas de ida y vuelta, cada una con su horario y sus días; los tiempos por parada se definen por sentido.
- Vendedor: vende, consulta y cancela pasajes comerciales de su empresa. El administrador general puede delegar secciones de solo lectura o edición a colaboradores de plataforma.
- Administrador de empresa: conecta su propia cuenta vendedora de prueba en `/admin/ventas/mercadopago`.
- Pasajero: crea una cuenta con nombre, apellido, DNI, fecha de nacimiento y correo; ve los tickets asociados a su DNI/correo y puede seguir la unidad durante el viaje.
- Las disposiciones asignadas a unidades se pueden eliminar tras reasignar esas unidades a otra grilla o a una copia. Las vinculadas a viajes anteriores se conservan para no perder la configuración histórica.

## Pruebas

- Logica de asientos y puntualidad: `cd web && npm test`
- Typecheck/build del panel: `cd web && npm run build`
- Typecheck/build del portal público: `cd D:\00 Pasajeros.ar\PasajerosAr && npm run build`
- Base de datos (Postgres local, sin Supabase): `supabase/tests/run.sh`
  Simula el esquema `auth` de Supabase y prueba aislamiento entre empresas, bloqueo y versionado de
  disposiciones, jornada, viajes, contador y pasajes de prueba (idempotencia, autorización auditada,
  QR inválidos/anulados/reutilizados, relevo/reapertura auditados, seguimiento GPS, cambio atomico de viaje
  ventas y cancelaciones, asociación de pasajes de pasajeros y permisos de plataforma).

## Que NO esta probado

- La comunicación real con Mercado Pago requiere las credenciales de prueba de una aplicación y cuentas vendedora/compradora de prueba.
- Los permisos de la tabla `auth.users` y la configuracion de roles propia de Supabase: el arnes local los imita.

## Pendiente conocido

- Correccion de conteos por un administrador (hoy el contador solo agrega registros).
- Pruebas de pagos reales; el flujo implementado queda bloqueado a modo test hasta una habilitación separada para producción.
