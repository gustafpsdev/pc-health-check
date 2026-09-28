<#
.SYNOPSIS
    Diagnostico de saude de PC (Windows) — coleta especificacoes, detecta o que
    esta deixando a maquina lenta e gera um relatorio HTML com recomendacoes,
    passo a passo de solucao e um guia de otimizacao.

.DESCRIPTION
    Levanta hardware, sistema, disco, memoria, inicializacao e atualizacoes via
    CIM/WMI, aplica regras de diagnostico, calcula uma nota de saude (0-100) e
    gera um relatorio HTML com:
      - achados priorizados por gravidade, cada um com passos de solucao;
      - um guia de otimizacao (limpeza e manutencao) baseado nas orientacoes
        oficiais da Microsoft.

    Compativel com Windows PowerShell 5.1 e PowerShell 7.

.PARAMETER DemoData
    Usa um PC simulado (data/demo-pc.json) em vez de coletar da maquina atual.

.PARAMETER Clean
    Limpa com segurança os arquivos temporários (%TEMP% e Windows\Temp),
    ignorando os que estao em uso. Nao roda em modo -DemoData.

.PARAMETER OutputPath
    Caminho do relatorio HTML. Padrao: output/pc-health-report.html.

.PARAMETER DataPath
    Caminho do JSON de demonstracao (usado com -DemoData).

.EXAMPLE
    ./Get-PCHealthReport.ps1                 # diagnostica esta maquina

.EXAMPLE
    ./Get-PCHealthReport.ps1 -Clean          # diagnostica e limpa os temporários

.EXAMPLE
    ./Get-PCHealthReport.ps1 -DemoData       # roda com o PC de exemplo

.NOTES
    Autor: Gustavo Paiva
    Rode como usuario comum; alguns dados e a limpeza ficam mais completos como Administrador.
    Guia de otimizacao baseado nas orientacoes da Microsoft (support.microsoft.com).
#>

[CmdletBinding()]
param(
    [switch]$DemoData,
    [switch]$Clean,
    [string]$OutputPath = "output/pc-health-report.html",
    [string]$DataPath = "data/demo-pc.json"
)

$ptBR = [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")
function Fmt($value, $dec = 1) { return ([double]$value).ToString("N$dec", $ptBR) }

# ===========================================================================
# 0) LIMPEZA OPCIONAL DE TEMPORARIOS (-Clean)
# ===========================================================================
function Invoke-TempCleanup {
    $targets = @($env:TEMP, (Join-Path $env:SystemRoot "Temp")) | Select-Object -Unique
    $freedBytes = 0
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { continue }
        $before = (Get-ChildItem $t -Recurse -Force -File -ErrorAction SilentlyContinue |
                   Measure-Object Length -Sum).Sum
        Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue   # arquivos em uso sao ignorados
        $after = (Get-ChildItem $t -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
        if ($before -and $after) { $freedBytes += ($before - $after) }
        elseif ($before) { $freedBytes += $before }
    }
    return [math]::Round($freedBytes / 1MB, 1)
}

if ($Clean -and -not $DemoData) {
    Write-Host "[limpeza] removendo arquivos temporários ..." -ForegroundColor Cyan
    $freedMB = Invoke-TempCleanup
    Write-Host ("[limpeza] liberados ~{0} MB de temporários." -f (Fmt $freedMB)) -ForegroundColor Green
}
elseif ($Clean -and $DemoData) {
    Write-Host "[limpeza] ignorada em modo demonstracao." -ForegroundColor Yellow
}

# ===========================================================================
# 1) COLETA — monta um "snapshot" padronizado (demo OU maquina real)
# ===========================================================================
function Get-LiveSnapshot {
    Write-Host "[coletando] lendo dados desta maquina ..." -ForegroundColor Cyan

    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)   # KB -> /1MB = GB
    $usedGB  = [math]::Round($totalGB - $freeGB, 1)
    $usedPct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100) } else { 0 }
    $uptime  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)

    $disks = @()
    foreach ($ld in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")) {
        if (-not $ld.Size) { continue }
        $tGB = [math]::Round($ld.Size / 1GB, 1)
        $fGB = [math]::Round($ld.FreeSpace / 1GB, 1)
        $fPct = if ($ld.Size -gt 0) { [math]::Round(($ld.FreeSpace / $ld.Size) * 100) } else { 0 }
        $disks += [PSCustomObject]@{ drive = $ld.DeviceID; totalGB = $tGB; freeGB = $fGB; freePercent = $fPct }
    }

    $sysDiskType = "Desconhecido"; $health = "Desconhecido"
    try {
        $sysNum = (Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$sysNum" } | Select-Object -First 1
        if (-not $pd) { $pd = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1 }
        if ($pd) {
            $mt = "$($pd.MediaType)"
            if ($mt -match 'SSD|4') { $sysDiskType = "SSD" }
            elseif ($mt -match 'HDD|3') { $sysDiskType = "HDD" }
            $health = "$($pd.HealthStatus)"
        }
    } catch { }

    $startupCount = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
    $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ name = $_.Name; memMB = [math]::Round($_.WorkingSet64 / 1MB) } }

    $lastUpdateDays = $null
    try {
        $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } |
              Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { $lastUpdateDays = [math]::Round(((Get-Date) - $hf.InstalledOn).TotalDays) }
    } catch { }

    $tempGB = 0
    try {
        $sum = (Get-ChildItem $env:TEMP -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
        if ($sum) { $tempGB = [math]::Round($sum / 1GB, 1) }
    } catch { }

    $gpu = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name } | ForEach-Object { $_.Name })

    return [PSCustomObject]@{
        computer = [PSCustomObject]@{ hostname = $env:COMPUTERNAME; manufacturer = $cs.Manufacturer; model = $cs.Model }
        os       = [PSCustomObject]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; uptimeDays = $uptime }
        cpu      = [PSCustomObject]@{ name = $cpu.Name; cores = $cpu.NumberOfCores; logical = $cpu.NumberOfLogicalProcessors; maxClockGhz = [math]::Round($cpu.MaxClockSpeed / 1000, 1); loadPercent = [int]$cpu.LoadPercentage }
        memory   = [PSCustomObject]@{ totalGB = $totalGB; usedGB = $usedGB; usedPercent = $usedPct }
        storage  = [PSCustomObject]@{ systemDiskType = $sysDiskType; health = $health }
        disks    = $disks
        gpu      = $gpu
        startupCount = $startupCount
        topProcesses = $top
        lastUpdateDays = $lastUpdateDays
        tempGB = $tempGB
    }
}

if ($DemoData) {
    Write-Host "[modo demonstracao] lendo $DataPath ..." -ForegroundColor Cyan
    if (-not (Test-Path $DataPath)) { throw "Arquivo de demo nao encontrado: $DataPath" }
    $snap = Get-Content $DataPath -Raw | ConvertFrom-Json
}
else {
    $snap = Get-LiveSnapshot
}

# ===========================================================================
# 2) DIAGNOSTICO — regras -> achados (com passos) + nota de saude
#    (Severidade interna em ASCII: Alta / Media / Baixa)
# ===========================================================================
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding($area, $sev, $title, $detail, $steps) {
    $findings.Add([PSCustomObject]@{ Area = $area; Severity = $sev; Title = $title; Detail = $detail; Steps = @($steps) })
}

foreach ($d in $snap.disks) {
    if ($d.freePercent -lt 10) {
        Add-Finding "Disco" "Alta" "Disco $($d.drive) quase cheio" `
            "Apenas $($d.freePercent)% livres ($(Fmt $d.freeGB) GB de $(Fmt $d.totalGB) GB). Abaixo de 10% o Windows fica lento." `
            @(
                "Ativar o Sensor de Armazenamento: Configurações &gt; Sistema &gt; Armazenamento.",
                "Rodar a Limpeza de Disco: tecle Win+R, digite <code>cleanmgr</code>, escolha o disco $($d.drive).",
                "Limpar temporários: Win+R &gt; <code>%temp%</code> (apagar tudo) e depois <code>C:\Windows\Temp</code>.",
                "Esvaziar a Lixeira e mover arquivos grandes para outro disco ou para a nuvem."
            )
    }
    elseif ($d.freePercent -lt 20) {
        Add-Finding "Disco" "Media" "Disco $($d.drive) com pouco espaço" `
            "$($d.freePercent)% livres ($(Fmt $d.freeGB) GB). O ideal é manter pelo menos 20% livres." `
            @(
                "Ativar o Sensor de Armazenamento (Configurações &gt; Sistema &gt; Armazenamento).",
                "Desinstalar aplicativos que não usa (Configurações &gt; Aplicativos &gt; Aplicativos instalados)."
            )
    }
}
if ($snap.storage.systemDiskType -eq "HDD") {
    Add-Finding "Disco" "Alta" "Disco do sistema é HDD (mecânico)" `
        "O sistema roda em HDD. Este costuma ser o maior gargalo de lentidão — trocar por SSD é o upgrade de melhor custo-benefício." `
        @(
            "Escolher um SSD compatível (SATA 2,5&quot; ou NVMe, conforme a placa).",
            "Migrar com software de clonagem, ou reinstalar o Windows limpo no SSD.",
            "Manter o HDD como disco secundário para arquivos."
        )
}
if ($snap.storage.health -and $snap.storage.health -notin @("Healthy","Desconhecido")) {
    Add-Finding "Disco" "Alta" "Saúde do disco: $($snap.storage.health)" `
        "O disco reportou estado diferente de saudável. Risco de perda de dados." `
        @(
            "Fazer backup imediato dos dados importantes.",
            "Rodar <code>chkdsk C: /scan</code> e conferir o Visualizador de Eventos.",
            "Programar a substituição do disco."
        )
}
if ($snap.memory.usedPercent -ge 90) {
    Add-Finding "Memória" "Alta" "Memória RAM sob forte pressão" `
        "$($snap.memory.usedPercent)% da RAM em uso ($(Fmt $snap.memory.usedGB) GB de $(Fmt $snap.memory.totalGB) GB)." `
        @(
            "Fechar abas e programas não usados (Ctrl+Shift+Esc &gt; Processos, ordenar por Memória).",
            "Desativar apps em segundo plano: Configurações &gt; Aplicativos &gt; app &gt; Opções avançadas.",
            "Se for recorrente, aumentar a RAM (idealmente 16 GB)."
        )
}
elseif ($snap.memory.usedPercent -ge 80) {
    Add-Finding "Memória" "Media" "Uso de RAM elevado" `
        "$($snap.memory.usedPercent)% da RAM em uso." `
        @(
            "Reduzir a quantidade de programas e abas abertos ao mesmo tempo.",
            "Avaliar upgrade de RAM se o uso alto persistir."
        )
}
if ($snap.memory.totalGB -lt 8) {
    Add-Finding "Memória" "Media" "Pouca RAM instalada" `
        "A máquina tem $(Fmt $snap.memory.totalGB) GB de RAM. 8 GB é o mínimo confortável hoje." `
        @(
            "Planejar upgrade para 8&ndash;16 GB.",
            "Enquanto isso, limitar programas simultâneos e abas do navegador."
        )
}
if ($snap.startupCount -gt 10) {
    Add-Finding "Inicialização" "Media" "Muitos programas na inicialização" `
        "$($snap.startupCount) itens iniciam junto com o Windows, deixando o boot lento." `
        @(
            "Abrir o Gerenciador de Tarefas (Ctrl+Shift+Esc) e ir na aba Inicializar.",
            "Clicar com o botão direito nos itens de 'Alto impacto' desnecessários &gt; Desabilitar."
        )
}
if ($snap.lastUpdateDays -ne $null -and $snap.lastUpdateDays -gt 45) {
    Add-Finding "Atualizações" "Media" "Windows sem atualizar há $($snap.lastUpdateDays) dias" `
        "Correções de segurança e desempenho ficam pendentes." `
        @(
            "Configurações &gt; Windows Update &gt; Verificar se há atualizações.",
            "Conferir 'Opções avançadas' &gt; 'Atualizações opcionais' para drivers."
        )
}
if ($snap.os.uptimeDays -gt 7) {
    Add-Finding "Sistema" "Baixa" "Sem reiniciar há $(Fmt $snap.os.uptimeDays 0) dias" `
        "Reiniciar resolve lentidão acumulada e aplica atualizações pendentes." `
        @( "Salvar o trabalho e reiniciar (Iniciar &gt; Energia &gt; Reiniciar)." )
}
if ($snap.cpu.loadPercent -gt 85) {
    Add-Finding "CPU" "Media" "Uso de CPU alto no momento" `
        "CPU em $($snap.cpu.loadPercent)%." `
        @(
            "Abrir o Gerenciador de Tarefas (Ctrl+Shift+Esc) &gt; aba Processos, ordenar por CPU.",
            "Encerrar ou reinstalar o processo que estiver consumindo demais."
        )
}
if ($snap.tempGB -gt 3) {
    Add-Finding "Limpeza" "Baixa" "Arquivos temporários acumulados" `
        "$(Fmt $snap.tempGB) GB em arquivos temporários." `
        @(
            "Ativar o Sensor de Armazenamento (Configurações &gt; Sistema &gt; Armazenamento).",
            "Ou rodar este script com <code>-Clean</code> para limpar os temporários com segurança."
        )
}

$weights = @{ "Alta" = 20; "Media" = 10; "Baixa" = 5 }
$penalty = 0
foreach ($f in $findings) { $penalty += $weights[$f.Severity] }
$score = [math]::Max(0, 100 - $penalty)
$scoreClass = if ($score -ge 80) { "green" } elseif ($score -ge 50) { "amber" } else { "red" }
$scoreLabel = if ($score -ge 80) { "Boa" } elseif ($score -ge 50) { "Atencao" } else { "Ruim" }
$cAlta  = @($findings | Where-Object Severity -eq "Alta").Count
$cMedia = @($findings | Where-Object Severity -eq "Media").Count
$cBaixa = @($findings | Where-Object Severity -eq "Baixa").Count

# ===========================================================================
# 3) RELATORIO HTML
# ===========================================================================
function Sev-Badge($s) { switch ($s) { "Alta" {"b-red"} "Media" {"b-amber"} "Baixa" {"b-blue"} default {"b-gray"} } }
function Sev-Label($s) { switch ($s) { "Media" {"Média"} default { $s } } }

$sevOrder = @{ "Alta"=0; "Media"=1; "Baixa"=2 }
$findSorted = $findings | Sort-Object @{ Expression = { $sevOrder[$_.Severity] } }

$findCards = foreach ($f in $findSorted) {
    $stepsHtml = ($f.Steps | ForEach-Object { "<li>$_</li>" }) -join ""
    @"
    <div class="finding sev-$($f.Severity)">
      <div class="f-head">
        <div><span class="area">$($f.Area)</span><span class="f-title">$($f.Title)</span></div>
        <span class="badge $(Sev-Badge $f.Severity)">$(Sev-Label $f.Severity)</span>
      </div>
      <p class="f-detail">$($f.Detail)</p>
      <div class="f-rec"><b>Como resolver:</b><ul class="f-steps">$stepsHtml</ul></div>
    </div>
"@
}
$findHtml = if ($findings.Count -gt 0) { $findCards -join "`n" } else { "<p class='ok'>Nenhum problema relevante encontrado. Máquina saudável.</p>" }

$diskRows = foreach ($d in $snap.disks) {
    "<tr><td>$($d.drive)</td><td class='num'>$(Fmt $d.totalGB) GB</td><td class='num'>$(Fmt $d.freeGB) GB</td><td class='num'>$($d.freePercent)%</td></tr>"
}
$gpuText = ($snap.gpu -join ", ")
$topText = ($snap.topProcesses | ForEach-Object { "$($_.name) ($($_.memMB) MB)" }) -join " · "
$updateText = if ($snap.lastUpdateDays -ne $null) { "$($snap.lastUpdateDays) dias atrás" } else { "não determinado" }
$generatedAt = (Get-Date).ToString("dd/MM/yyyy HH:mm")
$modeLabel = if ($DemoData) { "PC de demonstração (fictício)" } else { "$($snap.computer.hostname)" }

$specRows = @"
      <tr><td>Equipamento</td><td>$($snap.computer.manufacturer) $($snap.computer.model)</td></tr>
      <tr><td>Sistema</td><td>$($snap.os.caption) (build $($snap.os.build))</td></tr>
      <tr><td>Processador</td><td>$($snap.cpu.name) &mdash; $($snap.cpu.cores) núcleos / $($snap.cpu.logical) threads</td></tr>
      <tr><td>Memória RAM</td><td>$(Fmt $snap.memory.totalGB) GB (em uso: $($snap.memory.usedPercent)%)</td></tr>
      <tr><td>Disco do sistema</td><td>$($snap.storage.systemDiskType) &mdash; saúde: $($snap.storage.health)</td></tr>
      <tr><td>Vídeo</td><td>$gpuText</td></tr>
      <tr><td>Ligado há</td><td>$(Fmt $snap.os.uptimeDays 0) dias</td></tr>
      <tr><td>Última atualização</td><td>$updateText</td></tr>
      <tr><td>Programas na inicialização</td><td>$($snap.startupCount)</td></tr>
      <tr><td>Processos que mais consomem</td><td>$topText</td></tr>
"@

# --- Guia de otimizacao (estatico, baseado nas orientacoes da Microsoft) ---
$guideHtml = @"
    <div class="guide">
      <div class="g-card">
        <h3>Rápido (5&ndash;10 min)</h3>
        <ol>
          <li>Reiniciar o computador (Iniciar &gt; Energia &gt; Reiniciar).</li>
          <li>Fechar programas e abas pesados (Ctrl+Shift+Esc &gt; Processos).</li>
          <li>Rodar o Windows Update (Configurações &gt; Windows Update).</li>
          <li>Verificação rápida de vírus (Segurança do Windows &gt; Proteção contra vírus e ameaças).</li>
        </ol>
      </div>
      <div class="g-card">
        <h3>Limpeza de disco</h3>
        <ol>
          <li>Ativar o Sensor de Armazenamento (Configurações &gt; Sistema &gt; Armazenamento) — limpa temporários e Lixeira sozinho.</li>
          <li>Limpeza de Disco: Win+R &gt; <code>cleanmgr</code> &gt; escolher C:.</li>
          <li>Temporários: Win+R &gt; <code>%temp%</code> e <code>C:\Windows\Temp</code> (apagar).</li>
          <li>Esvaziar a Lixeira; desinstalar apps sem uso.</li>
        </ol>
      </div>
      <div class="g-card">
        <h3>Manutenção e ajustes</h3>
        <ol>
          <li>Desabilitar programas na inicialização (Ctrl+Shift+Esc &gt; Inicializar).</li>
          <li>Otimizar unidades: <code>dfrgui</code> (SSD faz TRIM, HDD desfragmenta).</li>
          <li>Integridade do sistema (admin): <code>sfc /scannow</code> e <code>DISM /Online /Cleanup-Image /RestoreHealth</code>.</li>
          <li>Melhor desempenho: Configurações &gt; Sistema &gt; Energia &gt; Melhor desempenho.</li>
          <li>Upgrades de maior impacto: SSD e mais RAM.</li>
        </ol>
      </div>
    </div>
    <p class="src">Guia baseado nas orientações oficiais da Microsoft (support.microsoft.com).</p>
"@

$html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Diagnóstico de PC</title>
<style>
  :root{--bg:#f4f6fb;--card:#fff;--ink:#1a2233;--muted:#5b6678;--line:#e6e9f0;
    --brand:#2f5bea;--red:#e5484d;--amber:#f5a623;--green:#22a06b;--blue:#2f5bea}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font-family:"Segoe UI",system-ui,-apple-system,Arial,sans-serif;line-height:1.5}
  .wrap{max-width:1000px;margin:0 auto;padding:32px 20px 64px}
  h1{font-size:1.5rem;margin:0}
  .sub{color:var(--muted);font-size:.9rem;margin-top:4px}
  h2{font-size:1.1rem;margin:26px 0 10px}
  .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px;margin:20px 0}
  .kpi{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;text-align:center}
  .kpi .value{font-size:1.9rem;font-weight:800}
  .kpi .label{color:var(--muted);font-size:.72rem;text-transform:uppercase;letter-spacing:.03em;margin-top:2px}
  .kpi.green .value{color:var(--green)}.kpi.amber .value{color:var(--amber)}.kpi.red .value{color:var(--red)}
  .score-ring{font-size:2.4rem;font-weight:800}
  section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px;margin:14px 0}
  table{width:100%;border-collapse:collapse;font-size:.92rem}
  td{padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  td:first-child{color:var(--muted);width:210px}
  td.num{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink)}
  .finding{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--line);border-radius:10px;padding:14px 16px;margin:10px 0}
  .finding.sev-Alta{border-left-color:var(--red)}
  .finding.sev-Media{border-left-color:var(--amber)}
  .finding.sev-Baixa{border-left-color:var(--blue)}
  .f-head{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}
  .area{display:inline-block;background:#eef1f8;color:var(--muted);font-size:.7rem;padding:2px 8px;border-radius:6px;margin-right:8px;text-transform:uppercase;letter-spacing:.03em}
  .f-title{font-weight:600}
  .f-detail{margin:8px 0 6px;color:#333}
  .f-rec{color:#333;font-size:.92rem}
  .f-steps{margin:4px 0 0;padding-left:18px}
  .f-steps li{margin:3px 0}
  code{background:#eef1f8;padding:1px 6px;border-radius:4px;font-family:"Consolas",monospace;font-size:.86em;color:#12203f}
  .badge{display:inline-block;padding:3px 12px;border-radius:999px;font-size:.76rem;font-weight:700}
  .b-red{background:#fdecec;color:var(--red)}.b-amber{background:#fdf3e0;color:#b6790f}
  .b-blue{background:#e9eefc;color:var(--brand)}.b-gray{background:#eef1f8;color:var(--muted)}
  .ok{color:var(--green);font-weight:600}
  .guide{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px}
  .g-card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
  .g-card h3{margin:0 0 8px;font-size:1rem;color:var(--brand)}
  .g-card ol{margin:0;padding-left:18px}
  .g-card li{margin:5px 0;font-size:.9rem}
  .src{color:var(--muted);font-size:.78rem;margin-top:10px}
  footer{color:var(--muted);font-size:.8rem;text-align:center;margin-top:26px}
</style>
</head>
<body>
<div class="wrap">
  <h1>Diagnóstico de Saúde &mdash; PC</h1>
  <div class="sub">$modeLabel &middot; gerado em $generatedAt</div>

  <div class="kpis">
    <div class="kpi $scoreClass"><div class="value score-ring">$score</div><div class="label">Nota de saúde ($scoreLabel)</div></div>
    <div class="kpi red"><div class="value">$cAlta</div><div class="label">Prioridade alta</div></div>
    <div class="kpi amber"><div class="value">$cMedia</div><div class="label">Prioridade média</div></div>
    <div class="kpi"><div class="value">$cBaixa</div><div class="label">Prioridade baixa</div></div>
  </div>

  <h2>Achados e como resolver</h2>
$findHtml

  <h2>Guia de otimização passo a passo</h2>
$guideHtml

  <h2>Especificações</h2>
  <section>
    <table>
$specRows
    </table>
  </section>

  <h2>Discos</h2>
  <section>
    <table class="disk">
      <tr><td>Unidade</td><td class="num">Total</td><td class="num">Livre</td><td class="num">% livre</td></tr>
$($diskRows -join "`n")
    </table>
  </section>

  <footer>
    Gerado por <b>Get-PCHealthReport.ps1</b> &middot; Gustavo Paiva
  </footer>
</div>
</body>
</html>
"@

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$html | Set-Content -Path $OutputPath -Encoding UTF8

# ===========================================================================
# 4) Resumo no console (ASCII)
# ===========================================================================
Write-Host ""
Write-Host "============== DIAGNOSTICO ==============" -ForegroundColor Green
Write-Host ("Maquina        : {0}" -f $modeLabel)
Write-Host ("Nota de saude  : {0}/100" -f $score) -ForegroundColor Yellow
Write-Host ("Achados        : {0} (alta {1}, media {2}, baixa {3})" -f $findings.Count, $cAlta, $cMedia, $cBaixa)
Write-Host "========================================" -ForegroundColor Green
Write-Host ("Relatorio salvo em: {0}" -f $OutputPath) -ForegroundColor Cyan
