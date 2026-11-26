# PanelBoot · EnsambleDoor

Interfaz de puesto y servidor .NET para validación de paneles, impresión Kanban, lectores QR y PLC Siemens S7-1500.

## Compilar en Windows

Con .NET 8 SDK y una versión de Node.js compatible con Vite, desde la raíz:

```powershell
Set-Location frontend
npm ci
npm run build
Set-Location ..
dotnet build backend/backend.csproj
```

La compilación de Vite genera `backend/wwwroot`. Para ejecutar, usá `dotnet run --project backend/backend.csproj` y abrí `http://localhost:5121`.

- [Instalación y orden de migraciones SQL](docs/manual_instalacion.md)
- [Estaciones independientes](docs/estaciones_independientes.md)
- [Salteo, selección de paneles e impresión](docs/salteo.md)
- [PLC Siemens y flujo de cuna](docs/plc_siemens_s7_1500.md)

Configurá `connection.json`, `plc-recipe.json` y los parámetros de estación en cada instalación. Esos archivos con datos locales deben quedar fuera del repositorio.
