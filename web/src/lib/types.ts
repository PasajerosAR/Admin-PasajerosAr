import type { DayType } from './dayType';
import type { CellKind } from './seatGrid';
import type { Maneuver } from './turnGuide';

export type UserRole = 'platform_admin' | 'platform_staff' | 'company_admin' | 'seller' | 'support' | 'driver';
export type VehicleStatus = 'available' | 'assigned' | 'in_service' | 'maintenance' | 'out_of_service' | 'retired';
export type TripStatus = 'scheduled' | 'in_progress' | 'completed' | 'cancelled';

export interface Profile {
  id: string;
  company_id: string | null;
  role: UserRole;
  full_name: string;
  dni: string | null;
  phone: string | null;
  active: boolean;
}

export interface Vehicle {
  id: string;
  company_id: string;
  kind: 'combi' | 'minibus' | 'colectivo';
  internal_number: string;
  plate: string;
  brand: string | null;
  model: string | null;
  year: number | null;
  status: VehicleStatus;
  layout_id: string | null;
}

export interface SeatLayout {
  id: string;
  company_id: string;
  group_id: string;
  version: number;
  name: string;
  locked_at: string | null;
}

export interface Locality { id: string; name: string; province: string | null }
export interface Route {
  id: string; name: string; active: boolean; company_id: string | null;
  origin_place_id: string | null; destination_place_id: string | null;
  path: [number, number][] | null; via: { seg: number; lat: number; lng: number }[] | null;
  maneuvers: Maneuver[] | null;
}
export interface RouteStop {
  id: string; route_id: string; position: number; name: string; lat: number | null; lng: number | null; place_id: string | null;
}
export interface ServiceStop { service_id: string; route_stop_id: string; minutes_from_start: number; dwell_minutes: number }
export interface Company { id: string; name: string; active: boolean; created_at: string; logo_path: string | null; blocked_features: string[] }
export interface Service { id: string; code: string; active: boolean }
export interface ServiceDeparture {
  id: string; service_id: string; route_id: string; departure_time: string; day_types: DayType[]; active: boolean;
}

export interface Trip {
  id: string;
  service_id: string;
  service_date: string;
  scheduled_departure: string;
  vehicle_id: string | null;
  layout_id: string | null;
  driver_id: string | null;
  status: TripStatus;
  started_at: string | null;
  ended_at: string | null;
  started_manually: boolean;
  start_reason: string | null;
}

export interface Shift { id: string; driver_id: string; started_at: string; ended_at: string | null }

export interface CountResult { onboard: number; capacity: number; over_capacity: boolean }

export type { CellKind };

export const STATUS_LABEL: Record<TripStatus, string> = {
  scheduled: 'Programado', in_progress: 'En viaje', completed: 'Finalizado', cancelled: 'Cancelado'
};
export const VEHICLE_STATUS_LABEL: Record<VehicleStatus, string> = {
  available: 'Disponible', assigned: 'Asignado', in_service: 'En servicio',
  maintenance: 'En mantenimiento', out_of_service: 'Fuera de servicio', retired: 'Baja definitiva'
};
export const VEHICLE_KIND_LABEL: Record<Vehicle['kind'], string> = {
  combi: 'Combi', minibus: 'Minibús', colectivo: 'Colectivo'
};

export type IncidentKind = 'breakdown' | 'delay' | 'accident' | 'traffic' | 'other';
export const INCIDENT_LABEL: Record<IncidentKind, string> = {
  breakdown: 'Falla mecánica', delay: 'Demora', accident: 'Accidente', traffic: 'Tránsito o corte', other: 'Otra'
};

// ---------------------------------------------------------------- módulo de ventas
export type PaymentMethod = 'cash' | 'debit' | 'credit' | 'transfer' | 'mp' | 'complimentary';
export type SaleStatus    = 'completed' | 'refunded' | 'partial_refund';
export type TicketStatus  = 'valid' | 'boarded' | 'cancelled';

export const PAYMENT_METHOD_LABEL: Record<PaymentMethod, string> = {
  cash: 'Efectivo', debit: 'Débito', credit: 'Crédito',
  transfer: 'Transferencia', mp: 'MercadoPago', complimentary: 'Cortesía'
};
export const SALE_STATUS_LABEL: Record<SaleStatus, string> = {
  completed: 'Completada', refunded: 'Devuelta', partial_refund: 'Dev. parcial'
};
export const TICKET_STATUS_LABEL: Record<TicketStatus, string> = {
  valid: 'Válido', boarded: 'Abordo', cancelled: 'Cancelado'
};

export interface TicketPrice {
  id: string;
  company_id: string;
  route_id: string;
  from_pos: number;
  to_pos: number;
  price: number;
  seat_class: string | null;
  active: boolean;
}

export interface Sale {
  id: string;
  company_id: string;
  seller_id: string;
  trip_id: string;
  payment_method: PaymentMethod;
  mp_payment_id: string | null;
  total: number;
  status: SaleStatus;
  notes: string | null;
  created_at: string;
  refunded_at: string | null;
  refunded_by: string | null;
}

export interface SaleTicket {
  id: string;
  company_id: string;
  sale_id: string;
  trip_id: string;
  seat_label: string | null;
  layout_cell_id: string | null;
  from_stop_id: string;
  to_stop_id: string;
  passenger_name: string;
  passenger_dni: string;
  passenger_email: string;
  passenger_phone: string;
  price: number;
  qr_code: string;
  is_complimentary: boolean;
  status: TicketStatus;
  boarded_at: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancel_reason: string | null;
  created_at: string;
}

export interface PlatformPermission {
  id: string;
  profile_id: string;
  section: 'companies' | 'routes' | 'places' | 'gps' | 'reports' | 'all';
  can_edit: boolean;
  granted_by: string;
}
