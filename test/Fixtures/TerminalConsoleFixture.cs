using System;
using System.Collections.Generic;
namespace Mutator {
 public static class ConsoleFixture {
  public static bool IsInputRedirected, IsOutputRedirected, TreatControlCAsInput;
  public static readonly Queue<ConsoleKeyInfo> Keys = new Queue<ConsoleKeyInfo>();
  public static readonly List<string> Writes = new List<string>();
  public static bool KeyAvailable { get { return Keys.Count>0; } }
  public static ConsoleKeyInfo ReadKey(bool intercept) { return Keys.Dequeue(); }
  public static void Write(string text) { Writes.Add(text); }
  public static void Reset() { IsInputRedirected=false; IsOutputRedirected=false; TreatControlCAsInput=false; Keys.Clear(); Writes.Clear(); }
 }
}
