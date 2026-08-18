# Runbook de migración — Módulo de Baja de Peso (v2, completo)

**Para:** quien instale esto en la PC dedicada del Policlínico San Damián.
**Versión:** 2 — reemplaza cualquier copia anterior de este documento.
**Preparado:** 2026-08-07, junto con el desarrollador del sistema.
**Tiempo estimado total:** 2 a 3 horas, sin apuro, la primera vez.

Este documento es autónomo — no necesitás haber visto el proyecto antes. Sí necesitás
permisos de administrador en la PC destino y comodidad básica con PowerShell (copiar y
pegar comandos es suficiente).

**Regla general para todo el documento:** si un comando da un resultado distinto al
"resultado esperado" que se muestra, **parar y no improvisar el siguiente paso** — ver
la sección 12 (Rollback / si algo sale mal) antes de continuar.

---

## 0. Qué es esto, en una frase

Un backend Node.js + PostgreSQL para el panel de evolución del programa de Baja de Peso.
Hoy corre en la PC personal del desarrollador con datos reales de 4 pacientes ya
cargados; esta migración lo lleva a la PC dedicada del consultorio, con persistencia
automática y backups, para que quede operando de forma permanente sin depender de una
laptop personal.

---

## 1. Qué incluye este paquete

| Archivo                       | Tamaño | Qué es                                                                                                                                                             |
| ----------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `baja-de-peso-app-codigo.zip` | ~76 KB | El código de la aplicación (34 archivos: backend, frontend, tests, docs) — sin `node_modules`, sin secretos. Generado desde el commit `eda2fc4` del repo.          |
| `baja_de_peso_dump.sql`       | ~8 KB  | ⚠️ **Contiene datos reales de pacientes.** 1 cuenta de doctor, 4 pacientes, 16 evaluaciones clínicas. Tratarlo como información médica confidencial (ver Parte 8). |
| `RUNBOOK-migracion.md`        | —      | Este documento                                                                                                                                                     |

**Verificación de integridad** (opcional, pero recomendado si se transfirió por USB — confirma que el archivo no se corrompió en la copia):

```powershell
Get-FileHash "ruta\a\baja-de-peso-app-codigo.zip" -Algorithm SHA256
# esperado: 0B93054A0091D58B6AC43B06FB5E11F919DC8C6F32A90BA5607D7C002B70F83D

Get-FileHash "ruta\a\baja_de_peso_dump.sql" -Algorithm SHA256
# esperado: 15E1C29490BD676C76FDE150CFE04BF046F5A23B01600B16A7087C5AB1DE6783
```

Si el hash no coincide exactamente, la transferencia se corrompió — volvé a copiar el
archivo, no sigas adelante con uno que no coincide.

---

## 2. Parte 0 — Antes de empezar: revisar qué hay en la PC destino

_(~5 minutos)_

Abrí PowerShell y corré, uno por uno:

```powershell
node --version
```

**Esperado:** `v22.x.x`. Este proyecto se desarrolló y probó con `v22.16.0` — cualquier
`v22.x` debería servir; si da `v18`, `v20`, o no reconoce el comando, ir a la Parte 1.

```powershell
psql --version
```

**Esperado:** `psql (PostgreSQL) 16.x`. Se desarrolló con `16.9`. Si da otra versión
mayor (15, 17) o no reconoce el comando, ir a la Parte 1.

```powershell
Get-Service -Name "*postgres*"
```

Si ya aparece un servicio `postgresql-x64-16` con `Status: Running`, PostgreSQL ya está
instalado y corriendo — anotá si tenés o no la contraseña del usuario `postgres` de
**esa** instalación (la vas a necesitar en la Parte 3; si no la tenés, puede que haga
falta reinstalar PostgreSQL desde cero para fijar una nueva).

Si **ambos** (`node` y `psql`) ya dieron la versión correcta, podés saltar directo a la
Parte 3.

---

## 3. Parte 1 — Instalar prerequisitos

_(~20-30 minutos, depende de la velocidad de internet)_

### 3.1 — Node.js v22 (LTS)

1. Ir a [nodejs.org](https://nodejs.org) y descargar la versión **LTS** (no la "Current").
2. Ejecutar el instalador, dejar todas las opciones por defecto (incluye npm
   automáticamente).
3. Cerrar y volver a abrir PowerShell (importante — si no, no reconoce el comando
   `node` recién instalado).
4. Confirmar: `node --version` → `v22.x.x`.

### 3.2 — PostgreSQL 16

1. Ir a [postgresql.org/download/windows](https://www.postgresql.org/download/windows/)
   → "Download the installer" → elegir la versión **16.x** (no la más nueva si es la
   17 — este proyecto usa específicamente la 16).
2. Ejecutar el instalador:
   - Componentes: dejar todos marcados (PostgreSQL Server, pgAdmin, Command Line Tools,
     Stack Builder no es necesario).
   - Directorio de datos: dejar el default.
   - **Contraseña del superusuario `postgres`:** este es el paso más importante de
     todo el instalador. Elegí una contraseña **larga y única, distinta a cualquier
     otra que uses** — esta base va a tener datos de salud reales. Anotala de
     inmediato en un gestor de contraseñas, antes de seguir — si se pierde, hay que
     reinstalar Postgres para resetearla.
   - Puerto: dejar `5432` (el default).
   - Locale: dejar el default.
3. Al terminar, confirmar: `psql --version` → `psql (PostgreSQL) 16.x`.
4. Confirmar que el servicio quedó corriendo y en arranque automático:
   ```powershell
   Get-Service -Name "postgresql-x64-16" | Select-Object Status, StartType
   ```
   **Esperado:** `Status: Running`, `StartType: Automatic`. Si `StartType` no es
   `Automatic`:
   ```powershell
   Set-Service -Name "postgresql-x64-16" -StartupType Automatic
   ```

---

## 4. Parte 2 — Restaurar la base de datos

_(~15 minutos)_

Todo esto se corre desde PowerShell. Reemplazá `LA_CONTRASEÑA_DE_POSTGRES` por la que
elegiste en el paso 3.2 cada vez que aparezca.

### 4.1 — Elegir una contraseña nueva para el rol de la aplicación

**No reutilizar ninguna contraseña de la PC de desarrollo — generar una nueva acá:**

```powershell
node -e "console.log(require('crypto').randomBytes(18).toString('base64url'))"
```

Copiá el resultado y guardalo en un gestor de contraseñas — la vas a necesitar en los
pasos 4.2 y 5.3. En este documento la vamos a llamar `LA_CONTRASEÑA_APP`.

LA_CONTRASEÑA_APP = sandamian2026

### 4.2 — Crear el rol y la base de datos vacía

```powershell
$env:PGPASSWORD = "LA_CONTRASEÑA_DE_POSTGRES"
psql -U postgres -h localhost -c "CREATE ROLE baja_de_peso_app WITH LOGIN PASSWORD 'LA_CONTRASEÑA_APP';"
```

**Esperado:** `CREATE ROLE`. Si dice `role "baja_de_peso_app" already exists`, alguien
ya corrió este paso antes — confirmar con el desarrollador antes de seguir (no volver a
crear el rol con otra contraseña sin avisar, rompe cualquier `.env` ya configurado).

```powershell
psql -U postgres -h localhost -c "CREATE DATABASE baja_de_peso OWNER postgres;"
```

**Esperado:** `CREATE DATABASE`. Si dice `database "baja_de_peso" already exists`,
parar y confirmar con el desarrollador — no continuar sin saber si esa base ya tiene
datos.

### 4.3 — Restaurar el dump (esquema + los 16 datos reales, en un solo paso)

```powershell
psql -U postgres -h localhost -d baja_de_peso -f "ruta\a\baja_de_peso_dump.sql"
```

Este archivo incluye la extensión `pgcrypto`, las 3 tablas con sus restricciones, y
todos los datos reales — **no hace falta correr ningún otro script de migración
además de este paso.**

**Salida esperada** (resumida — va a imprimir más líneas, esto es lo importante):

```
CREATE EXTENSION
CREATE TABLE   (×3 — doctors, evaluations, patients)
COPY 1          (doctors)
COPY 16         (evaluations)
COPY 4          (patients)
ALTER TABLE    (varias — llaves primarias, foráneas, restricciones)
CREATE INDEX
```

Si en vez de `COPY 16` dice `COPY 0`, o el comando corta con un error `ERROR:`, **no
sigas** — la restauración no fue limpia. Volvé a intentar desde el paso 4.2 con la base
recién creada (no reutilices una base a medio restaurar).

### 4.4 — Dar permisos al rol de la aplicación

```powershell
psql -U postgres -h localhost -d baja_de_peso -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO baja_de_peso_app;"
```

**Esperado:** `GRANT`.

_(Nota técnica, no bloqueante: esto le da al rol de la app permisos más amplios de los
que el código realmente usa — nunca hace `DELETE` ni `TRUNCATE` por ejemplo. Se replica
así a propósito porque es exactamente lo que ya está probado funcionando en la PC de
desarrollo; acotarlo es una mejora de seguridad para más adelante, no para hoy.)_

### 4.5 — Verificar la restauración con los valores exactos esperados

```powershell
$env:PGPASSWORD = "LA_CONTRASEÑA_APP"
psql -U baja_de_peso_app -h localhost -d baja_de_peso -c "SELECT (SELECT count(*) FROM doctors) AS doctores, (SELECT count(*) FROM patients) AS pacientes, (SELECT count(*) FROM evaluations) AS evaluaciones;"
```

**Resultado exacto esperado:**

```
 doctores | pacientes | evaluaciones
----------+-----------+--------------
        1 |         4 |           16
```

Si alguno de estos tres números es distinto, la restauración no está completa — no
seguir a la Parte 3.

---

## 5. Parte 3 — Desplegar el código

_(~15 minutos)_

1. Descomprimí `baja-de-peso-app-codigo.zip` en una carpeta fija, por ejemplo
   `C:\baja-de-peso-app` (evitá rutas con espacios o tildes).
2. Abrí PowerShell **en esa carpeta** (`cd C:\baja-de-peso-app`) y corré:
   ```powershell
   npm install
   ```
   **Esperado:** termina sin errores en rojo, algo como `added 127 packages`. Warnings
   en amarillo sobre paquetes deprecados son normales, no son un problema.
3. Copiá `.env.example` a `.env`:
   ```powershell
   Copy-Item .env.example .env
   ```
4. Abrí `.env` con el Bloc de notas (`notepad .env`) y completalo así:

   ```
   DATABASE_URL=postgresql://baja_de_peso_app:LA_CONTRASEÑA_APP@localhost:5432/baja_de_peso
   PORT=3001
   HOST=127.0.0.1
   JWT_SECRET=<generar uno nuevo, ver abajo>
   ALLOWED_ORIGIN=http://127.0.0.1:3001
   ```

   Para el `JWT_SECRET` (tampoco reutilizar el de la PC de desarrollo):

   ```powershell
   node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
   ```

   Pegá el resultado como valor de `JWT_SECRET`, guardá el archivo.

   **Sobre `HOST`:** `127.0.0.1` significa que la app solo responde a peticiones desde
   esta misma PC. Si otras PCs del consultorio van a necesitar acceder directamente
   (no solo esta máquina), avisale al desarrollador **antes** de cambiar esto — implica
   también ajustar la regla de firewall (Parte 7, punto 2).

5. **Prueba manual antes de instalarlo como servicio:**

   ```powershell
   npm start
   ```

   **Esperado:** `API corriendo en http://127.0.0.1:3001`, y la terminal queda
   "colgada" ahí (es normal, el proceso sigue corriendo en primer plano).

   En **otra** ventana de PowerShell:

   ```powershell
   Invoke-RestMethod http://127.0.0.1:3001/api/health
   ```

   **Esperado:** `status ok` (formato tabla de PowerShell) o `{"status":"ok"}`.

   Abrí `http://127.0.0.1:3001` en un navegador. Iniciá sesión con la cuenta de doctor
   existente (la contraseña es la misma que usan hoy — se migró junto con los datos en
   el dump, el sistema no la cambia). Confirmá que aparecen los 4 pacientes reales:
   Gianella Canazas, john, Roberto S., Valeria T.

   Volvé a la primera ventana y presioná `Ctrl+C` para cortar esta prueba — en la
   Parte 6 lo dejamos corriendo de forma permanente.

---

## 6. Parte 4 — Que el sistema sobreviva un reinicio de la PC

_(~15 minutos)_

Sin esto, si la PC se reinicia (corte de luz, actualización de Windows), el sistema
queda caído hasta que alguien lo note y lo levante a mano. Usamos
[NSSM](https://nssm.cc/) para registrarlo como un servicio real de Windows — arranca
solo, **sin que nadie tenga que iniciar sesión en la PC**.

1. Descargar NSSM de [nssm.cc/download](https://nssm.cc/download) (el `.zip`),
   descomprimir, y copiar `nssm.exe` de la carpeta `win64` a una ruta simple, por
   ejemplo `C:\nssm\nssm.exe`.
2. Abrir PowerShell **como administrador** (clic derecho → "Ejecutar como
   administrador") — este paso falla en silencio si no es como administrador. Correr:
   ```powershell
   C:\nssm\nssm.exe install BajaDePesoAPI "C:\Program Files\nodejs\node.exe" "C:\baja-de-peso-app\src\server.js"
   C:\nssm\nssm.exe set BajaDePesoAPI AppDirectory "C:\baja-de-peso-app"
   C:\nssm\nssm.exe set BajaDePesoAPI Start SERVICE_AUTO_START
   C:\nssm\nssm.exe set BajaDePesoAPI AppStdout "C:\baja-de-peso-app\service.log"
   C:\nssm\nssm.exe set BajaDePesoAPI AppStderr "C:\baja-de-peso-app\service-error.log"
   C:\nssm\nssm.exe start BajaDePesoAPI
   ```
   _(Las líneas de `AppStdout`/`AppStderr` son nuevas respecto a la primera versión de
   este runbook — sin esto, si el servicio falla al arrancar, no queda ningún registro
   de por qué.)_
3. Verificar:

   ```powershell
   Get-Service BajaDePesoAPI
   ```

   **Esperado:** `Status: Running`.

   Si dice `Stopped`, revisar el log de errores:

   ```powershell
   Get-Content C:\baja-de-peso-app\service-error.log -Tail 20
   ```

   Las causas más comunes: `.env` mal configurado (paso 5.4), o el puerto 3001 ya en
   uso por la prueba manual de la Parte 3 que no se cerró (`Ctrl+C` en esa ventana antes
   de seguir acá).

4. **Prueba real** (no te la saltees — es la que de verdad confirma que esto funciona):
   reiniciá la PC completa (`Restart-Computer` o el botón de Windows), esperá a que
   arranque, **sin iniciar sesión en Windows**, y desde otra PC de la misma red (o
   esperando el tiempo normal de arranque y después iniciando sesión) confirmá que
   `http://127.0.0.1:3001/api/health` responde de nuevo sin que nadie haya hecho nada
   manualmente.

---

## 7. Parte 5 — Backups automáticos

_(~15 minutos)_

**Diseño del esquema** (decidido junto con el desarrollador, 2026-08-07):

- **Frecuencia:** diario, 2 AM.
- **Retención en dos niveles:** diarios guardados 90 días (recuperación rápida ante un
  error reciente) + mensuales (día 1 de cada mes) **sin borrado automático** — alineado
  con los 15 años que exige la
  [Norma Técnica de Salud para la Gestión de la Historia Clínica](https://www.gob.pe/institucion/minsa/normas-legales/187487-214-)
  (R.M. Nº 214-2018/MINSA). La base es chica, así que guardar los mensuales
  indefinidamente no cuesta espacio. _(No es asesoría legal — confirmar con quien
  maneje el tema regulatorio en el policlínico.)_
- **Ubicación:** solo local por ahora — sin copia en la nube todavía (decisión
  explícita).
- **Verificación:** cada corrida confirma que el `.sql` generado no está vacío/corrupto
  y deja todo registrado en un log.

_(Este diseño fue probado en vivo antes de escribir este runbook: se corrió la lógica
completa contra una base de prueba, incluyendo una simulación de fallo intencional
—contraseña incorrecta— para confirmar que el chequeo de integridad realmente detecta
un problema y no solo cuando todo sale bien.)_

### 7.1 — Crear la estructura de carpetas

```powershell
New-Item -ItemType Directory -Force -Path "C:\backups-baja-de-peso\diarios"
New-Item -ItemType Directory -Force -Path "C:\backups-baja-de-peso\mensuales"
```

Si hay un segundo disco físico disponible, usar esa ruta en vez de `C:\`.

### 7.2 — Crear el script `C:\backups-baja-de-peso\backup.ps1`

```powershell
$ErrorActionPreference = "Stop"
$fecha = Get-Date -Format "yyyy-MM-dd"
$logFile = "C:\backups-baja-de-peso\backup.log"
$pgDump = "C:\Program Files\PostgreSQL\16\bin\pg_dump.exe"

function Log($msg) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -Append -FilePath $logFile -Encoding utf8
}

$env:PGPASSWORD = "LA_CONTRASEÑA_DE_POSTGRES"

# --- respaldo diario (retención: 90 días) ---
$dailyPath = "C:\backups-baja-de-peso\diarios\baja_de_peso_$fecha.sql"
try {
  & $pgDump -U postgres -h localhost -d baja_de_peso -f $dailyPath
  if ($LASTEXITCODE -ne 0) { throw "pg_dump salió con código $LASTEXITCODE" }
  $contenido = Get-Content $dailyPath -Raw
  if ($contenido.Length -lt 500 -or $contenido -notmatch "COPY public\.patients") {
    throw "el dump generado parece incompleto o vacío (tamaño: $($contenido.Length) bytes)"
  }
  Log "OK diario: $dailyPath ($([math]::Round((Get-Item $dailyPath).Length/1KB,1)) KB)"
} catch {
  Log "ERROR diario: $($_.Exception.Message)"
}

# --- respaldo mensual (día 1 de cada mes, sin borrado automático) ---
if ((Get-Date).Day -eq 1) {
  $monthPath = "C:\backups-baja-de-peso\mensuales\baja_de_peso_$(Get-Date -Format 'yyyy-MM').sql"
  try {
    & $pgDump -U postgres -h localhost -d baja_de_peso -f $monthPath
    if ($LASTEXITCODE -ne 0) { throw "pg_dump salió con código $LASTEXITCODE" }
    Log "OK mensual: $monthPath"
  } catch {
    Log "ERROR mensual: $($_.Exception.Message)"
  }
}

Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

# limpieza: solo los diarios de más de 90 días — los mensuales nunca se borran acá
Get-ChildItem "C:\backups-baja-de-peso\diarios\*.sql" -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } | Remove-Item
```

### 7.3 — Programarlo diario con el Programador de Tareas de Windows

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File C:\backups-baja-de-peso\backup.ps1"
$trigger = New-ScheduledTaskTrigger -Daily -At "2:00AM"
Register-ScheduledTask -TaskName "BackupBajaDePeso" -Action $action -Trigger $trigger -RunLevel Highest
```

### 7.4 — Verificar

```powershell
powershell -File C:\backups-baja-de-peso\backup.ps1
Get-Content C:\backups-baja-de-peso\backup.log -Tail 5
```

**Esperado:** la última línea dice `OK diario: ...`. Si dice `ERROR`, revisar que la
contraseña del paso 7.2 sea la correcta y que el servicio de PostgreSQL esté
`Running` (`Get-Service postgresql-x64-16`) antes de continuar.

```powershell
Get-ChildItem C:\backups-baja-de-peso\diarios\
```

**Esperado:** un archivo `baja_de_peso_YYYY-MM-DD.sql` de unos 8 KB.

**Recomendación a futuro, no bloqueante:** cada tanto (ej. una vez al trimestre),
restaurar manualmente el backup más reciente contra una base de prueba separada, para
confirmar que el proceso completo funciona de punta a punta — la verificación
automática de arriba agarra archivos vacíos/corruptos, pero no reemplaza probar una
restauración real.

---

## 8. Parte 6 — Seguridad, antes de dar esto por terminado

1. **Confirmar que la contraseña del superusuario `postgres` de esta PC es fuerte y
   distinta de cualquier otra** — si seguiste la Parte 1, ya la elegiste bien, solo
   confirmalo.
2. **Si en algún momento se expone la app a otras PCs del consultorio** (cambiar
   `HOST` de `127.0.0.1` a la IP de la red local): revisar la regla de firewall de
   Windows para Node.js y dejarla en el perfil **"Privado"**, nunca "Público":
   ```powershell
   Get-NetFirewallRule -DisplayName "*node*" | Set-NetFirewallProfile -Profile Private
   ```
3. **Borrar `baja_de_peso_dump.sql`** de esta PC y de cualquier USB/medio usado para
   traerlo, una vez confirmada la restauración exitosa (paso 4.5). Es texto plano con
   datos reales de pacientes.

---

## 9. Parte 7 — Checklist final consolidado

Correr esto de un tirón al final, como última confirmación:

```powershell
Write-Host "node:" (node --version)
Write-Host "psql:" (psql --version)
Write-Host "PostgreSQL service:" (Get-Service postgresql-x64-16).Status
Write-Host "BajaDePesoAPI service:" (Get-Service BajaDePesoAPI).Status
Invoke-RestMethod http://127.0.0.1:3001/api/health
$env:PGPASSWORD = "LA_CONTRASEÑA_APP"
psql -U baja_de_peso_app -h localhost -d baja_de_peso -c "SELECT (SELECT count(*) FROM doctors) AS doctores, (SELECT count(*) FROM patients) AS pacientes, (SELECT count(*) FROM evaluations) AS evaluaciones;"
Get-ScheduledTask -TaskName BackupBajaDePeso | Select-Object State
Get-Content C:\backups-baja-de-peso\backup.log -Tail 3
```

- [ ] `node` es v22.x, `psql` es 16.x
- [ ] Servicio `postgresql-x64-16`: `Running`
- [ ] Servicio `BajaDePesoAPI`: `Running`
- [ ] `/api/health` responde `{"status":"ok"}`
- [ ] La base tiene exactamente 1 doctor, 4 pacientes, 16 evaluaciones
- [ ] Login con la cuenta de doctor existente funciona desde el navegador
- [ ] El sistema sobrevivió un reinicio completo de la PC sin intervención manual
- [ ] La tarea `BackupBajaDePeso` existe y `backup.log` dice `OK diario`
- [ ] Contraseña del superusuario `postgres` fuerte y nueva (no reutilizada)
- [ ] `baja_de_peso_dump.sql` borrado de esta PC y de cualquier USB usado

---

## 10. Problemas conocidos, no bloqueantes

Identificados en la revisión previa a esta migración, documentados pero **no**
corregidos todavía — no impiden que el sistema funcione hoy, quedan para una próxima
actualización del código:

- Algunos campos del formulario de evaluación (`eval_date` en particular) no validan
  el formato antes de guardar — un error de tipeo puede dar un mensaje de error
  genérico en vez de uno claro. No corrompe datos, solo es menos claro de lo que
  debería.
- El login tiene una diferencia de tiempo de respuesta medible entre un correo
  registrado y uno que no existe — de bajo riesgo práctico con 1-2 cuentas de
  doctor, documentado para una corrección futura.

Si alguno de estos se manifiesta durante o después de la migración, no es indicio de
que algo salió mal en el proceso — son comportamientos ya conocidos del código actual.

---

## 11. Rollback / si algo sale mal

**Los datos originales no se tocan en ningún paso de este proceso** — el dump es una
copia de solo lectura tomada de la PC de desarrollo, que sigue intacta ahí. Si algo
falla en cualquier parte de este runbook, se puede volver a intentar desde cero sin
haber perdido nada.

Para reiniciar limpio en la PC destino (borra lo que se haya avanzado ahí, no toca la
PC de desarrollo):

```powershell
psql -U postgres -h localhost -c "DROP DATABASE IF EXISTS baja_de_peso;"
psql -U postgres -h localhost -c "DROP ROLE IF EXISTS baja_de_peso_app;"
```

y volver a empezar desde la Parte 4.2.

**Nunca correr estos dos comandos contra la PC de desarrollo** — ahí sí hay datos
reales sin otra copia más que este dump.

---

## 12. Contacto

Ante cualquier duda, o cualquier resultado que no coincida con lo "esperado" en este
documento, contactar al desarrollador antes de improvisar un paso que no esté acá — en
particular, nunca correr `DROP DATABASE`/`DROP TABLE` fuera de la sección 11, ni contra
una base que no sea explícitamente la de prueba que se está armando en esta PC.
