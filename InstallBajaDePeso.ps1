<#
Install-BajaDePeso.ps1  (v2 - sin dump externo)

Automatiza el RUNBOOK-migracion.md del modulo de Baja de Peso para la PC
dedicada del Policlinico San Damian, adaptado para NO depender de
baja_de_peso_dump.sql: la base se crea a partir del esquema versionado en el
propio codigo (db/schema.sql) y se carga con datos de demostracion enteramente
sinteticos (db/seed-demo-data.js) - 1 doctor, 4 pacientes, 16 evaluaciones,
generados para probar el flujo de la app, sin ninguna relacion con pacientes
reales.

Requiere:
  - PowerShell corrido COMO ADMINISTRADOR (necesario para las Partes 4 y 5).
  - baja-de-peso-app-codigo.zip en disco (incluye db/schema.sql y
    db/seed-demo-data.js).

USO TIPICO (primera corrida completa):
  .\Install-BajaDePeso.ps1 -ZipPath "C:\migracion\baja-de-peso-app-codigo.zip" `
                            -DoctorEmail "doctor@policlinicosanroman.pe" `
                            -DoctorName "Dra. Nombre Apellido"
  (va a pedir, de forma interactiva y sin mostrarlas en pantalla: la
  contrasena del superusuario postgres, y la contrasena a asignarle a la
  cuenta de doctor nueva.)

Para reanudar desde una parte especifica (por ejemplo si se corto en la 3):
  .\Install-BajaDePeso.ps1 -ZipPath ... -DoctorEmail ... -DoctorName ... -Parts 3,4,5,7

La Parte 1 (instalar Node/PostgreSQL) y la seguridad final (Parte 6) quedan
fuera de la automatizacion a proposito: son pasos que requieren una decision
humana (elegir y guardar la contrasena del superusuario postgres durante el
instalador grafico) o una verificacion manual final. El script SI valida
antes y despues que esos pasos hayan quedado bien hechos.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ZipPath,

    [string]$DoctorName = "Dra. Nombre Apellido",
    [Parameter(Mandatory = $true)]
    [string]$DoctorEmail,

    [string]$InstallDir = "C:\baja-de-peso-app",
    [string]$BackupDir = "C:\backups-baja-de-peso",
    [string]$NssmExe = "C:\nssm\nssm.exe",
    [string]$ServiceName = "BajaDePesoAPI",
    [string]$PgBinDir = "C:\Program Files\PostgreSQL\16\bin",

    # Que partes correr en esta ejecucion. Default: todas las automatizables.
    # 0=prerequisitos, 2=base de datos (rol+schema), 3=deploy de codigo +
    # doctor + seed demo, 4=servicio Windows, 5=backups, 7=checklist final.
    [int[]]$Parts = @(0, 2, 3, 4, 5, 7),

    [switch]$SkipHashCheck
)

$ErrorActionPreference = "Stop"
$ScriptLog = Join-Path $env:TEMP "baja-de-peso-install.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    Write-Host $line
    $line | Out-File -Append -FilePath $ScriptLog -Encoding utf8
}

function Stop-Runbook {
    param([string]$Reason)
    Write-Log "DETENIDO: $Reason" "ERROR"
    Write-Log "Ver la seccion 11 (Rollback) y 12 (Contacto) del runbook antes de reintentar." "ERROR"
    throw $Reason
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertFrom-SecureStringPlain {
    param([Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-PostgresSuperPassword {
    if (-not $script:PgSuperPasswordPlain) {
        $secure = Read-Host -Prompt "Contrasena del superusuario 'postgres' de ESTA PC (paso 3.2 del runbook)" -AsSecureString
        $script:PgSuperPasswordPlain = ConvertFrom-SecureStringPlain $secure
    }
    return $script:PgSuperPasswordPlain
}

function Read-DoctorPassword {
    if (-not $script:DoctorPasswordPlain) {
        $secure = Read-Host -Prompt "Contrasena a asignar a la cuenta de doctor '$DoctorEmail' (minimo 8 caracteres)" -AsSecureString
        $script:DoctorPasswordPlain = ConvertFrom-SecureStringPlain $secure
        if ($script:DoctorPasswordPlain.Length -lt 8) {
            Stop-Runbook "La contrasena de doctor debe tener al menos 8 caracteres."
        }
    }
    return $script:DoctorPasswordPlain
}

function Invoke-NativeStep {
    # Los comandos externos (npm, node, nssm) escriben mensajes normales de
    # progreso a stderr aunque terminen bien (ej. "npm notice"). Con
    # $ErrorActionPreference = "Stop" activo, canalizar esa salida (2>&1)
    # hacia otro cmdlet (Tee-Object, etc.) hace que PowerShell trate esas
    # lineas como errores terminantes y corte el script pese a que el
    # comando en realidad tuvo exito. Por eso estos comandos se corren aca
    # con $ErrorActionPreference = "Continue" y el exito real se valida
    # despues por $LASTEXITCODE, no por la ausencia de texto en stderr.
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$ArgList = @(),
        [switch]$LogOutput
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($LogOutput) {
            & $Exe @ArgList 2>&1 | ForEach-Object {
                $line = $_.ToString()
                Write-Host $line
                $line | Out-File -Append -FilePath $ScriptLog -Encoding utf8
            }
        } else {
            & $Exe @ArgList 2>&1 | Out-Null
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $LASTEXITCODE
}

function Invoke-NativeCapture {
    # Mismo problema que Invoke-NativeStep, pero para llamadas cuya salida se
    # captura en una variable en vez de mostrarse en pantalla (los psql -c/-f
    # de este script). Si psql devuelve un error real (por ejemplo "el rol ya
    # existe"), $LASTEXITCODE != 0 Y ademas escribe a stderr - con
    # $ErrorActionPreference = "Stop" eso corta el script con una excepcion
    # cruda ANTES de que el codigo de arriba pueda revisar el mensaje y
    # decidir que hacer (por ejemplo, mostrar el aviso de "ya existe,
    # confirmar con el desarrollador" en vez de romper feo). Por eso esta
    # llamada tambien se hace con $ErrorActionPreference = "Continue".
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$ArgList = @()
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Exe @ArgList 2>&1
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return [PSCustomObject]@{ Output = ($output | ForEach-Object { $_.ToString() }); ExitCode = $exit }
}

function New-RandomToken {
    param([int]$Bytes = 18)
    return (node -e "console.log(require('crypto').randomBytes($Bytes).toString('base64url'))")
}

# ---------------------------------------------------------------------------
# Parte 0 - Revisar que hay en la PC destino
# ---------------------------------------------------------------------------

function Invoke-Part0 {
    Write-Log "== Parte 0: verificando prerequisitos =="

    $nodeOk = $false
    try {
        $nodeVersion = (node --version)
        Write-Log "node --version -> $nodeVersion"
        # el runbook original pedia v22.x especificamente; se acepta v22 o
        # superior porque package.json no fija ningun "engines" y las
        # dependencias (express/pg/bcryptjs/jsonwebtoken) son compatibles
        if ($nodeVersion -match '^v(\d+)\.') {
            $nodeOk = [int]$Matches[1] -ge 22
        }
    } catch {
        Write-Log "node no esta instalado o no esta en PATH." "WARN"
    }

    $psqlOk = $false
    try {
        $psqlVersion = (psql --version)
        Write-Log "psql --version -> $psqlVersion"
        $psqlOk = $psqlVersion -match '16\.'
    } catch {
        Write-Log "psql no esta instalado o no esta en PATH." "WARN"
    }

    $svc = Get-Service -Name "postgresql-x64-16" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "Servicio postgresql-x64-16: Status=$($svc.Status) StartType=$($svc.StartType)"
        if ($svc.StartType -ne "Automatic") {
            Write-Log "Ajustando StartType a Automatic."
            Set-Service -Name "postgresql-x64-16" -StartupType Automatic
        }
    } else {
        Write-Log "No se encontro el servicio postgresql-x64-16." "WARN"
    }

    if (-not $nodeOk -or -not $psqlOk -or -not $svc -or $svc.Status -ne "Running") {
        Write-Log "PARTE 1 REQUERIDA MANUALMENTE: instalar/completar Node.js v22 LTS y/o PostgreSQL 16 siguiendo la seccion 3 del runbook (incluye elegir a mano la contrasena del superusuario postgres). Volve a correr este script (con -Parts 2,3,4,5,7) una vez confirmado node --version y psql --version." "ERROR"
        throw "Prerequisitos incompletos (ver Parte 1 del runbook, paso manual)."
    }

    Write-Log "Parte 0 OK: node v22.x y psql 16.x presentes, servicio Postgres corriendo."
}

# ---------------------------------------------------------------------------
# Parte 2 - Rol y base de datos (solo esquema, sin dump)
# ---------------------------------------------------------------------------

function Invoke-Part2 {
    Write-Log "== Parte 2: creando rol y base de datos =="

    $pgSuperPassword = Read-PostgresSuperPassword

    # contrasena nueva para el rol de la app
    Write-Log "Generando contrasena nueva para el rol baja_de_peso_app..."
    $appPassword = New-RandomToken -Bytes 18
    if (-not $appPassword) { Stop-Runbook "No se pudo generar la contrasena del rol de aplicacion (revisar que node funcione)." }

    # crear rol (via archivo temporal para no exponer la password en el historial de procesos)
    $roleSqlFile = New-TemporaryFile
    "CREATE ROLE baja_de_peso_app WITH LOGIN PASSWORD '$appPassword';" | Set-Content $roleSqlFile.FullName -Encoding utf8
    $env:PGPASSWORD = $pgSuperPassword
    $roleResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "postgres", "-h", "localhost", "-f", $roleSqlFile.FullName)
    $roleOutput = $roleResult.Output -join "`n"
    $roleExit = $roleResult.ExitCode
    Remove-Item $roleSqlFile.FullName -Force
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

    if ($roleOutput -match '(?i)already exists|ya existe') {
        Write-Log "El rol baja_de_peso_app ya existia. Esto requiere CONFIRMACION MANUAL con el desarrollador antes de seguir - no se reutiliza ni se pisa la contrasena existente." "ERROR"
        Stop-Runbook "Rol baja_de_peso_app ya existe. Confirmar antes de continuar."
    } elseif ($roleExit -ne 0) {
        Stop-Runbook "Fallo al crear el rol baja_de_peso_app: $roleOutput"
    }
    Write-Log "Rol baja_de_peso_app creado."

    # crear base
    $env:PGPASSWORD = $pgSuperPassword
    $dbResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "postgres", "-h", "localhost", "-c", "CREATE DATABASE baja_de_peso OWNER postgres;")
    $dbOutput = $dbResult.Output -join "`n"
    $dbExit = $dbResult.ExitCode
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

    if ($dbOutput -match '(?i)already exists|ya existe') {
        Write-Log "La base baja_de_peso ya existia. Esto requiere CONFIRMACION MANUAL - no se sabe si ya tiene datos." "ERROR"
        Stop-Runbook "Base baja_de_peso ya existe. Confirmar antes de continuar."
    } elseif ($dbExit -ne 0) {
        Stop-Runbook "Fallo al crear la base baja_de_peso: $dbOutput"
    }
    Write-Log "Base baja_de_peso creada."

    $script:AppDbPassword = $appPassword
    Write-Log "Parte 2 completa (el esquema se aplica en la Parte 3, ya con el codigo desplegado)."
}

# ---------------------------------------------------------------------------
# Parte 3 - Desplegar el codigo, aplicar esquema, crear doctor y sembrar demo
# ---------------------------------------------------------------------------

function Invoke-Part3 {
    Write-Log "== Parte 3: desplegando codigo, esquema y datos de demostracion =="

    if (-not (Test-Path $ZipPath)) {
        Stop-Runbook "No se encontro el zip en '$ZipPath'."
    }

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
    Write-Log "Codigo descomprimido en $InstallDir."

    $schemaFile = Join-Path $InstallDir "db\schema.sql"
    if (-not (Test-Path $schemaFile)) {
        Stop-Runbook "No se encontro db\schema.sql dentro del zip desplegado."
    }

    if (-not $script:AppDbPassword) {
        Stop-Runbook "No hay password del rol de app en memoria (corre la Parte 2 en la misma ejecucion, o pasa -Parts 2,3,...)."
    }
    $pgSuperPassword = Read-PostgresSuperPassword

    # aplicar el esquema como superusuario (igual que el runbook original con
    # el dump: la app nunca crea sus propias tablas en produccion)
    $env:PGPASSWORD = $pgSuperPassword
    $schemaResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "postgres", "-h", "localhost", "-d", "baja_de_peso", "-f", $schemaFile, "-v", "ON_ERROR_STOP=1")
    $schemaOutput = $schemaResult.Output
    $schemaExit = $schemaResult.ExitCode
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $schemaOutput | Out-File -Append -FilePath $ScriptLog -Encoding utf8

    if ($schemaExit -ne 0) {
        Stop-Runbook "Fallo al aplicar db\schema.sql: $($schemaOutput -join ' ')"
    }
    Write-Log "Esquema aplicado (extension pgcrypto, 3 tablas, indices)."

    # permisos para el rol de la app
    $env:PGPASSWORD = $pgSuperPassword
    & psql -U postgres -h localhost -d baja_de_peso -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO baja_de_peso_app;" -v ON_ERROR_STOP=1 | Out-Null
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    Write-Log "Permisos otorgados a baja_de_peso_app."

    Push-Location $InstallDir
    try {
        Write-Log "Corriendo npm install (puede tardar unos minutos)..."
        $npmExit = Invoke-NativeStep -Exe "npm" -ArgList @("install") -LogOutput
        if ($npmExit -ne 0) {
            Stop-Runbook "npm install fallo (codigo $npmExit)."
        }

        $jwtSecret = New-RandomToken -Bytes 48
        if (-not $jwtSecret) { Stop-Runbook "No se pudo generar JWT_SECRET." }

        $envContent = @"
DATABASE_URL=postgresql://baja_de_peso_app:$($script:AppDbPassword)@localhost:5432/baja_de_peso
PORT=3001
HOST=127.0.0.1
JWT_SECRET=$jwtSecret
ALLOWED_ORIGIN=http://127.0.0.1:3001
"@
        Set-Content -Path ".env" -Value $envContent -Encoding utf8
        Write-Log ".env generado con credenciales nuevas (HOST=127.0.0.1, solo esta PC)."

        # verificacion 4.5-equivalente: la base debe estar vacia (0/0/0) antes del seed
        $env:PGPASSWORD = $script:AppDbPassword
        $preCountsResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "baja_de_peso_app", "-h", "localhost", "-d", "baja_de_peso", "-t", "-c", "SELECT (SELECT count(*) FROM doctors), (SELECT count(*) FROM patients), (SELECT count(*) FROM evaluations);")
        $preCounts = $preCountsResult.Output
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
        Write-Log "Conteo antes del seed (esperado 0/0/0): $($preCounts -join ' ')"

        $doctorPassword = Read-DoctorPassword
        Write-Log "Creando cuenta de doctor y sembrando datos de demostracion (1 doctor, 4 pacientes, 16 evaluaciones sinteticos)..."
        $seedExit = Invoke-NativeStep -Exe "node" -ArgList @("db\seed-demo-data.js", $DoctorName, $DoctorEmail, $doctorPassword) -LogOutput
        if ($seedExit -ne 0) {
            Stop-Runbook "El seed de datos de demostracion fallo (codigo $seedExit). Ver $ScriptLog."
        }

        # verificacion equivalente a la 4.5 del runbook, ahora con datos sinteticos
        $env:PGPASSWORD = $script:AppDbPassword
        $countsResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "baja_de_peso_app", "-h", "localhost", "-d", "baja_de_peso", "-t", "-c", "SELECT (SELECT count(*) FROM doctors), (SELECT count(*) FROM patients), (SELECT count(*) FROM evaluations);")
        $counts = $countsResult.Output
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
        $parts = ($counts -join "").Trim() -split '\|' | ForEach-Object { $_.Trim() }
        if ($parts.Count -lt 3 -or $parts[0] -ne '1' -or $parts[1] -ne '4' -or $parts[2] -ne '16') {
            Stop-Runbook "Verificacion post-seed fallo. Esperado 1 doctor / 4 pacientes / 16 evaluaciones. Obtenido: '$($counts -join ' ')'."
        }
        Write-Log "Verificacion OK: 1 doctor, 4 pacientes, 16 evaluaciones (demo, sinteticos)."

        # prueba de arranque en segundo plano + /api/health
        Write-Log "Probando arranque en segundo plano..."
        $proc = Start-Process -FilePath "node" -ArgumentList "src\server.js" -WorkingDirectory $InstallDir -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/health" -TimeoutSec 10
            if ($health.status -ne "ok") {
                throw "Respuesta inesperada de /api/health: $($health | ConvertTo-Json -Compress)"
            }
            Write-Log "/api/health respondio OK durante la prueba."
        } catch {
            Stop-Runbook "La prueba de arranque fallo: $($_.Exception.Message). Revisar $InstallDir\.env antes de seguir."
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
        }

        Write-Log "PENDIENTE MANUAL: abrir http://127.0.0.1:3001 en un navegador, iniciar sesion con '$DoctorEmail', y confirmar que aparecen los 4 pacientes de demostracion (Carla Espinoza, Jorge Huaman, Rosa Quispe, Miguel Rios) antes de seguir a la Parte 4." "WARN"
    } finally {
        Pop-Location
    }

    Write-Log "Parte 3 completa."
}

# ---------------------------------------------------------------------------
# Parte 4 - Servicio de Windows (NSSM)
# ---------------------------------------------------------------------------

function Invoke-Part4 {
    Write-Log "== Parte 4: registrando servicio de Windows =="

    if (-not (Test-IsAdmin)) {
        Stop-Runbook "Esta parte requiere PowerShell como Administrador (clic derecho -> Ejecutar como administrador)."
    }

    if (-not (Test-Path $NssmExe)) {
        Stop-Runbook "No se encontro nssm.exe en '$NssmExe'. Descargalo de https://nssm.cc/download, descomprimi nssm.exe (carpeta win64) a esa ruta, y volve a correr con -Parts 4,5,7."
    }

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "El servicio $ServiceName ya existe (Status=$($existing.Status)). No se reinstala; si necesitas reconfigurarlo, quitalo primero con 'nssm remove $ServiceName confirm'." "WARN"
    } else {
        $nodeExe = (Get-Command node).Source
        & $NssmExe install $ServiceName $nodeExe "$InstallDir\src\server.js"
        & $NssmExe set $ServiceName AppDirectory $InstallDir
        & $NssmExe set $ServiceName Start SERVICE_AUTO_START
        & $NssmExe set $ServiceName AppStdout "$InstallDir\service.log"
        & $NssmExe set $ServiceName AppStderr "$InstallDir\service-error.log"
        Write-Log "Servicio $ServiceName instalado con NSSM."
    }

    Invoke-NativeStep -Exe $NssmExe -ArgList @("start", $ServiceName) | Out-Null
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name $ServiceName
    Write-Log "Servicio $ServiceName -> Status=$($svc.Status)"
    if ($svc.Status -ne "Running") {
        $errLog = "$InstallDir\service-error.log"
        if (Test-Path $errLog) {
            Write-Log "Ultimas lineas de service-error.log:" "ERROR"
            Get-Content $errLog -Tail 20 | ForEach-Object { Write-Log $_ "ERROR" }
        }
        Stop-Runbook "El servicio $ServiceName no quedo Running. Revisar .env y que el puerto 3001 este libre."
    }

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/health" -TimeoutSec 10
        Write-Log "/api/health via servicio: $($health | ConvertTo-Json -Compress)"
    } catch {
        Stop-Runbook "El servicio esta Running pero /api/health no respondio: $($_.Exception.Message)"
    }

    Write-Log "PENDIENTE MANUAL (no lo saltees): reiniciar la PC completa y confirmar que /api/health responde solo, sin iniciar sesion en Windows." "WARN"
    Write-Log "Parte 4 completa (servicio instalado y respondiendo; falta la prueba real de reinicio)."
}

# ---------------------------------------------------------------------------
# Parte 5 - Backups automaticos
# ---------------------------------------------------------------------------

function Invoke-Part5 {
    Write-Log "== Parte 5: configurando backups automaticos =="

    if (-not (Test-IsAdmin)) {
        Stop-Runbook "Esta parte requiere PowerShell como Administrador (para registrar la tarea programada)."
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir "diarios") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir "mensuales") | Out-Null

    $pgSuperPassword = Read-PostgresSuperPassword
    $pgDumpPath = Join-Path $PgBinDir "pg_dump.exe"

    $backupScriptPath = Join-Path $BackupDir "backup.ps1"
    $backupScriptContent = @"
`$ErrorActionPreference = "Stop"
`$fecha = Get-Date -Format "yyyy-MM-dd"
`$logFile = "$BackupDir\backup.log"
`$pgDump = "$pgDumpPath"

function Log(`$msg) {
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') `$msg" | Out-File -Append -FilePath `$logFile -Encoding utf8
}

`$env:PGPASSWORD = "$pgSuperPassword"

# --- respaldo diario (retencion: 90 dias) ---
`$dailyPath = "$BackupDir\diarios\baja_de_peso_`$fecha.sql"
try {
  & `$pgDump -U postgres -h localhost -d baja_de_peso -f `$dailyPath
  if (`$LASTEXITCODE -ne 0) { throw "pg_dump salio con codigo `$LASTEXITCODE" }
  `$contenido = Get-Content `$dailyPath -Raw
  if (`$contenido.Length -lt 500 -or `$contenido -notmatch "COPY public\.patients") {
    throw "el dump generado parece incompleto o vacio (tamano: `$(`$contenido.Length) bytes)"
  }
  Log "OK diario: `$dailyPath (`$([math]::Round((Get-Item `$dailyPath).Length/1KB,1)) KB)"
} catch {
  Log "ERROR diario: `$(`$_.Exception.Message)"
}

# --- respaldo mensual (dia 1 de cada mes, sin borrado automatico) ---
if ((Get-Date).Day -eq 1) {
  `$monthPath = "$BackupDir\mensuales\baja_de_peso_`$(Get-Date -Format 'yyyy-MM').sql"
  try {
    & `$pgDump -U postgres -h localhost -d baja_de_peso -f `$monthPath
    if (`$LASTEXITCODE -ne 0) { throw "pg_dump salio con codigo `$LASTEXITCODE" }
    Log "OK mensual: `$monthPath"
  } catch {
    Log "ERROR mensual: `$(`$_.Exception.Message)"
  }
}

Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

# limpieza: solo los diarios de mas de 90 dias
Get-ChildItem "$BackupDir\diarios\*.sql" -ErrorAction SilentlyContinue |
  Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-90) } | Remove-Item
"@
    Set-Content -Path $backupScriptPath -Value $backupScriptContent -Encoding utf8
    Write-Log "Script de backup escrito en $backupScriptPath."

    # Restringir el archivo (contiene la password de postgres) solo a
    # Administradores y SYSTEM. Se usan los SID conocidos (*S-1-5-32-544 =
    # Administradores, *S-1-5-18 = SYSTEM) en vez de los nombres en texto:
    # "Administrators" no existe con ese nombre en un Windows en espanol
    # (ahi el grupo se llama "Administradores"), y el SID es el mismo sin
    # importar el idioma de Windows.
    $icaclsInh = Invoke-NativeCapture -Exe "icacls" -ArgList @($backupScriptPath, "/inheritance:r")
    if ($icaclsInh.ExitCode -ne 0) {
        Stop-Runbook "No se pudo quitar la herencia de permisos de backup.ps1: $($icaclsInh.Output -join ' ')"
    }
    $icaclsGrant = Invoke-NativeCapture -Exe "icacls" -ArgList @($backupScriptPath, "/grant:r", "*S-1-5-32-544:F", "*S-1-5-18:F")
    if ($icaclsGrant.ExitCode -ne 0) {
        Stop-Runbook "No se pudieron restringir los permisos de backup.ps1 (contiene la contrasena de postgres en texto plano): $($icaclsGrant.Output -join ' ')"
    }
    Write-Log "Permisos de backup.ps1 restringidos a Administradores/SYSTEM."

    $existingTask = Get-ScheduledTask -TaskName "BackupBajaDePeso" -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "La tarea programada BackupBajaDePeso ya existe. No se recrea." "WARN"
    } else {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$backupScriptPath`""
        $trigger = New-ScheduledTaskTrigger -Daily -At "2:00AM"
        Register-ScheduledTask -TaskName "BackupBajaDePeso" -Action $action -Trigger $trigger -RunLevel Highest | Out-Null
        Write-Log "Tarea programada BackupBajaDePeso creada (diaria, 2 AM)."
    }

    Write-Log "Corriendo un backup de prueba ahora..."
    & powershell -File $backupScriptPath
    $lastLine = Get-Content (Join-Path $BackupDir "backup.log") -Tail 1
    Write-Log "Ultima linea de backup.log: $lastLine"
    if ($lastLine -notmatch "OK diario") {
        Stop-Runbook "El backup de prueba no dio 'OK diario'. Revisar $BackupDir\backup.log y que postgresql-x64-16 este Running."
    }

    Write-Log "Parte 5 completa."
}

# ---------------------------------------------------------------------------
# Parte 7 - Checklist final
# ---------------------------------------------------------------------------

function Invoke-Part7 {
    Write-Log "== Parte 7: checklist final =="

    $nodeV = try { node --version } catch { "NO INSTALADO" }
    $psqlV = try { psql --version } catch { "NO INSTALADO" }
    $pgSvc = (Get-Service postgresql-x64-16 -ErrorAction SilentlyContinue).Status
    $appSvc = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status

    Write-Log "node: $nodeV"
    Write-Log "psql: $psqlV"
    Write-Log "Servicio PostgreSQL: $pgSvc"
    Write-Log "Servicio $ServiceName : $appSvc"

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/health" -TimeoutSec 10
        Write-Log "/api/health: $($health | ConvertTo-Json -Compress)"
    } catch {
        Write-Log "/api/health NO respondio: $($_.Exception.Message)" "ERROR"
    }

    if ($script:AppDbPassword) {
        $env:PGPASSWORD = $script:AppDbPassword
        $countsResult = Invoke-NativeCapture -Exe "psql" -ArgList @("-U", "baja_de_peso_app", "-h", "localhost", "-d", "baja_de_peso", "-t", "-c", "SELECT (SELECT count(*) FROM doctors), (SELECT count(*) FROM patients), (SELECT count(*) FROM evaluations);")
        $counts = $countsResult.Output
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
        Write-Log "Conteo doctores/pacientes/evaluaciones: $($counts -join ' ')"
    } else {
        Write-Log "No se corrio la Parte 2 en esta ejecucion; no se repite el conteo." "WARN"
    }

    $task = Get-ScheduledTask -TaskName "BackupBajaDePeso" -ErrorAction SilentlyContinue
    Write-Log "Tarea BackupBajaDePeso: $($task.State)"
    $backupLog = Join-Path $BackupDir "backup.log"
    if (Test-Path $backupLog) {
        Get-Content $backupLog -Tail 3 | ForEach-Object { Write-Log "backup.log: $_" }
    }

    Write-Host ""
    Write-Host "===================== PENDIENTES MANUALES (no automatizables) ====================="
    Write-Host "[ ] Parte 1: confirmar que la contrasena del superusuario postgres es fuerte y unica."
    Write-Host "[ ] Login en http://127.0.0.1:3001 con '$DoctorEmail' y confirmar los 4 pacientes de"
    Write-Host "    demostracion (Carla Espinoza, Jorge Huaman, Rosa Quispe, Miguel Rios)."
    Write-Host "[ ] Reiniciar la PC completa y confirmar que el sistema vuelve solo, sin iniciar"
    Write-Host "    sesion en Windows."
    Write-Host "[ ] Guardar la contrasena del rol baja_de_peso_app, el JWT_SECRET (ya en"
    Write-Host "    $InstallDir\.env) y la contrasena de la cuenta de doctor en un gestor de"
    Write-Host "    contrasenas."
    Write-Host "[ ] Cuando haya datos reales de pacientes, cargarlos desde la propia app (login web) -"
    Write-Host "    los 4 pacientes/16 evaluaciones sembrados aca son sinteticos, solo para probar el"
    Write-Host "    flujo; borralos o reemplazalos antes de operar con pacientes reales."
    Write-Host "====================================================================================="
    Write-Log "Parte 7 (checklist) completa. Log detallado en $ScriptLog"
}

# ---------------------------------------------------------------------------
# Orquestador
# ---------------------------------------------------------------------------

Write-Log "Iniciando instalacion automatizada. Partes a correr: $($Parts -join ', ')"

foreach ($p in $Parts) {
    switch ($p) {
        0 { Invoke-Part0 }
        2 { Invoke-Part2 }
        3 { Invoke-Part3 }
        4 { Invoke-Part4 }
        5 { Invoke-Part5 }
        7 { Invoke-Part7 }
        default { Write-Log "Parte $p no es automatizable por este script (ver runbook: Parte 1 y Parte 6 son manuales)." "WARN" }
    }
}

Write-Log "Ejecucion finalizada."
