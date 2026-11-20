import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { must, useQuery } from '../lib/useQuery';
import { supabase } from '../lib/supabase';
import type { PlatformPermission } from '../lib/types';
import { Notice } from '../ui';
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
  ['/admin/ventas/caja', 'Cierre de caja', false],
  ['/admin/ventas/tarifas', 'Tarifas', false],
  ['/admin/ventas/mercadopago', 'Mercado Pago', false],
  ['/admin/ventas/usuarios', 'Usuarios de empresa', false],
  ['/admin/ventas/reportes', 'Reportes de ventas', false]
];
const SELLER_LINKS: [string, string, boolean][] = [
  ['/admin/ventas/vender', 'Ventanilla', false],
  ['/admin/ventas/pasajes', 'Pasajes', false],
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

export function AdminLayout() {
  const { profile, signOut, blockedFeatures } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);   // menú desplegable (solo se usa en pantallas chicas)
  const { pathname } = useLocation();
  useEffect(() => { setMenuOpen(false); }, [pathname]);
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
  return (
    <div className="admin">
      <header className="admin-topbar">
        <button type="button" className="menu-toggle secondary" aria-expanded={menuOpen} aria-controls="admin-nav" onClick={() => setMenuOpen((v) => !v)}>
          <svg viewBox="0 0 24 24" aria-hidden="true">{menuOpen ? <path d="M6 6l12 12M18 6 6 18" /> : <path d="M4 7h16M4 12h16M4 17h16" />}</svg>
          Menú
        </button>
        <span className="admin-topbar-title">{title}</span>
      </header>
      <nav id="admin-nav" className={menuOpen ? 'open' : ''} aria-label="Menú del panel">
        <div className="who">{profile?.full_name}<br />{title}</div>
        {links.map(([to, label, end]) => (
          <span key={to} className="nav-item">
            {groups[to] && <span className="nav-group">{groups[to]}</span>}
            <NavLink to={to} end={end} className={({ isActive }) => (isActive ? 'active' : '')}>{label}</NavLink>
          </span>
        ))}
        <a href="#salir" onClick={(e) => { e.preventDefault(); void signOut(); }}>Salir</a>
      </nav>
      <ProfileMenu />
      <main>
        {profile?.role === 'platform_staff' && permissions.error && <Notice kind="error">{permissions.error}</Notice>}
        <Outlet />
      </main>
    </div>
  );
}
