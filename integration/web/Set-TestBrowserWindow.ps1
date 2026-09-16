[CmdletBinding()]
param([Parameter(Mandatory)][int]$BrowserProcessId,[ValidateSet('Minimize','Restore')][string]$State)
$ErrorActionPreference='Stop'
$process=Get-Process -Id $BrowserProcessId
if($process.ProcessName -notin @('chrome','firefox')){throw 'Only the test-owned browser process is supported.'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TestBrowserWindow {
    public delegate bool Callback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    public static int Change(uint process, int command) {
        int count=0;
        EnumWindows((window,data)=>{uint owner;GetWindowThreadProcessId(window,out owner);
            if(owner==process && IsWindowVisible(window)){ShowWindow(window,command);if(IsIconic(window)!=(command==6))throw new Exception("Window state did not change");count++;}return true;},IntPtr.Zero);
        return count;
    }
}
'@
$owned=[Collections.Generic.HashSet[int]]::new();$null=$owned.Add($BrowserProcessId)
$snapshot=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -in @('chrome.exe','firefox.exe') -and $_.CreationDate -ge $process.StartTime.AddSeconds(-1)})
do{$added=$false;foreach($candidate in $snapshot){if($owned.Contains([int]$candidate.ParentProcessId) -and $owned.Add([int]$candidate.ProcessId)){$added=$true}}}while($added)
$count=0
foreach($ownedId in $owned){$count+=[TestBrowserWindow]::Change($ownedId,$(if($State -eq 'Minimize'){6}else{9}))}
if($count -eq 0){throw 'No visible window belonging to the test browser process was found.'}
Write-Output "Changed $count windows belonging to test browser $BrowserProcessId."
