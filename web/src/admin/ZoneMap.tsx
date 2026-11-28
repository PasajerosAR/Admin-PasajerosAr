import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { searchPlaces, type Place } from '../lib/geoSearch';

interface Props {
  lat: number | null;
  lng: number | null;
  radius: number;
  others: { name: string; lat: number; lng: number; radius_m: number }[];   // las otras zonas, para verlas de referencia
  onPick: (lat: number, lng: number) => void;
}

const round = (n: number) => Math.round(n * 1e6) / 1e6;
const START: L.LatLngTuple = [-31.7333, -60.5236];

// Mapa para ubicar el galpón: clic o arrastre del pin, y el círculo muestra el radio permitido.
export function ZoneMap({ lat, lng, radius, others, onPick }: Props) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);
  const latest = useRef(onPick);
  latest.current = onPick;
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Place[]>([]);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!el.current || map.current) return;
    const m = L.map(el.current).setView(START, 13);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© colaboradores de <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    m.on('click', (e: L.LeafletMouseEvent) => latest.current(round(e.latlng.lat), round(e.latlng.lng)));
    map.current = m;
    return () => { m.remove(); map.current = null; };
  }, []);

  useEffect(() => {
    const m = map.current, g = layer.current;
    if (!m || !g) return;
    g.clearLayers();
    others.forEach((z) => L.circle([z.lat, z.lng], { radius: z.radius_m, color: '#64748b', weight: 1, fillOpacity: 0.08, dashArray: '4 6' }).bindTooltip(z.name).addTo(g));
    if (lat !== null && lng !== null) {
      L.circle([lat, lng], { radius, color: '#0f5b8a', weight: 2, fillOpacity: 0.15 }).addTo(g);
      const icon = L.divIcon({ className: '', html: '<div class="pin sel">★</div>', iconSize: [28, 28], iconAnchor: [14, 14] });
      const mk = L.marker([lat, lng], { icon, draggable: true, title: 'Arrastrá para ajustar' }).addTo(g);
      mk.on('dragend', () => { const p = mk.getLatLng(); latest.current(round(p.lat), round(p.lng)); });
    }
  }, [lat, lng, radius, others]);

  // al abrir una zona ya cargada, el mapa se centra ahí
  const centered = useRef(false);
  useEffect(() => {
    if (centered.current || lat === null || lng === null || !map.current) return;
    centered.current = true;
    map.current.setView([lat, lng], 17);
  }, [lat, lng]);

  const search = async () => {
    if (!query.trim()) return;
    setMsg('Buscando...'); setResults([]);
    try {
      const data = await searchPlaces(query);
      setResults(data);
      setMsg(data.length ? null : 'No se encontró ese lugar. Probá con otra dirección o ubicalo directo en el mapa.');
    } catch { setMsg('No se pudo buscar. Ubicá el pin a mano en el mapa.'); }
  };
  const go = (r: Place) => {
    const la = round(Number(r.lat)), lo = round(Number(r.lon));
    map.current?.setView([la, lo], 17);
    onPick(la, lo);
    setResults([]);
  };

  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label>Buscar dirección
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Calle y número, ciudad"
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void search(); } }} />
        </label>
        <button type="button" className="secondary" onClick={() => void search()}>Buscar</button>
      </div>
      {msg && <p className="muted" style={{ margin: 0 }}>{msg}</p>}
      {results.length > 0 && (
        <ul style={{ margin: 0, padding: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 4 }}>
          {results.map((r) => <li key={r.display_name}><button type="button" className="secondary" style={{ width: '100%', textAlign: 'left' }} onClick={() => go(r)}>{r.display_name}</button></li>)}
        </ul>
      )}
      <div ref={el} className="stopmap" role="application" aria-label="Mapa para ubicar la zona de marcaje" />
    </div>
  );
}
