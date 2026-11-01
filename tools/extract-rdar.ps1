# Extracts files from Cyberpunk 2077 .archive (RDAR) files using the game's own Oodle DLL.
# Read only: it never writes to the game folder.
# Usage:
#   powershell -ExecutionPolicy Bypass -File extract-rdar.ps1 -Archive <path> -Out <dir> [-Paths a,b,c] [-All]
param(
  [Parameter(Mandatory=$true)][string]$Archive,
  [Parameter(Mandatory=$true)][string]$Out,
  [string[]]$Paths = @(),
  [switch]$All,
  [string]$HashFile = "",
  [string]$Oodle = "C:\Program Files\Epic Games\Cyberpunk2077\bin\x64\oo2ext_7_win64.dll"
)
$ErrorActionPreference = "Stop"
$src = @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Rdar {
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
  delegate int DecompFn(byte[] src, long srcLen, byte[] dst, long dstLen, int fuzz, int crc, int verbose,
    IntPtr dstBase, long e, IntPtr cb, IntPtr cbCtx, IntPtr scratch, long scratchSize, int threadPhase);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibrary(string p);
  [DllImport("kernel32", CharSet=CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string n);
  static DecompFn decomp;
  public static void Init(string dll) {
    IntPtr h = LoadLibrary(dll); if (h == IntPtr.Zero) throw new Exception("LoadLibrary failed: " + dll);
    IntPtr f = GetProcAddress(h, "OodleLZ_Decompress"); if (f == IntPtr.Zero) throw new Exception("no OodleLZ_Decompress");
    decomp = (DecompFn)Marshal.GetDelegateForFunctionPointer(f, typeof(DecompFn));
  }
  public static ulong Fnv(string s) {
    ulong h = 0xcbf29ce484222325UL;
    foreach (byte b in System.Text.Encoding.UTF8.GetBytes(s)) { h ^= b; h *= 0x100000001b3UL; }
    return h;
  }
  static byte[] Seg(FileStream fs, ulong off, uint zs, uint size) {
    fs.Seek((long)off, SeekOrigin.Begin);
    byte[] z = new byte[zs]; fs.Read(z, 0, (int)zs);
    if (zs == size) return z;
    if (z[0]==(byte)'K' && z[1]==(byte)'A' && z[2]==(byte)'R' && z[3]==(byte)'K') {
      uint real = BitConverter.ToUInt32(z, 4);
      byte[] body = new byte[zs - 8]; Array.Copy(z, 8, body, 0, body.Length);
      byte[] o = new byte[real];
      int n = decomp(body, body.Length, o, real, 1, 0, 0, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, 3);
      if (n != real) throw new Exception("decompress failed " + n + " vs " + real);
      return o;
    }
    byte[] o2 = new byte[size];
    int n2 = decomp(z, z.Length, o2, size, 1, 0, 0, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, 3);
    if (n2 != size) throw new Exception("decompress (no header) failed " + n2);
    return o2;
  }
  public static int Extract(string archive, string outDir, string[] paths, bool all, string[] hashes) {
    var want = new Dictionary<ulong,string>();
    foreach (var hx in hashes) { string t = hx.Trim(); if (t.Length == 0) continue; want[Convert.ToUInt64(t, 16)] = t.ToLowerInvariant() + ".bin"; }
    foreach (var p in paths) { string q = p.ToLowerInvariant().Replace('/', '\\'); want[Fnv(q)] = q; }
    int count = 0;
    using (var fs = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
      var br = new BinaryReader(fs);
      if (new string(br.ReadChars(4)) != "RDAR") throw new Exception("not RDAR");
      br.ReadUInt32(); ulong ipos = br.ReadUInt64(); uint isz = br.ReadUInt32();
      fs.Seek((long)ipos, SeekOrigin.Begin);
      br.ReadUInt32(); br.ReadUInt32(); br.ReadUInt64();
      uint nf = br.ReadUInt32(), ns = br.ReadUInt32(), nd = br.ReadUInt32();
      var fh = new ulong[nf]; var ss = new uint[nf]; var se = new uint[nf];
      for (int i = 0; i < nf; i++) { fh[i]=br.ReadUInt64(); br.ReadUInt64(); br.ReadUInt32(); ss[i]=br.ReadUInt32(); se[i]=br.ReadUInt32(); br.ReadUInt32(); br.ReadUInt32(); br.ReadBytes(20); }
      var so = new ulong[ns]; var sz = new uint[ns]; var su = new uint[ns];
      for (int i = 0; i < ns; i++) { so[i]=br.ReadUInt64(); sz[i]=br.ReadUInt32(); su[i]=br.ReadUInt32(); }
      Console.WriteLine("archive " + archive + ": " + nf + " files, " + ns + " segments");
      for (int i = 0; i < nf; i++) {
        string name;
        if (want.ContainsKey(fh[i])) name = want[fh[i]].Replace('\\','_');
        else if (all) name = fh[i].ToString("x16") + ".bin";
        else continue;
        for (uint s = ss[i]; s < se[i]; s++) {
          byte[] d = Seg(fs, so[s], sz[s], su[s]);
          string fn = Path.Combine(outDir, s == ss[i] ? name : name + ".buffer" + (s - ss[i]));
          File.WriteAllBytes(fn, d);
        }
        Console.WriteLine("extracted " + name + " (" + (se[i]-ss[i]) + " segments)");
        count++;
      }
    }
    return count;
  }
}
"@
Add-Type -TypeDefinition $src -Language CSharp
[Rdar]::Init($Oodle)
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$hashes = @()
if ($HashFile -ne "") { $hashes = @(Get-Content $HashFile) }
$n = [Rdar]::Extract($Archive, $Out, $Paths, $All.IsPresent, [string[]]$hashes)
Write-Host "done: $n files from $Archive"
