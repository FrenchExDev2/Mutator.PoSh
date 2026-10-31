using System;
using System.Collections.Generic;
namespace Mutator {
 public static class EditorFixture {
  public static string Fault = "", Value = "";
  public static int Invoked, FocusCalls;
  public static readonly List<string> Keys = new List<string>();
  public static void Reset(string fault) { Fault=fault; Value=""; Invoked=0; FocusCalls=0; Keys.Clear(); }
 }
 public static class EditorWindow {
  public static bool ShowWindow(IntPtr h, int c) { return true; }
  public static bool SetForegroundWindow(IntPtr h) { EditorFixture.FocusCalls++; return true; }
  public static IntPtr GetForegroundWindow() { return new IntPtr(EditorFixture.Fault=="focus" || (EditorFixture.Fault=="lost focus" && EditorFixture.Value!="") ? 202 : 101); }
 }
}
namespace System.Windows.Forms {
 public static class SendKeys { public static void SendWait(string value) { Mutator.EditorFixture.Keys.Add(value); if(value=="{ENTER}") Mutator.EditorFixture.Invoked++; } }
}
namespace System.Windows.Automation {
 public enum TreeScope { Descendants }
 public class ControlType { public static readonly ControlType ListItem=new ControlType(); public static readonly ControlType Edit=new ControlType(); }
 public class PropertyCondition { public string Name; public PropertyCondition(object property, string name) { Name=name; } }
 public class AutomationElement {
  public static readonly object NameProperty=new object();
  public static AutomationElement FromHandle(IntPtr handle) { return new AutomationElement(); }
  public class ElementInformation { public ControlType ControlType { get { return Mutator.EditorFixture.Fault=="wrong type" ? ControlType.Edit : ControlType.ListItem; } } }
  public ElementInformation Current { get { return new ElementInformation(); } }
  public AutomationElement FindFirst(TreeScope scope, PropertyCondition condition) {
   if((condition.Name.StartsWith("Type the") && Mutator.EditorFixture.Fault=="no palette") || (condition.Name.StartsWith("PowerShell:") && Mutator.EditorFixture.Fault=="no command")) return null;
   return new AutomationElement();
  }
  public object GetCurrentPattern(object pattern) { return pattern==ValuePattern.Pattern ? (object)new ValuePattern() : new SelectionItemPattern(); }
  public bool TryGetCurrentPattern(object pattern, out object result) { result=new InvokePattern(); return Mutator.EditorFixture.Fault!="fallback"; }
 }
 public class ValuePattern {
  public static readonly object Pattern=new object();
  public class ValueInformation { public string Value { get { return Mutator.EditorFixture.Fault=="changed value" ? "wrong command" : Mutator.EditorFixture.Value; } } }
  public ValueInformation Current { get { return new ValueInformation(); } }
  public void SetValue(string value) { Mutator.EditorFixture.Value=value; }
 }
 public class InvokePattern { public static readonly object Pattern=new object(); public void Invoke() { Mutator.EditorFixture.Invoked++; } }
 public class SelectionItemPattern { public static readonly object Pattern=new object(); public void Select() {} }
}
