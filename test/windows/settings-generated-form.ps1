<#
.SYNOPSIS
    SETFORM Inspect-equivalent, read-only probe on an explicitly private desktop.
.DESCRIPTION
    Reuses the #455 native CUIAutomation client interfaces and pattern probe.
    CompileOnly compiles interop only: no COM activation, HWND access or launches.
    No focus, input, clipboard, pattern mutations or editor invocation occurs.
#>
[CmdletBinding()]
param(
    [long] $Hwnd,
    [string] $Desktop,
    [string] $OutputPath,
    [ValidateSet('Edit', 'CheckBox', 'ComboBox', 'Button', 'Text')][string] $Kind,
    [string] $ExpectedName,
    [switch] $CompileOnly
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'settings-generated-form.ps1'
try {

$ErrorActionPreference = 'Stop'

if (-not ('SettingsPatterns.FormProbe' -as [type])) {
    # Compile the existing interfaces in the SAME assembly as this extension;
    # they are intentionally internal, and must not be copied or made public.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'settings-uia-patterns.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The #455 UIA client does not parse.' }
    $sources = @($ast.FindAll({ param($node)
        ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
            $node -is [Management.Automation.Language.StringConstantExpressionAst]) -and
        $node.Value.Contains('namespace SettingsPatterns')
    }, $true))
    if ($sources.Count -ne 1) { throw 'Expected exactly one #455 CUIAutomation interop source.' }
    if ('SettingsPatterns.Probe' -as [type]) {
        throw 'Compile SETFORM before the #455 client in a fresh PowerShell process.'
    }
    $extension = @'
namespace SettingsPatterns
{
    public static class FormProbe
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
        static void Require(bool condition, string message)
        { if (!condition) throw new System.InvalidOperationException(message); }
        static void Release(object value)
        { if (value != null && System.Runtime.InteropServices.Marshal.IsComObject(value))
            System.Runtime.InteropServices.Marshal.ReleaseComObject(value); }
        static object Property(IElement element, int id)
        { object value; element.GetCurrentPropertyValue(id, out value); return value; }
        public static System.Collections.Generic.Dictionary<string, object> Run(long hwnd, string kind, string name)
        {
            var result = new System.Collections.Generic.Dictionary<string, object>();
            result["pass"] = false;
            var thread = new System.Threading.Thread(() => {
                IAutomation automation = null; IElement element = null;
                object value = null, invoke = null;
                try {
                    Require(SetThreadDpiAwarenessContext((System.IntPtr)(-4)) != System.IntPtr.Zero,
                        "PMv2 DPI awareness unavailable");
                    automation = (IAutomation)System.Activator.CreateInstance(System.Type.GetTypeFromCLSID(
                        new System.Guid("ff48dba4-60ef-4201-aa87-54103eef594e")));
                    automation.ElementFromHandle((System.IntPtr)hwnd, out element);
                    result["name"] = Property(element, 30005);
                    result["helpText"] = Property(element, 30013);
                    result["enabled"] = Property(element, 30010);
                    result["offscreen"] = Property(element, 30022);
                    result["controlType"] = Property(element, 30003);
                    Require(string.IsNullOrEmpty(name) || object.Equals(result["name"], name), "Accessible name changed");
                    int type = kind == "Edit" ? 50004 : kind == "Button" ? 50000 :
                        kind == "CheckBox" ? 50002 : kind == "ComboBox" ? 50003 : 50020;
                    Require(System.Convert.ToInt32(result["controlType"]) == type, "UIA ControlType changed");
                    int hr = element.GetCurrentPattern(10002, out value);
                    result["Value"] = hr >= 0 && value != null;
                    if (kind == "Edit") {
                        Require(hr >= 0 && value != null, "Edit is missing Value pattern");
                        int readOnly; ((IValue)value).GetCurrentIsReadOnly(out readOnly);
                        result["valueReadOnly"] = readOnly != 0;
                        Require(readOnly == 0, "Editable projection reports read-only Value");
                        Require(object.Equals(Property(element, 30103), true), "Valid edit reports invalid data");
                    } else if (kind == "Text") {
                        // Read-only prose is Text, not a writable edit disguised as help.
                        if (hr >= 0 && value != null) {
                            int readOnly; ((IValue)value).GetCurrentIsReadOnly(out readOnly);
                            Require(readOnly != 0, "Help/diagnostics exposes writable Value");
                        }
                        Require(!System.Convert.ToBoolean(Property(element, 30009)), "Read-only prose is keyboard focusable");
                    } else if (kind == "Button") {
                        hr = element.GetCurrentPattern(10000, out invoke);
                        Require(hr >= 0 && invoke != null, "Editor escape hatch lost Invoke");
                        result["Invoke"] = true;
                    }
                    result["pass"] = true;
                } catch (System.Exception error) {
                    result["error"] = error.Message;
                    result["hresult"] = string.Format("0x{0:X8}", error.HResult);
                } finally { Release(invoke); Release(value); Release(element); Release(automation); }
            });
            thread.IsBackground = true;
            thread.SetApartmentState(System.Threading.ApartmentState.MTA);
            thread.Start(); thread.Join(); // Owned client process is bounded by the runner.
            return result;
        }
    }
}
'@
    Add-Type -TypeDefinition ($sources[0].Value + "`n" + $extension)
}
if ($CompileOnly) { return }
if (-not $Hwnd -or -not $Desktop -or -not $OutputPath -or -not $Kind) {
    throw 'Hwnd, Desktop, OutputPath and Kind are required unless CompileOnly is set.'
}
# Reuse the #455 desktop identity check, even for the new edit/text probes.
& (Join-Path $PSScriptRoot 'settings-uia-patterns-run.ps1') -CompileOnly | Out-Null
[Set91.Native]::AssertDesktop([IntPtr]$Hwnd, $Desktop)
if ($Kind -in 'CheckBox', 'ComboBox') {
    $result = [SettingsPatterns.Probe]::Run($Hwnd, $Desktop, $Kind, $ExpectedName, $false, $false)
    if ($result['pass']) {
        $metadata = [SettingsPatterns.FormProbe]::Run($Hwnd, $Kind, $ExpectedName)
        $result['controlType'] = $metadata['controlType']
        if (-not $metadata['pass']) {
            $result['pass'] = $false
            $result['error'] = $metadata['error']
        }
    }
} else {
    $result = [SettingsPatterns.FormProbe]::Run($Hwnd, $Kind, $ExpectedName)
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
if (-not $result['pass']) { exit 1 }

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
