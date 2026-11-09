# Installs Accar TV on an Android TV over the home network, without touching the TV's downloads.
# Uses only official tools: Google's adb, fetched from dl.google.com when it is not already here.
param(
    [string]$Ip,
    [string]$PairAddress,
    [string]$PairCode,
    [switch]$SetHome,
    [switch]$Remote,
    [switch]$Debloat,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

$Package = 'ru.accar.tv'
$Activity = "$Package/ru.kraft.launcher.MainActivity"
$ApkUrl = 'https://github.com/al0ha-c0de/accar-tv/raw/main/accar-tv.apk'
$ToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$Work = Join-Path $env:LOCALAPPDATA 'AccarTV'
$TvBackup = '/sdcard/AccarTV/disabled.txt'

# Only the maker's ads, data collection and partner auto-installs. Nothing is removed: each one is
# switched off with pm disable-user and comes back with -Restore. A trailing * matches a family.
$AdPackages = @(
    'com.zeasn.services.general',           # Zeasn: ads, weather and shortcuts on the stock home
    'com.zeasn.deviceportal.asdprovider.*', # Zeasn: device portal, collects data and pings OTA
    'android.autoinstalls.config.*'         # partner apps installed from Play without asking
)
# Never touched, whatever the list says.
$Protected = '^(android|com\.android\..*|com\.google\.android\.(gms|gsf|tvlauncher|leanbacklauncher)|ru\.accar\.tv)$'

function Select-AdPackages([string[]]$installed, [string]$homePackage) {
    foreach ($name in $installed) {
        if ($name -match $Protected -or $name -eq $homePackage) { continue }
        foreach ($pattern in $AdPackages) {
            $wanted = if ($pattern.EndsWith('*')) { $name.StartsWith($pattern.TrimEnd('*')) } else { $name -eq $pattern }
            if ($wanted) { $name; break }
        }
    }
}

function Say([string]$text) { Write-Host $text }
function Ask([string]$question) { if ($Quiet) { return '' } return (Read-Host $question).Trim() }
function Yes([string]$question, [bool]$preset) {
    if ($Quiet) { return $preset }
    $answer = (Read-Host "$question (Д/Н)").Trim().ToLower()
    return $answer -eq 'д' -or $answer -eq 'y' -or $answer -eq 'да'
}
function Fail([string]$text) {
    Write-Host ''
    Write-Host $text -ForegroundColor Yellow
    if (!$Quiet) { Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null }
    exit 1
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Say $(if ($Restore) { 'Возврат сервисов телевизора' } else { 'Установка Accar TV' })
Say ''

# 1. adb: a copy next to this script, the one on PATH, or Google's official download.
$adb = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
if (!(Test-Path $adb)) { $adb = Join-Path $Work 'platform-tools\adb.exe' }
if (!(Test-Path $adb)) {
    $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($onPath) { $adb = $onPath.Source }
}
if (!(Test-Path $adb)) {
    Say 'Скачиваем инструменты Google (около 7 МБ)…'
    $zip = Join-Path $Work 'platform-tools.zip'
    try { Invoke-WebRequest -UseBasicParsing -Uri $ToolsUrl -OutFile $zip }
    catch { Fail 'Не удалось скачать инструменты Google. Проверьте интернет на компьютере.' }
    Expand-Archive -Path $zip -DestinationPath $Work -Force
    Remove-Item $zip
    $adb = Join-Path $Work 'platform-tools\adb.exe'
}

# 2. The app itself: a file next to this script, or the latest one from GitHub.
$apk = Join-Path $PSScriptRoot 'accar-tv.apk'
if (!$Restore -and !(Test-Path $apk)) {
    Say 'Скачиваем Accar TV…'
    $apk = Join-Path $Work 'accar-tv.apk'
    try { Invoke-WebRequest -UseBasicParsing -Uri $ApkUrl -OutFile $apk }
    catch { Fail 'Не удалось скачать Accar TV. Проверьте интернет на компьютере.' }
}

function Adb { & $adb @args 2>&1 | ForEach-Object { "$_" } }

# 3. Connecting. Newer TVs pair with a code first; older ones use network debugging on port 5555.
Say ''
Say 'На телевизоре: «Настройки» → «Об устройстве» → 7 раз нажмите на «Сборка».'
Say 'Затем в «Для разработчиков» включите «Отладка по сети» или «Беспроводная отладка».'
Say ''
if (!$PairAddress -and !$Quiet -and (Yes 'Телевизор показывает код сопряжения?' $false)) {
    $PairAddress = Ask 'Адрес и порт сопряжения с экрана (например 192.168.0.50:37123)'
    $PairCode = Ask 'Код сопряжения'
}
if ($PairAddress) {
    $paired = Adb pair $PairAddress $PairCode
    if (($paired -join ' ') -notmatch 'Successfully') { Fail "Сопряжение не удалось: $($paired -join ' ')" }
    if (!$Ip) { $Ip = Ask 'Адрес и порт подключения с экрана «Беспроводная отладка»' }
}
if (!$Ip) { $Ip = Ask 'IP-адрес телевизора (виден в «Настройки» → «Сеть»)' }
if (!$Ip) { Fail 'Не указан адрес телевизора.' }
$target = if ($Ip -match ':\d+$') { $Ip } else { "${Ip}:5555" }

Say "Подключаемся к $target…"
Adb connect $target | Out-Null
Say 'Если на телевизоре появится «Разрешить отладку?», отметьте «Всегда» и нажмите «ОК».'
$state = ''
for ($i = 0; $i -lt 60; $i++) {
    $state = (Adb -s $target get-state) -join ''
    if ($state -eq 'device') { break }
    if ($i % 5 -eq 4) { Adb connect $target | Out-Null }
    Start-Sleep -Seconds 1
}
if ($state -ne 'device') { Fail 'Телевизор не ответил. Проверьте, что отладка включена и компьютер в той же сети.' }

function Packages([string]$filter) {
    Adb -s $target shell pm list packages $filter | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ }
}

# Restore: switch back on everything this installer switched off, then stop.
if ($Restore) {
    $listed = Adb -s $target shell cat $TvBackup | Where-Object { $_ -match '^[\w.]+$' }
    $local = Join-Path $Work "disabled-$($target -replace '[:.]', '-').txt"
    if (!$listed -and (Test-Path $local)) { $listed = Get-Content $local }
    $off = @(Packages '-d')
    $back = @($listed | Select-Object -Unique | Where-Object { $_ -in $off })
    if (!$back) { Say 'Отключённых установщиком сервисов нет.' }
    foreach ($name in $back) {
        if ($DryRun) { Say "Включили бы: $name"; continue }
        Adb -s $target shell pm enable $name | Out-Null
        Say "Включён: $name"
    }
    if (!$DryRun) { Adb -s $target shell rm -f $TvBackup | Out-Null; if (Test-Path $local) { Remove-Item $local } }
    Adb disconnect $target | Out-Null
    Say ''
    Say 'Готово. Сервисы телевизора возвращены.'
    if (!$Quiet) { Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null }
    exit 0
}

# 4. Install, replacing an older Accar TV; a copy signed differently has to go first.
Say 'Устанавливаем Accar TV…'
$result = (Adb -s $target install -r $apk) -join ' '
if ($result -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
    if (!(Yes 'На телевизоре старая версия с другой подписью. Удалить её и поставить новую?' $true)) { Fail 'Установка отменена.' }
    Adb -s $target uninstall $Package | Out-Null
    $result = (Adb -s $target install $apk) -join ' '
}
if ($result -notmatch 'Success') { Fail "Установка не удалась: $result" }
Say 'Accar TV установлен.'

# 5. Optional steps. Each changes a TV setting, so each is asked for.
if ($SetHome -or (Yes 'Сделать Accar TV главным экраном?' $false)) {
    $homeResult = (Adb -s $target shell cmd package set-home-activity $Activity) -join ' '
    if ($homeResult -match 'Success') { Say 'Accar TV стал главным экраном.' }
    else { Say 'Этот телевизор не дал сменить экран отсюда: нажмите «Домой» и выберите Accar TV → «Всегда».' }
}
if ($Remote -or (Yes 'Включить пульт с телефона (клавиатура и курсор Accar)?' $false)) {
    Adb -s $target shell ime enable "$Package/ru.kraft.launcher.RemoteKeyboard" | Out-Null
    Adb -s $target shell ime set "$Package/ru.kraft.launcher.RemoteKeyboard" | Out-Null
    $service = "$Package/ru.kraft.launcher.CursorService"
    $enabled = ((Adb -s $target shell settings get secure enabled_accessibility_services) -join '').Trim()
    if ($enabled -eq 'null' -or !$enabled) { $enabled = $service }
    elseif ($enabled -notmatch [regex]::Escape($service)) { $enabled = "${enabled}:$service" }
    Adb -s $target shell settings put secure enabled_accessibility_services $enabled | Out-Null
    Adb -s $target shell settings put secure accessibility_enabled 1 | Out-Null
    Say 'Пульт включён: откройте Accar TV → «Настройки» → «Пульт с телефона».'
}

if ($Debloat -or (Yes 'Отключить рекламу и сбор данных производителя? Вернуть можно в любой момент' $false)) {
    $homeLine = (Adb -s $target shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME) | Select-Object -Last 1
    $homePackage = "$homeLine".Split('/')[0].Trim()
    $found = @(Select-AdPackages @(Packages '-e') $homePackage)
    if (!$found) { Say 'На этом телевизоре нечего отключать из нашего списка.' }
    else {
        $local = Join-Path $Work "disabled-$($target -replace '[:.]', '-').txt"
        if (!$DryRun) { Adb -s $target shell mkdir -p /sdcard/AccarTV | Out-Null }
        foreach ($name in $found) {
            if ($DryRun) { Say "Отключили бы: $name"; continue }
            # The list is written first, so a cut connection still leaves a way back.
            Adb -s $target shell "echo $name >> $TvBackup" | Out-Null
            Add-Content -Path $local -Value $name
            $off = (Adb -s $target shell pm disable-user --user 0 $name) -join ' '
            if ($off -match 'disabled') { Say "Отключён: $name" } else { Say "Не отключился: $name ($off)" }
        }
        Say 'Вернуть: запустите Restore-TV.bat. «Вернуть прежний экран» в Accar их не включает.'
    }
}

Adb -s $target shell monkey -p $Package -c android.intent.category.LEANBACK_LAUNCHER 1 | Out-Null
Adb disconnect $target | Out-Null
Say ''
Say 'Готово. Accar TV открыт на телевизоре.'
Say 'Вернуть прежний экран: Accar TV → «Настройки» → «Вернуть прежний экран».'
if (!$Quiet) { Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null }
