/* =============================================================================
   api.js — Puntal Agro: helpers de acceso a la API REST (ES5, XHR)
   =============================================================================
   Expone en window:
     apiGet(path, cb)           — GET con Authorization Bearer
     apiPost(path, data, cb)    — POST JSON con Authorization Bearer
     apiPut(path, data, cb)     — PUT JSON con Authorization Bearer
     apiDelete(path, cb)        — DELETE con Authorization Bearer
     apiLock(tabla, id, empresaId, cb)   — tomar/renovar el lock de un registro
     apiUnlock(tabla, id, cb)            — liberar el lock de un registro

   Callbacks: function(err, data)
     err  = null si OK; { status, error } si falla
     data = objeto JSON parseado (null si no hay body)
     Si err.status === 409, err.error trae el mensaje listo para mostrar
     ("Lo está editando María") y err.bloqueadoPor = {nombre, desde}.

   La sesión (token) se lee de localStorage['pa_sesion_activa'].
   ============================================================================= */
(function (global) {
  'use strict';

  var LS_SESION = 'pa_sesion_activa';

  function getToken() {
    try {
      var raw = localStorage.getItem(LS_SESION);
      if (!raw) return null;
      var obj = JSON.parse(raw);
      return (obj && obj.token) ? obj.token : null;
    } catch (e) { return null; }
  }

  function xhr(method, path, data, cb) {
    var req = new XMLHttpRequest();
    req.open(method, path, true);
    req.setRequestHeader('Content-Type', 'application/json');
    var token = getToken();
    if (token) req.setRequestHeader('Authorization', 'Bearer ' + token);

    req.onreadystatechange = function () {
      if (req.readyState !== 4) return;
      var json = null;
      try { json = JSON.parse(req.responseText); } catch (e) {}
      if (req.status >= 200 && req.status < 300) {
        if (cb) cb(null, json);
      } else {
        var msg = (json && json.error) ? json.error : ('Error ' + req.status);
        var errObj = { status: req.status, error: msg };
        if (json && json.bloqueadoPor) errObj.bloqueadoPor = json.bloqueadoPor;
        if (cb) cb(errObj, null);
      }
    };

    req.send(
      (data !== null && data !== undefined) ? JSON.stringify(data) : null
    );
  }

  global.apiGet    = function (path, cb)       { xhr('GET',    path, null, cb); };
  global.apiPost   = function (path, data, cb) { xhr('POST',   path, data, cb); };
  global.apiPut    = function (path, data, cb) { xhr('PUT',    path, data, cb); };
  global.apiDelete = function (path, cb)       { xhr('DELETE', path, null, cb); };

  // Locking pesimista de registros: 'tabla' es un identificador lógico
  // (nombre de colección, o namespace tipo 'plan_uso_suelo:lote').
  global.apiLock = function (tabla, id, empresaId, cb) {
    xhr('POST', '/api/locks/' + encodeURIComponent(tabla) + '/' + encodeURIComponent(id),
      { empresaId: empresaId || null }, cb);
  };
  global.apiUnlock = function (tabla, id, cb) {
    xhr('DELETE', '/api/locks/' + encodeURIComponent(tabla) + '/' + encodeURIComponent(id), null, cb);
  };

})(window);
