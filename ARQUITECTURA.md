# Arquitectura del proyecto — PuntalAgro-Tableros-3C

## Contexto

El cliente mantiene un conjunto de páginas HTML standalone que usan `localStorage` como base de datos en el navegador. Periódicamente comparte nuevas versiones de esos archivos vía GitHub.

Nuestro trabajo es **traducir** esas páginas a una aplicación de 3 capas:

- **Frontend** — HTML/JS sin localStorage, consume la API REST
- **Backend** — Node.js / Express
- **Base de datos** — PostgreSQL


---

## Estructura de directorios

```
PuntalAgro-Tableros-3C/
├── client-src/              ← versiones del cliente SIN MODIFICAR
│   ├── 2026-06-23/          ← fecha de recepción (una carpeta por entrega)
│   │   ├── tablero_insumos_ot.html
│   │   ├── usuarios.html
│   │   └── ...
│   └── 2026-09-01/          ← próxima entrega del cliente
│       └── ...
├── frontend/
│   ├── api.js               ← capa HTTP pura 
│   └── *.html               ← versiones adaptadas al modelo 3 capas
├── backend/
│   └── server.js            ← API REST Express
└── database/
    └── init.sql             ← schema PostgreSQL + datos iniciales
```

### Regla fundamental

`client-src/` es de solo lectura. Nunca se modifican esos archivos — son la referencia para calcular qué cambió el cliente entre versiones.

