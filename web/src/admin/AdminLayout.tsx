import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { must, useQuery } from '../lib/useQuery';
import { supabase } from '../lib/supabase';
import type { PlatformPermission } from '../lib/types';
import { Notice } from '../ui';
import { fold } from '../lib/text';
import { ProfileMenu } from './ProfileMenu';

const PLATFORM_LINKS: [string, string, boolean][] = [
  ['/admin', 'Empresas', true],
  ['/admin/equipo', 'Equipo de plataforma', false],
  ['/admin/recorridos', 'Catálogo de recorridos', false],
  ['/admin/localidades', 'Localidades', false],
  ['/admin/gps', 'Seguimiento GPS', false],
  ['/admin/ventas/reportes', 'Reportes globales', false]
];
// Títulos de grupo del menú: se muestra antes del primer enlace de cada grupo
const PLATFORM_GROUPS: Record<string, string> = {
  '/admin': 'Empresas', '/admin/recorridos': 'Catálogo', '/admin/gps': 'Control'
};
const COMPANY_GROUPS: Record<string, string> = {
  '/admin': 'Día a día', '/admin/servicios': 'Servicios', '/admin/vehiculos': 'Flota y personal', '/admin/ventas': 'Ventas y cobros'
};
const LINKS: [string, string, boolean][] = [
  ['/admin', 'Operación del día', true],
  ['/admin/gps', 'Seguimiento GPS', false],
  ['/admin/servicios', 'Servicios', false],
  ['/admin/recorridos', 'Recorridos', false],
  ['/admin/vehiculos', 'Flota', false],
  ['/admin/disposiciones', 'Disposiciones de asientos', false],
  ['/admin/conductores', 'Conductores', false],
  ['/admin/ventas', 'Resumen de ventas', false],
  ['/admin/ventas/vender', 'Ventanilla', false],
  ['/admin/ventas/pasajes', 'Pasajes', false],
  ['/admin/ventas/abonos', 'Abonos', false],
  ['/admin/ventas/caja', 'Cierre de caja', false],
  ['/admin/ventas/tarifas', 'Tarifas', false],
  ['/admin/ventas/mercadopago', 'Mercado Pago', false],
  ['/admin/ventas/usuarios', 'Usuarios de empresa', false],
  ['/admin/ventas/reportes', 'Reportes de ventas', false]
];
const SELLER_LINKS: [string, string, boolean][] = [
  ['/admin/ventas/vender', 'Ventanilla', false],
  ['/admin/ventas/pasajes', 'Pasajes', false],
  ['/admin/ventas/abonos', 'Abonos', false],
  ['/admin/ventas/caja', 'Cierre de caja', false],
  ['/admin/ventas/reportes', 'Reportes de ventas', false]
];
const SUPPORT_LINKS: [string, string, boolean][] = [
  ['/admin/ventas/pasajes', 'Pasajes', false],
  ['/admin/ventas/reportes', 'Reportes de ventas', false]
];
const STAFF_LINKS: [string, string, boolean, PlatformPermission['section']][] = [
  ['/admin/empresas', 'Empresas', false, 'companies'],
  ['/admin/gps', 'Seguimiento GPS', false, 'gps'],
  ['/admin/recorridos', 'Catálogo de recorridos', false, 'routes'],
  ['/admin/localidades', 'Localidades', false, 'places'],
  ['/admin/ventas/reportes', 'Reportes globales', false, 'reports']
];

// Iconos del menú (trazos simples de 24 px); los enlaces sin icono usan el de "documento".
const ICONS: Record<string, string> = {
  '/admin': 'M4 5h7v7H4zM13 5h7v4h-7zM13 11h7v8h-7zM4 14h7v5H4z',
  '/admin/empresas': 'M4 20V6l8-3 8 3v14M9 20v-5h6v5M8 9h2M14 9h2M8 12h2M14 12h2',
  '/admin/equipo': 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 19c0-3 3-5 6-5s6 2 6 5M16 6a3 3 0 0 1 0 5M18 14c2 .6 3 2.3 3 5',
  '/admin/gps': 'M12 21s7-6.2 7-11.5a7 7 0 0 0-14 0C5 14.800 12 21 12 21zM12 12a2.500 2.500 0 1 0 0-5 2.500 2.500 0 0 0 0 5z',
  '/admin/servicios': 'M4 6h16M4 12h16M4 18h10',
  '/admin/recorridos': 'M6 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM18 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM8 17h6a3 3 0 0 0 0-6h-4a3 3 0 0 1 0-6h6',
  '/admin/localidades': 'M12 21s6-5.400 6-10a6 6 0 0 0-12 0c0 4.600 6 10 6 10zM12 13a2 2 0 1 0 0-4 2 2 0 0 0 0 4z',
  '/admin/vehiculos': 'M4 16V7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v9M3 16h18v2H3zM7 21v-3M17 21v-3M4 11h16',
  '/admin/disposiciones': 'M5 4h5v5H5zM14 4h5v5h-5zM5 13h5v5H5zM14 13h5v5h-5z',
  '/admin/conductores': 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 3.500-6 8-6s8 2 8 6',
  '/admin/ventas': 'M5 20V10M12 20V4M19 20v-7',
  '/admin/ventas/vender': 'M3 7h18v10H3zM3 11h18M7 15h3',
  '/admin/ventas/pasajes': 'M4 8a2 2 0 0 0 0 4v4h16v-4a2 2 0 0 1 0-4V6H4zM14 6v12',
  '/admin/ventas/abonos': 'M4 6h16v12H4zM4 10h16M8 14h3',
  '/admin/ventas/caja': 'M4 7h16v12H4zM8 7V5h8v2M12 11v4M10 13h4',
  '/admin/ventas/tarifas': 'M20 12l-8 8-9-9V4h7zM8 8h.01',
  '/admin/ventas/mercadopago': 'M3 8h18v10H3zM3 12h18M16 15h2',
  '/admin/ventas/usuarios': 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 19c0-3 3-5 6-5s6 2 6 5M17 8v6M14 11h6',
  '/admin/ventas/reportes': 'M6 3h9l4 4v14H6zM14 3v5h5M9 13h7M9 17h7'
};
function NavIcon({ to }: { to: string }) {
  return <svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true"><path d={ICONS[to] ?? 'M6 3h9l4 4v14H6zM14 3v5h5'} /></svg>;
}

export function AdminLayout() {
  const { profile, signOut, blockedFeatures } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);   // menú desplegable (solo se usa en pantallas chicas)
  const { pathname } = useLocation();
  const [query, setQuery] = useState('');
  useEffect(() => { setMenuOpen(false); setQuery(''); }, [pathname]);
  const platform = profile?.role === 'platform_admin';
  const permissions = useQuery(async () => profile?.role === 'platform_staff'
    ? must(await supabase.from('platform_permissions').select('section,can_edit')) as Pick<PlatformPermission, 'section' | 'can_edit'>[]
    : [], [profile?.role]);
  const staffSections = new Set((permissions.data ?? []).map((permission) => permission.section));
  const staffLinks = STAFF_LINKS.filter(([, , , section]) => staffSections.has(section) || staffSections.has('all'));
  // Secciones que la empresa no tiene habilitadas (bloqueadas por el administrador general)
  const enabled = (links: [string, string, boolean][]) => links.filter(([to]) => !(
    (to === '/admin/gps' && blockedFeatures.includes('gps')) || (to.startsWith('/admin/ventas') && blockedFeatures.includes('fares'))
  ));
  const links = platform ? PLATFORM_LINKS
    : profile?.role === 'platform_staff' ? staffLinks
      : profile?.role === 'company_admin' ? enabled(LINKS)
        : profile?.role === 'seller' ? enabled(SELLER_LINKS)
          : enabled(SUPPORT_LINKS);
  const groups = platform ? PLATFORM_GROUPS : profile?.role === 'company_admin' ? COMPANY_GROUPS : {};
  const title = platform ? 'Administración general'
    : profile?.role === 'platform_staff' ? 'Equipo de plataforma'
      : profile?.role === 'support' ? 'Atención al cliente (solo lectura)'
        : profile?.role === 'seller' ? 'Ventas'
          : 'Administrador';
  const q = fold(query);
  const shown = q ? links.filter(([, label]) => fold(label).includes(q)) : links;
  // sección actual: el enlace más específico que coincide con la ruta
  const current = [...links].filter(([to, , end]) => (end ? pathname === to : pathname === to || pathname.startsWith(to + '/')))
    .sort((a, b) => b[0].length - a[0].length)[0]?.[1] ?? title;
  return (
    <div className="admin">
      <nav id="admin-nav" className={menuOpen ? 'open' : ''} aria-label="Menú del panel">
        <div className="who"><b>Pasajeros<span>.ar</span></b><small>{profile?.full_name}<br />{title}</small></div>
        <input type="search" className="nav-search" placeholder="Buscar sección…" aria-label="Buscar sección del menú" value={query} onChange={(e) => setQuery(e.target.value)} />
        {shown.map(([to, label, end]) => (
          <span key={to} className="nav-item">
            {!q && groups[to] && <span className="nav-group">{groups[to]}</span>}
            <NavLink to={to} end={end} className={({ isActive }) => (isActive ? 'active' : '')}><NavIcon to={to} />{label}</NavLink>
          </span>
        ))}
        {q && shown.length === 0 && <span className="nav-empty">Sin resultados</span>}
        <a href="#salir" className="nav-exit" onClick={(e) => { e.preventDefault(); void signOut(); }}><svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4H5v16h4M16 8l4 4-4 4M20 12H9" /></svg>Salir</a>
      </nav>
      <div className="admin-body">
        <header className="admin-topbar">
          <button type="button" className="menu-toggle secondary" aria-expanded={menuOpen} aria-controls="admin-nav" onClick={() => setMenuOpen((v) => !v)}>
            <svg viewBox="0 0 24 24" aria-hidden="true">{menuOpen ? <path d="M6 6l12 12M18 6 6 18" /> : <path d="M4 7h16M4 12h16M4 17h16" />}</svg>
            Menú
          </button>
          <span className="admin-topbar-title">{current}</span>
        </header>
        <ProfileMenu />
        <main>
          {profile?.role === 'platform_staff' && permissions.error && <Notice kind="error">{permissions.error}</Notice>}
          <Outlet />
        </main>
      </div>
    </div>
  );
}
