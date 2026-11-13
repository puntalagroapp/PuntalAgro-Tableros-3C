// Pruebas de regresión de los defectos de QA de las migraciones 022/023
// (documento "Incidencias de QA para corrección", 12/11/2026):
//   DEF-01  categoría de insumo inexistente (TC-023-06 y TC-API-06)
//   DEF-02  PUT de una OT inexistente
//   DEF-03  clase de depósito inválida
//   DEF-04  superficie negativa en lotes de una OT
//
// Corren contra la API levantada (no usan la base directamente) y borran lo
// que crean. Usar una base de prueba: las OT de prueba consumen números del
// contador de OT de la empresa.
//
//   PA_API=http://localhost:8080 PA_TOKEN=<token de sesión> PA_EMPRESA=<empresaId> \
//     node --test backend/tests/
//
// El usuario del token tiene que poder escribir Maestros de esa empresa y
// tener "cargar" en tablero_insumos_ot (admin_general o admin_cliente sirven).
'use strict';
const test = require('node:test');
const assert = require('node:assert');

const API = process.env.PA_API || 'http://localhost:8080';
const TOKEN = process.env.PA_TOKEN;
const EMP = process.env.PA_EMPRESA;
if (!TOKEN || !EMP) throw new Error('Faltan PA_TOKEN y PA_EMPRESA');

const sufijo = Date.now().toString(36);
const qEmp = '?empresaId=' + encodeURIComponent(EMP);

async function api(metodo, ruta, body) {
  const r = await fetch(API + ruta, {
    method: metodo,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + TOKEN },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await r.json(); } catch (e) { /* sin cuerpo */ }
  return { status: r.status, json };
}
async function buscarMaestro(col, id) {
  const r = await api('GET', '/api/maestros/' + col + qEmp);
  assert.strictEqual(r.status, 200);
  return (r.json || []).find(x => x.id === id) || null;
}
async function buscarOt(id) {
  const r = await api('GET', '/api/ordenes-trabajo' + qEmp);
  assert.strictEqual(r.status, 200);
  return (r.json || []).find(x => x.id === id) || null;
}
const borrar = (col, id) => api('DELETE', '/api/maestros/' + col + '/' + encodeURIComponent(id) + qEmp);
const borrarOt = id => api('DELETE', '/api/ordenes-trabajo/' + encodeURIComponent(id) + qEmp);

// ── DEF-01 ──────────────────────────────────────────────────────────────────
test('DEF-01 insumos: categoría válida, inválida y ausente (POST y PUT)', async (t) => {
  const creados = [];
  t.after(async () => { for (const id of creados) await borrar('insumos', id); });
  const ins = (id, extra) => Object.assign({ id, empresaId: EMP, nombre: 'QA insumo ' + id, unidadId: 'L', activo: true }, extra);

  await t.test('POST con categoría inexistente → 400 y no se guarda', async () => {
    const id = 'qa_ins_inv_' + sufijo;
    const r = await api('POST', '/api/maestros/insumos', ins(id, { tipo: 'CATEGORIA_INEXISTENTE_QA' }));
    assert.strictEqual(r.status, 400);
    assert.match(r.json.error, /no existe/);
    assert.strictEqual(await buscarMaestro('insumos', id), null);
  });

  await t.test('POST sin categoría o vacía → 400 y no se guarda', async () => {
    for (const extra of [{}, { tipo: '' }, { tipo: null }]) {
      const id = 'qa_ins_sin_' + sufijo + '_' + Object.keys(extra).length + String(extra.tipo);
      const r = await api('POST', '/api/maestros/insumos', ins(id, extra));
      assert.strictEqual(r.status, 400, JSON.stringify(extra));
      assert.strictEqual(await buscarMaestro('insumos', id), null);
    }
  });

  const idOk = 'qa_ins_herb_' + sufijo;
  await t.test('POST con HERB y con COMB → 201', async () => {
    for (const [id, tipo] of [[idOk, 'HERB'], ['qa_ins_comb_' + sufijo, 'COMB']]) {
      const r = await api('POST', '/api/maestros/insumos', ins(id, { tipo }));
      assert.strictEqual(r.status, 201, tipo);
      creados.push(id);
      assert.strictEqual((await buscarMaestro('insumos', id)).tipo, tipo);
    }
  });

  await t.test('PUT con categoría inexistente → 400 y no cambia', async () => {
    const r = await api('PUT', '/api/maestros/insumos/' + idOk, { empresaId: EMP, tipo: 'CATEGORIA_INEXISTENTE_QA' });
    assert.strictEqual(r.status, 400);
    assert.strictEqual((await buscarMaestro('insumos', idOk)).tipo, 'HERB');
  });

  await t.test('PUT con categoría vacía → 400 y no cambia', async () => {
    const r = await api('PUT', '/api/maestros/insumos/' + idOk, { empresaId: EMP, tipo: '' });
    assert.strictEqual(r.status, 400);
    assert.strictEqual((await buscarMaestro('insumos', idOk)).tipo, 'HERB');
  });

  await t.test('PUT sin tipo (campos operativos, como tablero_insumos_ot) → 200 y conserva la categoría', async () => {
    const r = await api('PUT', '/api/maestros/insumos/' + idOk, { empresaId: EMP, id: idOk, stockMin: 5, moneda: 'ARS' });
    assert.strictEqual(r.status, 200);
    const x = await buscarMaestro('insumos', idOk);
    assert.strictEqual(x.tipo, 'HERB');
    assert.strictEqual(Number(x.stockMin), 5);
  });

  await t.test('PUT con categoría válida → 200 y cambia', async () => {
    const r = await api('PUT', '/api/maestros/insumos/' + idOk, { empresaId: EMP, tipo: 'FUNG' });
    assert.strictEqual(r.status, 200);
    assert.strictEqual((await buscarMaestro('insumos', idOk)).tipo, 'FUNG');
  });
});

// ── DEF-03 ──────────────────────────────────────────────────────────────────
test('DEF-03 depósitos: clase válida, omitida, vacía e inválida (POST y PUT)', async (t) => {
  const creados = [];
  t.after(async () => { for (const id of creados) await borrar('depositos', id); });
  const dep = (id, extra) => Object.assign({ id, empresaId: EMP, nombre: 'QA depósito ' + id, campoId: null, activo: true }, extra);
  const casos = [
    ['granos', { clase: 'granos' }, 'granos'],
    ['insumos', { clase: 'insumos' }, 'insumos'],
    ['omitida', {}, 'insumos'],
    ['vacia', { clase: '' }, 'insumos'],
  ];
  for (const [nom, extra, esperada] of casos) {
    await t.test('POST clase ' + nom + ' → 201 y queda "' + esperada + '"', async () => {
      const id = 'qa_dep_' + nom + '_' + sufijo;
      const r = await api('POST', '/api/maestros/depositos', dep(id, extra));
      assert.strictEqual(r.status, 201);
      creados.push(id);
      assert.strictEqual((await buscarMaestro('depositos', id)).clase, esperada);
    });
  }

  await t.test('POST clase desconocida → 400 y no se guarda', async () => {
    const id = 'qa_dep_inv_' + sufijo;
    const r = await api('POST', '/api/maestros/depositos', dep(id, { clase: 'invalida' }));
    assert.strictEqual(r.status, 400);
    assert.strictEqual(await buscarMaestro('depositos', id), null);
  });

  await t.test('PUT clase desconocida → 400 y no cambia', async () => {
    const id = 'qa_dep_granos_' + sufijo;
    const r = await api('PUT', '/api/maestros/depositos/' + id, dep(id, { clase: 'invalida' }));
    assert.strictEqual(r.status, 400);
    assert.strictEqual((await buscarMaestro('depositos', id)).clase, 'granos');
  });

  await t.test('PUT clase válida → 200 y cambia', async () => {
    const id = 'qa_dep_granos_' + sufijo;
    const r = await api('PUT', '/api/maestros/depositos/' + id, dep(id, { clase: 'insumos' }));
    assert.strictEqual(r.status, 200);
    assert.strictEqual((await buscarMaestro('depositos', id)).clase, 'insumos');
  });
});

// ── DEF-02 y DEF-04 ─────────────────────────────────────────────────────────
function trabajo(destinos) {
  return [{ laborTipo: 'LP', destinos: destinos.map((d, i) =>
    Object.assign({ id: 'qa_d' + (i + 1), loteId: 'qa_lote_' + (i + 1), campoId: null, estadoLote: 'Pendiente', lineas: [] }, d)) }];
}
function ot(id, destinos) {
  return { id, empresaId: EMP, fecha: '2026-11-13', estado: 'Pendiente', obs: 'QA', trabajos: trabajo(destinos) };
}

test('DEF-02 PUT de una OT inexistente → 404 sin cambios', async (t) => {
  const id = 'qa_ot_no_existe_' + sufijo;
  await t.test('con trabajos vacíos', async () => {
    const r = await api('PUT', '/api/ordenes-trabajo/' + id, { empresaId: EMP, trabajos: [] });
    assert.strictEqual(r.status, 404);
  });
  await t.test('con trabajos', async () => {
    const r = await api('PUT', '/api/ordenes-trabajo/' + id, ot(id, [{ ha: 10 }]));
    assert.strictEqual(r.status, 404);
    assert.strictEqual(await buscarOt(id), null);
  });
});

test('DEF-04 superficies de lotes de OT (POST y PUT)', async (t) => {
  const creadas = [];
  t.after(async () => { for (const id of creadas) await borrarOt(id); });

  for (const [nom, d] of [['ha=-10', { ha: -10 }], ['haReal=-1', { ha: 10, haReal: -1 }], ['ha no numérica', { ha: 'abc' }]]) {
    await t.test('POST con ' + nom + ' → 400 y no se guarda', async () => {
      const id = 'qa_ot_neg_' + sufijo + '_' + nom.replace(/\W/g, '');
      const r = await api('POST', '/api/ordenes-trabajo', ot(id, [{ ha: 5 }, d]));
      assert.strictEqual(r.status, 400);
      assert.strictEqual(await buscarOt(id), null);
    });
  }

  const idOk = 'qa_ot_ok_' + sufijo;
  await t.test('POST con ha=0, sin ha y ha positiva → 201', async () => {
    const r = await api('POST', '/api/ordenes-trabajo', ot(idOk, [{ ha: 0 }, {}, { ha: 12.5, haReal: 12 }]));
    assert.strictEqual(r.status, 201);
    creadas.push(idOk);
    const x = await buscarOt(idOk);
    assert.deepStrictEqual(x.trabajos[0].destinos.map(d => d.ha === null || d.ha === undefined ? null : Number(d.ha)), [0, null, 12.5]);
  });

  await t.test('PUT con ha negativa → 400 y la OT no cambia', async () => {
    const r = await api('PUT', '/api/ordenes-trabajo/' + idOk, ot(idOk, [{ ha: -3 }]));
    assert.strictEqual(r.status, 400);
    assert.strictEqual((await buscarOt(idOk)).trabajos[0].destinos.length, 3);
  });

  await t.test('PUT de una OT real con datos válidos → 200 (DEF-02 no rompe la edición)', async () => {
    const actual = await buscarOt(idOk);
    const r = await api('PUT', '/api/ordenes-trabajo/' + idOk, Object.assign(ot(idOk, [{ ha: 7 }]), { obs: 'QA editada' }));
    assert.strictEqual(r.status, 200);
    const x = await buscarOt(idOk);
    assert.strictEqual(x.obs, 'QA editada');
    assert.strictEqual(x.trabajos[0].destinos.length, 1);
    assert.strictEqual(x.num, actual.num);
  });
});
