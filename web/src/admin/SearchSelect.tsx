import { useEffect, useRef, useState } from 'react';

export interface SearchOption { value: string; label: string }

// Lista desplegable con buscador, para elegir entre muchas opciones sin recorrer un select enorme.
export function SearchSelect({ options, value, onChange, placeholder = 'Buscar...', emptyLabel = 'Sin resultados' }: {
  options: SearchOption[]; value: string; onChange: (value: string) => void; placeholder?: string; emptyLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const box = useRef<HTMLDivElement>(null);
  const selected = options.find((o) => o.value === value);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  const needle = text.trim().toLocaleLowerCase('es-AR');
  const shown = options.filter((o) => !needle || o.label.toLocaleLowerCase('es-AR').includes(needle)).slice(0, 50);
  const pick = (v: string) => { onChange(v); setOpen(false); setText(''); };
  return (
    <div className="search-select" ref={box}>
      <input
        role="combobox" aria-expanded={open} aria-autocomplete="list" placeholder={placeholder} autoComplete="off"
        value={open ? text : selected?.label ?? ''}
        onFocus={() => { setOpen(true); setText(''); }}
        onChange={(e) => { setText(e.target.value); setOpen(true); }}
        onKeyDown={(e) => { if (e.key === 'Escape') setOpen(false); if (e.key === 'Enter' && shown[0]) { e.preventDefault(); pick(shown[0].value); } }}
      />
      {open && (
        <ul role="listbox">
          {shown.length === 0 && <li className="muted">{emptyLabel}</li>}
          {shown.map((o) => (
            <li key={o.value} role="option" aria-selected={o.value === value} className={o.value === value ? 'on' : ''}
              onMouseDown={(e) => { e.preventDefault(); pick(o.value); }}>{o.label}</li>
          ))}
        </ul>
      )}
    </div>
  );
}
