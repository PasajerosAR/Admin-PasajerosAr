import { Navigate, Route, Routes } from 'react-router-dom';
import type { ReactNode } from 'react';
import { useAuth } from './auth/AuthProvider';
import { Login } from './auth/Login';
import { configured } from './lib/supabase';
import { Loading, Notice } from './ui';
import { AdminLayout } from './admin/AdminLayout';
import { TripsPage } from './admin/TripsPage';
import { VehiclesPage } from './admin/VehiclesPage';
import { LayoutsPage } from './admin/LayoutsPage';
import { LayoutEditorPage } from './admin/LayoutEditorPage';
import { RoutesPage } from './admin/RoutesPage';
import { ServicesPage } from './admin/ServicesPage';
import { PlacesPage } from './admin/PlacesPage';
import { CompaniesPage } from './admin/CompaniesPage';
import { PlatformStaffPage } from './admin/PlatformStaffPage';
import { DriversPage } from './admin/DriversPage';
import { LiveTripsPage } from './admin/LiveTripsPage';
import { CompanyUsersPage } from './admin/sales/CompanyUsersPage';
import { SellTicketPage } from './admin/sales/SellTicketPage';
import { TicketsPage } from './admin/sales/TicketsPage';
import { TarifasPage } from './admin/sales/TarifasPage';
import { SalesDashboardPage } from './admin/sales/SalesDashboardPage';
import { SalesReportsPage } from './admin/sales/SalesReportsPage';
import { MercadoPagoPage } from './admin/sales/MercadoPagoPage';
import type { PlatformPermission } from './lib/types';
import { must } from './lib/useQuery';
import { supabase } from './lib/supabase';
import { DriverThemeProvider } from './auth/DriverTheme';
import { useQuery } from './lib/useQuery';

const STAFF_PATHS: Record<PlatformPermission['section'], string> = {
  companies: '/admin/empresas',
  routes: '/admin/recorridos',
  places: '/admin/localidades',
  gps: '/admin/gps',
  reports: '/admin/ventas/reportes',
  all: '/admin/empresas'
};

function StaffHome() {
  const permissions = useQuery<{ section: PlatformPermission['section'] }[]>(async () =>
    must(await supabase.from('platform_permissions').select('section')) as { section: PlatformPermission['section'] }[], []);
  if (permissions.loading) return <Loading />;
  if (permissions.error) return <Notice kind="error">{permissions.error}</Notice>;
  const section = permissions.data?.[0]?.section;
  return section ? <Navigate to={STAFF_PATHS[section]} replace /> : <Notice>Tu usuario no tiene permisos asignados.</Notice>;
}

function StaffRoute({ section, children }: { section: PlatformPermission['section']; children: ReactNode }) {
  const permission = useQuery(async () => must(await supabase.from('platform_permissions')
    .select('section').or(`section.eq.${section},section.eq.all`).limit(1)), [section]);
  if (permission.loading) return <Loading />;
  if (permission.error) return <Notice kind="error">{permission.error}</Notice>;
  return permission.data?.length ? <>{children}</> : <Navigate to="/admin" replace />;
}

export function App() {
  const { loading, session, profile, signOut } = useAuth();

  if (!configured) {
    return (
      <div className="center">
        <h1>Falta configurar Supabase</h1>
        <Notice kind="warn">Copiá <code>.env.example</code> a <code>.env.local</code> y completá VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY.</Notice>
      </div>
    );
  }
  if (loading) return <div className="center"><Loading /></div>;
  if (!session) {
    return <DriverThemeProvider><Login /></DriverThemeProvider>;
  }
  if (!profile || !profile.active) {
    return (
      <div className="center">
        <Notice>Tu usuario no tiene un perfil activo. Pedile al administrador de tu empresa que lo habilite.</Notice>
        <button className="secondary" onClick={signOut}>Salir</button>
      </div>
    );
  }
  if (profile.role === 'platform_admin') {
    return (
      <Routes>
        <Route path="/admin" element={<AdminLayout />}>
          <Route index element={<CompaniesPage />} />
          <Route path="empresas" element={<CompaniesPage />} />
          <Route path="equipo" element={<PlatformStaffPage />} />
          <Route path="gps" element={<LiveTripsPage />} />
          <Route path="recorridos" element={<RoutesPage />} />
          <Route path="localidades" element={<PlacesPage />} />
          <Route path="ventas/reportes" element={<SalesReportsPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/admin" replace />} />
      </Routes>
    );
  }

  if (profile.role === 'platform_staff') {
    return (
      <Routes>
        <Route path="/admin" element={<AdminLayout />}>
          <Route index element={<StaffHome />} />
          <Route path="gps" element={<StaffRoute section="gps"><LiveTripsPage /></StaffRoute>} />
          <Route path="recorridos" element={<StaffRoute section="routes"><RoutesPage /></StaffRoute>} />
          <Route path="localidades" element={<StaffRoute section="places"><PlacesPage /></StaffRoute>} />
          <Route path="ventas/reportes" element={<StaffRoute section="reports"><SalesReportsPage /></StaffRoute>} />
          <Route path="empresas" element={<StaffRoute section="companies"><CompaniesPage /></StaffRoute>} />
        </Route>
        <Route path="*" element={<Navigate to="/admin" replace />} />
      </Routes>
    );
  }

  if (profile.role === 'driver') {
    return (
      <div className="center">
        <Notice>Los conductores usan la app del conductor. Este panel es solo para administración.</Notice>
        <button className="secondary" onClick={signOut}>Salir</button>
      </div>
    );
  }

  return (
    <Routes>
      <Route path="/admin" element={<AdminLayout />}>
        <Route index element={profile.role === 'seller' ? <Navigate to="/admin/ventas/vender" replace />
          : profile.role === 'support' ? <Navigate to="/admin/ventas/reportes" replace /> : <TripsPage />} />
        <Route path="gps" element={profile.role === 'company_admin' ? <LiveTripsPage /> : <Navigate to="/admin" replace />} />
        <Route path="vehiculos" element={profile.role === 'company_admin' ? <VehiclesPage /> : <Navigate to="/admin" replace />} />
        <Route path="disposiciones" element={profile.role === 'company_admin' ? <LayoutsPage /> : <Navigate to="/admin" replace />} />
        <Route path="disposiciones/:id" element={profile.role === 'company_admin' ? <LayoutEditorPage /> : <Navigate to="/admin" replace />} />
        <Route path="recorridos" element={profile.role === 'company_admin' || profile.role === 'support' ? <RoutesPage /> : <Navigate to="/admin" replace />} />
        <Route path="servicios" element={profile.role === 'company_admin' ? <ServicesPage /> : <Navigate to="/admin" replace />} />
        <Route path="conductores" element={profile.role === 'company_admin' ? <DriversPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas" element={profile.role === 'company_admin' ? <SalesDashboardPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/vender" element={profile.role === 'company_admin' || profile.role === 'seller' ? <SellTicketPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/mercadopago" element={profile.role === 'company_admin' ? <MercadoPagoPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/pasajes" element={profile.role === 'company_admin' || profile.role === 'seller' || profile.role === 'support' ? <TicketsPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/tarifas" element={profile.role === 'company_admin' ? <TarifasPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/usuarios" element={profile.role === 'company_admin' ? <CompanyUsersPage /> : <Navigate to="/admin" replace />} />
        <Route path="ventas/reportes" element={<SalesReportsPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/admin" replace />} />
    </Routes>
  );
}
