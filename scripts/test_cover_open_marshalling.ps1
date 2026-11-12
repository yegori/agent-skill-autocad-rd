# Actual Open-CoverSnapshot against REQUIRED CLR object args. NO COM server/Word/WindowAPI.
param([string]$DocumentLibrary='', [switch]$VariantAbi)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
if(-not $DocumentLibrary){$DocumentLibrary=Join-Path $root 'toolkit/cover_document.ps1'}
. $DocumentLibrary
Add-Type -TypeDefinition @'
using System;
using System.Collections;
namespace OpenFake {
 public class Doc {}
 public class EnumerableDoc : Doc,IEnumerable {public IEnumerator GetEnumerator(){yield return "FLATTENED_SENTINEL";}}
 public class Documents {
  public object[] Args; public int Calls; public bool Fail; public object Result;
  // Intentionally no OPTIONAL/default metadata: tests the real PowerShell/CLR binder boundary.
  public object Open(object a1,object a2,object a3,object a4,object a5,object a6,object a7,object a8,
                     object a9,object a10,object a11,object a12,object a13,object a14,object a15,object a16){
   Calls++;Args=new object[]{a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16};
   if(Fail)throw new InvalidOperationException("inert_open_failure");return Result;
  }
 }
}
'@
function Assert-Open([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}
$parameters=[OpenFake.Documents].GetMethod('Open').GetParameters()
Assert-Open ($parameters.Count -eq 16 -and @($parameters|Where-Object{$_.IsOptional -or $_.HasDefaultValue}).Count -eq 0) 'fixture default metadata invalid'
$passed=1
$path='X:\generic\папка\шаблон_пример.docx' # Value-only fixture; never opened or created.
foreach($enumerable in @($false,$true)){
 $docs=[OpenFake.Documents]::new()
 $expected=if($enumerable){,[OpenFake.EnumerableDoc]::new()}else{,[OpenFake.Doc]::new()}
 $docs.Result=$expected
 try{$actual=Open-CoverSnapshot $docs $path}
 catch{Write-Output "INERT required-signature body calls=$($docs.Calls); no inference about actual Word dispatch";throw}
 Assert-Open ([object]::ReferenceEquals($actual,$expected) -and $docs.Calls -eq 1) 'returned document flattened or call repeated'
 $a=$docs.Args
 Assert-Open ($a.Length -eq 16 -and $a[0] -ceq $path) 'path/order changed'
 foreach($index in @(1,3,6,11,12)){Assert-Open ($a[$index] -is [bool] -and $a[$index] -eq $false) "false security option changed at $index"}
 foreach($index in @(2,14)){Assert-Open ($a[$index] -is [bool] -and $a[$index] -eq $true) "readonly/noEncodingDialog changed at $index"}
 foreach($index in @(4,5,7,8)){Assert-Open ($a[$index] -ceq 'not-a-supplied-password') "password sentinel changed at $index"}
 Assert-Open ($a[9] -is [int] -and $a[9] -eq 0) 'existing auto format argument changed'
 foreach($index in @(10,13,15)){
  Assert-Open ($a[$index] -is [Runtime.InteropServices.ErrorWrapper] -and $a[$index].ErrorCode -eq -2147352572) "optional slot $index is not DISP_E_PARAMNOTFOUND"
 }
 Assert-Open (@($a|Where-Object{$_ -is [Runtime.InteropServices.ErrorWrapper]}).Count -eq 3) 'extra missing slots'
 $passed++
}
$docs=[OpenFake.Documents]::new();$docs.Fail=$true;$docs.Result=[OpenFake.Doc]::new();$actual=$null;$caught=$null
try{$actual=Open-CoverSnapshot $docs $path}catch{$caught=$_}
Assert-Open ($null -ne $caught -and $caught.ToString() -match 'inert_open_failure' -and $null -eq $actual -and $docs.Calls -eq 1) 'Open failure reported success/retried'
$passed++
Write-Output "PASS actual Open helper: $passed inert groups; required16 args, exact optional slots, scalar returns/error; no COM server"
if($VariantAbi){
 if(-not $IsWindows){throw 'variant_memory_check_requires_windows'}
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OpenVariantMemory {
 [DllImport("oleaut32.dll",ExactSpelling=true)] public static extern int VariantClear(IntPtr variant);
}
'@
 # Args were supplied by the ACTUAL helper, even on the inert throwing Open call above.
 foreach($index in @(10,13,15)){
  $memory=[Runtime.InteropServices.Marshal]::AllocHGlobal(24)
  try{
   for($i=0;$i -lt 24;$i++){[Runtime.InteropServices.Marshal]::WriteByte($memory,$i,0)}
   [Runtime.InteropServices.Marshal]::GetNativeVariantForObject($docs.Args[$index],$memory)
   $vt=[Runtime.InteropServices.Marshal]::ReadInt16($memory,0)
   $code=[Runtime.InteropServices.Marshal]::ReadInt32($memory,8)
   Assert-Open ($vt -eq 10 -and $code -eq -2147352572) 'VARIANT is not VT_ERROR/DISP_E_PARAMNOTFOUND'
   Write-Output "PASS memory ABI slot $($index+1): VT_ERROR=$vt DISP_E_PARAMNOTFOUND=$code; no COM server"
  }finally{
   try{Assert-Open ([OpenVariantMemory]::VariantClear($memory) -eq 0) 'VariantClear failed'}
   finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($memory)}
  }
 }
}
