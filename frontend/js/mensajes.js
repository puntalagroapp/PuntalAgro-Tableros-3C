/* =============================================================================
   mensajes.js — Puntal Agro: helpers de mensajes de éxito/error (ES5)
   =============================================================================
   Expone en window:
     marcarExito(el, texto)  — pinta el mensaje como éxito (ver css/mensajes.css)
     marcarError(el, texto)  — pinta el mensaje como error
     limpiarMsg(el)          — lo deja vacío, sin estilo

   `el` es el elemento <span class="msg"> (o similar) donde va el mensaje —
   nunca un id ni un selector, así no importa cómo se llame en cada pantalla.
   ============================================================================= */
(function (global) {
  'use strict';

  var ICONO_OK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M20 6 9 17l-5-5"/></svg>';
  var ICONO_ERROR = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/></svg>';

  function pintar(el, icono, texto, clase) {
    if (!el) return;
    el.innerHTML = icono + '<span></span>';
    el.lastChild.textContent = texto;
    el.className = 'msg ' + clase;
  }

  global.marcarExito = function (el, texto) {
    pintar(el, ICONO_OK, texto, 'msg-ok');
  };

  global.marcarError = function (el, texto) {
    pintar(el, ICONO_ERROR, texto, 'msg-error');
  };

  global.limpiarMsg = function (el) {
    if (!el) return;
    el.innerHTML = '';
    el.className = 'msg';
  };

})(window);
