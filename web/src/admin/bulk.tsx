import { useState } from 'react';

// Selección múltiple para las listas del admin: casilla por fila, "seleccionar todo" arriba y barra para eliminar lo marcado.
export interface Bulk {
  count: number; selected: string[]; all: boolean; some: boolean;
  has: (id: string) => boolean; toggle: (id: string) => void; toggleAll: () => void; clear: () => void;
}

/** `ids` son las filas que se ven ahora (ya filtradas): "seleccionar todo" actúa solo sobre esas. */
export function useBulk(ids: string[]): Bulk {
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const selected = ids.filter((id) => picked.has(id));
  const all = ids.length > 0 && selected.length === ids.length;
  return {
    count: selected.length, selected, all, some: selected.length > 0 && !all,
    has: (id) => picked.has(id),
    toggle: (id) => setPicked((prev) => { const next = new Set(prev); if (next.has(id)) next.delete(id); else next.add(id); return next; }),
    toggleAll: () => setPicked(all ? new Set() : new Set(ids)),
    clear: () => setPicked(new Set())
  };
}

export function HeadCheck({ bulk, disabled }: { bulk: Bulk; disabled?: boolean }) {
  return (
    <th className="bulk-col">
      <input type="checkbox" aria-label="Seleccionar todo" checked={bulk.all} disabled={disabled}
        ref={(el) => { if (el) el.indeterminate = bulk.some; }} onChange={bulk.toggleAll} />
    </th>
  );
}

export function RowCheck({ bulk, id, disabled }: { bulk: Bulk; id: string; disabled?: boolean }) {
  return (
    <td className="bulk-col">
      <input type="checkbox" aria-label="Seleccionar" checked={bulk.has(id)} disabled={disabled} onChange={() => bulk.toggle(id)} />
    </td>
  );
}

export const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** Confirmación común: "¿Estás seguro que quieres eliminar 3 abonos?" */
export const confirmDelete = (n: number, one: string, many: string, extra?: string) =>
  window.confirm(`¿Estás seguro que quieres eliminar ${plural(n, one, many)}?${extra ? `\n\n${extra}` : ''}`);

export function BulkBar({ bulk, one, many, busy, onDelete }: { bulk: Bulk; one: string; many: string; busy?: boolean; onDelete: () => void }) {
  if (bulk.count === 0) return null;
  return (
    <div className="bulk-bar" role="status">
      <b>{plural(bulk.count, `${one} seleccionado`, `${many} seleccionados`)}</b>
      <button type="button" className="danger" disabled={busy} onClick={onDelete}>{busy ? 'Eliminando...' : 'Eliminar seleccionados'}</button>
      <button type="button" className="secondary" disabled={busy} onClick={bulk.clear}>Quitar selección</button>
    </div>
  );
}
