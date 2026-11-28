\set ON_ERROR_STOP on
-- Marcaje de entrada y salida: zonas, distancia en el servidor, bloqueo/revisión, duplicados, inmutabilidad y RLS.
-- Chofer A y Admin A son de la empresa A; Admin B es de la empresa B.
insert into auth.users (id, email) values ('a7000000-0000-0000-0000-000000000045', 'chofer.marcaje@test');
insert into public.profiles (id, company_id, role, full_name) values ('a7000000-0000-0000-0000-000000000045', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer marcaje');
create temp table k as select gen_random_uuid() as k_in, gen_random_uuid() as k_in2, gen_random_uuid() as k_out,
  gen_random_uuid() as k_far, gen_random_uuid() as k_nophoto;
grant all on k to authenticated;
-- fotos "subidas" (como superusuario; la política de subida se prueba aparte)
insert into storage.objects (bucket_id, name)
select 'punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/' || x || '.jpg'
from (select k_in::text || '-in' x from k union all select k_in2::text || '-in' from k union all select k_out::text || '-out' from k
      union all select k_far::text || '-in' from k) s;

-- sin zonas: sigue el fichaje de siempre y marcar no está disponible
select t.login('a7000000-0000-0000-0000-000000000045');
select public.start_shift();
select public.end_shift();
select t.expect_fail($q$select public.punch_shift('in', (select k_in from k), -31.7333, -60.5236, 10, now())$q$, 'CLOCK_NOT_CONFIGURED');
select t.logout();

-- el admin configura dos zonas (Galpón Paraná y Galpón Santa Fe) y el modo
select t.login('a1000000-0000-0000-0000-000000000001');
insert into public.clock_zones (company_id, name, lat, lng, radius_m)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Galpón Paraná', -31.7333, -60.5236, 100),
       ('aaaaaaaa-0000-0000-0000-000000000001', 'Galpón Santa Fe', -31.6333, -60.7000, 50);
select t.expect_fail($q$insert into public.clock_zones (company_id, name, lat, lng, radius_m) values ('aaaaaaaa-0000-0000-0000-000000000001', 'x', 0, 0, 5)$q$, 'check');
select t.expect_fail($q$select public.save_clock_settings('otro', 30)$q$, 'INVALID_MODE');
select t.expect_fail($q$select public.save_clock_settings('block', 3)$q$, 'INVALID_DAYS');
select public.save_clock_settings('block', 30);
select t.logout();

-- el chofer no puede crear zonas ni cambiar la configuración
select t.login('a7000000-0000-0000-0000-000000000045');
select t.expect_fail($q$insert into public.clock_zones (company_id, name, lat, lng, radius_m) values ('aaaaaaaa-0000-0000-0000-000000000001', 'mia', 0, 0, 100)$q$, 'row-level security');
select t.expect_fail($q$select public.save_clock_settings('review', 30)$q$, 'FORBIDDEN');
-- con zonas, las funciones viejas ya no abren ni cierran jornadas
select t.expect_fail($q$select public.start_shift()$q$, 'CLOCK_REQUIRED');
select t.expect_fail($q$select public.end_shift()$q$, 'CLOCK_REQUIRED');

-- sin foto en el servidor no se marca
select t.expect_fail($q$select public.punch_shift('in', (select k_nophoto from k), -31.7333, -60.5236, 10, now())$q$, 'PHOTO_MISSING');
-- fuera de la zona y modo bloquear: rechazado, sin jornada ni marcaje
select t.expect_fail($q$select public.punch_shift('in', (select k_far from k), -31.7400, -60.5236, 10, now())$q$, 'OUT_OF_ZONE');
select t.expect_eq((select count(*)::int from public.shift_punches), 0, 'el intento bloqueado no deja marcaje');
select t.expect_eq((select count(*)::int from public.shifts where ended_at is null), 0, 'ni jornada abierta');

-- dentro de la zona (a ~55 m del centro, radio 100)
select t.expect_eq(public.punch_shift('in', (select k_in from k), -31.73380, -60.5236, 12, now() - interval '3 seconds')->>'status', 'ok', 'entrada ok');
select t.expect_eq((select inside from public.shift_punches where kind = 'in'), true, 'entrada dentro de zona');
select t.expect_eq((select zone_name from public.shift_punches where kind = 'in'), 'Galpón Paraná', 'zona detectada');
select t.expect_eq((select low_accuracy from public.shift_punches where kind = 'in'), false, 'precisión buena');
select t.expect_eq((select delayed from public.shift_punches where kind = 'in'), false, 'no demorado');
select t.expect_eq((select count(*)::int from public.shifts where ended_at is null), 1, 'jornada abierta');
-- mismo toque reintentado: devuelve el mismo marcaje, no duplica
select t.expect_eq(public.punch_shift('in', (select k_in from k), -31.73380, -60.5236, 12, now())->>'status', 'duplicate', 'reintento no duplica');
-- otro toque con otra clave mientras hay jornada abierta
select t.expect_fail($q$select public.punch_shift('in', (select k_in2 from k), -31.73380, -60.5236, 12, now())$q$, 'ALREADY_IN');
select t.expect_eq((select count(*)::int from public.shift_punches), 1, 'un solo marcaje de entrada');

-- el marcaje original no se puede cambiar ni borrar, ni por el dueño de la función
select t.logout();
select t.expect_fail($q$update public.shift_punches set inside = false$q$, 'IMMUTABLE');
select t.expect_fail($q$delete from public.shift_punches$q$, 'IMMUTABLE');
select t.login('a7000000-0000-0000-0000-000000000045');
select t.expect_eq((select count(*)::int from public.shift_punches where inside = false), 0, 'siguen igual');

-- salida: dentro de la otra zona (Santa Fe, radio 50), con precisión mala y demorada
select t.logout();
insert into storage.objects (bucket_id, name)
select 'punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/' || k_out::text || '-out.jpg' from k
on conflict do nothing;
select t.login('a7000000-0000-0000-0000-000000000045');
select t.expect_eq(public.punch_shift('out', (select k_out from k), -31.6333, -60.7000, 250, now() - interval '10 minutes')->>'status', 'ok', 'salida ok');
select t.expect_eq((select zone_name from public.shift_punches where kind = 'out'), 'Galpón Santa Fe', 'salida en otra zona');
select t.expect_eq((select low_accuracy from public.shift_punches where kind = 'out'), true, 'precisión baja marcada');
select t.expect_eq((select delayed from public.shift_punches where kind = 'out'), true, 'demorado marcado');
select t.expect_eq((select count(*)::int from public.shifts where ended_at is null), 0, 'jornada cerrada');
select t.expect_eq((select count(*)::int from public.shift_punches), 2, 'dos marcajes por jornada');

-- modo revisión: fuera de zona se registra, marcado
select t.logout();
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_clock_settings('review', 30);
select t.logout();
create temp table k2 as select gen_random_uuid() as k;
grant all on k2 to authenticated;
insert into storage.objects (bucket_id, name)
select 'punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/' || k::text || '-in.jpg' from k2;
select t.login('a7000000-0000-0000-0000-000000000045');
select t.expect_eq(public.punch_shift('in', (select k from k2), -31.7400, -60.5236, 20, now())->>'inside', 'false', 'fuera de zona registrado');
select t.expect_eq((select count(*)::int from public.shift_punches where not inside), 1, 'queda para revisión');
select t.expect_eq((select distance_m from public.shift_punches where not inside) > 500, true, 'distancia al borde guardada');
select t.expect_fail($q$select public.review_punch((select id from public.shift_punches where not inside), 'approved', 'ok')$q$, 'FORBIDDEN');
select t.logout();

-- el admin revisa sin alterar el original
select t.login('a1000000-0000-0000-0000-000000000001');
select public.review_punch((select id from public.shift_punches where not inside), 'rejected', 'Estaba en otra parada');
select t.expect_eq((select count(*)::int from public.punch_reviews), 1, 'revisión registrada');
select t.expect_eq((select count(*)::int from public.shift_punches where not inside), 1, 'original intacto');
select t.expect_eq((select count(*)::int from public.shift_punches), 3, 'el admin ve los marcajes de su empresa');
select t.logout();

-- otra empresa no ve nada, ni zonas, ni marcajes, ni revisiones, ni fotos
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*)::int from public.shift_punches), 0, 'B no ve marcajes de A');
select t.expect_eq((select count(*)::int from public.clock_zones), 0, 'B no ve zonas de A');
select t.expect_eq((select count(*)::int from public.punch_reviews), 0, 'B no ve revisiones de A');
select t.expect_eq((select count(*)::int from storage.objects where bucket_id = 'punch-photos'), 0, 'B no ve fotos de A');
select t.expect_fail($q$select public.review_punch((select id from public.shift_punches limit 1), 'approved', null)$q$, 'NOT_FOUND');
select t.logout();

-- fotos: el chofer ve las suyas y el admin las de su empresa
select t.login('a7000000-0000-0000-0000-000000000045');
select t.expect_eq((select count(*)::int from storage.objects where bucket_id = 'punch-photos') > 0, true, 'el chofer ve sus fotos');
select t.logout();
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*)::int from storage.objects where bucket_id = 'punch-photos') > 0, true, 'el admin ve las fotos de su empresa');
select t.logout();

-- subida: solo en la carpeta propia y con el nombre esperado
select t.login('a7000000-0000-0000-0000-000000000045');
insert into storage.objects (bucket_id, name) values ('punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/11111111-1111-1111-1111-111111111111-in.jpg');
select t.expect_fail($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/11111111-1111-1111-1111-111111111112-in.jpg')$q$, 'row-level security');
select t.expect_fail($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'bbbbbbbb-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/11111111-1111-1111-1111-111111111113-in.jpg')$q$, 'row-level security');
select t.expect_fail($q$insert into storage.objects (bucket_id, name) values ('punch-photos', 'aaaaaaaa-0000-0000-0000-000000000001/a7000000-0000-0000-0000-000000000045/foto.png')$q$, 'row-level security');
select t.logout();
\echo 'PRUEBAS DE MARCAJES PASARON'
