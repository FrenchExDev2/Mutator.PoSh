function Get-MutatorUtcNow {
    [datetimeoffset]::UtcNow
}

function Restart-MutatorEditorSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Private recovery action is authorized by the explicit Start-MutatorMemoryWatchdog boundary.')]
    [CmdletBinding()]
    param([Collections.IDictionary]$Previous,[string]$DesktopRuntimeRoot='C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App')
    # VS Code may itself recover the language server after its process disappears.
    $find={Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop | Where-Object {
        $_.ProcessId -ne $Previous.Id -and $_.ParentProcessId -eq $Previous.ParentId -and $_.CommandLine -like '*PowerShellEditorServices*' -and $_.CommandLine -like '*Start-EditorServices*'
    }|Sort-Object CreationDate -Descending|Select-Object -First 1}
    $deadline=(Get-MutatorUtcNow).AddSeconds(8)
    do{$replacement=& $find;if($replacement){return @{Id=[int]$replacement.ProcessId;Mode='VSCodeAutomatic'}};Start-Sleep -Milliseconds 500}while((Get-MutatorUtcNow) -lt $deadline)
    $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Previous.ParentId) -ErrorAction Stop
    if(!$parent -or $parent.Name -notmatch '^Code(?: - Insiders)?\.exe$'){throw 'The original VS Code parent is absent; editor restart is refused.'}
    $code=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($parent.Name)) -ErrorAction Stop|Where-Object {$_.MainWindowHandle -ne 0})
    if($code.Count -ne 1){throw 'Exactly one VS Code window is required for unattended session restart.'}
    $desktop=Get-ChildItem -LiteralPath $DesktopRuntimeRoot -Directory -ErrorAction Stop|Where-Object Name -Like '10.*'|Sort-Object Name -Descending|Select-Object -First 1
    if(!$desktop){throw 'The Windows Desktop Runtime 10 is required for a verified editor restart.'}
    foreach($assembly in @('WindowsBase.dll','UIAutomationTypes.dll','UIAutomationClient.dll','System.Windows.Forms.dll')){[void][Reflection.Assembly]::LoadFrom((Join-Path $desktop.FullName $assembly))}
    if(!('Mutator.EditorWindow' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Mutator { public static class EditorWindow {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
}}
'@
    }
    $handle=$code[0].MainWindowHandle
    [void][Mutator.EditorWindow]::ShowWindow($handle,9)
    [void][Mutator.EditorWindow]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 200
    if([Mutator.EditorWindow]::GetForegroundWindow() -ne $handle){throw 'VS Code could not be focused; no restart keystroke was sent.'}
    [Windows.Forms.SendKeys]::SendWait('^+p')
    $window=[Windows.Automation.AutomationElement]::FromHandle($handle)
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Type the name of a command to run.')
    $deadline=(Get-MutatorUtcNow).AddSeconds(10)
    do{$edit=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition);if($edit){break};Start-Sleep -Milliseconds 200}while((Get-MutatorUtcNow) -lt $deadline)
    if(!$edit){throw 'The verified VS Code command palette input was not found.'}
    $value=$edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $command='>PowerShell: Restart Session';$value.SetValue($command)
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'PowerShell: Restart Session')
    $deadline=(Get-MutatorUtcNow).AddSeconds(10)
    do{$item=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition);if($item){break};Start-Sleep -Milliseconds 200}while((Get-MutatorUtcNow) -lt $deadline)
    if(!$item -or $item.Current.ControlType -ne [Windows.Automation.ControlType]::ListItem -or $value.Current.Value -cne $command -or [Mutator.EditorWindow]::GetForegroundWindow() -ne $handle){throw 'The exact PowerShell restart command could not be verified.'}
    $pattern=$null
    if($item.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
    else{$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();[Windows.Forms.SendKeys]::SendWait('{ENTER}')}
    $deadline=(Get-MutatorUtcNow).AddSeconds(45)
    do{$replacement=& $find;if($replacement){return @{Id=[int]$replacement.ProcessId;Mode='VerifiedVSCodeCommand'}};Start-Sleep -Seconds 1}while((Get-MutatorUtcNow) -lt $deadline)
    throw 'VS Code restart was requested but no replacement Editor Services process appeared.'
}
