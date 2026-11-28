// Funciones que el administrador general puede bloquear a cada empresa (columna companies.blocked_features).
// Para sumar un bloqueo nuevo: agregar su clave acá y en known_company_features() de la base, y aplicarlo donde corresponda.
export interface FeatureInfo { key: string; label: string; help: string }

export const COMPANY_FEATURES: FeatureInfo[] = [
  { key: 'web', label: 'Web de venta de pasajes', help: 'La empresa no aparece en la web de venta y no se le puede comprar por ahí.' },
  { key: 'gps', label: 'Seguimiento GPS', help: 'No se guarda la posición de sus unidades ni aparece en el mapa.' },
  { key: 'scanner', label: 'Escáner de pasajes', help: 'La app del conductor no muestra el lector de QR ni los pasajes de prueba.' },
  { key: 'fares', label: 'Tarifas, ventas y taquilla', help: 'Sin tarifas, ventas ni venta de pasajes: no hay ventanilla en el panel ni taquilla en la app del conductor.' },
  { key: 'incidents', label: 'Incidencias', help: 'El conductor no puede informar incidencias.' },
  { key: 'pay_cash', label: 'Cobro en efectivo (taquilla)', help: 'La taquilla de la app del conductor no cobra en efectivo.' },
  { key: 'pay_transfer', label: 'Cobro por transferencia (taquilla)', help: 'La taquilla de la app del conductor no cobra por transferencia.' },
  { key: 'pay_qr', label: 'Cobro por QR (taquilla)', help: 'La taquilla de la app del conductor no ofrece el cobro por QR.' },
  { key: 'clock', label: 'Marcaje de entrada y salida', help: 'El conductor inicia y cierra la jornada tocando el botón, sin foto ni ubicación, y no queda registro de marcajes.' },
  { key: 'counter', label: 'Contador de pasajeros', help: 'El conductor no puede cargar cuántos suben y bajan.' }
];

export const featureLabel = (key: string): string => COMPANY_FEATURES.find((f) => f.key === key)?.label ?? key;
