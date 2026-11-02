<#
.SYNOPSIS
    Native CUIAutomation probe for one private-desktop Settings control.
.DESCRIPTION
    The caller owns the fixture and checks pending/save behavior. No input,
    clipboard access or process launching occurs here. Exercise is opt-in.
    CompileOnly compiles the interop without contacting UIA or any window.
#>
[CmdletBinding()]
param(
    [long] $Hwnd,
    [string] $Desktop,
    [string] $OutputPath,
    [ValidateSet('CheckBox', 'ComboBox')][string] $Kind,
    [string] $ExpectedName,
    [switch] $Exercise,
    [switch] $UseSelectionItem,
    [switch] $CompileOnly
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'settings-uia-patterns.ps1'
try {

$ErrorActionPreference = 'Stop'
if (-not ('SettingsPatterns.Probe' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SettingsPatterns
{
    // Partial interfaces: placeholders MUST NOT be called. Verified against
    // Windows SDK 10.0.26100.0/um/UIAutomationClient.h; slots include IUnknown.
    [ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAutomation
    {
        void CompareElements();                  // 3
        void CompareRuntimeIds();                // 4
        void GetRootElement();                   // 5
        void ElementFromHandle(IntPtr hwnd, out IElement element); // 6
        void ElementFromPoint();                 // 7
        void GetFocusedElement();                // 8
        void GetRootElementBuildCache();          // 9
        void ElementFromHandleBuildCache();       // 10
        void ElementFromPointBuildCache();        // 11
        void GetFocusedElementBuildCache();       // 12
        void CreateTreeWalker();                 // 13
        void GetControlViewWalker();             // 14
        void GetContentViewWalker();             // 15
        void GetRawViewWalker(out IWalker walker); // 16
    }

    [ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IElement
    {
        void SetFocus();                         // 3 (unused)
        void GetRuntimeId();                     // 4
        void FindFirst();                        // 5
        void FindAll();                          // 6
        void FindFirstBuildCache();              // 7
        void FindAllBuildCache();                // 8
        void BuildUpdatedCache();                // 9
        void GetCurrentPropertyValue(int id, [MarshalAs(UnmanagedType.Struct)] out object value); // 10
        void GetCurrentPropertyValueEx();        // 11
        void GetCachedPropertyValue();           // 12
        void GetCachedPropertyValueEx();         // 13
        void GetCurrentPatternAs();              // 14
        void GetCachedPatternAs();               // 15
        [PreserveSig]
        int GetCurrentPattern(int id, [MarshalAs(UnmanagedType.IUnknown)] out object pattern); // 16
    }

    [ComImport, Guid("4042c624-389c-4afc-a630-9df854a541fc")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWalker
    {
        void GetParentElement(IElement element, out IElement parent); // 3
        void GetFirstChildElement(IElement element, out IElement child); // 4
        void GetLastChildElement(IElement element, out IElement child); // 5
        void GetNextSiblingElement(IElement element, out IElement sibling); // 6
    }

    [ComImport, Guid("94cf8058-9b8d-4ab9-8bfd-4cd0a33c8c70")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IToggle
    {
        void Toggle();                           // 3
        void GetCurrentToggleState(out int state); // 4
    }

    [ComImport, Guid("619be086-1f4e-4ee4-bafa-210128738730")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IExpandCollapse
    {
        [PreserveSig] int Expand();               // 3
        void Collapse();                         // 4
        [PreserveSig] int GetCurrentExpandCollapseState(out int state); // 5
    }

    [ComImport, Guid("a94cd8b1-0844-4cd6-9d2d-640537ab39e9")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IValue
    {
        void SetValue([MarshalAs(UnmanagedType.BStr)] string value); // 3
        void GetCurrentValue([MarshalAs(UnmanagedType.BStr)] out string value); // 4
        void GetCurrentIsReadOnly(out int readOnly); // 5
    }

    [ComImport, Guid("a8efa66a-0fda-421a-9194-38021f3578ea")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISelectionItem
    {
        void Select();                           // 3
        void AddToSelection();                   // 4 (unused)
        void RemoveFromSelection();              // 5 (unused)
        void GetCurrentIsSelected(out int selected); // 6
    }

    [ComImport, Guid("5ed5202e-b2ac-47a6-b638-4b0bf140d78e")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISelection
    {
        void GetCurrentSelection(out IElementArray selection); // 3
    }

    [ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IElementArray
    {
        void GetLength(out int length);           // 3
        void GetElement(int index, out IElement element); // 4
    }

    public static class Probe
    {
        const int ElementNotEnabled = unchecked((int)0x80040200);
        [StructLayout(LayoutKind.Sequential)]
        struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct ComboInfo
        {
            public uint Size;
            public Rect Item, Button;
            public uint State;
            public IntPtr Combo, Edit, List;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct GuiThreadInfo
        {
            public uint Size, Flags;
            public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
            public Rect CaretRect;
        }
        [DllImport("user32.dll")]
        static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
        [DllImport("user32.dll")]
        static extern bool GetComboBoxInfo(IntPtr hwnd, ref ComboInfo info);
        [DllImport("user32.dll")]
        static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")]
        static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")]
        static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")]
        static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
        [DllImport("user32.dll")]
        static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")]
        static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")]
        static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")]
        static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool GetUserObjectInformationW(IntPtr handle, int index,
            StringBuilder name, uint bytes, out uint needed);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr ReadComboMessage(IntPtr hwnd, uint message, IntPtr w, IntPtr l,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr ReadComboText(IntPtr hwnd, uint message, IntPtr w, StringBuilder text,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr ReadItemRect(IntPtr hwnd, uint message, IntPtr w, ref Rect rect,
            uint flags, uint timeout, out IntPtr result);

        static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
        }
        static object Property(IElement element, int id)
        {
            object value;
            element.GetCurrentPropertyValue(id, out value);
            return value;
        }
        static object Pattern(IElement element, int id, string name, Dictionary<string, object> result)
        {
            object value;
            int hr = element.GetCurrentPattern(id, out value);
            result[name] = hr >= 0 && value != null;
            result[name + "Hresult"] = String.Format("0x{0:X8}", hr);
            if (hr < 0) { Release(value); return null; }
            return value;
        }
        static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
        // Keep observations separate from assertions: a failed expansion must
        // retain its HRESULT and native popup state before Collapse cleans up.
        static Dictionary<string, object> ExpansionSnapshot(IntPtr hwnd, IExpandCollapse expand)
        {
            var snapshot = new Dictionary<string, object>();
            snapshot["utc"] = DateTimeOffset.UtcNow.ToString("o");
            snapshot["tick_ms"] = Environment.TickCount64;
            uint pid;
            uint thread = GetWindowThreadProcessId(hwnd, out pid);
            var gui = new GuiThreadInfo();
            gui.Size = (uint)Marshal.SizeOf(typeof(GuiThreadInfo));
            if (thread != 0 && GetGUIThreadInfo(thread, ref gui))
            {
                snapshot["activeHwnd"] = gui.Active.ToInt64();
                snapshot["focusHwnd"] = gui.Focus.ToInt64();
                snapshot["captureHwnd"] = gui.Capture.ToInt64();
                snapshot["guiFlags"] = gui.Flags;
            }
            int state;
            int hr = expand.GetCurrentExpandCollapseState(out state);
            snapshot["stateHresult"] = String.Format("0x{0:X8}", hr);
            if (hr >= 0) snapshot["state"] = state;
            IntPtr dropped;
            bool replied = ReadComboMessage(hwnd, 0x0157, IntPtr.Zero, IntPtr.Zero, 2, 2000, out dropped) != IntPtr.Zero;
            snapshot["droppedStateReplied"] = replied;
            snapshot["droppedState"] = replied ? (object)dropped.ToInt64() : null;
            var info = new ComboInfo();
            info.Size = (uint)Marshal.SizeOf(typeof(ComboInfo));
            bool hasInfo = GetComboBoxInfo(hwnd, ref info);
            snapshot["comboInfoAvailable"] = hasInfo;
            snapshot["listHwnd"] = hasInfo ? info.List.ToInt64() : 0;
            snapshot["listExists"] = hasInfo && IsWindow(info.List);
            snapshot["listVisible"] = hasInfo && IsWindowVisible(info.List);
            if (hasInfo && info.List != IntPtr.Zero)
            {
                uint listPid;
                snapshot["listThreadId"] = GetWindowThreadProcessId(info.List, out listPid);
                snapshot["listProcessId"] = listPid;
            }
            Rect rect;
            if (hasInfo && GetWindowRect(info.List, out rect))
                snapshot["listRect"] = new int[] { rect.Left, rect.Top, rect.Right, rect.Bottom };
            return snapshot;
        }
        static Dictionary<string, object> ExpandObserved(IntPtr hwnd, IExpandCollapse expand,
            List<object> attempts)
        {
            var receipt = new Dictionary<string, object>();
            attempts.Add(receipt);
            receipt["before"] = ExpansionSnapshot(hwnd, expand);
            var timer = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                int hr = expand.Expand();
                receipt["hresult"] = String.Format("0x{0:X8}", hr);
                if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            }
            catch (COMException error)
            {
                receipt["hresult"] = String.Format("0x{0:X8}", error.HResult);
                throw;
            }
            finally
            {
                receipt["returnTimestamp"] = System.Diagnostics.Stopwatch.GetTimestamp();
                receipt["returnTickMs"] = Environment.TickCount64;
                receipt["elapsedMilliseconds"] = timer.Elapsed.TotalMilliseconds;
                receipt["returned"] = ExpansionSnapshot(hwnd, expand);
            }
            return receipt;
        }
        static string ReadCombo(object value, object selection)
        {
            if (value != null)
            {
                string text;
                ((IValue)value).GetCurrentValue(out text);
                return text;
            }
            IElementArray items = null;
            IElement item = null;
            try
            {
                ((ISelection)selection).GetCurrentSelection(out items);
                int count;
                items.GetLength(out count);
                Require(count == 1, "Expected one selected combo item");
                items.GetElement(0, out item);
                return Convert.ToString(Property(item, 30005));
            }
            finally { Release(item); Release(items); }
        }
        static string OtherNativeLabel(IntPtr hwnd, string current)
        {
            IntPtr count;
            Require(ReadComboMessage(hwnd, 0x146, IntPtr.Zero, IntPtr.Zero, 2, 2000, out count) != IntPtr.Zero,
                "Combo item count unavailable"); // CB_GETCOUNT
            Require(count.ToInt64() > 0 && count.ToInt64() <= 256, "Invalid combo item count");
            for (int index = 0; index < count.ToInt32(); index++)
            {
                IntPtr length, copied;
                Require(ReadComboMessage(hwnd, 0x149, (IntPtr)index, IntPtr.Zero, 2, 2000, out length) != IntPtr.Zero,
                    "Combo item length unavailable"); // CB_GETLBTEXTLEN
                Require(length.ToInt64() >= 0 && length.ToInt64() <= 4096, "Invalid combo label length");
                var text = new StringBuilder(length.ToInt32() + 1);
                Require(ReadComboText(hwnd, 0x148, (IntPtr)index, text, 2, 2000, out copied) != IntPtr.Zero &&
                    copied.ToInt64() >= 0, "Combo item label unavailable"); // CB_GETLBTEXT
                if (text.ToString() != current) return text.ToString();
            }
            throw new InvalidOperationException("No different native combo label");
        }
        static bool SelectOther(IElement element, IWalker walker, int depth, ref int budget,
            IValue writableValue, Dictionary<string, object> result)
        {
            Require(depth <= 8 && --budget >= 0, "Popup traversal bound exceeded");
            object pattern = null;
            int hr = element.GetCurrentPattern(10010, out pattern);
            try
            {
                if (hr >= 0 && pattern != null)
                {
                    int selected;
                    ((ISelectionItem)pattern).GetCurrentIsSelected(out selected);
                    // Default auto-update-channel is normalized to this
                    // build's channel on reload. Exercise an explicit choice.
                    bool defaultChannel = Object.Equals(result["name"], "Auto-update channel") &&
                        Convert.ToString(Property(element, 30005)).StartsWith("Default (");
                    if (selected == 0 && !defaultChannel && Convert.ToBoolean(Property(element, 30010)))
                    {
                        result["selectionItemName"] = Property(element, 30005);
                        result["SelectionItem"] = true;
                        if (writableValue != null)
                        {
                            writableValue.SetValue(Convert.ToString(result["selectionItemName"]));
                            result["operation"] = "Value.SetValue";
                        }
                        else
                        {
                            ((ISelectionItem)pattern).Select();
                            result["operation"] = "SelectionItem.Select";
                        }
                        return true;
                    }
                }
            }
            finally { Release(pattern); }
            IElement child;
            walker.GetFirstChildElement(element, out child);
            while (child != null)
            {
                IElement next = null;
                try
                {
                    if (SelectOther(child, walker, depth + 1, ref budget, writableValue, result)) return true;
                    walker.GetNextSiblingElement(child, out next);
                }
                finally { Release(child); }
                child = next;
            }
            return false;
        }
        static void RunCore(long hwnd, string desktop, string kind, string expected, bool exercise, bool useSelectionItem,
            Dictionary<string, object> result)
        {
            Require(SetThreadDpiAwarenessContext((IntPtr)(-4)) != IntPtr.Zero, "PMv2 DPI context unavailable");
            uint pid, needed;
            uint thread = GetWindowThreadProcessId((IntPtr)hwnd, out pid);
            var actual = new StringBuilder(256);
            Require(thread != 0 && !String.IsNullOrEmpty(desktop) &&
                !desktop.Equals("Default", StringComparison.OrdinalIgnoreCase) &&
                GetUserObjectInformationW(GetThreadDesktop(thread), 2, actual, 512, out needed) &&
                actual.ToString().Equals(desktop, StringComparison.Ordinal),
                "Target is not on the specified private desktop");
            result["privateDesktopVerified"] = true;
            result["processId"] = pid;
            IAutomation automation = null;
            IElement element = null;
            IWalker walker = null;
            object toggle = null, expand = null, value = null, selection = null;
            try
            {
                automation = (IAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(
                    new Guid("ff48dba4-60ef-4201-aa87-54103eef594e")));
                automation.ElementFromHandle((IntPtr)hwnd, out element);
                // Collect observations before contract assertions, including on red baselines.
                result["name"] = Property(element, 30005);
                result["frameworkId"] = Property(element, 30024);
                result["helpText"] = Property(element, 30013);
                result["enabled"] = Property(element, 30010);
                result["offscreen"] = Property(element, 30022);
                result["dataValid"] = Property(element, 30103);
                toggle = Pattern(element, 10015, "Toggle", result);
                expand = Pattern(element, 10005, "ExpandCollapse", result);
                value = Pattern(element, 10002, "Value", result);
                selection = Pattern(element, 10001, "Selection", result);
                Require(String.IsNullOrEmpty(expected) || Object.Equals(result["name"], expected),
                    "Accessible name changed");
                Require(Object.Equals(result["dataValid"], true), "Valid fixture reports invalid data");
                bool enabled = Convert.ToBoolean(result["enabled"]);
                if (kind == "CheckBox")
                {
                    Require(toggle != null, "Missing Toggle pattern");
                    int before;
                    ((IToggle)toggle).GetCurrentToggleState(out before);
                    result["before"] = before;
                    if (exercise)
                    {
                        try
                        {
                            ((IToggle)toggle).Toggle();
                            Require(enabled, "Disabled Toggle unexpectedly succeeded");
                        }
                        catch (COMException error)
                        {
                            result["operationHresult"] = String.Format("0x{0:X8}", error.HResult);
                            if (enabled || error.HResult != ElementNotEnabled) throw;
                            result["disabledRejected"] = true;
                        }
                        Thread.Sleep(100);
                        int after;
                        ((IToggle)toggle).GetCurrentToggleState(out after);
                        result["after"] = after;
                        Require(enabled ? before != after : before == after, "Unexpected Toggle state after operation");
                    }
                }
                else
                {
                    Require(expand != null, "Missing ExpandCollapse pattern");
                    Require(value != null, "Missing Value pattern");
                    IValue writableValue = (IValue)value;
                    int readOnly;
                    writableValue.GetCurrentIsReadOnly(out readOnly);
                    result["valueReadOnly"] = readOnly != 0;
                    Require(readOnly == 0, "Combo Value pattern is read-only");
                    string before = ReadCombo(value, selection);
                    result["before"] = before;
                    if (exercise)
                    {
                        bool expanded = false;
                        var expansions = new List<object>();
                        result["expansions"] = expansions;
                        try
                        {
                            try
                            {
                                ExpandObserved((IntPtr)hwnd, (IExpandCollapse)expand, expansions);
                                expanded = true;
                                Require(enabled, "Disabled Expand unexpectedly succeeded");
                            }
                            catch (COMException error)
                            {
                                result["operationHresult"] = String.Format("0x{0:X8}", error.HResult);
                                if (enabled || error.HResult != ElementNotEnabled) throw;
                                result["disabledRejected"] = true;
                            }
                            if (!enabled && writableValue != null)
                            {
                                try
                                {
                                    writableValue.SetValue(OtherNativeLabel((IntPtr)hwnd, before));
                                    throw new InvalidOperationException("Disabled Value.SetValue unexpectedly succeeded");
                                }
                                catch (COMException error)
                                {
                                    result["disabledValueHresult"] = String.Format("0x{0:X8}", error.HResult);
                                    if (error.HResult != ElementNotEnabled) throw;
                                    result["disabledValueRejected"] = true;
                                }
                            }
                            if (enabled)
                            {
                                var expansion = (Dictionary<string, object>)expansions[0];
                                long returned = (long)expansion["returnTimestamp"];
                                double sinceReturn = (System.Diagnostics.Stopwatch.GetTimestamp() - returned) *
                                    1000.0 / System.Diagnostics.Stopwatch.Frequency;
                                // Observe no earlier than return + 100 ms. Diagnostic work
                                // consumes the wait, but can overrun it; retain the actual offset.
                                if (sinceReturn < 100) Thread.Sleep((int)Math.Ceiling(100 - sinceReturn));
                                double observedAfter = (System.Diagnostics.Stopwatch.GetTimestamp() - returned) *
                                    1000.0 / System.Diagnostics.Stopwatch.Frequency;
                                var snapshot = ExpansionSnapshot((IntPtr)hwnd, (IExpandCollapse)expand);
                                snapshot["millisecondsSinceExpandReturn"] = observedAfter;
                                snapshot["returnedSnapshotOverran100ms"] = sinceReturn > 100;
                                expansion["after100ms"] = snapshot;
                                Require(Object.Equals(snapshot["stateHresult"], "0x00000000"), "Cannot read expanded state");
                                int state = Convert.ToInt32(snapshot["state"]);
                                result["expandedState"] = state;
                                Require(state == 1, "Combo did not expand");
                                Require(Object.Equals(snapshot["droppedStateReplied"], true),
                                    "Native dropped-state read timed out");
                                Require(Convert.ToInt64(snapshot["droppedState"]) != 0 &&
                                    Object.Equals(snapshot["listExists"], true) && Object.Equals(snapshot["listVisible"], true),
                                    "Expanded combo has no visible native popup");
                                var info = new ComboInfo();
                                info.Size = (uint)Marshal.SizeOf(typeof(ComboInfo));
                                Require(GetComboBoxInfo((IntPtr)hwnd, ref info) && info.List != IntPtr.Zero,
                                    "Combo popup unavailable");
                                IntPtr currentIndex, ignored;
                                Require(ReadComboMessage((IntPtr)hwnd, 0x0147, IntPtr.Zero, IntPtr.Zero, 3, 2000, out currentIndex) != IntPtr.Zero,
                                    "Cannot read initial combo selection");
                                int hoverIndex = currentIndex.ToInt32() == 0 ? 1 : 0;
                                ReadComboMessage(info.List, 0x0197, (IntPtr)hoverIndex, IntPtr.Zero, 3, 2000, out ignored); // LB_SETTOPINDEX
                                Rect targetRect = new Rect(), currentRect = new Rect();
                                Require(ReadItemRect(info.List, 0x0198, (IntPtr)hoverIndex, ref targetRect, 3, 2000, out ignored) != IntPtr.Zero && ignored.ToInt64() >= 0,
                                    "Cannot read hover row rectangle"); // LB_GETITEMRECT
                                Require(ReadItemRect(info.List, 0x0198, currentIndex, ref currentRect, 3, 2000, out ignored) != IntPtr.Zero && ignored.ToInt64() >= 0,
                                    "Cannot read current row rectangle");
                                int hoverY = (targetRect.Top + targetRect.Bottom) / 2;
                                Require(targetRect.Bottom > targetRect.Top && hoverY >= 0, "Hover row is not visible");
                                int initialY = (currentRect.Top + currentRect.Bottom) / 2;
                                result["hoverIndex"] = hoverIndex;
                                result["hoverY"] = hoverY;
                                Rect popupClient;
                                Require(GetClientRect(info.List, out popupClient), "Popup client unavailable");
                                result["popupHeight"] = popupClient.Bottom;
                                result["popupWidth"] = popupClient.Right;
                                ReadComboMessage(info.List, 0x0200, IntPtr.Zero, (IntPtr)((initialY << 16) | 11), 3, 2000, out ignored);
                                ReadComboMessage(info.List, 0x0200, IntPtr.Zero, (IntPtr)((hoverY << 16) | 10), 3, 2000, out ignored);
                                result["hoverValue"] = ReadCombo(value, selection);
                                Require(!Object.Equals(before, result["hoverValue"]), "Hover did not change the native provisional selection");
                                IntPtr hoverSave = GetDlgItem(GetAncestor((IntPtr)hwnd, 2), 301);
                                result["hoverSaveBeforeModifier"] = IsWindowEnabled(hoverSave);
                                Require(!Convert.ToBoolean(result["hoverSaveBeforeModifier"]), "Hover dirtied pending config");
                                bool modifierReleased = false;
                                try
                                {
                                    Require(ReadComboMessage((IntPtr)hwnd, 0x0100, (IntPtr)0x11, (IntPtr)1, 3, 2000, out ignored) != IntPtr.Zero,
                                        "Cannot send hover modifier press");
                                    result["hoverSaveEnabled"] = IsWindowEnabled(hoverSave);
                                    Require(!Convert.ToBoolean(result["hoverSaveEnabled"]), "Hover plus modifier dirtied pending config");
                                }
                                finally
                                {
                                    // Pair even a timed-out send: it may have reached the target.
                                    modifierReleased = ReadComboMessage((IntPtr)hwnd, 0x0101, (IntPtr)0x11,
                                        (IntPtr)unchecked((int)0xC0000001), 3, 2000, out ignored) != IntPtr.Zero;
                                    result["hoverModifierReleased"] = modifierReleased;
                                }
                                Require(modifierReleased, "Cannot send hover modifier release");
                                ((IExpandCollapse)expand).Collapse();
                                result["cancelValue"] = ReadCombo(value, selection);
                                result["cancelSaveEnabled"] = IsWindowEnabled(hoverSave);
                                Require(!Convert.ToBoolean(result["cancelSaveEnabled"]), "Cancelled hover dirtied pending config");
                                Require(Object.Equals(before, result["cancelValue"]), "Cancel changed the combo value");
                                ExpandObserved((IntPtr)hwnd, (IExpandCollapse)expand, expansions);
                                IElement list = null;
                                try
                                {
                                    automation.ElementFromHandle(info.List, out list);
                                    automation.GetRawViewWalker(out walker);
                                    int budget = 256;
                                    Require(SelectOther(list, walker, 0, ref budget, useSelectionItem ? null : writableValue, result),
                                        "No enabled unselected popup SelectionItem");
                                    Require(Object.Equals(result["operation"], useSelectionItem ? "SelectionItem.Select" : "Value.SetValue"),
                                        "Combo operation used the wrong pattern");
                                    IntPtr save = GetDlgItem(GetAncestor((IntPtr)hwnd, 2), 301);
                                    result["saveEnabledBeforeCollapse"] = save != IntPtr.Zero && IsWindowEnabled(save);
                                    Require(Convert.ToBoolean(result["saveEnabledBeforeCollapse"]),
                                        "Popup operation did not update pending config before Collapse");
                                }
                                finally { Release(list); }
                            }
                        }
                        finally
                        {
                            if (expanded) ((IExpandCollapse)expand).Collapse();
                        }
                        Thread.Sleep(100);
                        string after = ReadCombo(value, selection);
                        result["after"] = after;
                        Require(enabled ? before != after : before == after, "Unexpected combo value after operation");
                    }
                }
                result["nameAfter"] = Property(element, 30005);
                Require(Object.Equals(result["name"], result["nameAfter"]), "Operation changed accessible name");
                Require(Object.Equals(result["helpText"], Property(element, 30013)), "Operation changed help text");
                result["pass"] = true;
            }
            finally
            {
                Release(walker); Release(selection); Release(value); Release(expand);
                Release(toggle); Release(element); Release(automation);
            }
        }
        public static Dictionary<string, object> Run(long hwnd, string desktop, string kind,
            string expected, bool exercise, bool useSelectionItem)
        {
            var result = new Dictionary<string, object>();
            result["pass"] = false;
            result["kind"] = kind;
            result["exercise"] = exercise;
            var thread = new Thread(() =>
            {
                try { RunCore(hwnd, desktop, kind, expected, exercise, useSelectionItem, result); }
                catch (Exception error)
                {
                    // Retain observations; do not serialize arbitrary exception data or stacks.
                    result["error"] = error.Message;
                    result["errorType"] = error.GetType().Name;
                    result["hresult"] = String.Format("0x{0:X8}", error.HResult);
                }
            });
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
            // The launcher bounds and terminates this dedicated process if COM hangs.
            thread.Join();
            return result;
        }
    }
}
"@
}
if ($CompileOnly) { return }
if (-not $Hwnd -or -not $Desktop -or -not $OutputPath -or -not $Kind) {
    throw 'Hwnd, Desktop, OutputPath and Kind are required unless CompileOnly is set.'
}
$result = [SettingsPatterns.Probe]::Run($Hwnd, $Desktop, $Kind, $ExpectedName, $Exercise.IsPresent, $UseSelectionItem.IsPresent)
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
if (-not $result['pass']) { exit 1 }

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
