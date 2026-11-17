// Funciones que el administrador general puede bloquear a cada empresa (columna companies.blocked_features).
// Para sumar un bloqueo nuevo: agregar su clave acá y en known_company_features() de la base, y aplicarlo donde corresponda.
export interface FeatureInfo { key: string; label: string; help: string }

export const COMPANY_FEATURES: FeatureInfo[] = [
  { key: 'web', label: 'Web de venta de pasajes', help: 'La empresa no aparece en la web de venta y no se le puede comprar por ahí.' },
  { key: 'gps', label: 'Seguimiento GPS', help: 'No se guarda la posición de sus unidades ni aparece en el mapa.' },
  { key: 'scanner', label: 'Escáner de pasajes', help: 'La app del conductor no muestra el lector de QR ni los pasajes de prueba.' },
  { key: 'fares', label: 'Tarifas y ventas', help: 'Sin sección de ventas, tarifas ni venta de pasajes en el panel.' },
  { key: 'incidents', label: 'Incidencias', help: 'El conductor no puede informar incidencias.' },
  { key: 'counter', label: 'Contador de pasajeros', help: 'El conductor no puede cargar cuántos suben y bajan.' }
];

export const featureLabel = (key: string): string => COMPANY_FEATURES.find((f) => f.key === key)?.label ?? key;
