# =====================================================================
#  IR CAMERA VIEWER PRO
#  Author : Julian  <dohoanghuan@gmail.com>
#  License: MIT  (c) 2026 Julian  -  see LICENSE
#  Repo   : https://github.com/aphongdo/windows-ir-camera-viewer
#  A single-file PowerShell + WinForms tool to view a laptop's built-in
#  infrared (Windows Hello) camera, plus live ambient-light (lux) and
#  microphone level/direction meters. Built & tuned on a Lenovo ThinkBook
#  16 G7+ AKP (AMD Ryzen AI 7 H 350). See README.md for the full write-up.
# =====================================================================
#  WHAT IT IS
#    A single-file PowerShell + WinForms app that views the laptop's
#    built-in INFRARED (Windows Hello) camera and, optionally, shows two
#    live sensors on a top bar: ambient LIGHT (lux) and a SOUND meter with
#    a radar-style LEFT/RIGHT direction gauge. Bottom bar = image controls.
#    Snapshots (PNG) and recordings (MP4) are written to the Desktop.
#
#  HOW TO RUN
#    Launch via IR-Camera-Viewer.cmd (runs: powershell -STA -File this.ps1).
#    MUST be Windows PowerShell 5.1, single-threaded apartment (-STA) for
#    WinForms. Camera + mic privacy must allow desktop apps.
#
#  TARGET HARDWARE (the machine this was built on - AMD Lenovo laptop)
#    - "Integrated IR Camera": Chicony VID_04F2&PID_B829&MI_02, driver
#      "Realtek DMFT - IR". ONLY one mode: 640x360 @30fps, subtype L8
#      (8-bit grayscale). This is the hardware ceiling - cannot be raised.
#    - Ambient Light Sensor via AMD Sensor Fusion Hub (WinRT LightSensor).
#    - "Microphone Array (Realtek)": 2 channels, 48 kHz. (There is no
#      proximity / human-presence / ToF sensor on this machine.)
#
#  KEY TECHNIQUES
#    1. IR CAMERA = MEDIA FOUNDATION ONLY. The IR sensor is exposed only
#       through MF (WinRT MediaFrameReader, SourceKind=Infrared). It shows
#       as "(none)" to DirectShow, so OBS / VLC / ffmpeg-dshow CANNOT see it
#       (black screen, no formats). That is by design, not a bug.
#    2. DE-FLICKER. The IR illuminator strobes on alternate frames (active
#       illumination for Windows Hello) -> raw feed flickers bright/dark.
#       IRProc.Mean() + a decaying 'peak' drops the dark frames (script:filter).
#    3. IMAGE PROCESSING (C# IRProc, compiled via Add-Type for speed):
#       Stretch() = per-frame auto-contrast; BuildLut()/ApplyLut() =
#       brightness/contrast/gamma via a 256-entry lookup table.
#    4. RECORDING. Processed BGRA frames are piped to ffmpeg's stdin
#       (rawvideo -> libx264 mp4). ffmpeg found via PATH or the winget
#       "Links" folder (installed with: winget install Gyan.FFmpeg).
#    5. MICROPHONE (CA4.Mic, WASAPI via raw COM interop):
#       - Targets the "Microphone Array" endpoint BY FRIENDLY NAME. The
#         default capture endpoint is often the empty 3.5mm jack -> silence.
#       - Opens in RAW mode (IAudioClient2::SetClientProperties,
#         AUDCLNT_STREAMOPTIONS_RAW) to BYPASS Realtek noise-suppression/AEC;
#         otherwise ambient noise is gated to exact 0 and L/R become identical.
#       - Background thread computes per-channel RMS (L,R,Mono) and stores raw
#         samples in a ring buffer for TDOA.
#    6. SOUND DIRECTION (this was studied carefully - read before changing):
#       - LEVEL difference is USELESS here: the array has a large fixed L/R
#         gain imbalance and almost no directional level signal. Not used.
#       - Direction = TDOA (cross-correlation lag between the 2 channels,
#         CA4.Mic.BestLag). FIXED calibrated front reference (script:cen), no drift.
#         Physical bearing: sin(theta) = delay_samples * c / (fs * mic_spacing).
#         Calibrated by a 0/90/180 endfire test: front lag ~= 0 (=90 deg); endfire
#         ~= +-6.8 samples (=+-90 deg) -> micDist ~= 4.86 cm. Broadband LEFT ->
#         higher lag, RIGHT -> lower lag. Recenter re-nulls the front reference.
#       - USE BROADBAND SOUND (music, claps, "shh", voice). A PURE TONE does
#         NOT work: its cross-correlation is periodic (aliases at the tone
#         period) and the array's per-frequency phase filtering shifts/flips
#         the offset (7557Hz: L~0/R+3 ; 1000Hz: L+3/R-1 - opposite!). Only
#         broadband averages the phase errors out to the true geometric delay.
#       - Two closely-spaced mics => LEFT/RIGHT axis only (front/back
#         ambiguous), angle is approximate. NOT a full 360-degree radar.
#
#  GOTCHAS / THINGS TO WATCH
#    - HRESULT 0xC00D7167 "We need to reboot": pending reboot after an IR
#      driver change. Restart Windows. Do NOT swap the IR driver to a generic
#      "USB camera" - it breaks the DMFT/Windows Hello.
#    - Keep this file ASCII-only (no accents). PS 5.1 reads a BOM-less .ps1 as
#      ANSI and would mojibake UTF-8 text.
#    - Sensors are opt-in (Light/Sound buttons) and only poll while enabled;
#      turning Sound off releases the mic.
#    - Timers run on the UI thread (no locking needed vs the mic thread except
#      the ring buffer, which is already locked in C#).
#
#  HOW TO CHANGE COMMON THINGS
#    - Direction sign flips? swap to dir=(lag-cen)/scale. Angle scale: change
#      $script:micDist (smaller = extremes hit +-90 sooner). Smoothing: 0.6/0.4.
#    - Broadband delay range: BestLag(2048, MAXLAG,...) - MAXLAG=8 suits
#      broadband; a smaller value (<= period/2) is only needed for pure tones.
#    - Record quality: edit the ffmpeg args in Toggle-Rec (preset/crf/fps).
#    - Frame rate feel: $timer.Interval (frame loop) / $sensorTimer.Interval.
#    - "Recenter direction" (Sensors menu) nulls the front reference to whatever
#      is playing now (treats that direction as 90 deg / front). Default cen=0.
#    - Proper future upgrade for angle: FFT-based GCC-PHAT + a per-frequency
#      phase-offset calibration curve (measure with a tone sweep from center).
#
#  LAYOUT (WinForms dock order matters): add pb(Fill) -> panel(Bottom) ->
#    sensorPanel(Top) -> menu(Top); MenuStrip stays topmost, PictureBox fills.
# =====================================================================

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

Add-Type -TypeDefinition @"
using System;
public static class IRProc {
  public static int Mean(byte[] b){ long s=0; for(int i=0;i<b.Length;i+=4){ s+=b[i]; } int n=b.Length/4; if(n<1)n=1; return (int)(s/n); }
  public static void Stretch(byte[] b){
    int min=255,max=0; for(int i=0;i<b.Length;i+=4){ int v=b[i]; if(v<min)min=v; if(v>max)max=v; }
    int range=max-min; if(range<1)range=1; double s=255.0/range;
    for(int i=0;i<b.Length;i+=4){ int v=(int)((b[i]-min)*s); if(v<0)v=0; if(v>255)v=255; byte g=(byte)v; b[i]=g; b[i+1]=g; b[i+2]=g; b[i+3]=255; }
  }
  public static byte[] BuildLut(int brightness, double contrast, double gamma){
    byte[] lut=new byte[256]; double invg=1.0/gamma;
    for(int i=0;i<256;i++){ double v=(i-128)*contrast + 128 + brightness; if(v<0)v=0; if(v>255)v=255; v=255.0*Math.Pow(v/255.0, invg);
      int r=(int)Math.Round(v); if(r<0)r=0; if(r>255)r=255; lut[i]=(byte)r; } return lut;
  }
  public static void ApplyLut(byte[] b, byte[] lut){ for(int i=0;i<b.Length;i+=4){ byte g=lut[b[i]]; b[i]=g; b[i+1]=g; b[i+2]=g; b[i+3]=255; } }
}
"@

# ---- microphone capture (WASAPI RAW) + ring buffer + TDOA cross-correlation ----
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Threading;
namespace CA4 {
 [StructLayout(LayoutKind.Sequential,Pack=1)] public struct WFX{ public ushort t,ch; public uint sps,abps; public ushort ba,bits,cb; }
 [StructLayout(LayoutKind.Sequential)] public struct PKEY{ public Guid fmtid; public int pid; }
 [StructLayout(LayoutKind.Explicit)] public struct PV{ [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
 [StructLayout(LayoutKind.Sequential)] public struct ACPROPS{ public uint cbSize; public int bIsOffload; public int eCategory; public int Options; }
 [ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class E {}
 [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface IE {
   [PreserveSig] int EnumAudioEndpoints(int d,int mask,out IMMColl c); [PreserveSig] int GetDefaultAudioEndpoint(int d,int r,out IMMDevice dev); [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,out IMMDevice dev); }
 [ComImport,Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface IMMColl { [PreserveSig] int GetCount(out uint n); [PreserveSig] int Item(uint i,out IMMDevice dev); }
 [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface IMMDevice {
   [PreserveSig] int Activate(ref Guid iid,int cls,IntPtr p,[MarshalAs(UnmanagedType.IUnknown)] out object o); [PreserveSig] int OpenPropertyStore(int a,out IPS s); [PreserveSig] int GetId(out IntPtr id); [PreserveSig] int GetState(out uint st); }
 [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface IPS {
   [PreserveSig] int GetCount(out uint n); [PreserveSig] int GetAt(uint i,out PKEY k); [PreserveSig] int GetValue(ref PKEY k,out PV v); [PreserveSig] int SetValue(ref PKEY k,ref PV v); [PreserveSig] int Commit(); }
 [ComImport,Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface IAC {
   [PreserveSig] int Initialize(int s,int f,long bd,long pd,IntPtr fmt,IntPtr ses); [PreserveSig] int GetBufferSize(out uint n); [PreserveSig] int GetStreamLatency(out long l);
   [PreserveSig] int GetCurrentPadding(out uint p); [PreserveSig] int IsFormatSupported(int s,IntPtr f,out IntPtr cf); [PreserveSig] int GetMixFormat(out IntPtr fmt); [PreserveSig] int GetDevicePeriod(out long a,out long b);
   [PreserveSig] int Start(); [PreserveSig] int Stop(); [PreserveSig] int Reset(); [PreserveSig] int SetEventHandle(IntPtr h); [PreserveSig] int GetService(ref Guid iid,[MarshalAs(UnmanagedType.IUnknown)] out object o);
   [PreserveSig] int IsOffloadCapable(int cat,out int c); [PreserveSig] int SetClientProperties(IntPtr props); [PreserveSig] int GetBufferSizeLimits(IntPtr fmt,int ev,out long mn,out long mx); }
 [ComImport,Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface ICC {
   [PreserveSig] int GetBuffer(out IntPtr d,out uint fr,out uint fl,out ulong dp,out ulong qp); [PreserveSig] int ReleaseBuffer(uint fr); [PreserveSig] int GetNextPacketSize(out uint fr); }
 public static class Mic {
   static IAC client; static ICC cap; static Thread th; static volatile bool run; static int ch,bits;
   public static volatile float L,R,Mono; public static int Channels,SampleRate; public static string Chosen=""; public static bool Raw=true;
   const int BN=16384; static float[] bufL=new float[BN]; static float[] bufR=new float[BN]; static int bpos=0; static object lk=new object();
   static PKEY FK(){ PKEY k=new PKEY(); k.fmtid=new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid=14; return k; }
   static string NameOf(IMMDevice d){ IPS ps; if(d.OpenPropertyStore(0,out ps)!=0) return "?"; PKEY k=FK(); PV v; if(ps.GetValue(ref k,out v)!=0) return "?"; return v.p!=IntPtr.Zero?Marshal.PtrToStringUni(v.p):"?"; }
   public static int Start(string kw){
     var en=(IE)(new E()); IMMColl c; int hr=en.EnumAudioEndpoints(1,1,out c); if(hr!=0) return hr;
     uint n; c.GetCount(out n); IMMDevice chosen=null; string cn="";
     for(uint i=0;i<n;i++){ IMMDevice d; c.Item(i,out d); string nm=NameOf(d); if(kw!=null&&nm.IndexOf(kw,StringComparison.OrdinalIgnoreCase)>=0){chosen=d;cn=nm;break;} if(chosen==null){chosen=d;cn=nm;} }
     if(chosen==null) return unchecked((int)0x80004005); Chosen=cn;
     Guid ic=new Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"); object o; hr=chosen.Activate(ref ic,23,IntPtr.Zero,out o); if(hr!=0) return hr;
     client=(IAC)o;
     try { ACPROPS pr=new ACPROPS(); pr.cbSize=(uint)Marshal.SizeOf(typeof(ACPROPS)); pr.Options=(Raw?1:0); IntPtr pp=Marshal.AllocHGlobal((int)pr.cbSize); Marshal.StructureToPtr(pr,pp,false); client.SetClientProperties(pp); Marshal.FreeHGlobal(pp); } catch {}
     IntPtr pf; hr=client.GetMixFormat(out pf); if(hr!=0) return hr;
     WFX f=(WFX)Marshal.PtrToStructure(pf,typeof(WFX)); ch=f.ch; bits=f.bits; Channels=ch; SampleRate=(int)f.sps;
     hr=client.Initialize(0,0,3000000,0,pf,IntPtr.Zero); if(hr!=0) return hr;
     Guid icc=new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"); object oc; hr=client.GetService(ref icc,out oc); if(hr!=0) return hr;
     cap=(ICC)oc; hr=client.Start(); if(hr!=0) return hr;
     run=true; th=new Thread(Loop); th.IsBackground=true; th.Start(); return 0;
   }
   public static void Stop(){ run=false; try{ if(client!=null) client.Stop(); }catch{} L=0;R=0;Mono=0; }
   static void Loop(){ int bps=bits/8;
     while(run){ uint pk; if(cap.GetNextPacketSize(out pk)!=0){Thread.Sleep(3);continue;}
       while(pk>0){ IntPtr d; uint fr,fl; ulong dp,qp; if(cap.GetBuffer(out d,out fr,out fl,out dp,out qp)!=0) break;
         if(fr>0){ double sl=0,sr=0; bool sil=(fl&0x2)!=0;
           if(!sil && d!=IntPtr.Zero){ int tot=(int)fr*ch*bps; byte[] b=new byte[tot]; Marshal.Copy(d,b,0,tot);
             lock(lk){ for(int i=0;i<fr;i++){ int ix=(i*ch)*bps; float ls=0,rs=0;
               if(bits==32){ ls=BitConverter.ToSingle(b,ix); rs=(ch>=2)?BitConverter.ToSingle(b,ix+4):ls; }
               else if(bits==16){ ls=BitConverter.ToInt16(b,ix)/32768f; rs=(ch>=2)?BitConverter.ToInt16(b,ix+2)/32768f:ls; }
               bufL[bpos]=ls; bufR[bpos]=rs; bpos=(bpos+1)%BN; sl+=(double)ls*ls; sr+=(double)rs*rs; } } }
           L=(float)Math.Sqrt(sl/fr); R=(float)Math.Sqrt(sr/fr); Mono=(L+R)/2f; }
         cap.ReleaseBuffer(fr); if(cap.GetNextPacketSize(out pk)!=0) break; }
       Thread.Sleep(3); } }
   // cross-correlation time delay (samples). LEFT source -> negative, RIGHT -> positive (this device).
   public static double BestLag(int win, int maxLag, out double conf){
     conf=0; if(win>BN) win=BN; float[] a=new float[win]; float[] b=new float[win];
     lock(lk){ int start=bpos-win; for(int i=0;i<win;i++){ int idx=((start+i)%BN+BN)%BN; a[i]=bufL[idx]; b[i]=bufR[idx]; } }
     double best=-1e18; int bl=0; int M=2*maxLag+1; double[] cc=new double[M];
     for(int lag=-maxLag; lag<=maxLag; lag++){ double s=0; for(int i=0;i<win;i++){ int j=i+lag; if(j<0||j>=win) continue; s+=(double)a[i]*b[j]; } cc[lag+maxLag]=s; if(s>best){best=s;bl=lag;} }
     double frac=0; int bi=bl+maxLag;
     if(bi>0 && bi<M-1){ double y1=cc[bi-1],y2=cc[bi],y3=cc[bi+1]; double den=(y1-2*y2+y3); if(Math.Abs(den)>1e-12) frac=0.5*(y1-y3)/den; if(frac>1)frac=1; if(frac<-1)frac=-1; }
     double mean=0; for(int k=0;k<M;k++) mean+=cc[k]; mean/=M; conf=(best-mean)/(Math.Abs(best)+1e-9);
     return bl+frac;
   }
 }
}
"@

$genAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$actAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Await($op,$t){ $x=$genAsTask.MakeGenericMethod($t).Invoke($null,@($op)); $x.Wait(-1)|Out-Null; $x.Result }
function AwaitAction($op){ $x=$actAsTask.Invoke($null,@($op)); $x.Wait(-1)|Out-Null }

[void][Windows.Media.Capture.MediaCapture,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameSourceGroup,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Media.Capture.Frames.MediaFrameReader,Windows.Media,ContentType=WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
[void][Windows.Storage.Streams.Buffer,Windows.Storage.Streams,ContentType=WindowsRuntime]

$IR = [Windows.Media.Capture.Frames.MediaFrameSourceKind]::Infrared
$script:als=$null
try { [void][Windows.Devices.Sensors.LightSensor,Windows.Devices.Sensors,ContentType=WindowsRuntime]; $script:als=[Windows.Devices.Sensors.LightSensor]::GetDefault() } catch {}
$script:ffmpeg = $null
$gc = Get-Command ffmpeg -ErrorAction SilentlyContinue
if($gc){ $script:ffmpeg = $gc.Source } else { $c = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe"; if(Test-Path $c){ $script:ffmpeg = $c } }

# ---------- open IR camera ----------
try {
  $groups = Await ([Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]])
  $grp=$null
  foreach($g in $groups){ if($g.DisplayName -eq 'Integrated IR Camera'){ $grp=$g; break } }
  if(-not $grp){ foreach($g in $groups){ foreach($si in $g.SourceInfos){ if($si.SourceKind -eq $IR){ $grp=$g; break } }; if($grp){break} } }
  if(-not $grp){ [System.Windows.Forms.MessageBox]::Show("Infrared camera not found."); return }
  $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
  $settings.SourceGroup = $grp
  $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
  $settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu
  $settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::ExclusiveControl
  $mc = New-Object Windows.Media.Capture.MediaCapture
  try { AwaitAction ($mc.InitializeAsync($settings)) }
  catch { $settings.SharingMode=[Windows.Media.Capture.MediaCaptureSharingMode]::SharedReadOnly; $mc=New-Object Windows.Media.Capture.MediaCapture; AwaitAction ($mc.InitializeAsync($settings)) }
  $src=$null
  foreach($kv in $mc.FrameSources){ if($kv.Value.Info.SourceKind -eq $IR){ $src=$kv.Value; break } }
  $reader = Await ($mc.CreateFrameReaderAsync($src)) ([Windows.Media.Capture.Frames.MediaFrameReader])
  $null = Await ($reader.StartAsync()) ([Windows.Media.Capture.Frames.MediaFrameReaderStartStatus])
}
catch {
  $d=$_.Exception; while($d.InnerException){ $d=$d.InnerException }
  $hr = try { '0x{0:X8}' -f $d.HResult } catch { '' }
  [System.Windows.Forms.MessageBox]::Show("Could not open the IR camera.`n$hr $($d.Message)`n`nIf it says 'reboot' -> restart the machine.")
  return
}

# ---------- state ----------
$script:stretch=$true; $script:mirror=$true; $script:filter=$true
$script:peak=0.0; $script:zoom=1.0; $script:lastBmp=$null
$script:bright=0; $script:contrastF=1.0; $script:gamma=1.0
$script:lut=[IRProc]::BuildLut(0,1.0,1.0)
$script:W=0; $script:H=0
$script:recording=$false; $script:rec=$null; $script:recPath=""
$script:fs=$false; $script:micOn=$false; $script:lux=0
$script:cen=0.0; $script:lastLag=0.0; $script:dir=0.0; $script:dirActive=$false
$script:micDist=0.0486  # calibrated from 0/90/180 endfire test: +-6.8 samples (full L/R) = +-90 deg (~4.86 cm effective)

# ---------- shared GDI objects ----------
$script:fntBold  = New-Object System.Drawing.Font("Segoe UI",8,[System.Drawing.FontStyle]::Bold)
$script:fntBig   = New-Object System.Drawing.Font("Segoe UI",13,[System.Drawing.FontStyle]::Bold)
$script:fntSmall = New-Object System.Drawing.Font("Consolas",9)
$script:brWhite  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240,240,240))
$script:brDim    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140,140,140))
$script:brCyan   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90,200,235))
$script:brGreen  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80,200,120))
$script:brOrange = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235,175,55))
$script:brRed    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(225,70,70))
$script:brTrack  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(55,55,55))
$script:penGray  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(95,95,95))
$script:penNeedle= New-Object System.Drawing.Pen (([System.Drawing.Color]::FromArgb(90,200,235)),3)

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "IR Camera Viewer"
$form.Width = 1040; $form.Height = 700
$form.BackColor = [System.Drawing.Color]::Black
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true

$pb = New-Object System.Windows.Forms.PictureBox
$pb.Dock='Fill'; $pb.SizeMode='Zoom'; $pb.BackColor=[System.Drawing.Color]::Black
$form.Controls.Add($pb)

# ---------- bottom bar: image adjustments ----------
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock='Bottom'; $panel.Height=72; $panel.WrapContents=$false; $panel.BackColor=[System.Drawing.Color]::FromArgb(30,30,30); $panel.Padding='6,8,6,6'
function New-Lbl($t){ $l=New-Object System.Windows.Forms.Label; $l.Text=$t; $l.ForeColor='White'; $l.AutoSize=$true; $l.Margin='10,14,2,0'; return $l }
function New-Tb($min,$max,$val){ $tb=New-Object System.Windows.Forms.TrackBar; $tb.Minimum=$min; $tb.Maximum=$max; $tb.Value=$val; $tb.Width=150; $tb.TickStyle='None'; return $tb }
$btnRec = New-Object System.Windows.Forms.Button
$btnRec.Text="REC"; $btnRec.Width=64; $btnRec.Height=40; $btnRec.Margin='4,10,6,4'; $btnRec.ForeColor='White'; $btnRec.BackColor=[System.Drawing.Color]::FromArgb(160,40,40); $btnRec.FlatStyle='Flat'
$btnSnap = New-Object System.Windows.Forms.Button
$btnSnap.Text="Snap"; $btnSnap.Width=58; $btnSnap.Height=40; $btnSnap.Margin='0,10,10,4'; $btnSnap.ForeColor='White'; $btnSnap.BackColor=[System.Drawing.Color]::FromArgb(50,90,140); $btnSnap.FlatStyle='Flat'
$tbB=New-Tb -100 100 0; $tbC=New-Tb -100 100 0; $tbG=New-Tb 10 300 100
$panel.Controls.AddRange(@($btnRec,$btnSnap,(New-Lbl "Bright"),$tbB,(New-Lbl "Contrast"),$tbC,(New-Lbl "Gamma"),$tbG))
$form.Controls.Add($panel)

# ---------- top bar: sensors ----------
$sensorPanel = New-Object System.Windows.Forms.Panel
$sensorPanel.Dock='Top'; $sensorPanel.Height=86; $sensorPanel.BackColor=[System.Drawing.Color]::FromArgb(24,24,24)
$bf=[System.Windows.Forms.Control].GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic'); $bf.SetValue($sensorPanel,$true,$null)
$cbLux = New-Object System.Windows.Forms.CheckBox
$cbLux.Appearance='Button'; $cbLux.Text="Light"; $cbLux.ForeColor='White'; $cbLux.FlatStyle='Flat'; $cbLux.TextAlign='MiddleCenter'; $cbLux.SetBounds(8,14,70,58)
$cbMic = New-Object System.Windows.Forms.CheckBox
$cbMic.Appearance='Button'; $cbMic.Text="Sound"; $cbMic.ForeColor='White'; $cbMic.FlatStyle='Flat'; $cbMic.TextAlign='MiddleCenter'; $cbMic.SetBounds(84,14,70,58)
$sensorPanel.Controls.Add($cbLux); $sensorPanel.Controls.Add($cbMic)
$form.Controls.Add($sensorPanel)

# ---------- MENU ----------
$menu = New-Object System.Windows.Forms.MenuStrip
$menu.BackColor=[System.Drawing.Color]::FromArgb(45,45,45); $menu.ForeColor='White'
function New-Mi($text){ $m=New-Object System.Windows.Forms.ToolStripMenuItem; $m.Text=$text; return $m }
$mTop1 = New-Mi "Functions"
$miSnap = New-Mi "Snapshot`tP"; $miRec = New-Mi "Record`tR"; $miFS = New-Mi "Fullscreen`tF11"; $miPanel= New-Mi "Show/Hide bottom bar`tH"; $miPanel.Checked=$true
$mTop1.DropDownItems.AddRange(@($miSnap,$miRec,(New-Object System.Windows.Forms.ToolStripSeparator),$miFS,$miPanel))
$mTop2 = New-Mi "Image"
$miMirror = New-Mi "Mirror`tM"; $miMirror.Checked=$true; $miFilter = New-Mi "Anti-flicker`tF"; $miFilter.Checked=$true; $miStretch = New-Mi "Auto-brighten`tS"; $miStretch.Checked=$true
$miZin = New-Mi "Zoom in`t+"; $miZout = New-Mi "Zoom out`t-"
$mTop2.DropDownItems.AddRange(@($miMirror,$miFilter,$miStretch,(New-Object System.Windows.Forms.ToolStripSeparator),$miZin,$miZout))
$mTop4 = New-Mi "Sensors"
$miLux = New-Mi "Light meter (lux)"; $miMic = New-Mi "Sound meter (mic)"; $miRecenter = New-Mi "Recenter direction"
$mTop4.DropDownItems.AddRange(@($miLux,$miMic,(New-Object System.Windows.Forms.ToolStripSeparator),$miRecenter))
$mTop3 = New-Mi "Help"; $miHelp = New-Mi "Shortcuts..."; $mTop3.DropDownItems.Add($miHelp) | Out-Null
$menu.Items.AddRange(@($mTop1,$mTop2,$mTop4,$mTop3))
$form.MainMenuStrip = $menu
$form.Controls.Add($menu)

# ---------- helpers ----------
$script:statusTimer = New-Object System.Windows.Forms.Timer
$script:statusTimer.Interval = 3000
$script:statusTimer.Add_Tick({ $script:statusTimer.Stop(); Update-Lut })
function Show-Status($msg){ $form.Text=$msg; $script:statusTimer.Stop(); $script:statusTimer.Start() }
function Update-Lut {
  $b=$tbB.Value; $c=$tbC.Value; $g=$tbG.Value/100.0
  $script:bright=[int]($b*1.28); $script:contrastF=(259.0*($c+255))/(255.0*(259-$c)); $script:gamma=$g
  $script:lut=[IRProc]::BuildLut($script:bright,$script:contrastF,$script:gamma)
  $form.Text = "IR Camera Viewer   Bright:$b  Contrast:$c  Gamma:$([math]::Round($g,2))  Zoom:$([math]::Round($script:zoom,2))x" + $(if($script:recording){"   [RECORDING]"}else{""})
}
$tbB.Add_ValueChanged({ Update-Lut }); $tbC.Add_ValueChanged({ Update-Lut }); $tbG.Add_ValueChanged({ Update-Lut })
function Take-Snapshot { if($script:lastBmp){ $desk=[Environment]::GetFolderPath('Desktop'); $n=Join-Path $desk ("IR_snapshot_{0}.png" -f (Get-Date -Format 'yyyyMMdd_HHmmss')); $script:lastBmp.Save($n,[System.Drawing.Imaging.ImageFormat]::Png); Show-Status "Saved image: $n" } }
function Toggle-Mirror { $script:mirror=-not $script:mirror; $miMirror.Checked=$script:mirror }
function Toggle-Filter { $script:filter=-not $script:filter; $miFilter.Checked=$script:filter }
function Toggle-Stretch{ $script:stretch=-not $script:stretch; $miStretch.Checked=$script:stretch }
function Toggle-Panel  { $panel.Visible=-not $panel.Visible; $miPanel.Checked=$panel.Visible }
function Zoom-In  { $script:zoom=[math]::Min(5.0,$script:zoom+0.25); Update-Lut }
function Zoom-Out { $script:zoom=[math]::Max(1.0,$script:zoom-0.25); Update-Lut }
function Recenter { $script:cen=$script:lastLag; $script:dir=0.0 }
function Toggle-FS {
  if($script:fs){ $form.FormBorderStyle='Sizable'; $form.WindowState='Normal'; $menu.Visible=$true; $sensorPanel.Visible=$true; $panel.Visible=$true; $miPanel.Checked=$true; $script:fs=$false }
  else { $form.WindowState='Normal'; $form.FormBorderStyle='None'; $form.WindowState='Maximized'; $menu.Visible=$false; $sensorPanel.Visible=$false; $panel.Visible=$false; $miPanel.Checked=$false; $script:fs=$true }
  $miFS.Checked=$script:fs
}
function Toggle-Rec {
  if($script:recording){
    $script:recording=$false; $btnRec.Text="REC"; $btnRec.BackColor=[System.Drawing.Color]::FromArgb(160,40,40)
    try { $script:rec.StandardInput.Close() } catch {}; try { $script:rec.WaitForExit(4000) } catch {}
    $p=$script:recPath; $script:rec=$null; Show-Status "Saved video: $p"
  } else {
    if(-not $script:ffmpeg){ [System.Windows.Forms.MessageBox]::Show("ffmpeg not found (needed to record)."); return }
    if($script:W -eq 0){ [System.Windows.Forms.MessageBox]::Show("Wait for the image, then record."); return }
    $desk=[Environment]::GetFolderPath('Desktop'); $script:recPath=Join-Path $desk ("IR_rec_{0}.mp4" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$script:ffmpeg
    $psi.Arguments="-y -f rawvideo -pixel_format bgra -video_size $($script:W)x$($script:H) -framerate 15 -i - -c:v libx264 -preset veryfast -pix_fmt yuv420p `"$($script:recPath)`""
    $psi.RedirectStandardInput=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $script:rec=[System.Diagnostics.Process]::Start($psi); $script:recording=$true; $btnRec.Text="STOP"; $btnRec.BackColor=[System.Drawing.Color]::FromArgb(200,20,20)
  }
  $miRec.Checked=$script:recording; Update-Lut
}
function Show-Help {
  $t = @"
SHORTCUTS
  P     Snapshot (PNG to Desktop)
  R     Start / stop recording (MP4 to Desktop)
  F11   Fullscreen        + -  Zoom in / out
  M     Mirror   F Anti-flicker   S Auto-brighten   H bottom bar
  Esc   Exit

SOUND meter (top bar, RAW mic, no noise suppression):
  Radar gauge = TDOA bearing, calibrated (front = 90 deg, full
  left = 180, full right = 0). Works best with BROADBAND sound
  (music, clap, "shh", voice) - a pure tone is ambiguous. Two
  close mics => LEFT/RIGHT axis only; angle is coarse near the
  extremes. 'Recenter direction' re-nulls the front reference.
Files are saved to the Desktop.
"@
  [System.Windows.Forms.MessageBox]::Show($t,"Help")
}

# ---------- sensor rendering ----------
$sensorPanel.Add_Paint({
  param($sender,$e)
  $g=$e.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([System.Drawing.Color]::FromArgb(24,24,24))
  if($cbLux.Checked){
    $g.DrawString("LIGHT", $script:fntBold, $script:brDim, 168, 12)
    $g.DrawString(("{0} lux" -f $script:lux), $script:fntBig, $script:brWhite, 166, 30)
    $lx=[double]$script:lux; $lg = if($lx -gt 1){ [math]::Min(1.0,[math]::Log10($lx)/4.0) } else { 0 }
    $g.FillRectangle($script:brTrack, 168, 62, 150, 10); $g.FillRectangle($script:brCyan, 168, 62, [int](150*$lg), 10)
  }
  if($cbMic.Checked -and $script:micOn){
    $sx=360
    $mono=[double][CA4.Mic]::Mono
    $g.DrawString("SOUND", $script:fntBold, $script:brDim, $sx, 8)
    $level=[math]::Min(1.0,$mono*4)
    $lb = if($level -lt 0.5){$script:brGreen}elseif($level -lt 0.8){$script:brOrange}else{$script:brRed}
    $g.FillRectangle($script:brTrack, $sx, 26, 200, 15); $g.FillRectangle($lb, $sx, 26, [int](200*$level), 15)
    $db = if($mono -gt 0.00001){ "{0} dB" -f [int](20*[math]::Log10($mono)) } else { "-inf" }
    $g.DrawString($db, $script:fntSmall, $script:brWhite, ($sx+206), 26)
    $g.DrawString("Sound level", $script:fntBold, $script:brDim, $sx, 48)
    # radar gauge
    $cx=650; $cy=76; $rr=40
    $arc=New-Object System.Collections.Generic.List[System.Drawing.PointF]
    for($aa=180;$aa -le 360;$aa+=12){ $rad=$aa*[math]::PI/180; $arc.Add((New-Object System.Drawing.PointF([single]($cx+$rr*[math]::Cos($rad)),[single]($cy+$rr*[math]::Sin($rad))))) }
    $g.DrawLines($script:penGray,$arc.ToArray())
    $g.DrawString("L",$script:fntSmall,$script:brDim,($cx-$rr-14),($cy-12))
    $g.DrawString("R",$script:fntSmall,$script:brDim,($cx+$rr+4),($cy-12))
    $g.DrawString("C",$script:fntSmall,$script:brDim,($cx-5),($cy-$rr-16))
    $dv = if($script:dirActive){ $script:dir } else { $script:dir }
    $ang = (270 + $dv*90) * [math]::PI/180
    $ex=$cx + $rr*[math]::Cos($ang); $ey=$cy + $rr*[math]::Sin($ang)
    $pen = if($script:dirActive){ $script:penNeedle } else { $script:penGray }
    $g.DrawLine($pen,[single]$cx,[single]$cy,[single]$ex,[single]$ey)
    $g.FillEllipse($script:brCyan,($cx-4),($cy-4),8,8)
    $deg=[int]($dv*90)
    $word = if($dv -lt -0.15){"LEFT"}elseif($dv -gt 0.15){"RIGHT"}else{"CENTER"}
    $g.DrawString(("{0}  {1}{2} deg" -f $word,$(if($deg -gt 0){'+'}else{''}),$deg), $script:fntSmall, $script:brWhite, ($cx+$rr+16), ($cy-24))
    if(-not $script:dirActive){ $g.DrawString("(quiet)", $script:fntSmall, $script:brDim, ($cx+$rr+16), ($cy-6)) }
  }
  elseif($cbMic.Checked){ $g.DrawString("SOUND (opening mic...)", $script:fntSmall, $script:brDim, 360, 30) }
})

$script:sensorTimer = New-Object System.Windows.Forms.Timer
$script:sensorTimer.Interval = 50
$script:sensorTimer.Add_Tick({
  if(-not ($cbLux.Checked -or $cbMic.Checked)){ $script:sensorTimer.Stop(); $sensorPanel.Invalidate(); return }
  if($cbLux.Checked -and $script:als){ try { $rd=$script:als.GetCurrentReading(); if($rd){ $script:lux=[int][math]::Round($rd.IlluminanceInLux,0) } } catch {} }
  if($cbMic.Checked -and $script:micOn){
    $l=[double][CA4.Mic]::L; $r=[double][CA4.Mic]::R; $mono=[double][CA4.Mic]::Mono
    if($mono -gt 0.006 -and ($l+$r) -gt 0.00001){
      # direction from TDOA (time delay), auto-centered to remove the array's fixed offset.
      # level difference is NOT used (this mic array's L/R imbalance carries no direction).
      $cf=0.0; $lag=[CA4.Mic]::BestLag(2048,8,[ref]$cf); $script:lastLag=$lag
      # absolute bearing (calibrated 0/90/180 test): front lag ~= 0 => 90 deg; endfire ~= +-6.8 samples => +-90 deg.
      # $script:cen = fixed front reference (0 default, no auto-drift; Recenter re-nulls it). Broadband LEFT = higher lag.
      $sinT=($script:cen-$lag) * 343.0 / (48000.0 * $script:micDist)
      if($sinT -gt 1){$sinT=1}; if($sinT -lt -1){$sinT=-1}
      $dirRaw=[math]::Asin($sinT) / ([math]::PI/2)   # normalized bearing -1..+1 (= degrees/90)
      $script:dir=$script:dir*0.6 + $dirRaw*0.4
      $script:dirActive=$true
    } else { $script:dirActive=$false }
  }
  $sensorPanel.Invalidate()
})
function Toggle-LuxSensor {
  if($cbLux.Checked){ if(-not $script:als){ [System.Windows.Forms.MessageBox]::Show("No ambient light sensor on this machine."); $cbLux.Checked=$false; return }; $script:sensorTimer.Start() }
  $miLux.Checked=$cbLux.Checked; $sensorPanel.Invalidate()
}
function Toggle-MicSensor {
  if($cbMic.Checked){
    $hr=[CA4.Mic]::Start("Array")
    if($hr -ne 0){ [System.Windows.Forms.MessageBox]::Show(("Could not open microphone (0x{0:X8})." -f $hr)); $cbMic.Checked=$false; return }
    $script:micOn=$true; $script:cen=0.0; $script:dir=0.0; $script:sensorTimer.Start()
  } else { try { [CA4.Mic]::Stop() } catch {}; $script:micOn=$false }
  $miMic.Checked=$cbMic.Checked; $sensorPanel.Invalidate()
}
$cbLux.Add_CheckedChanged({ Toggle-LuxSensor })
$cbMic.Add_CheckedChanged({ Toggle-MicSensor })

# ---------- events ----------
$btnRec.Add_Click({ Toggle-Rec }); $btnSnap.Add_Click({ Take-Snapshot })
$miSnap.Add_Click({ Take-Snapshot }); $miRec.Add_Click({ Toggle-Rec }); $miFS.Add_Click({ Toggle-FS }); $miPanel.Add_Click({ Toggle-Panel })
$miMirror.Add_Click({ Toggle-Mirror }); $miFilter.Add_Click({ Toggle-Filter }); $miStretch.Add_Click({ Toggle-Stretch }); $miZin.Add_Click({ Zoom-In }); $miZout.Add_Click({ Zoom-Out })
$miLux.Add_Click({ $cbLux.Checked = -not $cbLux.Checked }); $miMic.Add_Click({ $cbMic.Checked = -not $cbMic.Checked }); $miRecenter.Add_Click({ Recenter })
$miHelp.Add_Click({ Show-Help })
$tt = New-Object System.Windows.Forms.ToolTip
$tt.SetToolTip($btnSnap,"Snapshot (P)"); $tt.SetToolTip($btnRec,"Record (R)")
$tt.SetToolTip($cbLux,"Show ambient light (lux)"); $tt.SetToolTip($cbMic,"Sound level + radar direction (opens mic, RAW)")

$form.Add_KeyDown({
  switch($_.KeyCode){
    'R'{ Toggle-Rec } 'F11'{ Toggle-FS } 'F'{ Toggle-Filter } 'S'{ Toggle-Stretch } 'M'{ Toggle-Mirror } 'H'{ Toggle-Panel } 'P'{ Take-Snapshot }
    'Escape'{ if($script:fs){ Toggle-FS } else { $form.Close() } }
    'Oemplus'{ Zoom-In } 'Add'{ Zoom-In } 'OemMinus'{ Zoom-Out } 'Subtract'{ Zoom-Out }
  }
})

# ---------- frame loop ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20
$timer.Add_Tick({
  try {
    $frame=$reader.TryAcquireLatestFrame(); if($frame -eq $null){ return }
    $vmf=$frame.VideoMediaFrame; if($vmf -eq $null){ $frame.Dispose(); return }
    $sb=$vmf.SoftwareBitmap; if($sb -eq $null){ $frame.Dispose(); return }
    $bgra=[Windows.Graphics.Imaging.SoftwareBitmap]::Convert($sb,[Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)
    $w=$bgra.PixelWidth; $h=$bgra.PixelHeight; $len=$w*$h*4
    $buf=New-Object Windows.Storage.Streams.Buffer($len); $bgra.CopyToBuffer($buf)
    $bytes=[System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::ToArray($buf)
    $bgra.Dispose(); $frame.Dispose(); $script:W=$w; $script:H=$h
    if($script:filter){ $mean=[IRProc]::Mean($bytes); if($mean -gt $script:peak){ $script:peak=$mean } else { $script:peak=$script:peak*0.90 }; if($script:peak -lt 1){ $script:peak=1 }; if($mean -lt $script:peak*0.55){ return } }
    if($script:stretch){ [IRProc]::Stretch($bytes) }
    [IRProc]::ApplyLut($bytes,$script:lut)
    if($script:recording -and $script:rec -ne $null){ try { $script:rec.StandardInput.BaseStream.Write($bytes,0,$len) } catch {} }
    $bmp=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect=New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $bd=$bmp.LockBits($rect,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,$bmp.PixelFormat)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes,0,$bd.Scan0,$len); $bmp.UnlockBits($bd)
    if($script:zoom -gt 1.0){
      $zw=[int]($w/$script:zoom); $zh=[int]($h/$script:zoom); $zx=[int](($w-$zw)/2); $zy=[int](($h-$zh)/2)
      $zb=New-Object System.Drawing.Bitmap($w,$h,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $gr=[System.Drawing.Graphics]::FromImage($zb); $gr.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
      $gr.DrawImage($bmp,(New-Object System.Drawing.Rectangle(0,0,$w,$h)),(New-Object System.Drawing.Rectangle($zx,$zy,$zw,$zh)),[System.Drawing.GraphicsUnit]::Pixel)
      $gr.Dispose(); $bmp.Dispose(); $bmp=$zb
    }
    if($script:mirror){ $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
    $old=$pb.Image; $pb.Image=$bmp; $script:lastBmp=$bmp; if($old){ $old.Dispose() }
  } catch {}
})

$form.Add_FormClosing({
  try { $timer.Stop() } catch {}
  try { $script:sensorTimer.Stop() } catch {}
  try { if($script:micOn){ [CA4.Mic]::Stop() } } catch {}
  if($script:recording){ try { $script:rec.StandardInput.Close(); $script:rec.WaitForExit(4000) } catch {} }
  try { $reader.StopAsync()|Out-Null } catch {}
  try { $mc.Dispose() } catch {}
})

Update-Lut
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
