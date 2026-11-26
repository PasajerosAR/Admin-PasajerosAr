# Sistema de diseño v2 — Panel admin

Especificación del rediseño del panel admin (`web/src/admin`). La paleta de colores actual **no cambia** (azul `#0f5c8c`, fondos `#f1f5f9`, nav oscuro `#0d1824`). El objetivo es orden, densidad y coherencia: campos con ancho según su contenido, jerarquía clara, patrones idénticos en todas las páginas.

Regla de oro: **solo se cambia la estructura del JSX (clases, contenedores, posición de elementos) y nada de lógica** (estado, consultas, handlers, condiciones, ids, aria-labels). No se agregan dependencias, no se toca `lib/`, no se tocan estilos del conductor/login.

## Tokens (styles.css)

- `--control-h: 32px` (desktop) / `40px` (celular).
- h1: 20px · h2: 14px · cuerpo: 13px · muted: 12px · labels: 11.5px.
- Tarjetas: padding 14px 16px, radius 12px, `--shadow`.
- Contenido: `main` centrado con `max-width: 1240px`.

## Patrones de página (orden de arriba hacia abajo)

1. **`PageHead`** (nuevo componente en `../ui`): título + subtítulo opcional a la izquierda; acciones (botones) a la derecha.
   ```tsx
   <PageHead title="Flota" subtitle="Vehículos y disposiciones de asientos" actions={<><button>Acción</button></>} />
   ```
   Reemplaza al `<h1>` suelto y a las filas de botones sueltas que haya arriba de la página. Los botones importantes (p. ej. "Publicar") van en `actions`; los secundarios también, con `className="secondary"`.

2. **`toolbar`**: barra de controles de la página (fecha, tipo de día, botones de actualizar/generar). Fondo de tarjeta, `align-items: flex-end`. Solo si la página tiene varios controles sueltos arriba (ej. Operación del día).

3. **Avisos**: `Notice` como hasta ahora.

4. **Formulario de alta**: `card` + `form-grid` (reemplaza a `card stack` + `row` en formularios de alta/edición).
   ```tsx
   <form className="card" onSubmit={...}>
     <div className="card-head"><h2>Agregar vehículo</h2></div>
     <div className="form-grid">
       <label>Tipo<select …>…</select></label>
       <label>Nombre<input … /></label>
       <label className="span-2">Año<input type="number" … /></label>   {/* campo corto */}
       <label className="span-12">Descripción<input … /></label>        {/* ancho completo */}
       <div className="form-actions"><button type="submit">Guardar</button></div>
     </div>
   </form>
   ```
   Columnas: cada `label` ocupa 4/12 por defecto (3 por fila); `span-2` = 2/12 (números, fechas cortas), `span-6` = 6/12, `span-12` = fila completa. Los botones de submit van en `.form-actions` al final.

5. **Listado**: `card list-card` (reemplaza a `card table-wrap` + FilterBox suelto):
   ```tsx
   <div className="card list-card">
     <div className="list-head">
       <FilterBox … />
       {/* filtros extra como <label className="inline">…</label> opcional */}
       <span className="list-head-spacer" />
       {/* acciones del listado, ej. botones de exportar, si la página ya los tenía */}
     </div>
     <div className="table-wrap">
       <table>…</table>
     </div>
     {/* nota al pie si existía, como */}
     <p className="list-foot">…texto muted…</p>
   </div>
   ```
   El BulkBar, si la página lo usa, va justo debajo de `.list-head` (dentro de list-head está bien también; elegir lo que quede más limpio).

6. **Notas muted de ayuda**: si estaban al pie de la lista pasan a `.list-foot`; si explicaban un formulario se mantienen dentro de la card con `className="muted"` pero al final, después de `.form-actions`.

## Reglas de controles

- **Números**: `type="number"` ya queda compacto por CSS (ancho por dígitos, sin flechitas, alineado a la derecha). No poner `style` de ancho a mano.
- **Fechas/horas**: `type="date"`, `type="datetime-local"` y `TimeInput` ya quedan compactos por CSS. No fijar ancho con estilos inline.
- **Selects**: `width: auto` por CSS; quitar cualquier `style={{ flex: … }}` de ancho que tuvieran.
- **Labels**: siempre `<label>Texto<control/></label>`; no cambiar el orden texto/control.
- **Botones de tabla**: quedan compactos por CSS (`td button`). Usar `className="td-actions"` en el `<td>` de acciones para alinear a la derecha.
- Prohibido agregar `style={{ ... }}` de layout/espaciado; todo va por clases.

## Estadísticas (Ventas, Reportes)

Reemplazar las `<section className="card stack">` de números por:
```tsx
<div className="stats">
  <div className="stat"><span>Ventas</span><b>{totals.sales}</b></div>
  …
</div>
```
Quitar los `style={{ fontSize: 24 }}` inline.

## Archivos y alcance por grupo

- Grupo operación: `admin/TripsPage.tsx`, `admin/FirstSteps.tsx`, `admin/LiveTripsPage.tsx`, `admin/GpsAlerts.tsx`
- Grupo catálogo: `admin/ServicesPage.tsx`, `admin/RoutesPage.tsx`, `admin/PlacesPage.tsx`, `admin/StopMap.tsx`
- Grupo flota: `admin/VehiclesPage.tsx`, `admin/DriversPage.tsx`, `admin/LayoutsPage.tsx`, `admin/LayoutEditorPage.tsx`
- Grupo ventas: `admin/sales/*.tsx` (10 archivos)
- Grupo plataforma: `admin/CompaniesPage.tsx`, `admin/PlatformStaffPage.tsx`

Los componentes compartidos (`ui.tsx`, `bulk.tsx`, `SearchSelect.tsx`, `AdminLayout.tsx`, `ProfileMenu.tsx`) y `styles.css` ya están rediseñados: **no modificarlos**.

## Verificación

Al terminar cada página: `cd web && npm run typecheck` debe pasar sin errores nuevos. Los tests (`npm test`) no se tocan. Reportar: archivos modificados, decisiones de layout tomadas y cualquier cosa que haya quedado dudosa.

## Estética

- Jerarquía clara: un solo título grande, acciones visibles arriba a la derecha.
- Sin cajas anidadas innecesarias (card dentro de card solo si el diseño actual ya lo exigía, ej. ventanilla).
- Espaciado consistente; tablas densas (padding 7px 10px).
- Sin gradientes nuevos, sin sombras exageradas, esquinas 8–12px.
- Móvil: todo colapsa a una columna (el CSS ya lo maneja; verificar que ninguna página se desborde).
