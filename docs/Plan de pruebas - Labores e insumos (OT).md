# Plan de pruebas — Registro de labores e insumos (tablero_insumos_ot.html)

Rama: `feature/formulaciones-y-reportes-2026-10-30`
Versión del cliente de referencia: `client-src/2026-10-30/` (más su corrección de "Corregir aplicación" del 01/11)

Cómo usarlo: marcar cada caso con **OK** o **ERROR** y anotar al lado lo que se vio (como en `Casos testing usuarios permisos .txt`). Si algo falla, anotar empresa, número de OT y pasos exactos.

---

## 0. Preparación

### 0.1 Entorno
- [ ] Levantar Docker (`docker compose up -d`).
- [ ] Si la base no es la local que ya tiene todo aplicado, correr en orden: `012_tarifas_referencia_labor.sql`, `013_ot_ultimo_registro.sql`, `014_tanda_e_impresa.sql`, `015_ot_rapida.sql`. Después `docker compose restart api_server`.
- [ ] Abrir el tablero con la consola del navegador abierta (F12). **Cualquier error rojo en consola es un ERROR**, aunque la pantalla parezca andar.

### 0.2 Datos base (en una empresa de prueba, ej. Don Eduardo)
- [ ] Una campaña activa con **Plan de uso del suelo** cargado: al menos 2 campos y 4 lotes con cultivo (ej. 2 de Soja, 2 de Maíz) y una unidad de negocio que no sea cultivo (ej. Estructura o Arrendamiento).
- [ ] Maestros: 3 insumos (uno con formulación asignada, uno sin), 2 depósitos, 1 contratista.
- [ ] Labores: se cargan en **Maestros / Padrones (`maestros.html`) → Labores**, entrando como **admin general** (para los demás roles ese catálogo es de solo lectura). Es una sola lista global: la misma labor sirve como propia o contratada; el tipo se elige en cada trabajo de la OT. Cargar al menos: "Siembra soja", "Resiembra soja", "Pulverización" y "Fertilización". El "Precio ref." de la labor se usa como tarifa sugerida si no hay tarifa de referencia por campaña.
- [ ] Stock inicial: una compra/ingreso con fecha **anterior** a las OT de prueba, con stock suficiente de 2 insumos y escaso de 1 (para provocar el aviso de faltante).
- [ ] Precio unitario cargado en los insumos (solapa Maestros → Insumos de este tablero) para ver importes en Costos.
- [ ] Usuarios: uno con nivel **ver**, uno **cargar** y uno **administrar** sobre la empresa.

---

## 1. Maestros: tarifa de referencia de labores propias
- [ ] 1.1 Maestros → Labores propias **sin** campaña elegida. Esperado: pide elegir campaña, no deja editar tarifas.
- [ ] 1.2 Con campaña elegida, cargar tarifa y moneda de una labor. Recargar la página. Esperado: el valor persiste para esa campaña.
- [ ] 1.3 Cambiar a otra campaña. Esperado: la tarifa es independiente (vacía o la de esa campaña).
- [ ] 1.4 Con usuario **cargar**. Esperado: no puede modificar la tarifa de referencia (requiere administrar).
- [ ] 1.5 Maestros → Labores contratadas. Esperado: lista de solo lectura ("se carga en cada OT").

## 2. Crear una OT (ventanas 1, 2 y 3)

### Ventana 1 — Datos
- [ ] 2.1 "＋ Nueva orden de trabajo". Esperado: abre la pantalla de 4 solapas en **1 Datos**; la solapa 4 está deshabilitada.
- [ ] 2.2 Intentar avanzar sin campaña. Esperado: no deja (la campaña es obligatoria).

### Ventana 2 — Trabajos
- [ ] 2.3 Sin trabajos, el texto explica que la orden es una o más labores. "+ Nuevo trabajo" abre el armado (pasos A, B, C).
- [ ] 2.4 **Trabajo 1 — labor propia sobre lotes:** labor propia, 2 insumos con dosis y depósito, cultivo Soja, tildar 2 lotes, "↓ Sumar al trabajo", "✓ Agregar". Esperado: aparece T1 con sus lotes × insumos y el requerimiento total = dosis × ha.
- [ ] 2.5 La tarifa del trabajo 1 tomó la tarifa de referencia de la campaña (verificar después en la solapa Labores).
- [ ] 2.6 El insumo con formulación muestra su EIQ/banda (si están en Maestros).
- [ ] 2.7 **Trabajo 2 — labor contratada sobre unidad de negocio:** labor contratada, elegir contratista, en C elegir la unidad de negocio y un campo. Dejar la descripción vacía y "✓ Agregar". Esperado: pide describir el trabajo. Completar la descripción y agregar. Esperado: T2 con etiqueta "… · sin lote".
- [ ] 2.8 Labor contratada **sin** contratista. Esperado: pregunta si agregar igual.
- [ ] 2.9 Insumo sin dosis. Esperado: aviso, no deja agregar.
- [ ] 2.10 Resiembra:
  - Elegir "Pulverización". Esperado: no aparece "¿Es resiembra?" (solo aparece en labores de siembra).
  - Elegir "Siembra soja" y tildar "Sí, es resiembra". Esperado: el trabajo muestra el badge "Resiembra".
  - Elegir "Resiembra soja" sin tildar nada. Esperado: badge "Resiembra" igual (se detecta por el nombre).
  - En Costos, la resiembra suma al costo pero **no** a la superficie sembrada.
- [ ] 2.11 En T1 "+ Agregar lote", sumar un tercer lote. Esperado: el lote nuevo trae la receta del trabajo.
- [ ] 2.12 Editar en línea ha, dosis, insumo y observación de un lote ya agregado. Esperado: recalcula el requerimiento.
- [ ] 2.13 Quitar el único lote de un trabajo (⌫). Esperado: el trabajo queda con aviso "se quedó sin lotes", no se borra solo.
- [ ] 2.14 Quitar un trabajo (✕). Esperado: pide confirmación.
- [ ] 2.15 "✕ Cancelar este trabajo" con datos cargados. Esperado: pide confirmar el descarte.
- [ ] 2.16 Dejar un trabajo a medio armar y pasar a la ventana 3. Esperado: se agrega solo (o avisa qué falta).

### Ventana 3 — Revisar
- [ ] 2.17 Esperado: totales por insumo en **orden de mezclado** (el de formulación primero según su orden), depósito y disponible (= stock real − comprometido por otras OT).
- [ ] 2.18 Con el insumo de stock escaso. Esperado: avisa el faltante pero **deja emitir**.
- [ ] 2.19 "← Anterior" hasta la ventana 1 y volver. Esperado: no se pierden observaciones ni trabajos.
- [ ] 2.20 "Emitir OT". Esperado: pantalla "Se emitió la OT #N" con Nueva OT / Ver la OT / Imprimir. El número es correlativo.
- [ ] 2.21 Recargar la página. Esperado: la OT está en el listado con sus 2 trabajos idénticos.

### Navegación y cambios sin guardar
- [ ] 2.22 Empezar otra OT nueva, cargar algo y salir al listado. Esperado: pide confirmación.
- [ ] 2.23 En una OT existente, cambiar algo y "Descartar cambios". Esperado: vuelve a lo guardado.
- [ ] 2.24 Abrir una OT desde el listado. Esperado: entra a la ventana 4. "Editar" entra a la 1.

## 3. Impresión
- [ ] 3.1 "🖨 Imprimir para el campo". Esperado: documento por lote, cada labor con insumos en orden de mezclado, cuadros para completar, total de la orden y firmas. Aviso de que no hay hoja de mapa (conocido).
- [ ] 3.2 "Volver" desde la impresión. Esperado: regresa a la OT sin perder lo que se estaba editando.
- [ ] 3.3 Editar esa OT. Esperado: banner "Ya se imprimió esta OT". Al guardar, pide confirmar mostrando el resumen de cambios.

## 4. Lo realizado (ventana 4)

### Paso a — Qué se hizo
- [ ] 4.1 Esperado: todos los lotes/destinos pendientes en "Se hizo", fecha general = hoy.
- [ ] 4.2 Lote A: "Se hizo", superficie real menor que la planificada y otra fecha. Lote B: "Queda pendiente". Lote C: "Se hizo" normal.
- [ ] 4.3 Dejar en blanco la superficie de un lote "Se hizo". Esperado: "Falta la superficie realmente trabajada…".
- [ ] 4.4 Marcar todo en "Queda pendiente". Esperado: pide marcar al menos uno como "Se hizo" o "No se hace".
- [ ] 4.5 "Marcar todo «Se hizo»" vuelve todo a Se hizo.

### Paso b — Insumos y confirmar
- [ ] 4.6 Esperado: una fila por insumo y depósito con Planificado, Entregado (editable), Devolución, Baja y Consumido calculado.
- [ ] 4.7 El selector de depósito muestra el **stock a la fecha** del registro (probar con una fecha atrasada: el saldo debe ser el de ese día, no el de hoy).
- [ ] 4.8 Devolución + baja > entregado. Esperado: no deja avanzar.
- [ ] 4.9 Insumo sin depósito. Esperado: pide elegirlo.
- [ ] 4.10 "▸ Ver consumo por lote". Esperado: prorrateo por lote coherente con la superficie real.
- [ ] 4.11 "✓ Confirmar OT" con stock insuficiente a la fecha. Esperado: pregunta si confirmar igual (stock negativo).
- [ ] 4.12 Confirmar. Esperado: pantalla "Se confirmaron N labores…", OT en estado **Parcial**.
- [ ] 4.13 Movimientos / Stock: el stock bajó lo consumido + baja; hay un comprobante por trabajo y fecha (los lotes con fechas distintas generan comprobantes distintos).
- [ ] 4.14 Registrar el lote B pendiente. Esperado: OT pasa a **Aplicada**.

### No se hace
- [ ] 4.15 En otra OT, cargar facturación a un trabajo contratado (solapa Labores) y en Lo realizado marcar todos sus lotes "No se hace". Esperado: aviso de que el trabajo se borra con su facturación y pagos; al aceptar, el trabajo desaparece de la OT.
- [ ] 4.16 Marcar **todo** "No se hace". Esperado: sugiere cancelar la OT en lugar de eso.

## 5. Volver a pendiente y Corregir aplicación
- [ ] 5.1 En una OT aplicada, "Volver a pendiente". Esperado: confirma listando lo que vuelve al stock; el stock se repone; la OT queda pendiente.
- [ ] 5.2 Recargar la página y entrar a Lo realizado. Esperado: aviso "Están cargados los datos de la última vez", con fechas, superficies y cantidades precargadas.
- [ ] 5.3 Confirmar sin cambiar nada. Esperado: los mismos comprobantes y movimientos que antes (mismas cantidades, fechas y depósitos).
- [ ] 5.4 Repetir 5.1 y cambiar una superficie antes de confirmar. Esperado: el consumo se recalcula.
- [ ] 5.5 En una OT con dos tandas (dos registros en fechas distintas), "✎ Corregir aplicación del <fecha>" de una sola. Esperado: solo esa tanda vuelve a pendiente; la otra queda intacta.
- [ ] 5.6 Lo realizado abre con los lotes de esa tanda en "Se hizo" y los datos precargados; los otros pendientes en "Queda pendiente".
- [ ] 5.7 Recargar antes de confirmar la corrección. Esperado: los datos precargados **siguen estando** (en la versión del cliente esto se pierde; en la nuestra se guarda).

## 6. Editar una OT con lotes aplicados
- [ ] 6.1 Editar una OT Parcial. Esperado: arriba "Ya aplicado", trabajos aplicados en gris; solo se editan contratista y observaciones. Los lotes pendientes de esos trabajos **no** se editan (decisión confirmada por el cliente).
- [ ] 6.2 Agregar un trabajo nuevo y guardar. Esperado: se guarda; el trabajo aplicado y su comprobante quedan intactos (verificar en Movimientos).
- [ ] 6.3 Concurrencia: abrir la misma OT en dos navegadores/usuarios. Esperado: el segundo la ve en solo lectura.
- [ ] 6.4 Mientras se edita en uno, registrar/deshacer lo aplicado en el otro y guardar el primero. Esperado: la edición se cancela con aviso (no pisa lo aplicado).

## 7. Integración con el Plan de uso del suelo (cambio de cultivo)
- [ ] 7.1 En `tablero_uso_suelo.html`, cambiar el cultivo de un lote que está en una OT pendiente (ej. Soja → Maíz).
- [ ] 7.2 Volver al tablero de OT. Esperado: aviso naranja "Cambió el plan de uso…" en el listado de OT, en Consumos, en Costos y dentro de la OT.
- [ ] 7.3 Intentar "✓ Confirmar OT". Esperado: se bloquea y abre la ventana para resolver.
- [ ] 7.4 Resolver: un lote pasa al cultivo nuevo y otro "se mantiene" el original. Esperado: el aviso desaparece y se puede confirmar.
- [ ] 7.5 Costos: lo mantenido aparece en "Gastos de cultivos que no se hicieron", suma al total pero **no** al costo por ha.
- [ ] 7.6 Volver el plan de uso a como estaba.
- [ ] 7.7 Al elegir lotes en la ventana 2, solo aparecen los del cultivo elegido en el plan de uso de **la campaña de la OT** (cambiar la campaña en la ventana 1 cambia los lotes ofrecidos).

## 8. OT rápida
- [ ] 8.1 "⚡ OT rápida (labor ya hecha)" sobre un **lote**: labor, contratista, tarifa, insumos con cantidad y depósito. Guardar. Esperado: OT nueva en estado **Aplicada**, etiqueta "rápida" en el listado, stock descontado, comprobante generado.
- [ ] 8.2 OT rápida sobre una **unidad de negocio** de un campo (con descripción). Esperado: igual que 8.1, sin lote.
- [ ] 8.3 Sin depósitos cargados. Esperado: aviso, no abre.
- [ ] 8.4 Ambas aparecen en Consumos, Labores e Historia del lote.
- [ ] 8.5 Editar una OT rápida y guardar. Esperado: sigue con la etiqueta "rápida".

## 9. Solapa Labores (antes "Contratistas")
- [ ] 9.1 Resumen por contratista y labor; KPIs arriba. Tocar una fila filtra el detalle.
- [ ] 9.2 Filtros: contratista, propio/contratado, tipo de labor, campo, lote, cultivo, estado de facturación, fechas. "Limpiar filtros".
- [ ] 9.3 Detalle por OT: cargar tarifa por ha a una labor contratada. Esperado: recalcula el importe; persiste al recargar.
- [ ] 9.4 Cargar estado de facturación (Parcial, monto) y pago. Esperado: Facturado, Pagado y Adeudado coherentes; persiste al recargar.
- [ ] 9.5 Una OT con 2 trabajos aparece como 2 filas (una por trabajo, con su tarifa y facturación).
- [ ] 9.6 "📄 Reporte (PDF)". Esperado: resumen + detalle por OT con Importe, Facturado, A facturar, Pagado, Adeudado iguales a la pantalla, respetando los filtros.

## 10. Consumos por lote e Historia del lote
- [ ] 10.1 Consumos: filas por lote e insumo con consumido, devoluciones, baja y dosis real (= usado / superficie real).
- [ ] 10.2 Filtros de Consumos.
- [ ] 10.3 "📋 Historia del lote": elegir lote y campaña. Esperado: cultivo(s) del plan, labores por fecha con productos y dosis.
- [ ] 10.4 Descargar el PDF de la Historia. Esperado: mismo contenido; acentos y ñ correctos.

## 11. Costos
- [ ] 11.1 Resumen de costos por campaña/campo/lote/actividad/cultivo, con labores (tarifa × superficie **real**) e insumos.
- [ ] 11.2 Cambiar $ / U$S. Esperado: convierte con el tipo de cambio.
- [ ] 11.3 Insumo sin precio. Esperado: aviso de que cuenta como 0.

## 12. Excel
- [ ] 12.1 Exportar. Esperado: hoja de OT con una fila por OT y columna "OT rápida"; hoja de líneas por lote/insumo con superficie, entregada, usado y devoluciones.

## 13. Cancelar, reactivar y borrar
- [ ] 13.1 Cancelar una OT pendiente. Esperado: estado Cancelada; no se puede registrar lo realizado.
- [ ] 13.2 Reactivar. Esperado: vuelve al estado según lo aplicado.
- [ ] 13.3 Borrar una OT con aplicaciones. Esperado: se borran sus comprobantes y el stock vuelve (verificar en Stock).

## 14. Permisos
- [ ] 14.1 Usuario **ver**: no ve botones de crear, editar, OT rápida, confirmar, corregir ni volver a pendiente.
- [ ] 14.2 Usuario **cargar**: puede crear/editar OT y registrar lo realizado; no edita tarifas de referencia.
- [ ] 14.3 Usuario **administrar**: todo.

## 15. Regresión (lo que no debería haber cambiado)
- [ ] 15.1 Stock, Movimientos (alta, edición y borrado de comprobantes manuales) y cierre de stock funcionan como antes.
- [ ] 15.2 Cambiar de empresa en la barra superior: las OT, comprobantes y números de OT no se mezclan entre empresas.
- [ ] 15.3 Formulaciones: el orden de mezclado se ve en el detalle de la OT, en la ventana 3 y en la impresión.

---

## Diferencias conocidas con el cliente (no reportar como error)
- **Bloqueo por cierre de stock:** no existe todavía; viene con la migración de Stock (rama aparte).
- **Valuación de insumos:** usamos un precio único por insumo; el cliente valúa a precio promedio ponderado a la fecha. Los importes de Costos e Historia pueden diferir del standalone del cliente. Viene con Stock.
- **Avisos al editar/borrar un comprobante** (stock negativo, aplicaciones posteriores): vienen con Stock.
- **Mapa de lotes** en la impresión: falta la geometría de los lotes.
- **Botón "Historia del lote":** en el cliente está en el encabezado de "Consumo por lote"; acá está en la barra de filtros.
- **Aviso "falta TC" en Labores:** en el cliente abre una ayuda; acá es un texto al pasar el mouse.
