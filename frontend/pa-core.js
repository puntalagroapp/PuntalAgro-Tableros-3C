/* ============================================================================
   pa-core.js — Capa de acceso Puntal Agro
   ============================================================================
   MODO LOCAL (cliente desarrollador):
     hostname = localhost / 127.0.0.1 / file:
     → Todo va a localStorage. Sin red.

   MODO PRODUCCIÓN (usuarios finales):
     Cualquier otro host (Docker / servidor web).
     → PA.init() carga datos desde /api/init a un caché EN MEMORIA (_cache).
       Los HTML llaman a PA.demo.* igual que siempre (sincrónicos).
       Las escrituras actualizan el caché y mandan XHR al backend.
       localStorage NO se usa para datos; solo conserva la sesión (token).

   El cliente puede modificar sus HTML y añadir llamadas a PA.demo.*.
   Cuando nos pasa el HTML, adaptamos pa-core.js para conectar ese nuevo
   método al backend sin tocar el HTML.

   Restricciones: ES5 (var/function), sin arrow functions, sin promesas.
   Callbacks: function(err, data).
   ============================================================================ */
(function (global) {
  'use strict';

  // ── 1. MODO ──────────────────────────────────────────────────────────────
  var esLocalhost = (
    global.location.hostname === 'localhost' ||
    global.location.hostname === '127.0.0.1' ||
    global.location.protocol === 'file:'
  );

  var API_URL    = '';      // rutas relativas; en Docker comparten dominio/puerto
  var modoActual = 'auto'; // se fija en PA.init()

  function usaApi() {
    // En producción (no localhost) siempre va a la API,
    // sin importar lo que el HTML pase como modo.
    // Así el cliente puede dejar modo:'demo' en sus HTMLs
    // y en producción igual usa el backend.
    if (!esLocalhost) return true;
    // En localhost: solo si se forzó explícitamente 'backend' (para tests)
    return modoActual === 'backend';
  }

  // ── 2. CLAVES DE DATOS ───────────────────────────────────────────────────
  var K_EMPRESAS   = 'pa_empresas';
  var K_CAMPOS     = 'pa_campos';
  var K_TERCEROS   = 'pa_terceros';
  var K_CHOFERES   = 'pa_choferes';
  var K_DEPOSITOS  = 'pa_depositos';
  var K_INSUMOS    = 'pa_insumos';
  var K_LABORES    = 'pa_labores';
  var K_TIPOACT    = 'pa_tipo_act';
  var K_MODOSACC   = 'pa_modos_accion';
  var K_TIPOPROV   = 'pa_tipo_prov';
  var K_UNIDADES   = 'pa_unidades';
  var K_ESPECIES   = 'pa_especies';
  var K_PERMISOS   = 'pa_permisos';
  var K_CLIENTES   = 'pa_clientes';
  var K_LOTES      = 'pa_lotes';
  var K_ACTIVIDADES = 'pa_actividades';
  var K_CATEGORIAS = 'pa_categorias_insumo';
  var K_USOS       = 'pa_usos_actividad';
  var K_FORMUL     = 'pa_formulaciones';
  var K_PRINACT    = 'pa_principios_activos';
  var K_SOCIOS     = 'pa_socios';
  var K_CAMPANIAS  = 'pa_campanias';
  var K_USUARIOS   = 'pa_usuarios';
  // Solo estas dos persisten en localStorage también en producción:
  var LS_SESION    = 'pa_sesion_activa';
  var LS_EMPACTIVA = 'pa_empresa_activa';
  var LS_SEEDVER   = 'pa_seed_version';

  var HERRAMIENTAS_PROPIAS = [
    { id: 'tablero_agro',       nombre: 'Tablero Comercial Agropecuario' },
    { id: 'tablero_evolucion',  nombre: 'Evolución de Variables' },
    { id: 'tablero_insumos_ot', nombre: 'Registro de Labores e Insumos' },
    { id: 'tablero_uso_suelo',  nombre: 'Plan de Uso del Suelo' },
    { id: 'ProgramaSiembra',    nombre: 'Programa de Siembra' },
    { id: 'tablero_hacienda',   nombre: 'Tablero de Relaciones Ganaderas' },
    { id: 'tablero_labores',    nombre: 'Precio de Labores y Fletes' },
    { id: 'Fitosanitarios',     nombre: 'Fitosanitarios' }
  ];

  // ── 3. ALMACENAMIENTO DUAL ───────────────────────────────────────────────
  // En local  → localStorage (persiste entre recargas, comodidad para el cliente)
  // En producción → _cache en memoria (no toca localStorage de datos)

  var _cache = {}; // caché en memoria para el modo producción

  function cacheGet(k, def) {
    if (usaApi()) {
      return _cache[k] !== undefined ? _cache[k] : def;
    }
    try {
      var s = localStorage.getItem(k);
      return s ? JSON.parse(s) : def;
    } catch (e) { return def; }
  }

  function cacheSet(k, v) {
    if (usaApi()) {
      _cache[k] = v;
    } else {
      try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {}
    }
  }

  // La sesión siempre va a localStorage (necesita persistir entre recargas en prod)
  function lsGet(k, def) {
    try { var s = localStorage.getItem(k); return s ? JSON.parse(s) : def; }
    catch (e) { return def; }
  }
  function lsSet(k, v) {
    try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {}
  }

  function uid(prefix) {
    var arr = new Uint32Array(2);
    (window.crypto || window.msCrypto).getRandomValues(arr);
    return (prefix || 'id') + '_' + arr[0].toString(36) + arr[1].toString(36);
  }

  // ── 4. HELPER XHR (ES5, sin fetch) ──────────────────────────────────────
  function apiXHR(method, ruta, datos, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open(method, API_URL + ruta, true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    var sesion = lsGet(LS_SESION, null);
    if (sesion && sesion.token) {
      xhr.setRequestHeader('Authorization', 'Bearer ' + sesion.token);
    }
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      if (xhr.status >= 200 && xhr.status < 300) {
        var data = null;
        try { data = JSON.parse(xhr.responseText); } catch (e) {}
        if (callback) callback(null, data);
      } else {
        if (callback) callback({ status: xhr.status, msg: xhr.responseText });
      }
    };
    xhr.send(datos !== null && datos !== undefined ? JSON.stringify(datos) : null);
  }

  // ── 5. HELPERS DE ESCRITURA ──────────────────────────────────────────────
  // Toda escritura: actualiza caché (local o memoria) + sync async al backend.

  function apiSync(coleccion, accion, datos) {
    if (!usaApi()) return;
    var method, url;
    if (accion === 'crear') {
      method = 'POST'; url = '/api/maestros/' + coleccion;
    } else if (accion === 'actualizar') {
      method = 'PUT'; url = '/api/maestros/' + coleccion + '/' + encodeURIComponent(datos.id);
    } else { // 'borrar': datos = string id
      method = 'DELETE'; url = '/api/maestros/' + coleccion + '/' + encodeURIComponent(datos);
      datos  = null;
    }
    apiXHR(method, url, datos, function (err) {
      if (err) console.error('PA sync [' + coleccion + '] ' + accion + ':', err.msg || err.status);
    });
  }

  function cacheGuardar(key, coleccion, obj, idPrefix) {
    var lista    = cacheGet(key, []);
    var esNuevo  = !obj.id;
    if (esNuevo) {
      obj.id = uid(idPrefix);
      lista.push(obj);
      cacheSet(key, lista);
      apiSync(coleccion, 'crear', obj);
    } else {
      var ok = false;
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].id === obj.id) { lista[i] = obj; ok = true; break; }
      }
      if (!ok) lista.push(obj);
      cacheSet(key, lista);
      apiSync(coleccion, 'actualizar', obj);
    }
    return obj;
  }

  function cacheBorrar(key, coleccion, id) {
    var lista = cacheGet(key, []);
    var nueva = [];
    for (var i = 0; i < lista.length; i++) {
      if (lista[i].id !== id) nueva.push(lista[i]);
    }
    cacheSet(key, nueva);
    apiSync(coleccion, 'borrar', id);
  }

  function _tieneRol(tercero, rol) {
    var tipos = tercero.tiposProveedor || [];
    for (var i = 0; i < tipos.length; i++) { if (tipos[i] === rol) return true; }
    return false;
  }

  // ── 6. SEED DEMO (solo modo local) ───────────────────────────────────────
  var SEED_VERSION = '6';

  function sembrarDatos() {
    if (lsGet(LS_SEEDVER, null) === SEED_VERSION) return;

    lsSet(K_CLIENTES, [
      { id: 'cli_demo', nombre: 'Cliente Demo', activo: true }
    ]);
    lsSet(K_EMPRESAS, [
      { id: 'e_1', clienteId: 'cli_demo', razonSocial: 'Estancia Don Eduardo',     cuit: '30-00000001-0', activo: true },
      { id: 'e_2', clienteId: 'cli_demo', razonSocial: 'Agropecuaria del Litoral', cuit: '30-00000002-0', activo: true }
    ]);
    lsSet(K_CAMPOS, [
      { id: 'c_1', empresaId: 'e_1', nombre: 'Campo Viejo', localidad: 'Río Cuarto',  provincia: 'Córdoba',    haTotales: 500 },
      { id: 'c_2', empresaId: 'e_1', nombre: 'La Loma',     localidad: 'Sampacho',     provincia: 'Córdoba',    haTotales: 300 },
      { id: 'c_3', empresaId: 'e_2', nombre: 'El Talar',    localidad: 'Gualeguaychú', provincia: 'Entre Ríos', haTotales: 800 }
    ]);
    lsSet(K_TIPOPROV, [
      { id: 'tp_1', nombre: 'transportista' },
      { id: 'tp_2', nombre: 'contratista' },
      { id: 'tp_3', nombre: 'prestador de servicios' },
      { id: 'tp_4', nombre: 'insumos' }
    ]);
    lsSet(K_UNIDADES, [
      { id: 'u_1', sigla: 'Lt',  nombre: 'Litros',              activo: true },
      { id: 'u_2', sigla: 'Kg',  nombre: 'Kilogramos',          activo: true },
      { id: 'u_3', sigla: 'g',   nombre: 'Gramos',              activo: true },
      { id: 'u_4', sigla: 'cc',  nombre: 'Centímetros cúbicos', activo: true },
      { id: 'u_5', sigla: 'ml',  nombre: 'Mililitros',          activo: true },
      { id: 'u_6', sigla: 'u',   nombre: 'Unidades',            activo: true },
      { id: 'u_7', sigla: 'tn',  nombre: 'Toneladas',           activo: true }
    ]);
    lsSet(K_ESPECIES, [
      { id: 'esp_0', nombre: 'Soja',               sigla: 'Sj',   activo: true },
      { id: 'esp_1', nombre: 'Maíz',               sigla: 'Mz',   activo: true },
      { id: 'esp_2', nombre: 'Trigo',              sigla: 'Tr',   activo: true },
      { id: 'esp_3', nombre: 'Sorgo',              sigla: 'Sg',   activo: true },
      { id: 'esp_4', nombre: 'Girasol',            sigla: 'G',    activo: true },
      { id: 'esp_5', nombre: 'Cebada',             sigla: 'Cb',   activo: true },
      { id: 'esp_6', nombre: 'Avena',              sigla: 'Av',   activo: true },
      { id: 'esp_7', nombre: 'Maíz Planta Entera', sigla: 'MzPE', activo: true }
    ]);
    lsSet(K_LABORES, [
      { id: 'lab_1',  nombre: 'Siembra',              precioRef: 0, activo: true },
      { id: 'lab_2',  nombre: 'Pulv. Terrestre',       precioRef: 0, activo: true },
      { id: 'lab_3',  nombre: 'Pulv. Aérea',           precioRef: 0, activo: true },
      { id: 'lab_4',  nombre: 'Desmalezado',           precioRef: 0, activo: true },
      { id: 'lab_5',  nombre: 'Corte-hilerado',        precioRef: 0, activo: true },
      { id: 'lab_6',  nombre: 'Enrrollado',            precioRef: 0, activo: true },
      { id: 'lab_7',  nombre: 'Embolsado',             precioRef: 0, activo: true },
      { id: 'lab_8',  nombre: 'Fertilización voleo',   precioRef: 0, activo: true },
      { id: 'lab_9',  nombre: 'Fertilización líquida', precioRef: 0, activo: true },
      { id: 'lab_10', nombre: 'Disco-Rastra-Rolo',     precioRef: 0, activo: true }
    ]);
    lsSet(K_MODOSACC, [
      { id: 'moa_h01', sistema: 'HRAC', codigo: 'ACCasa',  descripcion: 'Inhibidores de la acetil coenzima-A carboxilasa (ACCasa)',   activo: true },
      { id: 'moa_h02', sistema: 'HRAC', codigo: 'ALSSulf', descripcion: 'Inhibidores ALS - Sulfonilureas',                            activo: true },
      { id: 'moa_h03', sistema: 'HRAC', codigo: 'ALSIMI',  descripcion: 'Inhibidores ALS - Imidazolinonas',                           activo: true },
      { id: 'moa_h04', sistema: 'HRAC', codigo: 'InhF2',   descripcion: 'Inhibidores de la fotosíntesis en el fotosistema II',        activo: true },
      { id: 'moa_h05', sistema: 'HRAC', codigo: 'InhF1',   descripcion: 'Inhibidores del fotosistema I',                              activo: true },
      { id: 'moa_h06', sistema: 'HRAC', codigo: 'PPO',     descripcion: 'Inhibidores de la enzima protoporfirinógeno oxidasa (PPO)', activo: true },
      { id: 'moa_h07', sistema: 'HRAC', codigo: 'HPPD',    descripcion: 'Inhibidores de la biosíntesis de carotenoides (HPPD)',       activo: true },
      { id: 'moa_h08', sistema: 'HRAC', codigo: 'EPSPS',   descripcion: 'Inhibidores de la enzima EPSPS (Glifosato)',                 activo: true },
      { id: 'moa_h09', sistema: 'HRAC', codigo: 'IGS',     descripcion: 'Inhibidores de la glutamino sintetasa',                      activo: true },
      { id: 'moa_h10', sistema: 'HRAC', codigo: 'AuxSin',  descripcion: 'Acción similar al ácido indol acético (auxinas sintéticas)', activo: true },
      { id: 'moa_h11', sistema: 'HRAC', codigo: 'H-MOAD',  descripcion: 'Modo de acción desconocido (herbicida)',                     activo: true },
      { id: 'moa_i01', sistema: 'IRAC', codigo: '1',       descripcion: 'Inhibidores de la acetilcolinesterasa',                      activo: true },
      { id: 'moa_i02', sistema: 'IRAC', codigo: '3',       descripcion: 'Moduladores del canal de sodio',                             activo: true },
      { id: 'moa_i03', sistema: 'IRAC', codigo: '4',       descripcion: 'Moduladores del receptor nicotínico de la acetilcolina',     activo: true },
      { id: 'moa_i04', sistema: 'IRAC', codigo: '28',      descripcion: 'Moduladores del receptor de la rianodina',                   activo: true },
      { id: 'moa_i05', sistema: 'IRAC', codigo: 'F-MOAD',  descripcion: 'Modo de acción desconocido (insecticida)',                   activo: true },
      { id: 'moa_f01', sistema: 'FRAC', codigo: 'A',       descripcion: 'Metabolismo de ácidos nucleicos',                            activo: true },
      { id: 'moa_f02', sistema: 'FRAC', codigo: 'C',       descripcion: 'Respiración',                                                activo: true },
      { id: 'moa_f03', sistema: 'FRAC', codigo: 'G',       descripcion: 'Biosíntesis de esterol en las membranas',                    activo: true },
      { id: 'moa_f04', sistema: 'FRAC', codigo: 'M',       descripcion: 'Químicos con actividad multisitio',                          activo: true },
      { id: 'moa_f05', sistema: 'FRAC', codigo: 'F-MOAD',  descripcion: 'Modo de acción desconocido (fungicida)',                     activo: true }
    ]);
    lsSet(K_USUARIOS, [
      { id: 'u_1', nombre: 'Admin Puntal',  email: 'admin@puntal.com',       rol: 'admin_general',  clienteId: null,       activo: true },
      { id: 'u_2', nombre: 'Usuario Demo',  email: 'demo@puntalagro.com',    rol: 'admin_cliente',  clienteId: 'cli_demo', activo: true }
    ]);
    lsSet(K_PERMISOS, [
      { usuarioId: 'u_1', empresaId: 'e_1', campoIds: [], herramientas: [], nivel: 'administrar' },
      { usuarioId: 'u_1', empresaId: 'e_2', campoIds: [], herramientas: [], nivel: 'administrar' },
      { usuarioId: 'u_2', empresaId: 'e_1', campoIds: [], herramientas: [], nivel: 'cargar' },
      { usuarioId: 'u_2', empresaId: 'e_2', campoIds: [], herramientas: [], nivel: 'cargar' }
    ]);
    lsSet(K_CAMPANIAS, [
      { id: 'camp_1', nombre: '24/25', orden: 1, activa: false },
      { id: 'camp_2', nombre: '25/26', orden: 2, activa: true  }
    ]);
    lsSet(K_CATEGORIAS, [
      { id:'cat_sem',  codigo:'SEM',  label:'Semillas',                    base:true, fito:false, subcat:false, activo:true },
      { id:'cat_cura', codigo:'CURA', label:'Curasemillas e Inoculantes',  base:true, fito:false, subcat:false, activo:true },
      { id:'cat_herb', codigo:'HERB', label:'Herbicidas',                  base:true, fito:true,  subcat:false, activo:true },
      { id:'cat_inse', codigo:'INSE', label:'Insecticidas',                base:true, fito:true,  subcat:false, activo:true },
      { id:'cat_fung', codigo:'FUNG', label:'Fungicidas',                  base:true, fito:true,  subcat:false, activo:true },
      { id:'cat_coad', codigo:'COAD', label:'Coadyuvantes y Correctores',  base:true, fito:false, subcat:true,  activo:true },
      { id:'cat_fert', codigo:'FERT', label:'Fertilizantes',               base:true, fito:false, subcat:false, activo:true },
      { id:'cat_otro', codigo:'OTRO', label:'Otros Insumos',               base:true, fito:false, subcat:false, activo:true }
    ]);
    lsSet(K_USOS, [
      { id:'uso_agr', codigo:'AGR', label:'Agricultura',     activo:true },
      { id:'uso_gan', codigo:'GAN', label:'Ganadería',       activo:true },
      { id:'uso_dob', codigo:'DOB', label:'Doble propósito', activo:true }
    ]);
    lsSet(K_FORMUL, [
      { id:'f_agua', codigo:'',   descripcion:'Agua (media carga, corrección dureza/pH)',    orden:1,  activo:true },
      { id:'f_coad', codigo:'',   descripcion:'Coadyuvantes / correctores / secuestrantes',   orden:2,  activo:true },
      { id:'f_anti', codigo:'',   descripcion:'Antiespumante',                                orden:3,  activo:true },
      { id:'f_wp',   codigo:'WP', descripcion:'Polvos mojables',                              orden:4,  activo:true },
      { id:'f_wg',   codigo:'WG', descripcion:'Gránulos dispersables',                        orden:5,  activo:true },
      { id:'f_sg',   codigo:'SG', descripcion:'Gránulos solubles',                            orden:6,  activo:true },
      { id:'f_od',   codigo:'OD', descripcion:'Dispersiones oleosas',                         orden:7,  activo:true },
      { id:'f_sc',   codigo:'SC', descripcion:'Suspensiones concentradas',                    orden:8,  activo:true },
      { id:'f_cs',   codigo:'CS', descripcion:'Suspensiones de encapsulados (microcápsulas)', orden:9,  activo:true },
      { id:'f_se',   codigo:'SE', descripcion:'Suspo-emulsiones',                             orden:10, activo:true },
      { id:'f_ew',   codigo:'EW', descripcion:'Emulsiones de aceite en agua',                 orden:11, activo:true },
      { id:'f_ec',   codigo:'EC', descripcion:'Concentrados emulsionables',                   orden:12, activo:true },
      { id:'f_sl',   codigo:'SL', descripcion:'Concentrados / líquidos solubles',             orden:13, activo:true },
      { id:'f_acei', codigo:'',   descripcion:'Aceites / surfactantes / adyuvantes finales',  orden:14, activo:true },
      { id:'f_foli', codigo:'',   descripcion:'Micronutrientes / fertilizantes foliares',     orden:15, activo:true }
    ]);
    lsSet(K_PRINACT, [
      { id: 'pa_0', nombre: '(E,E)8,10-DODECADIENOL', eiq: null, uso: 'Feromona (control de plagas)', activo: true },
      { id: 'pa_1', nombre: '(E,Z)7,9-DODECADIENIL ACETATO', eiq: null, uso: 'Feromona (control de plagas)', activo: true },
      { id: 'pa_2', nombre: '(Z)/(E)-8-DODECENIL ACETATO', eiq: null, uso: 'Feromona (control de plagas)', activo: true },
      { id: 'pa_3', nombre: '2,4 D', eiq: 19.27, uso: 'Herbicida', activo: true },
      { id: 'pa_4', nombre: '2,4-DB', eiq: 19.27, uso: 'Herbicida', activo: true },
      { id: 'pa_5', nombre: 'ABAMECTINA', eiq: 35.65, uso: 'Insecticida/Acaricida', activo: true },
      { id: 'pa_6', nombre: 'ACEFATO', eiq: 18.45, uso: 'Insecticida', activo: true },
      { id: 'pa_7', nombre: 'ACEITE DE SOJA', eiq: 5.0, uso: 'Coadyuvante', activo: true },
      { id: 'pa_8', nombre: 'ACEITE MINERAL', eiq: 5.0, uso: 'Coadyuvante', activo: true },
      { id: 'pa_9', nombre: 'ACETAMIPRID', eiq: 24.83, uso: 'Insecticida', activo: true },
      { id: 'pa_10', nombre: 'ACETOCLOR', eiq: 22.0, uso: 'Herbicida', activo: true },
      { id: 'pa_11', nombre: 'ACIDO FOSFORICO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_12', nombre: 'ACIDO GIBERELICO', eiq: 5.0, uso: 'Regulador de crecimiento', activo: true },
      { id: 'pa_13', nombre: 'AFIDOPYROPEN', eiq: 18.0, uso: 'Insecticida', activo: true },
      { id: 'pa_14', nombre: 'ALCOHOL GRASO ETOXILADO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_15', nombre: 'ALCOHOL LAURICO ETOXILADO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_16', nombre: 'ALCOHOL LINEAL ETOXILADO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_17', nombre: 'ALCOHOLES GRASOS', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_18', nombre: 'ALFACIPERMETRINA/ALFAMETRINA', eiq: 36.71, uso: 'Insecticida', activo: true },
      { id: 'pa_19', nombre: 'ALQUIL ARIL POLIGLICOL ETER', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_20', nombre: 'AMETRINA', eiq: 22.0, uso: 'Herbicida', activo: true },
      { id: 'pa_21', nombre: 'ATRAZINA', eiq: 22.71, uso: 'Herbicida', activo: true },
      { id: 'pa_22', nombre: 'AZOXISTROBINA', eiq: 27.33, uso: 'Fungicida', activo: true },
      { id: 'pa_23', nombre: 'AZUFRE', eiq: 33.0, uso: 'Fungicida/Acaricida', activo: true },
      { id: 'pa_24', nombre: 'BACILLUS AMYLOLIQUEFACIENS', eiq: null, uso: 'Fungicida biológico', activo: true },
      { id: 'pa_25', nombre: 'BACILLUS THURINGIENSIS', eiq: null, uso: 'Insecticida biológico', activo: true },
      { id: 'pa_26', nombre: 'BACILLUS THURINGIENSIS var AIZAWAI', eiq: null, uso: 'Insecticida biológico', activo: true },
      { id: 'pa_27', nombre: 'BENAZOLIN ETIL', eiq: 20.0, uso: 'Herbicida', activo: true },
      { id: 'pa_28', nombre: 'BENZOATO DE EMAMECTINA', eiq: 30.5, uso: 'Insecticida', activo: true },
      { id: 'pa_29', nombre: 'BENZOVINDIFLUPIR', eiq: 22.0, uso: 'Fungicida', activo: true },
      { id: 'pa_30', nombre: 'BICICLOPIRONA', eiq: 20.0, uso: 'Herbicida', activo: true },
      { id: 'pa_31', nombre: 'BIFENTRIN', eiq: 44.43, uso: 'Insecticida', activo: true },
      { id: 'pa_32', nombre: 'BOSCALID', eiq: 19.43, uso: 'Fungicida', activo: true },
      { id: 'pa_33', nombre: 'BROMOXINIL', eiq: 21.93, uso: 'Herbicida', activo: true },
      { id: 'pa_34', nombre: 'Bacillus Velezensis', eiq: null, uso: 'Fungicida biológico', activo: true },
      { id: 'pa_35', nombre: 'CAPTAN', eiq: 33.0, uso: 'Fungicida', activo: true },
      { id: 'pa_36', nombre: 'CARBARIL', eiq: 22.83, uso: 'Insecticida', activo: true },
      { id: 'pa_37', nombre: 'CARBENDAZIM', eiq: 33.0, uso: 'Fungicida', activo: true },
      { id: 'pa_38', nombre: 'CARBONATO BASICO DE COBRE', eiq: 33.67, uso: 'Fungicida', activo: true },
      { id: 'pa_39', nombre: 'CARFENTRAZONE ETIL', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_40', nombre: 'CIPERMETRINA', eiq: 36.71, uso: 'Insecticida', activo: true },
      { id: 'pa_41', nombre: 'CIPROCONAZOLE', eiq: 21.67, uso: 'Fungicida', activo: true },
      { id: 'pa_42', nombre: 'CLETODIM', eiq: 18.93, uso: 'Herbicida', activo: true },
      { id: 'pa_43', nombre: 'CLOMAZONE', eiq: 23.13, uso: 'Herbicida', activo: true },
      { id: 'pa_44', nombre: 'CLOPYRALID', eiq: 19.5, uso: 'Herbicida', activo: true },
      { id: 'pa_45', nombre: 'CLOQUINTOCET MEXIL', eiq: 15.0, uso: 'Protector (safener)', activo: true },
      { id: 'pa_46', nombre: 'CLORANTRANILIPROLE', eiq: 27.5, uso: 'Insecticida', activo: true },
      { id: 'pa_47', nombre: 'CLORFENAPIR', eiq: 36.27, uso: 'Insecticida/Acaricida', activo: true },
      { id: 'pa_48', nombre: 'CLORIMURON ETIL', eiq: 24.0, uso: 'Herbicida', activo: true },
      { id: 'pa_49', nombre: 'CLOROTALONIL', eiq: 33.0, uso: 'Fungicida', activo: true },
      { id: 'pa_50', nombre: 'DELTAMETRINA', eiq: 27.13, uso: 'Insecticida', activo: true },
      { id: 'pa_51', nombre: 'DICAMBA', eiq: 25.43, uso: 'Herbicida', activo: true },
      { id: 'pa_52', nombre: 'DICLOSULAM', eiq: 17.83, uso: 'Herbicida', activo: true },
      { id: 'pa_53', nombre: 'DIFENOCONAZOLE', eiq: 22.83, uso: 'Fungicida', activo: true },
      { id: 'pa_54', nombre: 'DIFLUFENICAN', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_55', nombre: 'DIMETOATO', eiq: 32.71, uso: 'Insecticida', activo: true },
      { id: 'pa_56', nombre: 'DIMETOMORF', eiq: 21.83, uso: 'Fungicida', activo: true },
      { id: 'pa_57', nombre: 'DINOTEFURAN', eiq: 26.5, uso: 'Insecticida', activo: true },
      { id: 'pa_58', nombre: 'DIQUAT', eiq: 33.93, uso: 'Herbicida', activo: true },
      { id: 'pa_59', nombre: 'DIQUAT DIBROMURO', eiq: 33.93, uso: 'Herbicida', activo: true },
      { id: 'pa_60', nombre: 'DIURON', eiq: 24.66, uso: 'Herbicida', activo: true },
      { id: 'pa_61', nombre: 'DODECIL BENCEN SULFONICO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_62', nombre: 'EPOXICONAZOLE', eiq: 35.45, uso: 'Fungicida', activo: true },
      { id: 'pa_63', nombre: 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE DE SOJA', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_64', nombre: 'ESTERES METILICOS DE ACIDOS GRASOS DE ACEITE VEGETAL', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_65', nombre: 'ETEFON', eiq: 26.13, uso: 'Regulador de crecimiento', activo: true },
      { id: 'pa_66', nombre: 'FENOXAPROP-P ETIL', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_67', nombre: 'FIPRONIL', eiq: 35.83, uso: 'Insecticida', activo: true },
      { id: 'pa_68', nombre: 'FLUAZINAM', eiq: 21.13, uso: 'Fungicida', activo: true },
      { id: 'pa_69', nombre: 'FLUDIOXONIL', eiq: 20.13, uso: 'Fungicida', activo: true },
      { id: 'pa_70', nombre: 'FLUMETSULAM', eiq: 19.0, uso: 'Herbicida', activo: true },
      { id: 'pa_71', nombre: 'FLUMIOXAZIN', eiq: 17.66, uso: 'Herbicida', activo: true },
      { id: 'pa_72', nombre: 'FLUROCLORIDONA', eiq: 22.0, uso: 'Herbicida', activo: true },
      { id: 'pa_73', nombre: 'FLUROXIPIR MEPTIL', eiq: 21.0, uso: 'Herbicida', activo: true },
      { id: 'pa_74', nombre: 'FLUTRIAFOL', eiq: 22.0, uso: 'Fungicida', activo: true },
      { id: 'pa_75', nombre: 'FLUXAPIROXAD', eiq: 28.0, uso: 'Fungicida', activo: true },
      { id: 'pa_76', nombre: 'FOMESAFEN', eiq: 19.0, uso: 'Herbicida', activo: true },
      { id: 'pa_77', nombre: 'FOSFURO DE ALUMINIO', eiq: 30.0, uso: 'Fumigante/Insecticida', activo: true },
      { id: 'pa_78', nombre: 'GLIFOSATO', eiq: 15.33, uso: 'Herbicida', activo: true },
      { id: 'pa_79', nombre: 'GLUFOSINATO DE AMONIO', eiq: 19.92, uso: 'Herbicida', activo: true },
      { id: 'pa_80', nombre: 'HALAUXIFEN METIL', eiq: 19.0, uso: 'Herbicida', activo: true },
      { id: 'pa_81', nombre: 'HALOXIFOP-P METIL', eiq: 19.5, uso: 'Herbicida', activo: true },
      { id: 'pa_82', nombre: 'HEPTAMETILTRISILOXANO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_83', nombre: 'HIDROXIDO DE COBRE', eiq: 33.67, uso: 'Fungicida', activo: true },
      { id: 'pa_84', nombre: 'IMAZALIL', eiq: 24.0, uso: 'Fungicida', activo: true },
      { id: 'pa_85', nombre: 'IMAZAPIC', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_86', nombre: 'IMAZAPIR', eiq: 19.87, uso: 'Herbicida', activo: true },
      { id: 'pa_87', nombre: 'IMAZETAPIR', eiq: 19.0, uso: 'Herbicida', activo: true },
      { id: 'pa_88', nombre: 'IMIDACLOPRID', eiq: 36.71, uso: 'Insecticida', activo: true },
      { id: 'pa_89', nombre: 'IPRODIONE', eiq: 30.5, uso: 'Fungicida', activo: true },
      { id: 'pa_90', nombre: 'ISOXABEN', eiq: 21.0, uso: 'Herbicida', activo: true },
      { id: 'pa_91', nombre: 'ISOXAFLUTOLE', eiq: 22.5, uso: 'Herbicida', activo: true },
      { id: 'pa_92', nombre: 'LAMBDA-CIALOTRINA', eiq: 44.45, uso: 'Insecticida', activo: true },
      { id: 'pa_93', nombre: 'LECITINA DE SOJA', eiq: 10.0, uso: 'Coadyuvante', activo: true },
      { id: 'pa_94', nombre: 'LUFENURON', eiq: 22.93, uso: 'Insecticida', activo: true },
      { id: 'pa_95', nombre: 'M.C.P.A.', eiq: 19.5, uso: 'Herbicida', activo: true },
      { id: 'pa_96', nombre: 'M.S.M.A.', eiq: 23.0, uso: 'Herbicida', activo: true },
      { id: 'pa_97', nombre: 'MANCOZEB', eiq: 32.87, uso: 'Fungicida', activo: true },
      { id: 'pa_98', nombre: 'MESOTRIONE', eiq: 19.5, uso: 'Herbicida', activo: true },
      { id: 'pa_99', nombre: 'METALAXIL', eiq: 22.13, uso: 'Fungicida', activo: true },
      { id: 'pa_100', nombre: 'METALAXIL -M', eiq: 22.13, uso: 'Fungicida', activo: true },
      { id: 'pa_101', nombre: 'METALDEHIDO', eiq: 22.0, uso: 'Molusquicida', activo: true },
      { id: 'pa_102', nombre: 'METIL CICLOPROPENO', eiq: 10.0, uso: 'Regulador de crecimiento', activo: true },
      { id: 'pa_103', nombre: 'METIL TIOFANATO', eiq: 35.0, uso: 'Fungicida', activo: true },
      { id: 'pa_104', nombre: 'METOLACLORO', eiq: 21.61, uso: 'Herbicida', activo: true },
      { id: 'pa_105', nombre: 'METOMIL', eiq: 36.5, uso: 'Insecticida', activo: true },
      { id: 'pa_106', nombre: 'METOXIFENOCIDE', eiq: 22.93, uso: 'Insecticida', activo: true },
      { id: 'pa_107', nombre: 'METRIBUZIN', eiq: 28.0, uso: 'Herbicida', activo: true },
      { id: 'pa_108', nombre: 'METSULFURON METIL', eiq: 21.0, uso: 'Herbicida', activo: true },
      { id: 'pa_109', nombre: 'MICLOBUTANIL', eiq: 22.0, uso: 'Fungicida', activo: true },
      { id: 'pa_110', nombre: 'NICOSULFURON', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_111', nombre: 'NONIL FENOL ETOXILADO', eiq: null, uso: 'Coadyuvante', activo: true },
      { id: 'pa_112', nombre: 'NOVALURON', eiq: 22.0, uso: 'Insecticida', activo: true },
      { id: 'pa_113', nombre: 'OXICLORURO DE COBRE', eiq: 33.67, uso: 'Fungicida', activo: true },
      { id: 'pa_114', nombre: 'OXIDO CUPROSO', eiq: 33.67, uso: 'Fungicida', activo: true },
      { id: 'pa_115', nombre: 'OXIFLUORFEN', eiq: 27.43, uso: 'Herbicida', activo: true },
      { id: 'pa_116', nombre: 'PARAQUAT DICLORURO', eiq: 38.07, uso: 'Herbicida', activo: true },
      { id: 'pa_117', nombre: 'PENDIMETALIN', eiq: 23.0, uso: 'Herbicida', activo: true },
      { id: 'pa_118', nombre: 'PICLORAM', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_119', nombre: 'PICOXISTROBIN', eiq: 27.0, uso: 'Fungicida', activo: true },
      { id: 'pa_120', nombre: 'PIDIFLUMETOFEN', eiq: 22.0, uso: 'Fungicida', activo: true },
      { id: 'pa_121', nombre: 'PINOXADEN', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_122', nombre: 'PIRACLOSTROBIN', eiq: 31.5, uso: 'Fungicida', activo: true },
      { id: 'pa_123', nombre: 'PIRIMETANIL', eiq: 19.43, uso: 'Fungicida', activo: true },
      { id: 'pa_124', nombre: 'PIRIMIFOS METIL', eiq: 33.83, uso: 'Insecticida', activo: true },
      { id: 'pa_125', nombre: 'PIRIPROXIFEN', eiq: 26.93, uso: 'Insecticida (regulador)', activo: true },
      { id: 'pa_126', nombre: 'PIROXASULFONE', eiq: 18.5, uso: 'Herbicida', activo: true },
      { id: 'pa_127', nombre: 'PROFENOFOS', eiq: 41.5, uso: 'Insecticida', activo: true },
      { id: 'pa_128', nombre: 'PROHEXADIONE DE CALCIO', eiq: 15.0, uso: 'Regulador de crecimiento', activo: true },
      { id: 'pa_129', nombre: 'PROMETRINA', eiq: 22.0, uso: 'Herbicida', activo: true },
      { id: 'pa_130', nombre: 'PROPICONAZOLE', eiq: 21.93, uso: 'Fungicida', activo: true },
      { id: 'pa_131', nombre: 'PROTIOCONAZOLE', eiq: 22.0, uso: 'Fungicida', activo: true },
      { id: 'pa_132', nombre: 'QUIZALOFOP-P ETIL', eiq: 20.83, uso: 'Herbicida', activo: true },
      { id: 'pa_133', nombre: 'S-METOLACLORO', eiq: 21.61, uso: 'Herbicida', activo: true },
      { id: 'pa_134', nombre: 'SAFLUFENACIL', eiq: 19.83, uso: 'Herbicida', activo: true },
      { id: 'pa_135', nombre: 'SEDAXANE', eiq: 19.0, uso: 'Fungicida', activo: true },
      { id: 'pa_136', nombre: 'SPINOSAD', eiq: 26.0, uso: 'Insecticida', activo: true },
      { id: 'pa_137', nombre: 'SULFATO DE AMONIO', eiq: 10.0, uso: 'Coadyuvante', activo: true },
      { id: 'pa_138', nombre: 'SULFATO DE COBRE PENTAHIDRATADO', eiq: 33.67, uso: 'Fungicida', activo: true },
      { id: 'pa_139', nombre: 'SULFENTRAZONE', eiq: 23.5, uso: 'Herbicida', activo: true },
      { id: 'pa_140', nombre: 'T.C.M.T.B.', eiq: 30.0, uso: 'Fungicida', activo: true },
      { id: 'pa_141', nombre: 'TEBUCONAZOLE', eiq: 25.33, uso: 'Fungicida', activo: true },
      { id: 'pa_142', nombre: 'TERBUTILAZINA', eiq: 23.0, uso: 'Herbicida', activo: true },
      { id: 'pa_143', nombre: 'TIABENDAZOL', eiq: 23.5, uso: 'Fungicida', activo: true },
      { id: 'pa_144', nombre: 'TIAMETOXAM', eiq: 33.7, uso: 'Insecticida', activo: true },
      { id: 'pa_145', nombre: 'TIENCARBAZONE METIL', eiq: 18.0, uso: 'Herbicida', activo: true },
      { id: 'pa_146', nombre: 'TIODICARB', eiq: 33.93, uso: 'Insecticida', activo: true },
      { id: 'pa_147', nombre: 'TIRAM', eiq: 35.93, uso: 'Fungicida', activo: true },
      { id: 'pa_148', nombre: 'TOPRAMEZONE', eiq: 19.0, uso: 'Herbicida', activo: true },
      { id: 'pa_149', nombre: 'TRICHODERMA AFROHARZIANUM cepa Th2R199', eiq: null, uso: 'Fungicida biológico', activo: true },
      { id: 'pa_150', nombre: 'TRICHODERMA HARZIANUM', eiq: null, uso: 'Fungicida biológico', activo: true },
      { id: 'pa_151', nombre: 'TRIFLOXISTROBIN', eiq: 27.0, uso: 'Fungicida', activo: true }
    ]);
    lsSet(LS_SEEDVER, SEED_VERSION);
  }

  // ── 7. OBJETO PRINCIPAL PA ────────────────────────────────────────────────
  var CTX = null;

  var PA = {

    // ── PA.init ──────────────────────────────────────────────────────────────
    // Carga SOLO datos globales pequeños (listas fijas de Puntal).
    // Los maestros por empresa se cargan en loadContext() para no traer
    // más datos de los que la página necesita.
    init: function (opts, callback) {
      opts       = opts || {};
      modoActual = opts.modo || 'auto';

      if (!usaApi()) {
        sembrarDatos();
        console.log('PA modo LOCAL — datos en localStorage');
        if (callback) callback(null);
        return;
      }

      console.log('PA modo PRODUCCIÓN — cargando globales desde API…');
      apiXHR('GET', '/api/globales', null, function (err, data) {
        if (err) {
          console.warn('PA: API no disponible, usando caché local como fallback');
          sembrarDatos();
          if (callback) callback(null);
          return;
        }
        // Solo listas globales: pequeñas, fijas, no dependen de la empresa
        if (data.labores)        _cache[K_LABORES]   = data.labores;
        if (data.especies)       _cache[K_ESPECIES]  = data.especies;
        if (data.unidades)       _cache[K_UNIDADES]  = data.unidades;
        if (data.modosAccion)    _cache[K_MODOSACC]  = data.modosAccion;
        if (data.tiposProveedor) _cache[K_TIPOPROV]  = data.tiposProveedor;
        if (data.campanias)      _cache[K_CAMPANIAS] = data.campanias;
        if (data.categoriasInsumo) _cache[K_CATEGORIAS] = data.categoriasInsumo;
        if (data.usos)             _cache[K_USOS]       = data.usos;
        if (data.formulaciones)    _cache[K_FORMUL]     = data.formulaciones;
        if (data.principiosActivos) _cache[K_PRINACT]   = data.principiosActivos;
        if (data.empresas)       _cache[K_EMPRESAS]  = data.empresas;
        if (data.sesion) {
          lsSet(LS_SESION, data.sesion);
        } else {
          // Token inválido o sesión expirada: limpiar para forzar login
          localStorage.removeItem(LS_SESION);
        }
        if (data.clientes)      _cache[K_CLIENTES]  = data.clientes;
        if (data.campos)        _cache[K_CAMPOS]    = data.campos;
        console.log('PA: globales listos');
        if (callback) callback(null);
      });
    },

    // ── Sesión ───────────────────────────────────────────────────────────────
    haySesion: function () {
      return !!localStorage.getItem(LS_SESION);
    },

    login: function (email, callback) {
      if (usaApi()) {
        apiXHR('POST', '/api/auth/login', { email: email }, function (err, data) {
          if (err) { if (callback) callback(err); return; }
          lsSet(LS_SESION, data.sesion);
          if (callback) callback(null, data);
        });
      } else {
        var u = { id: 'u_1', email: email, nombre: 'Usuario Demo', rol: 'admin_general', token: 'token-demo' };
        lsSet(LS_SESION, u);
        if (callback) callback(null, { sesion: u, empresasDisponibles: cacheGet(K_EMPRESAS, []) });
      }
    },

    logout: function (callback) {
      if (usaApi()) {
        apiXHR('POST', '/api/auth/logout', null, function () {
          localStorage.removeItem(LS_SESION);
          _cache = {};
          CTX    = null;
          if (callback) callback(null);
        });
      } else {
        localStorage.removeItem(LS_SESION);
        CTX = null;
        if (callback) callback(null);
      }
    },

    // ── Contexto (empresa activa + permisos + maestros de empresa) ────────────
    // En producción hace DOS llamadas en paralelo:
    //   1. /api/context  → permisos del usuario para la empresa
    //   2. /api/maestros-empresa/:empresaId → maestros de esa empresa
    // Los maestros son los datos "grandes"; se cargan aquí porque ya tenemos
    // un callback (el HTML los espera antes de renderizar).
    loadContext: function (empresaId, callback) {
      var sesion  = lsGet(LS_SESION, { id: 'u_1', rol: 'admin_general' });
      var emps    = cacheGet(K_EMPRESAS, []);
      var empId   = empresaId || lsGet(LS_EMPACTIVA, null) || (emps.length ? emps[0].id : null);
      var permiso = { campoIds: [], herramientas: [], nivel: 'administrar' };

      if (!usaApi()) {
        CTX = { usuario: sesion, empresaActivaId: empId, empresasDisponibles: emps, permiso: permiso };
        lsSet(LS_EMPACTIVA, empId);
        if (callback) callback(null, CTX);
        return;
      }

      var qs = empId ? '?empresaId=' + encodeURIComponent(empId) : '';

      // Llamada 1: contexto y permisos
      apiXHR('GET', '/api/context' + qs, null, function (err, ctxData) {
        if (err) {
          // 401 = no autenticado → propagar para que el HTML redirija al login
          if (err.status === 401) { if (callback) callback(err); return; }
          CTX = { usuario: sesion, empresaActivaId: empId, empresasDisponibles: emps, permiso: permiso };
          lsSet(LS_EMPACTIVA, empId);
          if (callback) callback(null, CTX);
          return;
        }
        CTX = ctxData;
        if (ctxData.empresasDisponibles) _cache[K_EMPRESAS] = ctxData.empresasDisponibles;
        lsSet(LS_EMPACTIVA, CTX.empresaActivaId);

        // Llamada 2: maestros de la empresa activa (solo si hay empresa)
        if (!CTX.empresaActivaId) {
          if (callback) callback(null, CTX);
          return;
        }
        apiXHR('GET', '/api/maestros-empresa/' + encodeURIComponent(CTX.empresaActivaId), null,
          function (err2, mData) {
            if (!err2 && mData) {
              // Cada colección llega filtrada por empresa; se mezcla con el caché
              // global (datos de otras empresas ya cargadas en la sesión).
              if (mData.campos) {
                // Merge: conservar campos de otras empresas ya cargadas
                var empId = CTX.empresaActivaId;
                var otros = [], todos = cacheGet(K_CAMPOS, []);
                for (var ci = 0; ci < todos.length; ci++) {
                  if (todos[ci].empresaId !== empId) otros.push(todos[ci]);
                }
                _cache[K_CAMPOS] = otros.concat(mData.campos);
              }
              if (mData.terceros)       _cache[K_TERCEROS]    = mData.terceros;
              if (mData.choferes)       _cache[K_CHOFERES]    = mData.choferes;
              if (mData.depositos)      _cache[K_DEPOSITOS]   = mData.depositos;
              if (mData.insumos)        _cache[K_INSUMOS]     = mData.insumos;
              if (mData.tiposActividad) _cache[K_TIPOACT]     = mData.tiposActividad;
              if (mData.lotes)          _cache[K_LOTES]       = mData.lotes;
              if (mData.actividades)    _cache[K_ACTIVIDADES] = mData.actividades;
            }
            // Llamada 3: usuarios y permisos (solo para roles con acceso de gestión)
            var rolActual = CTX.usuario ? CTX.usuario.rol : 'usuario';
            if (rolActual === 'admin_general' || rolActual === 'admin_cliente') {
              apiXHR('GET', '/api/usuarios', null, function (err3, users) {
                if (!err3 && users) _cache[K_USUARIOS] = users;
                apiXHR('GET', '/api/permisos', null, function (err4, perms) {
                  if (!err4 && perms) _cache[K_PERMISOS] = perms;
                  if (callback) callback(null, CTX);
                });
              });
            } else {
              if (callback) callback(null, CTX);
            }
          }
        );
      });
    },

    setEmpresaActiva: function (empresaId, callback) {
      lsSet(LS_EMPACTIVA, empresaId);
      if (CTX) CTX.empresaActivaId = empresaId;
      if (callback) callback(null, { status: 'ok' });
    },

    ctx: function () { return CTX; },

    esModoApi: function () { return usaApi(); },

    // ── Chequeo de permisos (síncrono, solo controla la UI) ──────────────────
    can: function (accion, opts) {
      if (!CTX || !CTX.permiso) return true;
      var niveles = { ver: 1, cargar: 2, administrar: 3 };
      if ((niveles[CTX.permiso.nivel] || 0) < (niveles[accion] || 1)) return false;
      if (opts) {
        var hts = CTX.permiso.herramientas || [];
        if (opts.herramienta && hts.length) {
          var tieneHt = false;
          for (var i = 0; i < hts.length; i++) { if (hts[i] === opts.herramienta) { tieneHt = true; break; } }
          if (!tieneHt) return false;
        }
        var cids = CTX.permiso.campoIds || [];
        if (opts.campoId && cids.length) {
          var tieneCampo = false;
          for (var j = 0; j < cids.length; j++) { if (cids[j] === opts.campoId) { tieneCampo = true; break; } }
          if (!tieneCampo) return false;
        }
      }
      return true;
    }
  };

  // ── 8. MAESTROS (PA.demo) ────────────────────────────────────────────────
  // Sincrónicos. En producción leen de _cache; en local, de localStorage.
  // Las escrituras actualizan el caché Y disparan XHR al backend.
  PA.demo = {

    // ── TERCEROS ─────────────────────────────────────────────────────────────
    listarTerceros: function (empresaId, filtro) {
      var lista = cacheGet(K_TERCEROS, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) {
        var t = lista[i];
        if (t.empresaId !== empresaId)                                                         continue;
        if (filtro === 'proveedor'     && !t.esProveedor)                                      continue;
        if (filtro === 'cliente'       && !t.esCliente)                                        continue;
        if (filtro === 'transportista' && (!t.esProveedor || !_tieneRol(t,'transportista')))   continue;
        if (filtro === 'contratista'   && (!t.esProveedor || !_tieneRol(t,'contratista')))     continue;
        out.push(t);
      }
      return out;
    },
    getTerceros: function (empresaId) { return this.listarTerceros(empresaId, null); },
    guardarTercero: function (t)  { return cacheGuardar(K_TERCEROS, 'terceros', t, 'ter'); },
    borrarTercero: function (id) {
      cacheBorrar(K_TERCEROS, 'terceros', id);
      // Cascada: borra choferes del tercero
      var chs = cacheGet(K_CHOFERES, []);
      var ok  = [];
      for (var i = 0; i < chs.length; i++) { if (chs[i].terceroId !== id) ok.push(chs[i]); }
      cacheSet(K_CHOFERES, ok);
    },

    // ── CHOFERES ─────────────────────────────────────────────────────────────
    listarChoferes: function (empresaId) {
      var lista = cacheGet(K_CHOFERES, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarChofer: function (c) { return cacheGuardar(K_CHOFERES, 'choferes', c, 'cho'); },
    borrarChofer:  function (id) { cacheBorrar(K_CHOFERES, 'choferes', id); },

    // ── CAMPOS ────────────────────────────────────────────────────────────────
    listarCampos: function () { return cacheGet(K_CAMPOS, []); },
    camposDeEmpresa: function (empresaId) {
      var lista = cacheGet(K_CAMPOS, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarCampo: function (k) {
      var lista = cacheGet(K_CAMPOS, []);
      var esNuevo = !k.id;
      if (esNuevo) k.id = uid('cam');
      var ok = false;
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].id === k.id) { lista[i] = k; ok = true; break; }
      }
      if (!ok) lista.push(k);
      cacheSet(K_CAMPOS, lista);
      if (usaApi()) {
        var method = esNuevo ? 'POST' : 'PUT';
        var url = esNuevo ? '/api/campos' : '/api/campos/' + encodeURIComponent(k.id);
        apiXHR(method, url, k, function (err) {
          if (err) console.error('PA sync campos:', err.msg || err.status);
        });
      }
      return k;
    },
    borrarCampo: function (id) {
      var lista = cacheGet(K_CAMPOS, []), nueva = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].id !== id) nueva.push(lista[i]); }
      cacheSet(K_CAMPOS, nueva);
      if (usaApi()) {
        apiXHR('DELETE', '/api/campos/' + encodeURIComponent(id), null, function (err) {
          if (err) console.error('PA sync campos (borrar):', err.msg || err.status);
        });
      }
    },

    // ── DEPÓSITOS ────────────────────────────────────────────────────────────
    listarDepositos: function (empresaId) {
      var lista = cacheGet(K_DEPOSITOS, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarDeposito: function (d) { return cacheGuardar(K_DEPOSITOS, 'depositos', d, 'dep'); },
    borrarDeposito:  function (id) { cacheBorrar(K_DEPOSITOS, 'depositos', id); },

    // ── LABORES (lista global) ────────────────────────────────────────────────
    listarLabores: function () { return cacheGet(K_LABORES, []); },
    getLabores:    function () { return this.listarLabores(); },
    guardarLabor:  function (m) { return cacheGuardar(K_LABORES, 'labores', m, 'lab'); },
    borrarLabor:   function (id) { cacheBorrar(K_LABORES, 'labores', id); },

    // ── TIPOS DE ACTIVIDAD (por empresa) ─────────────────────────────────────
    listarTiposActividad: function (empresaId) {
      var lista = cacheGet(K_TIPOACT, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarTipoActividad: function (ta) { return cacheGuardar(K_TIPOACT, 'tipos-actividad', ta, 'ta'); },
    borrarTipoActividad:  function (id) { cacheBorrar(K_TIPOACT, 'tipos-actividad', id); },

    // ── ESPECIES (lista global) ───────────────────────────────────────────────
    listarEspecies: function ()    { return cacheGet(K_ESPECIES, []); },
    guardarEspecie: function (e)   { return cacheGuardar(K_ESPECIES, 'especies', e, 'esp'); },
    borrarEspecie:  function (id)  { cacheBorrar(K_ESPECIES, 'especies', id); },

    // ── UNIDADES (lista global) ───────────────────────────────────────────────
    listarUnidades: function ()    { return cacheGet(K_UNIDADES, []); },
    guardarUnidad:  function (u)   { return cacheGuardar(K_UNIDADES, 'unidades', u, 'un'); },
    borrarUnidad:   function (id)  { cacheBorrar(K_UNIDADES, 'unidades', id); },

    // ── INSUMOS (por empresa) ─────────────────────────────────────────────────
    listarInsumos: function (empresaId) {
      var lista = cacheGet(K_INSUMOS, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarInsumo: function (ins)  { return cacheGuardar(K_INSUMOS, 'insumos', ins, 'ins'); },
    borrarInsumo:  function (id)   { cacheBorrar(K_INSUMOS, 'insumos', id); },

    // ── MODOS DE ACCIÓN (lista global, HRAC / IRAC / FRAC) ───────────────────
    listarModosAccion: function (sistema) {
      var lista = cacheGet(K_MODOSACC, []);
      if (!sistema) return lista;
      var out = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].sistema === sistema) out.push(lista[i]); }
      return out;
    },
    guardarModoAccion: function (moa) { return cacheGuardar(K_MODOSACC, 'modos-accion', moa, 'moa'); },
    borrarModoAccion:  function (id)  { cacheBorrar(K_MODOSACC, 'modos-accion', id); },

    // ── TIPOS DE PROVEEDOR (lista global) ────────────────────────────────────
    listarTiposProveedor: function () { return cacheGet(K_TIPOPROV, []); },

    // ── CATEGORÍAS DE INSUMO (lista global, confirmado con el cliente 2026-07-21) ─
    // Se identifican por `codigo`, no por `id` (así las maneja maestros.html:
    // guardarCategoria/borrarCategoria reciben el objeto/código, nunca el id).
    // Por eso no se puede usar cacheGuardar/cacheBorrar tal cual: hay que
    // resolver el id existente a partir del código antes de delegar en ellos.
    listarCategorias: function () { return cacheGet(K_CATEGORIAS, []); },
    guardarCategoria: function (c) {
      if (!c.id) {
        var lista = cacheGet(K_CATEGORIAS, []);
        for (var i = 0; i < lista.length; i++) { if (lista[i].codigo === c.codigo) { c.id = lista[i].id; break; } }
      }
      return cacheGuardar(K_CATEGORIAS, 'categorias-insumo', c, 'cat');
    },
    borrarCategoria: function (cod) {
      var lista = cacheGet(K_CATEGORIAS, []);
      for (var i = 0; i < lista.length; i++) { if (lista[i].codigo === cod) { cacheBorrar(K_CATEGORIAS, 'categorias-insumo', lista[i].id); break; } }
    },

    // ── USOS (cultivo / unidad de negocio — lista global) ────────────────────
    listarUsos: function () { return cacheGet(K_USOS, []); },
    guardarUso: function (u) { return cacheGuardar(K_USOS, 'usos', u, 'uso'); },
    borrarUso:  function (id) { cacheBorrar(K_USOS, 'usos', id); },

    // ── FORMULACIONES (orden de mezclado en tanque — lista global) ──────────
    listarFormulaciones: function () { return cacheGet(K_FORMUL, []); },
    guardarFormulacion: function (f) { return cacheGuardar(K_FORMUL, 'formulaciones', f, 'f'); },
    borrarFormulacion:  function (id) { cacheBorrar(K_FORMUL, 'formulaciones', id); },

    // ── PRINCIPIOS ACTIVOS (lista global, EIQ) ───────────────────────────────
    listarPrincipiosActivos: function () { return cacheGet(K_PRINACT, []); },
    guardarPrincipioActivo: function (p) { return cacheGuardar(K_PRINACT, 'principios-activos', p, 'pa'); },
    borrarPrincipioActivo:  function (id) { cacheBorrar(K_PRINACT, 'principios-activos', id); },

    // ── SOCIOS (por empresa) ─────────────────────────────────────────────────
    listarSocios: function (empresaId) {
      var lista = cacheGet(K_SOCIOS, []);
      var out   = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].empresaId === empresaId) out.push(lista[i]); }
      return out;
    },
    guardarSocio: function (s) { return cacheGuardar(K_SOCIOS, 'socios', s, 'soc'); },
    borrarSocio:  function (id) { cacheBorrar(K_SOCIOS, 'socios', id); },

    // ── LOTES (por empresa y campo) ───────────────────────────────────────────
    listarLotes: function (empresaId, campoId) {
      var lista = cacheGet(K_LOTES, []), out = [];
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].empresaId !== empresaId) continue;
        if (campoId && lista[i].campoId !== campoId) continue;
        out.push(lista[i]);
      }
      return out;
    },
    guardarLote: function (l) { return cacheGuardar(K_LOTES, 'lotes', l, 'lot'); },
    borrarLote:  function (id) { cacheBorrar(K_LOTES, 'lotes', id); },

    // ── ACTIVIDADES (lote + tipo actividad + campaña) ─────────────────────────
    listarActividades: function (empresaId, campaniaId, loteId) {
      var lista = cacheGet(K_ACTIVIDADES, []), out = [];
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].empresaId !== empresaId) continue;
        if (campaniaId && lista[i].campaniaId !== campaniaId) continue;
        if (loteId && lista[i].loteId !== loteId) continue;
        out.push(lista[i]);
      }
      return out;
    },
    guardarActividad: function (a) { return cacheGuardar(K_ACTIVIDADES, 'actividades', a, 'act'); },
    borrarActividad:  function (id) { cacheBorrar(K_ACTIVIDADES, 'actividades', id); },

    // ── CAMPAÑAS (lista global) ───────────────────────────────────────────────
    listarCampanias: function () {
      var cs = cacheGet(K_CAMPANIAS, []).slice();
      cs.sort(function (a, b) { return (a.orden || 0) - (b.orden || 0); });
      return cs;
    },
    campaniaActiva: function () {
      var cs = cacheGet(K_CAMPANIAS, []);
      for (var i = 0; i < cs.length; i++) { if (cs[i].activa) return cs[i]; }
      return cs.length ? cs[cs.length - 1] : null;
    },
    guardarCampania: function (c) { return cacheGuardar(K_CAMPANIAS, 'campanias', c, 'camp'); },
    borrarCampania:  function (id) { cacheBorrar(K_CAMPANIAS, 'campanias', id); },

    // ── TABLERO COMPLETO (blob JSON para tableros con objeto root propio) ─────
    sincronizarTableroCompleto: function (claveRaiz, estructuraCompleta) {
      // Siempre escribe en localStorage: en local es la fuente de verdad,
      // en producción es caché de sesión para que loadRoot() lo encuentre
      // en el próximo acceso sin esperar respuesta async.
      try { localStorage.setItem(claveRaiz, JSON.stringify(estructuraCompleta)); } catch (e) {}
      if (usaApi()) {
        apiXHR('PUT', '/api/tablero/' + encodeURIComponent(claveRaiz),
          { datos: estructuraCompleta }, function (err) {
            if (err) console.error('PA: error sincronizando tablero:', err.msg || err);
          }
        );
      }
    },

    cargarTableroCompleto: function (claveRaiz, callback) {
      if (!usaApi()) {
        var datos = null;
        try { var s = localStorage.getItem(claveRaiz); datos = s ? JSON.parse(s) : null; } catch (e) {}
        if (callback) callback(null, datos);
      } else {
        apiXHR('GET', '/api/tablero/' + encodeURIComponent(claveRaiz), null, function (err, data) {
          if (callback) callback(err, data);
        });
      }
    },

    // ── USUARIOS ─────────────────────────────────────────────────────────────
    listarUsuarios: function () { return cacheGet(K_USUARIOS, []); },
    usuariosVisibles: function () {
      var ctx = PA.ctx ? PA.ctx() : null;
      var us = cacheGet(K_USUARIOS, []);
      if (!ctx || !ctx.usuario) return us;
      if (ctx.usuario.rol === 'admin_general') return us;
      if (ctx.usuario.rol === 'admin_cliente') {
        var out = [], cid = ctx.usuario.clienteId;
        for (var i = 0; i < us.length; i++) { if (us[i].clienteId === cid) out.push(us[i]); }
        return out;
      }
      return [];
    },
    guardarUsuario: function (u) {
      if (!usaApi()) return cacheGuardar(K_USUARIOS, 'usuarios', u, 'usr');
      var esNuevo = !u.id;
      if (esNuevo) u.id = uid('usr');
      var lista = cacheGet(K_USUARIOS, []), encontrado = false;
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].id === u.id) { lista[i] = u; encontrado = true; break; }
      }
      if (!encontrado) lista.push(u);
      cacheSet(K_USUARIOS, lista);
      var method = esNuevo ? 'POST' : 'PUT';
      var url = esNuevo ? '/api/usuarios' : '/api/usuarios/' + encodeURIComponent(u.id);
      apiXHR(method, url, u, function (err) {
        if (err) console.error('PA sync usuarios:', err.msg || err.status);
      });
      return u;
    },
    borrarUsuario: function (id) {
      var lista = cacheGet(K_USUARIOS, []), out = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].id !== id) out.push(lista[i]); }
      cacheSet(K_USUARIOS, out);
      var ps = cacheGet(K_PERMISOS, []), outp = [];
      for (var i = 0; i < ps.length; i++) { if (ps[i].usuarioId !== id) outp.push(ps[i]); }
      cacheSet(K_PERMISOS, outp);
      if (!usaApi()) return;
      apiXHR('DELETE', '/api/usuarios/' + encodeURIComponent(id), null, function (err) {
        if (err) console.error('PA sync usuarios (borrar):', err.msg || err.status);
      });
    },

    // ── PERMISOS (ABM directo) ────────────────────────────────────────────────
    listarPermisos: function () { return cacheGet(K_PERMISOS, []); },
    buscarPermiso: function (usuarioId, empresaId) {
      var ps = cacheGet(K_PERMISOS, []);
      for (var i = 0; i < ps.length; i++) {
        if (ps[i].usuarioId === usuarioId && ps[i].empresaId === empresaId) return ps[i];
      }
      return null;
    },
    guardarPermiso: function (perm) {
      var ps = cacheGet(K_PERMISOS, []), found = false;
      for (var i = 0; i < ps.length; i++) {
        if (ps[i].usuarioId === perm.usuarioId && ps[i].empresaId === perm.empresaId) {
          ps[i] = perm; found = true; break;
        }
      }
      if (!found) ps.push(perm);
      cacheSet(K_PERMISOS, ps);
      if (!usaApi()) return perm;
      apiXHR('POST', '/api/permisos', perm, function (err) {
        if (err) console.error('PA sync permisos:', err.msg || err.status);
      });
      return perm;
    },
    borrarPermiso: function (usuarioId, empresaId) {
      var ps = cacheGet(K_PERMISOS, []), out = [];
      for (var i = 0; i < ps.length; i++) {
        if (!(ps[i].usuarioId === usuarioId && ps[i].empresaId === empresaId)) out.push(ps[i]);
      }
      cacheSet(K_PERMISOS, out);
      if (!usaApi()) return;
      apiXHR('DELETE', '/api/permisos/' + encodeURIComponent(usuarioId) + '/' + encodeURIComponent(empresaId), null, function (err) {
        if (err) console.error('PA sync permisos (borrar):', err.msg || err.status);
      });
    },

    // ── CLIENTES / EMPRESAS ───────────────────────────────────────────────────
    listarClientes: function () { return cacheGet(K_CLIENTES, []); },
    listarEmpresas: function () { return cacheGet(K_EMPRESAS, []); },
    empresasDeCliente: function (clienteId) {
      var lista = cacheGet(K_EMPRESAS, []), out = [];
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].clienteId === clienteId) out.push(lista[i]);
      }
      return out;
    },
    guardarCliente: function (c) {
      var lista = cacheGet(K_CLIENTES, []);
      var esNuevo = !c.id;
      if (esNuevo) c.id = uid('cli');
      var ok = false;
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].id === c.id) { lista[i] = c; ok = true; break; }
      }
      if (!ok) lista.push(c);
      cacheSet(K_CLIENTES, lista);
      if (usaApi()) {
        var method = esNuevo ? 'POST' : 'PUT';
        var url = esNuevo ? '/api/clientes' : '/api/clientes/' + encodeURIComponent(c.id);
        apiXHR(method, url, c, function (err) {
          if (err) console.error('PA sync clientes:', err.msg || err.status);
        });
      }
      return c;
    },
    borrarCliente: function (id) {
      // Cascada en caché: eliminar empresas y campos del cliente
      var emps = cacheGet(K_EMPRESAS, []), empIds = [], keepEmps = [];
      for (var i = 0; i < emps.length; i++) {
        if (emps[i].clienteId === id) { empIds.push(emps[i].id); }
        else { keepEmps.push(emps[i]); }
      }
      cacheSet(K_EMPRESAS, keepEmps);
      var camps = cacheGet(K_CAMPOS, []), keepCamps = [];
      for (var i = 0; i < camps.length; i++) {
        var skip = false;
        for (var j = 0; j < empIds.length; j++) { if (camps[i].empresaId === empIds[j]) { skip = true; break; } }
        if (!skip) keepCamps.push(camps[i]);
      }
      cacheSet(K_CAMPOS, keepCamps);
      var lista = cacheGet(K_CLIENTES, []), nueva = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].id !== id) nueva.push(lista[i]); }
      cacheSet(K_CLIENTES, nueva);
      if (usaApi()) {
        apiXHR('DELETE', '/api/clientes/' + encodeURIComponent(id), null, function (err) {
          if (err) console.error('PA sync clientes (borrar):', err.msg || err.status);
        });
      }
    },
    guardarEmpresa: function (e) {
      var lista = cacheGet(K_EMPRESAS, []);
      var esNuevo = !e.id;
      if (esNuevo) e.id = uid('emp');
      var ok = false;
      for (var i = 0; i < lista.length; i++) {
        if (lista[i].id === e.id) { lista[i] = e; ok = true; break; }
      }
      if (!ok) lista.push(e);
      cacheSet(K_EMPRESAS, lista);
      if (usaApi()) {
        var method = esNuevo ? 'POST' : 'PUT';
        var url = esNuevo ? '/api/empresas' : '/api/empresas/' + encodeURIComponent(e.id);
        apiXHR(method, url, e, function (err) {
          if (err) console.error('PA sync empresas:', err.msg || err.status);
        });
      }
      return e;
    },
    borrarEmpresa: function (id) {
      // Cascada en caché: eliminar campos de la empresa
      var camps = cacheGet(K_CAMPOS, []), keepCamps = [];
      for (var i = 0; i < camps.length; i++) { if (camps[i].empresaId !== id) keepCamps.push(camps[i]); }
      cacheSet(K_CAMPOS, keepCamps);
      var lista = cacheGet(K_EMPRESAS, []), nueva = [];
      for (var i = 0; i < lista.length; i++) { if (lista[i].id !== id) nueva.push(lista[i]); }
      cacheSet(K_EMPRESAS, nueva);
      if (usaApi()) {
        apiXHR('DELETE', '/api/empresas/' + encodeURIComponent(id), null, function (err) {
          if (err) console.error('PA sync empresas (borrar):', err.msg || err.status);
        });
      }
    },
    empresasVisibles: function () {
      var ctx = PA.ctx ? PA.ctx() : null;
      var es = cacheGet(K_EMPRESAS, []);
      if (!ctx || !ctx.usuario || ctx.usuario.rol === 'admin_general') return es;
      if (ctx.usuario.rol === 'admin_cliente') {
        var out = [], cid = ctx.clienteId;
        for (var i = 0; i < es.length; i++) { if (es[i].clienteId === cid) out.push(es[i]); }
        return out;
      }
      return [];
    },

    // ── HERRAMIENTAS PROPIAS ──────────────────────────────────────────────────
    herramientasPropias: function () { return HERRAMIENTAS_PROPIAS.slice(); },

    // ── RESET DEMO (solo modo local) ─────────────────────────────────────────
    resetDemo: function () {
      var claves = [
        K_CLIENTES, K_EMPRESAS, K_CAMPOS, K_PERMISOS, K_USUARIOS,
        LS_SESION, LS_SEEDVER, LS_EMPACTIVA,
        K_TERCEROS, K_CHOFERES, K_TIPOPROV,
        K_DEPOSITOS, K_LABORES, K_TIPOACT, K_MODOSACC,
        K_INSUMOS, K_UNIDADES, K_ESPECIES,
        'agroTablerosRoot'
      ];
      try { for (var i = 0; i < claves.length; i++) localStorage.removeItem(claves[i]); }
      catch (e) {}
      global.location.reload();
    }
  };

  global.PA = PA;

})(typeof window !== 'undefined' ? window : this);
