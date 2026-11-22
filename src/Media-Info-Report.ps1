<#
.SYNOPSIS
    Media Info Report - Resolution, codecs, audio and size for every video, and which ones a TV may not play.

.DESCRIPTION
    PowerShell/WPF tool for reporting the resolution, codecs and audio of video files.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Media Info Report v<version>\" release folders, their zips and
                                        "Media Info Report.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Media Info Report

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Media Info Report v<version>".
$script:AppName     = 'Media Info Report'
$script:AppVersion  = '1.00'
$script:Description = 'PowerShell/WPF tool for reporting the resolution, codecs and audio of video files'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Media-Info-Report'
$script:IsPrivate   = $false  # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.Media-Info-Report'   # taskbar ID; the shortcut made by New-MediaInfoReportShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Media Info Report v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    # Source\src\<script> or Builds\<App> v<x.yy>\<script>: <project> is two levels up.
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')   # an unpacked release zip somewhere else
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}


function Get-AppSetting {
    <# Settings from settings.json in the data folder: the look, the video folders, ffprobe's place
       and what the TV plays. To begin with: Windows' Videos folder and a typical recent smart TV. #>
    $s = @{ Look = 'Light'; Roots = @([Environment]::GetFolderPath('MyVideos')); FFprobe = ''
            TvModel = 'Typical 4K HDR smart TV'
            TvHevc = $true; TvAv1 = $false; TvVp9 = $true; Tv4K = $true; TvHdr = $true; TvDv = $false; TvDts = $false; TvDtsMkv = $false; TvTrueHd = $false; TvFlac = $true; TvEarc = $false; MaxMbps = 0 }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                switch -regex ($p.Name) {
                    '^Roots$'   { $s.Roots = @($p.Value | ForEach-Object { [string]$_ }) }
                    '^TvModel$' { $s.TvModel = [string]$p.Value; break }
                    '^Tv'       { $s[$p.Name] = [bool]$p.Value }
                    '^MaxMbps$' { $s.MaxMbps = [double]$p.Value }
                    default     { $s[$p.Name] = [string]$p.Value }
                }
            }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#16191E'; Card = '#1F242B'; Line = '#343B45'; Ink = '#E6E9EE'; Soft = '#9AA3AE'; Accent = '#4C9BE8'; AccentInk = '#FFFFFF'
       Field = '#14171B'; UpdateBack = '#3A3022'; Hover = '#2A313A'; Select = '#24425F'; Good = '#4CC38A'; Warn = '#E0A040'; Bad = '#F07178'; Changed = '#2B3A2E' }
} else {
    @{ Page = '#F3F5F8'; Card = '#FFFFFF'; Line = '#D7DCE3'; Ink = '#1E2530'; Soft = '#5E6875'; Accent = '#1F6FBF'; AccentInk = '#FFFFFF'
       Field = '#FFFFFF'; UpdateBack = '#FFF4E0'; Hover = '#EAF0F7'; Select = '#D6E6F7'; Good = '#1E8A57'; Warn = '#9A5B00'; Bad = '#B3261E'; Changed = '#E7F5EC' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# A dark title bar in the dark look (Windows 10 20H1 and later; older Windows ignores it). #>
    if (-not $script:Dark) { return }
    try {
        if (-not ('MiDwm' -as [type])) { Add-Type -Namespace '' -Name 'MiDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = 1; [void][MiDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { Write-Verbose 'no dark title bar' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Add_SourceInitialized({ Set-TitleBar $this })
    return $w
}

# Shared styles: rounded buttons (normal and accent), text boxes and the list.
$script:Styles = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Card}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Select}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="BorderBrush" Value="{Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Opacity" Value="0.7"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <!-- Slim rounded scroll bars: a thin handle on a clear track, no arrow buttons. It widens a
         little while the pointer is over it and darkens on hover and drag. -->
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="4" Background="{Line}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Width" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Height" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="6,4"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="460" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="20"/>
    <TextBox x:Name="MsgInput" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppMessage {
    <# A message, a question (with -NoText: $true for the first button) or, with -Ask,
       a question with a text box (returns the text, or $null when cancelled). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [switch]$Ask, [string]$Default = '', [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo'); $box = $w.FindName('MsgInput')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    if ($Ask) { $box.Visibility = 'Visible'; $box.Text = $Default; $w.Add_ContentRendered({ $box.Focus(); $box.SelectAll() }) }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; $w.Close() })
    $no.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if ($Ask) { if ($script:MsgAnswer) { return $box.Text.Trim() } else { return $null } }
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22" MaxWidth="440">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Media-Info-Report.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region PROBE
# ---------------------------------------------------------------------------
#  Reading the videos: ffprobe (part of the free FFmpeg) tells us each file's
#  streams. It runs on four files at a time in the background (C#), so the
#  window stays usable; results are kept so the next scan only reads new or
#  changed files.
# ---------------------------------------------------------------------------
if (-not ('MiItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

public class MiItem {
    public string Name { get; set; }
    public string Folder { get; set; }
    public string Path { get; set; }
    public long Bytes { get; set; }
    public long Ticks { get; set; }           // last write time, to spot changed files
    public string Size { get; set; }
    public string Res { get; set; }           // 4K, 1080p, 720p, SD
    public int Width { get; set; }
    public int Height { get; set; }
    public string Video { get; set; }         // e.g. HEVC 10-bit HDR10
    public string VCodec { get; set; }
    public int BitDepth { get; set; }
    public string Hdr { get; set; }           // HDR10, HDR10+, Dolby Vision, HLG or empty
    public string Audio { get; set; }         // e.g. "E-AC-3 5.1, AAC 2.0"
    public string AudioCodecs { get; set; }   // codec names, for the checks
    public string Subs { get; set; }
    public string SubCodecs { get; set; }
    public string Container { get; set; }
    public double Seconds { get; set; }
    public string Length { get; set; }
    public double Mbps { get; set; }
    public string Rate { get; set; }
    public string Problem { get; set; }
    public int Severity { get; set; }         // 0 fine, 1 may need converting, 2 unlikely to play
    public string Error { get; set; }
}

public static class MiProbe {
    public static volatile bool Busy;
    public static volatile bool Cancel;
    public static int Done;
    public static int Total;
    public static ConcurrentQueue<string[]> Results = new ConcurrentQueue<string[]>();   // { path, json-or-error, ok }

    public static void Start(string ffprobe, string[] files, int parallel) {
        Busy = true; Cancel = false; Done = 0; Total = files.Length; Results = new ConcurrentQueue<string[]>();
        Task.Run(() => {
            try {
                Parallel.ForEach(files, new ParallelOptions { MaxDegreeOfParallelism = parallel }, (f, state) => {
                    if (Cancel) { state.Stop(); return; }
                    try {
                        var psi = new ProcessStartInfo(ffprobe,
                            "-v error -show_entries format=duration,bit_rate,format_name:stream=codec_type,codec_name,profile,width,height,pix_fmt,channels,channel_layout,color_transfer:stream_side_data=side_data_type -of json \"" + f + "\"") {
                            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
                            StandardOutputEncoding = System.Text.Encoding.UTF8 };
                        using (var p = Process.Start(psi)) {
                            var outTask = p.StandardOutput.ReadToEndAsync();
                            var errTask = p.StandardError.ReadToEndAsync();
                            if (!p.WaitForExit(60000)) { try { p.Kill(); } catch { } Results.Enqueue(new[] { f, "ffprobe took too long", "0" }); return; }
                            var json = outTask.Result;
                            if (p.ExitCode != 0 || string.IsNullOrWhiteSpace(json)) Results.Enqueue(new[] { f, (errTask.Result ?? "").Trim(), "0" });
                            else Results.Enqueue(new[] { f, json, "1" });
                        }
                    } catch (Exception e) { Results.Enqueue(new[] { f, e.Message, "0" }); }
                    finally { Interlocked.Increment(ref Done); }
                });
            } finally { Busy = false; }
        });
    }
}
'@
}
#endregion PROBE

$script:VideoExt = @('.mkv', '.mp4', '.m4v', '.avi', '.mov', '.wmv', '.ts', '.m2ts', '.mts', '.webm', '.mpg', '.mpeg', '.vob', '.flv', '.divx', '.ogm', '.3gp', '.3g2', '.asf', '.m2t', '.mpe')

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Find-FFprobe {
    <# The ffprobe in Settings, else on the PATH, else where winget, scoop or Chocolatey put it. #>
    if ($script:Settings.FFprobe -and (Test-Path -LiteralPath $script:Settings.FFprobe)) { return $script:Settings.FFprobe }
    $c = Get-Command ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffprobe.exe", "$env:ProgramFiles\ffmpeg\bin\ffprobe.exe", "$env:USERPROFILE\scoop\shims\ffprobe.exe", "$env:ProgramData\chocolatey\bin\ffprobe.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wg) {
        $hit = Get-ChildItem -LiteralPath $wg -Directory -Filter '*FFmpeg*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'ffprobe.exe' -Recurse -ErrorAction SilentlyContinue } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$script:CodecNames = @{ h264 = 'H.264'; hevc = 'HEVC'; av1 = 'AV1'; vp9 = 'VP9'; vp8 = 'VP8'; mjpeg = 'Motion JPEG'; mpeg4 = 'MPEG-4 (XviD/DivX)'; msmpeg4v3 = 'MPEG-4 (DivX 3)'; mpeg2video = 'MPEG-2'; mpeg1video = 'MPEG-1'; vc1 = 'VC-1'; wmv3 = 'WMV 9'; wmv2 = 'WMV 8'; theora = 'Theora'
                        aac = 'AAC'; ac3 = 'AC-3'; eac3 = 'E-AC-3'; dts = 'DTS'; truehd = 'TrueHD'; flac = 'FLAC'; mp3 = 'MP3'; opus = 'Opus'; vorbis = 'Vorbis'; pcm_s16le = 'PCM'; pcm_s24le = 'PCM'; wmav2 = 'WMA'; mp2 = 'MP2'
                        subrip = 'SRT'; ass = 'ASS'; ssa = 'SSA'; mov_text = 'Text'; hdmv_pgs_subtitle = 'PGS'; dvd_subtitle = 'VobSub'; dvb_subtitle = 'DVB' }
function Get-CodecName([string]$c) { if ($script:CodecNames.ContainsKey($c)) { return $script:CodecNames[$c] } else { return $c.ToUpper() } }

function Get-ResLabel([int]$w, [int]$h) {
    if ($w -ge 3200 -or $h -ge 1800) { return '4K' }
    if ($w -ge 1800 -or $h -ge 1000) { return '1080p' }
    if ($w -ge 1200 -or $h -ge 700) { return '720p' }
    if ($w -gt 0) { return 'SD' }
    return ''
}

function ConvertFrom-Probe([MiItem]$Item, [string]$Json) {
    <# Fills in one file's details from ffprobe's JSON. #>
    $j = $Json | ConvertFrom-Json
    $streams = @($j.streams)
    $v = $streams | Where-Object { $_.codec_type -eq 'video' -and $_.codec_name -notin 'mjpeg', 'png', 'bmp' } | Select-Object -First 1
    if (-not $v) { $v = $streams | Where-Object { $_.codec_type -eq 'video' -and $_.codec_name -eq 'mjpeg' -and -not $_.disposition.attached_pic } | Select-Object -First 1 }   # Motion JPEG video, rather than a cover
    if ($v) {
        $Item.VCodec = [string]$v.codec_name
        $Item.Width = [int]$v.width; $Item.Height = [int]$v.height
        $Item.Res = Get-ResLabel $Item.Width $Item.Height
        $Item.BitDepth = if ([string]$v.pix_fmt -match '10|12') { if ($v.pix_fmt -match '12') { 12 } else { 10 } } else { 8 }
        $sides = @($v.side_data_list | ForEach-Object { [string]$_.side_data_type })
        $Item.Hdr = if ($sides -match 'DOVI') { 'Dolby Vision' } elseif ($sides -match 'HDR Dynamic Metadata|HDR10\+') { 'HDR10+' } elseif ($v.color_transfer -eq 'smpte2084') { 'HDR10' } elseif ($v.color_transfer -eq 'arib-std-b67') { 'HLG' } else { '' }
        $Item.Video = (Get-CodecName $Item.VCodec) + $(if ($Item.BitDepth -gt 8) { " $($Item.BitDepth)-bit" }) + $(if ($Item.Hdr) { " $($Item.Hdr)" })
    }
    $aud = @($streams | Where-Object { $_.codec_type -eq 'audio' })
    $Item.AudioCodecs = (@($aud | ForEach-Object { [string]$_.codec_name }) | Select-Object -Unique) -join ','
    $Item.Audio = (@($aud | ForEach-Object {
        $n = Get-CodecName ([string]$_.codec_name)
        if ($_.codec_name -eq 'dts' -and $_.profile -match 'MA') { $n = 'DTS-HD MA' } elseif ($_.codec_name -eq 'dts' -and $_.profile -match 'HRA|HD') { $n = 'DTS-HD' }
        if ($_.profile -match 'Atmos') { $n += ' Atmos' }
        $ch = switch ([int]$_.channels) { 1 { '1.0' } 2 { '2.0' } 6 { '5.1' } 8 { '7.1' } default { if ($_.channels) { "$($_.channels) ch" } else { '' } } }
        "$n $ch".Trim()
    }) | Select-Object -Unique) -join ', '
    $subs = @($streams | Where-Object { $_.codec_type -eq 'subtitle' })
    $Item.SubCodecs = (@($subs | ForEach-Object { [string]$_.codec_name }) | Select-Object -Unique) -join ','
    $Item.Subs = if ($subs.Count) { "$($subs.Count) ($((@($subs | ForEach-Object { Get-CodecName ([string]$_.codec_name) }) | Select-Object -Unique) -join ', '))" } else { '' }
    $Item.Seconds = [double]$j.format.duration
    $Item.Length = if ($Item.Seconds -gt 0) { $t = [TimeSpan]::FromSeconds($Item.Seconds); if ($t.TotalHours -ge 1) { '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes } else { '{0}m {1:00}s' -f $t.Minutes, $t.Seconds } } else { '' }
    $Item.Mbps = if ($j.format.bit_rate) { [math]::Round([double]$j.format.bit_rate / 1e6, 1) } elseif ($Item.Seconds -gt 0) { [math]::Round($Item.Bytes * 8 / $Item.Seconds / 1e6, 1) } else { 0 }
    $Item.Rate = if ($Item.Mbps) { "$($Item.Mbps) Mb/s" } else { '' }
}

# Ready-made TVs for Settings > Your TV. Each sets the ticks; change any tick and it becomes "My own choice".
# The Sony line's video and sound formats are from Sony's Help Guide for the XR-42A90K, "Supported files
# and formats > Videos": H.264 and HEVC Main/Main10 up to 4K 60p, VP9 Profile 0/2 up to 4K, no AV1; sound
# AAC, AC3, E-AC3, AC4, LPCM and DTS core (in MKV), no TrueHD, DTS-HD MA or FLAC. The guide also has TrueHD,
# DTS-HD MA, Atmos and DTS:X passing through eARC, and a Dolby Vision HDMI format. HDR10 and HLG aren't in
# that list: they, and the other three lines, are general guides rather than from a maker's list.
$script:TvPresets = [ordered]@{
    'Sony BRAVIA XR-42A90K (2022)'                   = @{ TvHevc = $true; TvAv1 = $false; TvVp9 = $true; Tv4K = $true; TvHdr = $true; TvDv = $true; TvDts = $true; TvDtsMkv = $true; TvTrueHd = $false; TvFlac = $false }
    'Typical 4K HDR smart TV'                        = @{ TvHevc = $true; TvAv1 = $false; TvVp9 = $true; Tv4K = $true; TvHdr = $true; TvDv = $false; TvDts = $false; TvDtsMkv = $false; TvTrueHd = $false; TvFlac = $true }
    'Recent 4K TV with AV1 and Dolby Vision (2021 on)' = @{ TvHevc = $true; TvAv1 = $true; TvVp9 = $true; Tv4K = $true; TvHdr = $true; TvDv = $true; TvDts = $false; TvDtsMkv = $false; TvTrueHd = $false; TvFlac = $true }
    'Older HD TV (1080p, before 2016)'               = @{ TvHevc = $false; TvAv1 = $false; TvVp9 = $false; Tv4K = $false; TvHdr = $false; TvDv = $false; TvDts = $false; TvDtsMkv = $false; TvTrueHd = $false; TvFlac = $false }
}
# A TV picked by name always has that TV's ticks (a changed tick makes it "My own choice"), so settings
# saved before a ready-made TV was corrected or gained a tick pick the change up.
$tvPreset = $script:TvPresets[[string]$script:Settings.TvModel]
if ($tvPreset) { foreach ($k in $tvPreset.Keys) { $script:Settings[$k] = $tvPreset[$k] } }

# Which video and sound each file type can hold, for the TVs whose maker publishes it. Used while that TV is picked
# by name. Sony's (Help Guide for the XR-42A90K, Supported files and formats > Videos, "USB / Home Network"):
# https://helpguide.sony.net/tv/jaep1/v1/en/04-01-03_03.html  A line here for each line there, in ffprobe's names (MKV's Xvid and MPEG4 lines are both mpeg4, so one).
# It's for the TV's own player: apps on the TV may play more. Frame rates, levels and sample rates aren't checked.
$script:TvFileLists = @{
    'Sony BRAVIA XR-42A90K (2022)' = @(
        @{ Ext = 'mpg mpe mpeg'; Video = 'mpeg1video'; Sound = 'mp2'; Wide = 1920; High = 1080 }
        @{ Ext = 'mpg mpe mpeg'; Video = 'mpeg2video'; Sound = 'mp1 mp2 pcm_* ac3'; Wide = 1920; High = 1080 }
        @{ Ext = 'm2t'; Video = 'mpeg2video'; Sound = 'mp1 mp2 aac ac3 eac3'; Wide = 1920; High = 1080 }
        @{ Ext = 'm2ts mts'; Video = 'h264'; Sound = 'mp1 mp2 aac ac3 eac3'; Wide = 1920; High = 1080 }
        @{ Ext = 'mp4'; Video = 'h264'; Sound = 'aac ac3 eac3 ac4 mp1 mp2'; Wide = 1920; High = 1080 }
        @{ Ext = 'mp4'; Video = 'mpeg4'; Sound = 'aac ac3 eac3 mp1 mp2'; Wide = 1920; High = 1080 }
        @{ Ext = 'mp4'; Video = 'h264'; Sound = 'aac ac3 eac3 ac4 pcm_*'; Wide = 3840; High = 2160 }
        @{ Ext = 'mp4'; Video = 'hevc'; Sound = 'aac ac3 eac3 ac4'; Wide = 3840; High = 2160 }
        @{ Ext = 'avi'; Video = 'mpeg4'; Sound = 'mp1 mp2 mp3 ac3 eac3'; Wide = 1920; High = 1080 }
        @{ Ext = 'avi'; Video = 'mjpeg'; Sound = 'pcm_mulaw pcm_u8 pcm_s16le'; Wide = 1280; High = 720 }
        @{ Ext = 'asf wmv'; Video = 'vc1 wmv3'; Sound = 'wmav2'; Wide = 1920; High = 1080 }
        @{ Ext = 'mkv'; Video = 'mpeg4'; Sound = 'dts aac ac3 eac3 mp1 mp2 vorbis'; Wide = 1920; High = 1080 }
        @{ Ext = 'mkv'; Video = 'h264'; Sound = 'dts aac ac3 eac3 mp1 mp2 vorbis'; Wide = 1920; High = 1080 }
        @{ Ext = 'mkv'; Video = 'vp8'; Sound = 'dts aac ac3 eac3 mp1 mp2 vorbis'; Wide = 1920; High = 1080 }
        @{ Ext = 'mkv'; Video = 'vp9'; Sound = 'dts aac ac3 eac3 mp1 mp2 vorbis'; Wide = 3840; High = 2160 }
        @{ Ext = 'mkv'; Video = 'h264'; Sound = 'dts aac ac3 eac3'; Wide = 3840; High = 2160 }
        @{ Ext = 'mkv'; Video = 'hevc'; Sound = 'dts aac ac3 eac3'; Wide = 3840; High = 2160 }
        @{ Ext = '3gp 3g2'; Video = 'mpeg4'; Sound = 'aac ac3 eac3 mp1 mp2'; Wide = 1920; High = 1080 }
        @{ Ext = '3gp 3g2'; Video = 'h264'; Sound = 'aac ac3 eac3 mp1 mp2'; Wide = 1920; High = 1080 }
        @{ Ext = 'mov'; Video = 'h264'; Sound = 'aac ac3 eac3 mp1 mp2 pcm_mulaw pcm_u8 pcm_s16be pcm_s16le'; Wide = 1920; High = 1080 }
        @{ Ext = 'mov'; Video = 'mpeg4'; Sound = 'aac ac3 eac3 mp1 mp2 pcm_mulaw pcm_u8 pcm_s16be pcm_s16le'; Wide = 1920; High = 1080 }
        @{ Ext = 'mov'; Video = 'mjpeg'; Sound = 'aac ac3 eac3 mp1 mp2 pcm_mulaw pcm_u8 pcm_s16be pcm_s16le'; Wide = 1280; High = 720 }
        @{ Ext = 'webm'; Video = 'vp8'; Sound = 'vorbis'; Wide = 1920; High = 1080 }
        @{ Ext = 'webm'; Video = 'vp9'; Sound = 'vorbis'; Wide = 3840; High = 2160 }
    )
}

function Test-Item([MiItem]$Item) {
    <# What may stop it playing directly on the TV (as set in Settings > Your TV). #>
    $t = $script:Settings
    $p = New-Object Collections.Generic.List[string]
    $warn = { param($text, $level) $p.Add($text); if ($level -gt $script:sevNow) { $script:sevNow = $level } }
    $script:sevNow = 0
    if ($Item.Error) { & $warn "Couldn't be read: $($Item.Error)" 2 }
    elseif (-not $Item.VCodec) { & $warn 'No video stream found' 2 }
    else {
        $list = $script:TvFileLists[[string]$t.TvModel]
        $type = @(if ($list) { $list | Where-Object { ($_.Ext -split ' ') -contains $Item.Container } })   # its lines for this file type
        $lines = @()                                                                                        # and for this video in it
        if ($list -and -not $type.Count) { & $warn ".$($Item.Container) files aren't on your TV's list: may need converting" 1 }
        elseif ($type.Count) {
            $lines = @($type | Where-Object { ($_.Video -split ' ') -contains $Item.VCodec })
            if (-not $lines.Count) {
                if ($Item.VCodec -ne 'av1') { & $warn "$(Get-CodecName $Item.VCodec) video in a .$($Item.Container) file: not on your TV's list for that file type" 2 }
                $lines = $type
            } else {
                $long = [math]::Max($Item.Width, $Item.Height); $short = [math]::Min($Item.Width, $Item.Height)
                $fit = @($lines | Where-Object { $long -le $_.Wide -and $short -le $_.High + 8 })   # + 8: 1080p is often stored as 1088 lines
                if ($fit.Count) { $lines = $fit }
                else {
                    $most = $lines | Sort-Object { $_.Wide } -Descending | Select-Object -First 1
                    & $warn "$(Get-CodecName $Item.VCodec) at $($Item.Width)x$($Item.Height) in a .$($Item.Container) file: your TV's list stops at $($most.Wide)x$($most.High) for that" 2
                }
                if ($Item.VCodec -eq 'hevc' -and $Item.BitDepth -gt 10) { & $warn '12-bit HEVC: your TV''s list stops at 10-bit' 2 }
            }
        }
        switch -regex ($Item.VCodec) {
            '^hevc$'       { if (-not $t.TvHevc) { & $warn 'HEVC video: your TV may not play it' 2 } }
            '^av1$'        { if (-not $t.TvAv1) { & $warn 'AV1 video: most TVs before 2021 can''t play it' 2 } }
            '^vp9$'        { if (-not $t.TvVp9) { & $warn 'VP9 video: your TV may only play it in apps' 1 } }
            '^(mpeg4|msmpeg4v3|divx|xvid)$' { if (-not $type.Count) { & $warn 'Old XviD/DivX video: many TVs struggle with it' 1 } }
            '^(vc1|wmv3|wmv2)$'   { if (-not $type.Count) { & $warn 'VC-1/WMV video: often needs converting (most TVs play it only in .wmv files)' 1 } }
            '^(mpeg2video|mpeg1video)$' { if (-not $type.Count) { & $warn 'MPEG-2 video: large and often not played over the network' 1 } }
            '^(h264)$'     { if ($Item.BitDepth -gt 8) { & $warn '10-bit H.264: almost no TV plays it' 2 } }
        }
        if ($Item.Res -eq '4K' -and -not $t.Tv4K) { & $warn '4K: bigger than your TV shows' 1 }
        if ($Item.Width -gt 4096 -or $Item.Height -gt 2304) { & $warn "$($Item.Width)x$($Item.Height): bigger than 4K" 2 }
        if ($Item.Hdr -eq 'Dolby Vision' -and -not $t.TvDv) { & $warn 'Dolby Vision: may show wrong colours on your TV' 1 }
        elseif ($Item.Hdr -and $Item.Hdr -ne 'Dolby Vision' -and -not $t.TvHdr) { & $warn "$($Item.Hdr): your TV isn't set to show HDR" 1 }
        $ac = @($Item.AudioCodecs -split ',' | Where-Object { $_ })
        if (-not $ac.Count) { & $warn 'No sound track' 1 }
        else {
            # A sound bar or receiver on eARC takes TrueHD and DTS (all kinds) straight through. A TV that reads
            # DTS only from MKV can't pass it on from other files either, so that limit holds with eARC too.
            $dtsFileOk = (-not $t.TvDtsMkv) -or $Item.Container -eq 'mkv'
            $listed = @($lines | ForEach-Object { $_.Sound -split ' ' })
            $ok = @($ac | Where-Object {
                if ($lines.Count) {
                    $c = $_
                    if ($c -in 'truehd', 'mlp') { return [bool]($t.TvEarc -and $Item.Container -eq 'mkv') }   # handed on to the sound system
                    return @($listed | Where-Object { $c -like $_ }).Count -gt 0
                }
                switch -regex ($_) { '^dts$' { [bool]($dtsFileOk -and ($t.TvDts -or $t.TvEarc)) } '^(truehd|mlp)$' { [bool]($t.TvTrueHd -or $t.TvEarc) } '^(aac|ac3|eac3|ac4|mp3|mp2|vorbis)$' { $true } '^flac$' { [bool]$t.TvFlac } '^opus$' { $false } '^pcm' { $true } default { $false } }
            })
            if (-not $ok.Count) {
                $names = ($ac | ForEach-Object { Get-CodecName $_ }) -join ', '
                if (-not @($ac | Where-Object { $_ -ne 'flac' }).Count) { & $warn 'FLAC sound only: your TV can''t play it, so the media server has to convert the sound' 1 }
                elseif ($ac -contains 'dts' -and -not $dtsFileOk -and ($t.TvDts -or $t.TvEarc)) { & $warn "$names sound only, in a .$($Item.Container) file: your TV plays DTS only in MKV files, so it may be silent" 2 }
                elseif ($lines.Count) { & $warn "$names sound only, in a .$($Item.Container) file: not on your TV's list for that, so it may be silent" 2 }
                else { & $warn "$names sound only: your TV may play it silent" 2 }
            }
            if ($Item.Audio -match 'DTS-HD|DTS:X' -and $t.TvDts -and $ok -contains 'dts' -and -not $t.TvEarc -and -not @($ac | Where-Object { $_ -ne 'dts' }).Count) {
                & $warn 'DTS-HD sound: your TV plays its DTS core, not the full track' 0
            }
        }
        $sc = @($Item.SubCodecs -split ',' | Where-Object { $_ })
        if ($sc.Count -and -not @($sc | Where-Object { $_ -in 'subrip', 'ass', 'ssa', 'mov_text', 'webvtt' }).Count) { & $warn 'Picture subtitles only (PGS/VobSub): the server may need to burn them in' 1 }
        if ($type.Count -and $sc.Count -and $Item.Container -ne 'mkv') { & $warn "Subtitles inside a .$($Item.Container) file: your TV shows them only from MKV files, or from a separate .srt or .ass file" 0 }
        if (-not $list -and $Item.Container -in 'avi', 'wmv', 'flv', 'vob', 'mpg', 'mpeg', 'divx', 'ogm', '3gp') { & $warn "Old .$($Item.Container) file: often not played directly" 1 }
        if ($t.MaxMbps -and $Item.Mbps -gt [double]$t.MaxMbps) { & $warn "Very high bit rate ($($Item.Mbps) Mb/s): may stutter over Wi-Fi" 1 }
    }
    $Item.Problem = if ($p.Count) { $p -join '; ' } else { 'OK' }
    $Item.Severity = $script:sevNow
}

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
Media Info Report lists every video in your folders with its resolution, video format, sound, subtitles, size and length, and points out the ones your TV may not play directly. It only reads the files; it never changes them.

WHAT IT NEEDS
ffprobe, part of the free FFmpeg, reads the video details. If it isn't found, the app says how to get it (in a command window: winget install Gyan.FFmpeg), or you can point Settings... at your own ffprobe.exe.

SCANNING
Settings... sets the folders to scan (your Videos folder to begin with; NAS shares and mapped drives work too) and what your TV plays. Scan reads four files at a time in the background, and Stop ends it early. The results are kept, so the next scan only reads new or changed files; Scan all again reads everything.

WHAT THE COLOURS MEAN
Red: unlikely to play directly (for example a format your TV doesn't play, or sound it can't decode, so you'd see a picture with no sound). Amber: may need your media server to convert it, or may stutter. Green: should play.

YOUR TV
In Settings..., pick your TV (or the nearest) under Your TV: that ticks what it plays (HEVC, AV1, VP9, 4K, HDR, Dolby Vision, DTS, TrueHD and FLAC sound). Change any tick for your own choice. Tick the eARC box if a sound bar or AV receiver is plugged into the TV's eARC socket, as that takes TrueHD and DTS-HD sound straight through. Tick DTS in MKV files only if your TV reads DTS just from .mkv files: DTS in any other file is then flagged red (even with eARC) unless the file has another sound track the TV plays. You can also set the highest bit rate your TV copes with over your network. The checks follow those settings.
The Sony BRAVIA XR-42A90K (2022) choice takes its video and sound formats from Sony's list for that TV: H.264, HEVC (10-bit too) and VP9 up to 4K, no AV1; AAC, Dolby Digital, Dolby Digital Plus and DTS (the core track, in MKV files) sound. It doesn't play FLAC, and needs a sound system on eARC for TrueHD. While that TV is picked, each file type is checked against Sony's list too: which video and sound it can hold and how big the picture can be (for example VP9 only in MKV and WebM, MP3 only in AVI, and subtitles inside the file only in MKV). File types that aren't on the list are amber. Sony's list is for the TV's own player (USB and home network); Plex, Jellyfin and other apps on the TV may play more. Frame rates, levels and sample rates aren't checked. Changing a tick, other than eARC, makes it My own choice, which doesn't use the list. The HDR ticks and the other ready-made TVs are general guides, so check them against your own TV.

THE LIST
Problems only hides the ones that should play. Type in the search box to find a film by name, format or folder. Click a line to see everything about it on the right; double-click (or Play) to play it, and Open folder to see it in Explorer. Export... saves the list (or just what you have filtered) as an HTML report, to open in any browser, print or share, or as a CSV file for Excel.

LOOK
The Look button switches between Light, Dark and the same as Windows, from the next start.
'@

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" Height="580" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "$script:AppName Help"
    $w.FindName('HelpText').Text = $script:HelpText
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Settings: folders, ffprobe and the TV
# ---------------------------------------------------------------------------
function Show-SettingsWindow {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="600" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,0,18,8"/></Style>
    <Style x:Key="Head" TargetType="TextBlock"><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{Accent}"/></Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock Text="Video folders" Style="{StaticResource Head}"/>
    <TextBlock Text="One per line. Mapped drives and \\server\share paths work too." Margin="0,6,0,0" Foreground="{Soft}"/>
    <TextBox x:Name="FRoots" Height="74" Margin="0,6,0,0" AcceptsReturn="True" VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"/>
    <Button x:Name="FAdd" Content="Add folder..." HorizontalAlignment="Left" Margin="0,8,0,0"/>
    <TextBlock Text="ffprobe.exe (blank: found by itself)" Margin="0,14,0,4"/>
    <DockPanel><Button x:Name="FPick" Content="..." DockPanel.Dock="Right" Margin="6,0,0,0" Padding="10,4"/><TextBox x:Name="FProbe"/></DockPanel>
    <TextBlock x:Name="FProbeNote" Foreground="{Soft}" TextWrapping="Wrap" Margin="0,6,0,0"/>

    <Border BorderBrush="{Line}" BorderThickness="0,1,0,0" Margin="0,16,0,12"/>
    <TextBlock Text="Your TV" Style="{StaticResource Head}"/>
    <ComboBox x:Name="TModel" Margin="0,8,0,0" ToolTip="Pick your TV (or the nearest) to set the ticks below"/>
    <TextBlock x:Name="TNote" Foreground="{Soft}" TextWrapping="Wrap" Margin="0,6,0,0"/>
    <TextBlock Text="It plays:" Foreground="{Soft}" Margin="0,10,0,0"/>
    <WrapPanel Margin="0,6,0,0">
      <CheckBox x:Name="THevc" Content="HEVC (H.265)"/>
      <CheckBox x:Name="TAv1" Content="AV1"/>
      <CheckBox x:Name="TVp9" Content="VP9"/>
      <CheckBox x:Name="T4K" Content="4K"/>
      <CheckBox x:Name="THdr" Content="HDR10 / HLG"/>
      <CheckBox x:Name="TDv" Content="Dolby Vision"/>
      <CheckBox x:Name="TDts" Content="DTS sound"/>
      <CheckBox x:Name="TDtsMkv" Content="DTS in MKV files only"/>
      <CheckBox x:Name="TTrue" Content="TrueHD sound"/>
      <CheckBox x:Name="TFlac" Content="FLAC sound"/>
    </WrapPanel>
    <CheckBox x:Name="TEarc" Margin="0,4,0,8"><TextBlock TextWrapping="Wrap" Text="A sound bar or AV receiver on the TV's eARC socket (it takes TrueHD, DTS-HD, Atmos and DTS:X sound straight through)"/></CheckBox>
    <DockPanel Margin="0,6,0,0">
      <TextBox x:Name="TMax" DockPanel.Dock="Right" Width="80"/>
      <TextBlock Text="Highest bit rate it plays smoothly over your network (Mb/s, blank for no limit)" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,10,0"/>
    </DockPanel>
    <DockPanel Margin="0,20,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="FOk" Content="Save" Style="{StaticResource Accent}" MinWidth="90" IsDefault="True"/>
        <Button x:Name="FCancel" Content="Close" MinWidth="80" Margin="0" IsCancel="True"/>
      </StackPanel>
      <TextBlock x:Name="FSaved" Foreground="{Good}" VerticalAlignment="Center"/>
    </DockPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'Settings'
    $roots = $w.FindName('FRoots'); $roots.Text = (@($script:Settings.Roots) -join "`r`n")
    $probe = $w.FindName('FProbe'); $probe.Text = [string]$script:Settings.FFprobe
    $note = $w.FindName('FProbeNote')
    $found = Find-FFprobe
    $note.Text = if ($found) { "Using $found" } else { "Not found. Install it with: winget install Gyan.FFmpeg (in a command window), then press Save." }
    $boxes = @{ TvHevc = 'THevc'; TvAv1 = 'TAv1'; TvVp9 = 'TVp9'; Tv4K = 'T4K'; TvHdr = 'THdr'; TvDv = 'TDv'; TvDts = 'TDts'; TvDtsMkv = 'TDtsMkv'; TvTrueHd = 'TTrue'; TvFlac = 'TFlac'; TvEarc = 'TEarc' }
    foreach ($k in $boxes.Keys) { $w.FindName($boxes[$k]).IsChecked = [bool]$script:Settings[$k] }
    # Picking a TV sets the ticks; changing a tick by hand makes it "My own choice".
    $own = 'My own choice'
    $model = $w.FindName('TModel')
    foreach ($n in @($script:TvPresets.Keys) + $own) { [void]$model.Items.Add($n) }
    $model.SelectedItem = if ($script:TvPresets.Contains([string]$script:Settings.TvModel)) { [string]$script:Settings.TvModel } else { $own }
    $tv = @{ Setting = $false }
    $showNote = {
        $tNote = $w.FindName('TNote')
        if ($script:TvFileLists.ContainsKey([string]$model.SelectedItem)) {
            $tNote.Text = "Each file type is also checked against the maker's list for the TV's own player (apps on the TV may play more). Changing a tick below, other than eARC, turns that off."
            $tNote.Visibility = 'Visible'
        } else { $tNote.Visibility = 'Collapsed' }
    }
    & $showNote
    $model.Add_SelectionChanged({
        & $showNote
        $pre = $script:TvPresets[[string]$model.SelectedItem]
        if (-not $pre) { return }
        $tv.Setting = $true
        foreach ($k in $pre.Keys) { $w.FindName($boxes[$k]).IsChecked = $pre[$k] }
        $tv.Setting = $false
    })
    foreach ($k in $boxes.Keys) {
        if ($k -eq 'TvEarc') { continue }
        $cb = $w.FindName($boxes[$k])
        $onTick = { if (-not $tv.Setting -and [string]$model.SelectedItem -ne $own) { $model.SelectedItem = $own } }
        $cb.Add_Checked($onTick); $cb.Add_Unchecked($onTick)
    }
    $w.FindName('TMax').Text = if ($script:Settings.MaxMbps) { [string]$script:Settings.MaxMbps } else { '' }
    $saved = $w.FindName('FSaved')
    $w.FindName('FAdd').Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose a folder with videos'
        if ($dlg.ShowDialog() -eq 'OK') { $roots.Text = (($roots.Text.TrimEnd() + "`r`n" + $dlg.SelectedPath).Trim()) }
    })
    $w.FindName('FPick').Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'ffprobe (ffprobe.exe)|ffprobe.exe|Programs (*.exe)|*.exe'
        if ($dlg.ShowDialog($w)) { $probe.Text = $dlg.FileName }
    })
    $w.FindName('FOk').Add_Click({
        $script:Settings.Roots = @($roots.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $script:Settings.FFprobe = $probe.Text.Trim()
        foreach ($k in $boxes.Keys) { $script:Settings[$k] = [bool]$w.FindName($boxes[$k]).IsChecked }
        $script:Settings.TvModel = [string]$model.SelectedItem
        $m = $w.FindName('TMax').Text.Trim()
        $script:Settings.MaxMbps = if ($m -match '^\d+(\.\d+)?$') { [double]$m } else { 0 }
        Save-AppSetting
        $f = Find-FFprobe
        $note.Text = if ($f) { "Using $f" } else { "Not found. Install it with: winget install Gyan.FFmpeg (in a command window), then press Save." }
        foreach ($i in $script:Items) { Test-Item $i }
        [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh()
        Update-Summary
        $saved.Text = "Saved at $((Get-Date).ToString('HH:mm:ss'))."
    })
    $w.FindName('FCancel').Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1280" Height="760" MinWidth="800" MinHeight="440" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{Ink}"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style x:Key="ProblemText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Good}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Problem}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Severity}" Value="1"><Setter Property="Foreground" Value="{Warn}"/></DataTrigger>
        <DataTrigger Binding="{Binding Severity}" Value="2"><Setter Property="Foreground" Value="{Bad}"/><Setter Property="FontWeight" Value="SemiBold"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Text, RelativeSource={RelativeSource Self}}"/></Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Soft}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,7"/><Setter Property="BorderBrush" Value="{Line}"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Ink}"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{Hover}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{Select}"/><Setter Property="Foreground" Value="{Ink}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ProgressBar"><Setter Property="Foreground" Value="{Accent}"/><Setter Property="Background" Value="{Line}"/><Setter Property="BorderThickness" Value="0"/></Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="0,1,0,0" Padding="18,12" MinHeight="60">
      <DockPanel VerticalAlignment="Center">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnExport" Content="Export..." ToolTip="Save the list as an HTML report or a CSV file for Excel"/>
          <Button x:Name="BtnLook"/>
          <Button x:Name="BtnHelp" Content="Help"/>
          <Button x:Name="BtnAbout" Content="About" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="{Soft}" Margin="0,0,16,0"/>
      </DockPanel>
    </Border>
    <ProgressBar x:Name="Progress" DockPanel.Dock="Bottom" Height="3" Visibility="Hidden"/>
    <DockPanel DockPanel.Dock="Top" Margin="18,14,18,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="BtnSettings" Content="Settings..." ToolTip="The video folders, ffprobe and what your TV plays"/>
        <Button x:Name="BtnAll" Content="Scan all again" ToolTip="Read every file again, not just new or changed ones"/>
        <Button x:Name="BtnScan" Content="Scan" Style="{StaticResource Accent}" MinWidth="90" Margin="0"/>
      </StackPanel>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="TxtSummary" FontSize="16" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="TxtTotals" Foreground="{Soft}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DockPanel>
    <DockPanel DockPanel.Dock="Top" Margin="18,10,18,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <CheckBox x:Name="ChkProblems" Content="Problems only" Margin="0,0,14,0" IsChecked="True"/>
        <Grid Width="240">
          <TextBox x:Name="TxtSearch" ToolTip="Find a video by name, format or folder"/>
          <TextBlock x:Name="TxtHint" Text="Search" Foreground="{Soft}" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Grid>
      </StackPanel>
      <Border x:Name="Banner" Background="{UpdateBack}" CornerRadius="6" Padding="12,8" Visibility="Collapsed" Margin="0,0,14,0">
        <DockPanel>
          <Button x:Name="BtnCopyCmd" DockPanel.Dock="Right" Content="Copy the command" Margin="10,0,0,0" Padding="10,3"/>
          <TextBlock x:Name="TxtBanner" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>
    </DockPanel>
    <Grid Margin="18,12,18,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="320"/></Grid.ColumnDefinitions>
      <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column" RowHeaderWidth="0"
                Background="{Card}" RowBackground="{Card}" Foreground="{Ink}" BorderBrush="{Line}" BorderThickness="1"
                GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{Line}" CanUserResizeRows="False" EnableRowVirtualization="True">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Problem" Width="2.2*" Binding="{Binding Problem}" ElementStyle="{StaticResource ProblemText}" SortMemberPath="Severity"/>
          <DataGridTextColumn Header="Name" Width="2*" Binding="{Binding Name}" ElementStyle="{StaticResource Cell}"/>
          <DataGridTextColumn Header="Res" Width="60" Binding="{Binding Res}"/>
          <DataGridTextColumn Header="Video" Width="1.1*" Binding="{Binding Video}" ElementStyle="{StaticResource Cell}"/>
          <DataGridTextColumn Header="Sound" Width="1.3*" Binding="{Binding Audio}" ElementStyle="{StaticResource Cell}"/>
          <DataGridTextColumn Header="Size" Width="80" Binding="{Binding Size}" SortMemberPath="Bytes"/>
          <DataGridTextColumn Header="Length" Width="74" Binding="{Binding Length}" SortMemberPath="Seconds"/>
        </DataGrid.Columns>
      </DataGrid>
      <Border Grid.Column="1" Margin="12,0,0,0" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,14">
        <DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnPlay" Content="Play" IsEnabled="False"/>
            <Button x:Name="BtnFolder" Content="Open folder" Margin="0" IsEnabled="False"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock x:Name="DName" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Text="Click a video to see its details."/>
              <TextBlock x:Name="DProblem" TextWrapping="Wrap" Margin="0,8,0,0"/>
              <Grid x:Name="DGrid" Margin="0,12,0,0"/>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Set-Status([string]$Text, [string]$Tone = 'Soft') {
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = Get-Brush $Tone
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

$script:Items = New-Object Collections.ObjectModel.ObservableCollection[MiItem]
$script:ResultsPath = Join-Path $script:DataDir 'results.json'

function Save-Results {
    try { @($script:Items | Select-Object Name, Folder, Path, Bytes, Ticks, Size, Res, Width, Height, Video, VCodec, BitDepth, Hdr, Audio, AudioCodecs, Subs, SubCodecs, Container, Seconds, Length, Mbps, Rate, Error) |
          ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $script:ResultsPath -Encoding UTF8 }
    catch { Write-AppLog "results.json couldn't be saved: $($_.Exception.Message)" }
}

function Read-Results {
    if (-not (Test-Path -LiteralPath $script:ResultsPath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:ResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json   # kept in a variable: Windows PowerShell passes a JSON array on as one item
        foreach ($r in $saved) {
            $i = New-Object MiItem
            foreach ($p in $r.PSObject.Properties) { try { $i.($p.Name) = $p.Value } catch { Write-Verbose "skip $($p.Name)" } }
            Test-Item $i
            $script:Items.Add($i)
        }
    } catch { Write-AppLog "results.json couldn't be read: $($_.Exception.Message)" }
}

function Update-Summary {
    $all = @($script:Items)
    $red = @($all | Where-Object { $_.Severity -eq 2 }).Count
    $amber = @($all | Where-Object { $_.Severity -eq 1 }).Count
    $ui = $script:UI
    $ui.TxtSummary.Text = if (-not $all.Count) { 'No videos read yet. Press Scan.' } elseif ($red + $amber) { "$red unlikely to play, $amber may need converting, in $($all.Count) videos" } else { "All $($all.Count) videos should play" }
    $ui.TxtSummary.Foreground = Get-Brush $(if ($red) { 'Bad' } else { 'Ink' })
    if ($all.Count) {
        $bytes = ($all | Measure-Object Bytes -Sum).Sum
        $hours = [int](($all | Measure-Object Seconds -Sum).Sum / 3600)
        $byRes = ($all | Where-Object Res | Group-Object Res | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        $ui.TxtTotals.Text = "$(Format-Size $bytes)  ·  $hours hours  ·  $byRes"
    } else { $ui.TxtTotals.Text = "Folders: $(if (@($script:Settings.Roots).Count) { @($script:Settings.Roots) -join ', ' } else { 'none yet (Settings...)' })" }
}

function Update-View {
    $problems = [bool]$script:UI.ChkProblems.IsChecked
    $q = $script:UI.TxtSearch.Text.Trim()
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $test = {
        param($i)
        if ($problems -and $i.Severity -eq 0) { return $false }
        if ($q -and -not (($i.Name -like "*$q*") -or ($i.Video -like "*$q*") -or ($i.Audio -like "*$q*") -or ($i.Folder -like "*$q*") -or ($i.Problem -like "*$q*") -or ($i.Res -eq $q))) { return $false }
        return $true
    }.GetNewClosure()
    $view.Filter = [Predicate[object]]$test
    Update-Summary
}

function Show-Details {
    $i = $script:UI.Grid.SelectedItem
    $ui = $script:UI
    $ui.DGrid.Children.Clear(); $ui.DGrid.RowDefinitions.Clear(); $ui.DGrid.ColumnDefinitions.Clear()
    $ui.BtnPlay.IsEnabled = $false; $ui.BtnFolder.IsEnabled = $false
    if (-not ($i -is [MiItem])) { $ui.DName.Text = 'Click a video to see its details.'; $ui.DProblem.Text = ''; return }
    $ui.DName.Text = $i.Name
    $ui.DProblem.Text = $i.Problem -replace '; ', "`n"
    $ui.DProblem.Foreground = Get-Brush $(switch ($i.Severity) { 2 { 'Bad' } 1 { 'Warn' } default { 'Good' } })
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'; $ui.DGrid.ColumnDefinitions.Add($c1)
    $ui.DGrid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    $rows = @(
        @('Picture', $(if ($i.Width) { "$($i.Width) x $($i.Height)  ($($i.Res))" })),
        @('Video', $i.Video), @('Sound', $i.Audio), @('Subtitles', $(if ($i.Subs) { $i.Subs } else { 'None' })),
        @('File', ".$($i.Container)  ·  $($i.Size)"), @('Length', $i.Length), @('Bit rate', $i.Rate), @('Folder', $i.Folder))
    $r = 0
    foreach ($row in $rows) {
        if (-not $row[1]) { continue }
        $ui.DGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $a = New-Object Windows.Controls.TextBlock; $a.Text = $row[0]; $a.Foreground = Get-Brush 'Soft'; $a.Margin = '0,0,14,8'
        $b = New-Object Windows.Controls.TextBlock; $b.Text = $row[1]; $b.TextWrapping = 'Wrap'; $b.Margin = '0,0,0,8'
        [Windows.Controls.Grid]::SetRow($a, $r); [Windows.Controls.Grid]::SetRow($b, $r); [Windows.Controls.Grid]::SetColumn($b, 1)
        [void]$ui.DGrid.Children.Add($a); [void]$ui.DGrid.Children.Add($b); $r++
    }
    $ui.BtnPlay.IsEnabled = $true; $ui.BtnFolder.IsEnabled = $true
}

function Show-ProbeBanner {
    $f = Find-FFprobe
    $script:UI.Banner.Visibility = if ($f) { 'Collapsed' } else { 'Visible' }
    $script:UI.TxtBanner.Text = 'ffprobe (part of the free FFmpeg) is needed to read the videos. Install it in a command window with: winget install Gyan.FFmpeg, then press Scan. Or set its place in Settings...'
    return $f
}

# ---------------------------------------------------------------------------
#  Scanning
# ---------------------------------------------------------------------------
$script:Scan = $null

function Start-Scan([switch]$All) {
    if ([MiProbe]::Busy) { [MiProbe]::Cancel = $true; Set-Status 'Stopping...'; return }
    $ff = Show-ProbeBanner
    if (-not $ff) { Set-Status 'Install ffprobe first (see the yellow note).' 'Warn'; return }
    $roots = @($script:Settings.Roots | Where-Object { $_ })
    if (-not $roots.Count) { Show-SettingsWindow; $roots = @($script:Settings.Roots | Where-Object { $_ }); if (-not $roots.Count) { return } }
    Set-Status 'Finding the videos...'
    $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    $files = New-Object Collections.Generic.List[IO.FileInfo]
    $missing = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { $missing += $r; continue }
        try {
            foreach ($f in ([IO.DirectoryInfo]$r).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
                if ($script:VideoExt -contains $f.Extension.ToLowerInvariant() -and $f.Name -notmatch '(?i)(-sample|\.sample|-trailer|^trailer)\.') { $files.Add($f) }
            }
        } catch { Write-AppLog "Folder $($r): $($_.Exception.Message)"; $missing += $r }
    }
    # Keep what was read before when the file hasn't changed; read the rest.
    $old = @{}
    foreach ($i in $script:Items) { $old[$i.Path] = $i }
    $script:Items.Clear()
    $todo = New-Object Collections.Generic.List[string]
    $script:Pending = @{}
    foreach ($f in $files) {
        $prev = $old[$f.FullName]
        if (-not $All -and $prev -and $prev.Bytes -eq $f.Length -and $prev.Ticks -eq $f.LastWriteTimeUtc.Ticks -and -not $prev.Error) { $script:Items.Add($prev); continue }
        $i = New-Object MiItem
        $i.Name = $f.BaseName; $i.Folder = $f.DirectoryName; $i.Path = $f.FullName; $i.Bytes = $f.Length; $i.Ticks = $f.LastWriteTimeUtc.Ticks
        $i.Size = Format-Size $f.Length; $i.Container = $f.Extension.TrimStart('.').ToLowerInvariant()
        $script:Pending[$f.FullName] = $i
        $todo.Add($f.FullName)
    }
    Update-View
    if ($missing.Count) { Write-AppLog "Not found: $($missing -join '; ')" }
    if (-not $todo.Count) {
        Save-Results
        Set-Status ("{0} videos, nothing new or changed to read.{1}" -f $files.Count, $(if ($missing.Count) { " Not found: $($missing -join ', ')" } else { '' })) $(if ($missing.Count) { 'Warn' } else { 'Soft' })
        return
    }
    $script:Scan = [pscustomobject]@{ Started = Get-Date; Count = $todo.Count; Missing = $missing; Found = $files.Count }
    [MiProbe]::Start($ff, $todo.ToArray(), 4)
    $script:UI.BtnScan.Content = 'Stop'; $script:UI.BtnAll.IsEnabled = $false
    $script:UI.Progress.Visibility = 'Visible'; $script:UI.Progress.Maximum = $todo.Count
    Write-AppLog "Scan: $($todo.Count) of $($files.Count) videos to read"
}

function Update-Scan {
    if (-not $script:Scan) { return }
    $r = $null; $n = 0
    while ([MiProbe]::Results.TryDequeue([ref]$r)) {
        $i = $script:Pending[$r[0]]
        if (-not $i) { continue }
        if ($r[2] -eq '1') { try { ConvertFrom-Probe $i $r[1] } catch { $i.Error = $_.Exception.Message } } else { $i.Error = if ($r[1]) { ($r[1] -split "`n")[0] } else { 'unknown error' } }
        Test-Item $i
        $script:Items.Add($i); $n++
    }
    if ($n) { Update-Summary }
    $script:UI.Progress.Value = [MiProbe]::Done
    if ([MiProbe]::Busy) { Set-Status ("Reading videos: {0} of {1}..." -f [MiProbe]::Done, [MiProbe]::Total); return }
    if ($n) { return }   # one more tick to take the last results
    $s = $script:Scan; $script:Scan = $null
    $script:UI.BtnScan.Content = 'Scan'; $script:UI.BtnAll.IsEnabled = $true
    $script:UI.Progress.Visibility = 'Hidden'
    Save-Results
    Update-View
    $secs = [int]((Get-Date) - $s.Started).TotalSeconds
    $errs = @($script:Items | Where-Object Error).Count
    $msg = if ([MiProbe]::Cancel) { "Stopped after $([MiProbe]::Done) of $($s.Count)." } else { "Read $($s.Count) videos in $secs s ($($s.Found) in all) at $((Get-Date).ToString('HH:mm'))." }
    if ($errs) { $msg += " $errs couldn't be read." }
    if ($s.Missing.Count) { $msg += " Not found: $($s.Missing -join ', ')." }
    Set-Status $msg $(if ($errs -or $s.Missing.Count) { 'Warn' } else { 'Soft' })
    Write-AppLog $msg
}

function Get-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

function Export-Html([string]$Path, [array]$Rows) {
    $red = @($Rows | Where-Object { $_.Severity -eq 2 }).Count
    $amber = @($Rows | Where-Object { $_.Severity -eq 1 }).Count
    $bytes = ($Rows | Measure-Object -Property Bytes -Sum).Sum
    $hours = [math]::Round(($Rows | Measure-Object -Property Seconds -Sum).Sum / 3600)
    $byRes = (@($Rows | Where-Object Res | Group-Object Res | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" })) -join ', '
    $sb = New-Object Text.StringBuilder
    foreach ($i in $Rows) {
        $cls = switch ($i.Severity) { 2 { 'bad' } 1 { 'warn' } default { 'good' } }
        [void]$sb.AppendLine("<tr class=""$cls""><td class=""nm"" title=""$(Get-HtmlText $i.Path)"">$(Get-HtmlText $i.Name)</td><td class=""pr"">$(Get-HtmlText $i.Problem)</td><td>$(Get-HtmlText $i.Res)</td><td>$(Get-HtmlText $i.Video)</td><td>$(Get-HtmlText $i.Audio)</td><td>$(Get-HtmlText $i.Subs)</td><td class=""n"" data-v=""$($i.Bytes)"">$(Get-HtmlText $i.Size)</td><td class=""n"" data-v=""$([int]$i.Seconds)"">$(Get-HtmlText $i.Length)</td><td class=""n"" data-v=""$($i.Mbps)"">$(Get-HtmlText $i.Rate)</td><td class=""fd"">$(Get-HtmlText $i.Folder)</td></tr>")
    }
    $title = "Media info, $((Get-Date).ToString('d MMMM yyyy'))"
    $tv = [string]$script:Settings.TvModel
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { --page:#F3F5F8; --card:#FFFFFF; --line:#D7DCE3; --ink:#1E2530; --soft:#5E6875; --good:#1E7B45; --warn:#A35A00; --bad:#B3261E; }
@media (prefers-color-scheme: dark) { :root { --page:#16191E; --card:#1F242B; --line:#343B45; --ink:#E6E9EE; --soft:#9AA3AE; --good:#5CC48A; --warn:#E8A33D; --bad:#F2766B; } }
body { margin:0; padding:24px; background:var(--page); color:var(--ink); font:14px/1.4 "Segoe UI", system-ui, sans-serif; }
h1 { font-size:22px; margin:0 0 4px; } .sum { color:var(--soft); margin:0 0 4px; } .sum b { color:var(--ink); }
.bar { display:flex; gap:16px; align-items:center; flex-wrap:wrap; margin:14px 0 12px; }
input[type=search] { font:inherit; padding:7px 10px; width:min(360px, 100%); border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--ink); }
table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); }
th { text-align:left; color:var(--soft); font-weight:600; padding:9px 10px; border-bottom:1px solid var(--line); cursor:pointer; white-space:nowrap; user-select:none; }
td { padding:6px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
td.nm { font-weight:600; } td.n { white-space:nowrap; text-align:right; } td.fd { color:var(--soft); font-size:12px; }
tr.good td.pr { color:var(--good); } tr.warn td.pr { color:var(--warn); } tr.bad td.pr { color:var(--bad); font-weight:600; }
.foot { color:var(--soft); margin-top:12px; font-size:12px; }
@media print { body { padding:0; background:#fff; color:#000; } .bar { display:none; } tr { break-inside:avoid; } }
</style></head><body>
<h1>$(Get-HtmlText $title)</h1>
<p class="sum"><b>$($Rows.Count) video$(if ($Rows.Count -ne 1) { 's' })</b>: $red unlikely to play, $amber may need converting, $($Rows.Count - $red - $amber) should play$(if ($tv) { ", on $(Get-HtmlText $tv)" }).</p>
<p class="sum">$(Format-Size $bytes)  ·  $hours hours  ·  $(Get-HtmlText $byRes)</p>
<div class="bar"><input id="q" type="search" placeholder="Search" aria-label="Search"><label><input id="p" type="checkbox"> Only the ones with problems</label></div>
<table id="t"><thead><tr><th>Name</th><th>Plays on the TV?</th><th>Res</th><th>Video</th><th>Sound</th><th>Subtitles</th><th>Size</th><th>Length</th><th>Bit rate</th><th>Folder</th></tr></thead>
<tbody>
$($sb.ToString())</tbody></table>
<p class="foot">Made by Media Info Report v$script:AppVersion with ffprobe.</p>
<script>
var q = document.getElementById('q'), pc = document.getElementById('p'), rows = Array.prototype.slice.call(document.querySelectorAll('#t tbody tr'));
function show() { var s = q.value.toLowerCase(); rows.forEach(function (r) { r.style.display = (r.textContent.toLowerCase().indexOf(s) >= 0 && (!pc.checked || !r.classList.contains('good'))) ? '' : 'none'; }); }
q.addEventListener('input', show); pc.addEventListener('change', show);
document.querySelectorAll('#t th').forEach(function (th, n) {
  th.addEventListener('click', function () {
    var up = th.dataset.up !== '1'; th.dataset.up = up ? '1' : '0';
    var b = document.querySelector('#t tbody');
    rows.sort(function (x, y) {
      var a = x.cells[n], c = y.cells[n];
      if (a.dataset.v !== undefined) return (up ? 1 : -1) * (parseFloat(a.dataset.v || 0) - parseFloat(c.dataset.v || 0));
      return (up ? 1 : -1) * a.textContent.localeCompare(c.textContent, undefined, { numeric: true, sensitivity: 'base' });
    });
    rows.forEach(function (r) { b.appendChild(r); });
  });
});
</script>
</body></html>
"@
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
}

function Export-List {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'HTML report (*.html)|*.html|CSV file for Excel (*.csv)|*.csv'
    $dlg.FileName = "Media info $((Get-Date).ToString('yyyy-MM-dd'))"
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $rows = @([Windows.Data.CollectionViewSource]::GetDefaultView($script:Items))
    if ($dlg.FileName -match '\.html?$') {
        Export-Html $dlg.FileName $rows
        Set-Status "Saved the report of $($rows.Count) video$(if ($rows.Count -ne 1) { 's' }): $($dlg.FileName)" 'Good'
        if (Show-AppMessage "Saved the report of $($rows.Count) video$(if ($rows.Count -ne 1) { 's' }).`n`nOpen it now?" -YesText 'Open' -NoText 'Close') { Start-Process $dlg.FileName }
    } else {
        $rows | Select-Object Name, Problem, Res, Width, Height, Video, Hdr, Audio, Subs, Container, Size, Bytes, Length, Rate, Folder |
            Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Saved $($rows.Count) video$(if ($rows.Count -ne 1) { 's' }) to $($dlg.FileName)" 'Good'
    }
}

try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    $window.Title = "$script:AppName v$script:AppVersion"
    $icon = Get-AssetImage 'Media-Info-Report.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnExport', 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'Progress', 'BtnSettings', 'BtnAll', 'BtnScan', 'TxtSummary', 'TxtTotals',
                   'ChkProblems', 'TxtSearch', 'TxtHint', 'Banner', 'BtnCopyCmd', 'TxtBanner', 'Grid', 'BtnPlay', 'BtnFolder', 'DName', 'DProblem', 'DGrid') { $ui[$n] = $window.FindName($n) }
    $script:UI = $ui
    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })
    $ui.BtnSettings.Add_Click({ Invoke-Safely { Show-SettingsWindow; [void](Show-ProbeBanner); Update-Summary } })
    $ui.BtnScan.Add_Click({ Invoke-Safely { Start-Scan } })
    $ui.BtnAll.Add_Click({ Invoke-Safely { Start-Scan -All } })
    $ui.BtnExport.Add_Click({ Invoke-Safely { Export-List } })
    $ui.BtnCopyCmd.Add_Click({ [Windows.Clipboard]::SetText('winget install Gyan.FFmpeg'); Set-Status 'Copied: winget install Gyan.FFmpeg. Paste it in a command window, then press Scan.' })
    $ui.BtnPlay.Add_Click({ Invoke-Safely { $i = $ui.Grid.SelectedItem; if ($i) { Start-Process -FilePath $i.Path } } })
    $ui.BtnFolder.Add_Click({ Invoke-Safely { $i = $ui.Grid.SelectedItem; if ($i) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($i.Path)`"" } } })
    $ui.Grid.Add_MouseDoubleClick({ Invoke-Safely { $i = $ui.Grid.SelectedItem; if ($i) { Start-Process -FilePath $i.Path } } })
    $ui.Grid.Add_SelectionChanged({ Show-Details })
    $ui.ChkProblems.Add_Click({ Update-View })
    $ui.TxtSearch.Add_TextChanged({ $ui.TxtHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }; Update-View })
    $ui.Grid.ItemsSource = $script:Items
    $sortView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    foreach ($sd in @(@('Severity', 'Descending'), @('Name', 'Ascending'))) { $sortView.SortDescriptions.Add((New-Object ComponentModel.SortDescription $sd[0], $sd[1])) }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ try { Update-Scan } catch { Write-AppLog "Update: $($_.Exception.Message)" } })
    $window.Add_ContentRendered({
        Invoke-Safely {
            Set-Status 'Reading the last scan...'
            $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
            Read-Results
            Update-View
            [void](Show-ProbeBanner)
            Set-Status $(if ($script:Items.Count) { "Last scan $((Get-Item -LiteralPath $script:ResultsPath).LastWriteTime.ToString('d MMM HH:mm')). Press Scan to check for new or changed videos." } else { 'Press Scan to read your videos (Settings... sets the folders).' })
            $timer.Start()
        }
    })
    $window.Add_Closing({ [MiProbe]::Cancel = $true })
    $window.Add_Closed({ $timer.Stop() })
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}
