# Caelocord - Windows 10/11 screen recording studio
# Records MP4 files locally; it does not upload video to any server.
# With the user's approval, FFmpeg is downloaded from gyan.dev on first use.

$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    $dpiCode = @'
using System;
using System.Runtime.InteropServices;
public static class ScreenDpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
    Add-Type -TypeDefinition $dpiCode -ErrorAction SilentlyContinue
    [void][ScreenDpi]::SetProcessDPIAware()

    # Windows 10 (2004+) allows a visible control window to be excluded from captures.
    # WPF window handle belongs to this process, satisfying the Win32 API requirement.
    $captureCode = @'
using System;
using System.Runtime.InteropServices;
public static class CaeloCaptureWindow {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);
    [DllImport("dwmapi.dll")]
    public static extern int DwmFlush();
}
'@
    Add-Type -TypeDefinition $captureCode -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine('WPF initialization error: ' + $_.Exception.ToString())
    [System.Windows.MessageBox]::Show("Unable to initialize the interface: $($_.Exception.Message)", 'Caelocord') | Out-Null
    exit 1
}

$script:rootDir = Join-Path $env:LOCALAPPDATA 'Caelocord'
$script:localFfmpeg = Join-Path $script:rootDir 'ffmpeg.exe'
$script:ffmpeg = $null
$script:downloadJob = $null
$script:recordProcess = $null
$script:recordPath = $null
$script:lastSaved = $null
$script:stopRequested = $false
$script:stopDeadline = [DateTime]::MinValue
$script:elapsed = New-Object System.Diagnostics.Stopwatch
$script:micRefreshPending = $false
$script:captureExclusionActive = $false

function Find-Ffmpeg {
    # A portable offline distribution may include ffmpeg.exe next to Launch.bat
    # or under bin\. No system-wide installation is necessary.
    $candidates = @(
        (Join-Path $PSScriptRoot 'ffmpeg.exe'),
        (Join-Path $PSScriptRoot 'bin\ffmpeg.exe'),
        $script:localFfmpeg,
        (Join-Path $env:LOCALAPPDATA 'Recordium\ffmpeg.exe'),
        (Join-Path $env:LOCALAPPDATA 'KareKayit\ffmpeg.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }
    return $null
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Cælōcord | Blue Moon" Width="1080" Height="750"
        MinWidth="960" MinHeight="680" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanResize" Background="#040A16"
        Foreground="#ECF8FF" FontFamily="Segoe UI" FontSize="13">
 <shell:WindowChrome.WindowChrome>
   <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="7" GlassFrameThickness="0" CornerRadius="0" />
 </shell:WindowChrome.WindowChrome>
 <Window.Resources>
   <SolidColorBrush x:Key="Ink" Color="#F1FBFF"/>
   <SolidColorBrush x:Key="Muted" Color="#94B6CE"/>
   <SolidColorBrush x:Key="Accent" Color="#35D2FF"/>
   <LinearGradientBrush x:Key="HeroSurface" StartPoint="0,0" EndPoint="1,1">
     <GradientStop Color="#102D4C" Offset="0"/>
     <GradientStop Color="#0B1F3A" Offset="0.52"/>
     <GradientStop Color="#071429" Offset="1"/>
   </LinearGradientBrush>
   <LinearGradientBrush x:Key="PrimaryGradient" StartPoint="0,0" EndPoint="1,0.3">
     <GradientStop Color="#67EBFF" Offset="0"/>
     <GradientStop Color="#159FEB" Offset="0.48"/>
     <GradientStop Color="#0755B5" Offset="1"/>
   </LinearGradientBrush>
   <Style TargetType="TextBlock">
     <Setter Property="Foreground" Value="#ECF8FF"/>
   </Style>
   <Style x:Key="SmallLabel" TargetType="TextBlock">
     <Setter Property="FontSize" Value="11"/>
     <Setter Property="FontWeight" Value="SemiBold"/>
     <Setter Property="Foreground" Value="#9DBBD4"/>
     <Setter Property="Margin" Value="0,0,0,8"/>
   </Style>
   <Style x:Key="ControlButton" TargetType="Button">
     <Setter Property="Foreground" Value="#E0F6FF"/>
     <Setter Property="Background" Value="#112C47"/>
     <Setter Property="BorderBrush" Value="#265176"/>
     <Setter Property="BorderThickness" Value="1"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Padding" Value="14,9"/>
     <Setter Property="FontWeight" Value="SemiBold"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border x:Name="Shell" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                   BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
             <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                               Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Shell" Property="Background" Value="#15456A"/></Trigger>
             <Trigger Property="IsPressed" Value="True"><Setter TargetName="Shell" Property="Opacity" Value="0.75"/></Trigger>
             <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Shell" Property="Opacity" Value="0.4"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
   <Style x:Key="PrimaryButton" TargetType="Button">
     <Setter Property="Foreground" Value="#031323"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="FontSize" Value="15"/>
     <Setter Property="FontWeight" Value="Bold"/>
     <Setter Property="Height" Value="56"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border x:Name="Surface" CornerRadius="14" Background="{StaticResource PrimaryGradient}">
             <Border.Effect><DropShadowEffect Color="#029EEB" BlurRadius="28" Opacity="0.33" ShadowDepth="0"/></Border.Effect>
             <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
               <Ellipse Width="12" Height="12" Fill="#DBFFFF" Margin="0,0,11,0"/>
               <ContentPresenter VerticalAlignment="Center"/>
             </StackPanel>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.91"/></Trigger>
             <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.72"/></Trigger>
             <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.30"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
   <Style TargetType="ComboBox">
     <Setter Property="Background" Value="#0B1D35"/>
     <Setter Property="Foreground" Value="#E7F8FF"/>
     <Setter Property="Height" Value="42"/>
     <Setter Property="FontSize" Value="12"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="ComboBox">
           <Grid>
             <Border x:Name="Outline" Background="#0B1D35" CornerRadius="10" BorderBrush="#235078" BorderThickness="1"/>
             <ToggleButton Focusable="False" Foreground="#E7F8FF" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
               <ToggleButton.Template>
                 <ControlTemplate TargetType="ToggleButton">
                   <Grid Background="Transparent">
                     <ContentPresenter Content="{Binding SelectedItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                       ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                       Margin="12,0,33,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                     <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,15,0"
                           Data="M 0 0 L 5 5 L 10 0" Stroke="#A2DCF2" StrokeThickness="1.7"/>
                   </Grid>
                 </ControlTemplate>
               </ToggleButton.Template>
             </ToggleButton>
             <Popup Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
               <Border MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" Background="#0B2746"
                       BorderBrush="#26709B" BorderThickness="1" CornerRadius="11" MaxHeight="275" Padding="4">
                 <Border.Effect><DropShadowEffect Color="Black" BlurRadius="15" ShadowDepth="5" Opacity="0.30"/></Border.Effect>
                 <ScrollViewer SnapsToDevicePixels="True" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto">
                   <ItemsPresenter/>
                 </ScrollViewer>
               </Border>
             </Popup>
           </Grid>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Outline" Property="BorderBrush" Value="#3BBCE8"/></Trigger>
             <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Outline" Property="Opacity" Value="0.4"/></Trigger>
             <Trigger Property="IsDropDownOpen" Value="True"><Setter TargetName="Outline" Property="BorderBrush" Value="#37CEFF"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
   <Style TargetType="ComboBoxItem">
     <Setter Property="Padding" Value="11,9"/>
     <Setter Property="Foreground" Value="#E6F8FF"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="ComboBoxItem">
           <Border x:Name="ItemSurface" Background="Transparent" CornerRadius="7">
             <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="#154B72"/></Trigger>
             <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="#0E6588"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
   <Style TargetType="TextBox">
     <Setter Property="Foreground" Value="#ECFAFF"/>
     <Setter Property="Background" Value="#0B1D35"/>
     <Setter Property="BorderBrush" Value="#235078"/>
     <Setter Property="BorderThickness" Value="1"/>
     <Setter Property="Height" Value="42"/>
     <Setter Property="FontSize" Value="12"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="TextBox">
           <Border x:Name="Outline" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10">
             <ScrollViewer x:Name="PART_ContentHost" Margin="12,0" VerticalAlignment="Center"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Outline" Property="BorderBrush" Value="#37CEFF"/></Trigger>
             <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Outline" Property="Opacity" Value="0.4"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
   <Style x:Key="TitleBarButton" TargetType="Button">
     <Setter Property="Width" Value="38"/>
     <Setter Property="Height" Value="32"/>
     <Setter Property="Foreground" Value="#B6DDF2"/>
     <Setter Property="Background" Value="Transparent"/>
     <Setter Property="BorderThickness" Value="0"/>
     <Setter Property="Cursor" Value="Hand"/>
     <Setter Property="Template">
       <Setter.Value>
         <ControlTemplate TargetType="Button">
           <Border x:Name="Box" Background="{TemplateBinding Background}" CornerRadius="8">
             <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
           </Border>
           <ControlTemplate.Triggers>
             <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#13334F"/></Trigger>
           </ControlTemplate.Triggers>
         </ControlTemplate>
       </Setter.Value>
     </Setter>
   </Style>
 </Window.Resources>
 <Grid Background="#040A16" ClipToBounds="True">
   <!-- The brush fills EXACTLY the full window; its crop centers the moon in both axes. -->
   <Rectangle x:Name="FullWindowArtwork" IsHitTestVisible="False">
     <Rectangle.Fill>
       <ImageBrush Stretch="UniformToFill" AlignmentX="Center" AlignmentY="Center" TileMode="None" />
     </Rectangle.Fill>
   </Rectangle>
   <!-- Subtle darkening keeps controls legible while preserving the luminous blue scene. -->
   <Rectangle Fill="#49020A19" IsHitTestVisible="False"/>
   <Grid Margin="31,0,31,24">
     <Grid.RowDefinitions>
       <RowDefinition Height="64"/>
       <RowDefinition Height="106"/>
       <RowDefinition Height="*"/>
       <RowDefinition Height="78"/>
     </Grid.RowDefinitions>
     <!-- Compact titlebar -->
     <Grid Grid.Row="0">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <Grid x:Name="DragBar" Background="Transparent" Cursor="SizeAll">
         <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
           <!-- User's second image is the upper-left brand emblem, not a recreated symbol. -->
           <Grid Width="49" Height="49" Margin="0,0,11,0" IsHitTestVisible="False">
             <Ellipse Width="42" Height="42" Fill="#71020C20" Stroke="#5AA8E3" StrokeThickness="0.6"/>
             <Image x:Name="BrandMoonEmblem" Width="47" Height="47" Stretch="Uniform"/>
           </Grid>
           <TextBlock Text="CÆLŌCORD" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
           <Border Margin="12,0,0,0" CornerRadius="6" BorderBrush="#22547E" BorderThickness="1" VerticalAlignment="Center" Padding="8,3">
             <TextBlock Text="BLUE MOON" FontSize="9" FontWeight="Bold" Foreground="#A8D4F2"/>
           </Border>
         </StackPanel>
       </Grid>
       <Border Grid.Column="1" Background="#102C48" CornerRadius="15" Padding="12,6" Margin="0,0,21,0" VerticalAlignment="Center">
         <StackPanel Orientation="Horizontal">
           <Ellipse Width="7" Height="7" Fill="#6EE8E1" Margin="0,0,8,0" VerticalAlignment="Center"/>
           <TextBlock Text="LOCAL  •  PRIVATE" FontSize="10" FontWeight="SemiBold" Foreground="#A6CDDF"/>
         </StackPanel>
       </Border>
       <StackPanel Orientation="Horizontal" Grid.Column="2" VerticalAlignment="Center">
         <Button x:Name="MinButton" Style="{StaticResource TitleBarButton}" Content="─" FontSize="16"/>
         <Button x:Name="MaxButton" Style="{StaticResource TitleBarButton}" Content="□" FontSize="18" Margin="3,0,0,0"/>
         <Button x:Name="CloseButton" Style="{StaticResource TitleBarButton}" Content="×" FontSize="20" Margin="3,0,0,0"/>
       </StackPanel>
     </Grid>
     <!-- Title -->
     <Grid Grid.Row="1" Margin="0,5,0,18">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel VerticalAlignment="Center">
         <StackPanel.Effect><DropShadowEffect Color="#01030A" BlurRadius="9" ShadowDepth="1" Opacity="0.95"/></StackPanel.Effect>
         <TextBlock Text="Keep every moment." FontSize="29" FontWeight="Bold"/>
         <TextBlock Text="Capture the moment. Preserve the memory." Foreground="#91B9D5" FontSize="13" Margin="0,6,0,0"/>
       </StackPanel>
       <Border Grid.Column="1" Background="#B3091931" BorderBrush="#468AB3" BorderThickness="1" CornerRadius="12" VerticalAlignment="Center" Padding="12,10">
         <StackPanel Orientation="Horizontal">
           <TextBlock Text="✧" Foreground="#71E6FF" FontSize="18" Margin="0,0,8,0"/>
           <StackPanel>
             <TextBlock Text="UNLIMITED RECORDING" FontSize="10" FontWeight="Bold"/>
             <TextBlock Text="No watermark · No subscription" FontSize="10" Foreground="#9CC0D9" Margin="0,2,0,0"/>
           </StackPanel>
         </StackPanel>
       </Border>
     </Grid>
     <!-- Studio layout -->
     <Grid Grid.Row="2">
       <Grid.ColumnDefinitions>
         <ColumnDefinition Width="1.08*"/>
         <ColumnDefinition Width="19"/>
         <ColumnDefinition Width="0.92*"/>
       </Grid.ColumnDefinitions>
       <!-- recording stage -->
       <Border Grid.Column="0" CornerRadius="22" Background="#D40A1B33" BorderBrush="#4A8CB6" BorderThickness="1" ClipToBounds="True">
         <Border.Effect><DropShadowEffect BlurRadius="28" Opacity="0.22" ShadowDepth="5" Color="#006BBC"/></Border.Effect>
         <Grid>
           <!-- No secondary panel image: the first supplied image is the SINGLE continuous background. -->
           <Grid Margin="27,23,27,25">
           <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
           <Grid Grid.Row="0">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel Orientation="Horizontal">
               <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#61DED9" VerticalAlignment="Center" Margin="0,0,9,0"/>
               <TextBlock x:Name="StatusText" Text="Ready to record" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
             </StackPanel>
             <Border Grid.Column="1" Background="#153D62" CornerRadius="8" Padding="10,5">
               <TextBlock Text="✧  MP4  /  H.264" Foreground="#B3D8F0" FontSize="10" FontWeight="SemiBold"/>
             </Border>
           </Grid>
           <!-- FIXED composition: status messages cannot resize or vertically shift the moon. -->
           <Viewbox Grid.Row="1" Stretch="Uniform" StretchDirection="DownOnly" Margin="0,8,0,8">
             <Grid Width="430" Height="314" HorizontalAlignment="Center" VerticalAlignment="Center">
               <Grid.RowDefinitions>
                 <RowDefinition Height="210"/>
                 <RowDefinition Height="20"/>
                 <RowDefinition Height="48"/>
                 <RowDefinition Height="36"/>
               </Grid.RowDefinitions>
               <!-- The record emblem stays at the SAME height when recording starts/stops. -->
               <Image x:Name="RecordingMoonArtwork" Grid.Row="0" Width="200" Height="200"
                      HorizontalAlignment="Center" VerticalAlignment="Bottom"
                      Stretch="Uniform" Opacity="1" IsHitTestVisible="False"
                      RenderOptions.BitmapScalingMode="HighQuality"/>
               <TextBlock Grid.Row="1" Text="RECORDING TIME" HorizontalAlignment="Center"
                          VerticalAlignment="Center" Foreground="#B0DAF2" FontSize="10" FontWeight="Bold"/>
               <TextBlock x:Name="TimerText" Grid.Row="2" Text="00:00:00" FontFamily="Consolas"
                          FontWeight="Light" FontSize="47" HorizontalAlignment="Center"
                          VerticalAlignment="Center"/>
               <!-- This slot has a fixed height and width, even when text wraps or changes. -->
               <TextBlock x:Name="StatusDetail" Grid.Row="3" Text="Ready to record."
                          Foreground="#B0D8E9" FontSize="12" TextWrapping="Wrap"
                          TextAlignment="Center" TextTrimming="CharacterEllipsis"
                          Width="410" Height="36" VerticalAlignment="Top"
                          HorizontalAlignment="Center"/>
             </Grid>
           </Viewbox>
           <StackPanel Grid.Row="2">
             <Button x:Name="RecordButton" Content="START RECORDING" Style="{StaticResource PrimaryButton}"/>
             <Button x:Name="StopButton" Content="■  Stop and save" Style="{StaticResource ControlButton}" Height="44" Margin="0,11,0,0" IsEnabled="False"/>
           </StackPanel>
           </Grid>
         </Grid>
       </Border>
       <!-- preferences -->
       <Border Grid.Column="2" Background="#DE07182F" BorderBrush="#4A83AC" BorderThickness="1" CornerRadius="22">
         <Grid Margin="24,21,24,19">
           <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="*"/></Grid.RowDefinitions>
           <Grid Grid.Row="0">
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel>
               <TextBlock Text="Recording settings" FontWeight="Bold" FontSize="17"/>
               <TextBlock Text="Simple controls. Clear choices." FontSize="11" Foreground="#97C4DD" Margin="0,4,0,0"/>
             </StackPanel>
             <Border Grid.Column="1" CornerRadius="8" Background="#163756" Padding="9,6" VerticalAlignment="Center">
               <TextBlock Text="✧  OPTIONS" FontSize="10" Foreground="#B4DCF2" FontWeight="SemiBold"/>
             </Border>
           </Grid>
           <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="True">
             <StackPanel Margin="0,11,3,0">
               <Grid>
                 <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                 <StackPanel Grid.Column="0">
                   <TextBlock Text="DISPLAY" Style="{StaticResource SmallLabel}"/>
                   <ComboBox x:Name="ScreenBox"/>
                 </StackPanel>
                 <StackPanel Grid.Column="2">
                   <TextBlock Text="FPS" Style="{StaticResource SmallLabel}"/>
                   <ComboBox x:Name="FpsBox"/>
                 </StackPanel>
               </Grid>
               <StackPanel Margin="0,16,0,0">
                 <TextBlock Text="VIDEO QUALITY" Style="{StaticResource SmallLabel}"/>
                 <ComboBox x:Name="QualityBox"/>
               </StackPanel>
               <StackPanel Margin="0,16,0,0">
                 <TextBlock Text="MICROPHONE" Style="{StaticResource SmallLabel}"/>
                 <Grid>
                   <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions>
                   <ComboBox x:Name="MicBox" Grid.Column="0"/>
                   <Button x:Name="MicButton" Grid.Column="2" Content="Refresh" Style="{StaticResource ControlButton}" Padding="6,6" FontSize="11"/>
                 </Grid>
               </StackPanel>
               <StackPanel Margin="0,16,0,0">
                 <TextBlock Text="SAVE LOCATION" Style="{StaticResource SmallLabel}"/>
                 <Grid>
                   <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions>
                   <TextBox x:Name="FolderBox" Grid.Column="0"/>
                   <Button x:Name="BrowseButton" Grid.Column="2" Content="Browse..." Style="{StaticResource ControlButton}" Padding="7,6" FontSize="11"/>
                 </Grid>
               </StackPanel>
               <Border Background="#122F4A" BorderBrush="#215C86" BorderThickness="1" CornerRadius="10" Margin="0,18,0,0" Padding="11,10">
                 <StackPanel Orientation="Horizontal">
                   <TextBlock Text="ⓘ" Foreground="#6ECFFF" FontSize="14" Margin="0,0,9,0" VerticalAlignment="Top"/>
                   <TextBlock Text="The control panel is excluded from captures on supported Windows versions. System audio is not available in this build." TextWrapping="Wrap" Foreground="#A2C8E1" FontSize="11"/>
                 </StackPanel>
               </Border>
             </StackPanel>
           </ScrollViewer>
         </Grid>
       </Border>
     </Grid>
     <!-- bottom status strip -->
     <Grid Grid.Row="3" Margin="0,17,0,0">
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
       <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,12,0">
         <StackPanel.Effect><DropShadowEffect Color="Black" BlurRadius="8" ShadowDepth="1" Opacity="0.9"/></StackPanel.Effect>
         <TextBlock x:Name="EngineText" Text="Checking recording engine..." FontSize="11" Foreground="#BEDBED" FontWeight="SemiBold"/>
         <TextBlock x:Name="LastFileText" Text="Recordings stay on your computer." TextTrimming="CharacterEllipsis" FontSize="10" Foreground="#83ABC5" Margin="0,5,0,0"/>
       </StackPanel>
       <Button x:Name="InstallButton" Grid.Column="1" Style="{StaticResource ControlButton}" Content="Download FFmpeg" Visibility="Collapsed" Margin="0,0,10,0"/>
       <Button x:Name="OpenButton" Grid.Column="2" Style="{StaticResource ControlButton}" Content="▣  Open recordings folder"/>
     </Grid>
   </Grid>
 </Grid>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader($xaml)
    $script:window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [Console]::Error.WriteLine('WPF XAML load error: ' + $_.Exception.ToString())
    [System.Windows.MessageBox]::Show("Unable to load the interface: $($_.Exception.Message)", 'Caelocord') | Out-Null
    exit 1
}

# Load visual assets from the application folder. Missing artwork must not prevent recording.
function Set-KareArtwork([string]$elementName, [string]$relativeFile) {
    try {
        $element = $window.FindName($elementName)
        $path = Join-Path $PSScriptRoot $relativeFile
        if ($element -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $image = New-Object System.Windows.Media.Imaging.BitmapImage
            $image.BeginInit()
            $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.UriSource = [System.Uri]::new($path)
            $image.EndInit()
            $image.Freeze()
            if ($element -is [System.Windows.Shapes.Rectangle]) {
                # An ImageBrush always centers UniformToFill cropping inside its rectangle.
                $element.Fill.ImageSource = $image
            } else {
                $element.Source = $image
            }
        }
    } catch {
        [Console]::Error.WriteLine('Caelocord visual asset skipped: ' + $_.Exception.Message)
    }
}
Set-KareArtwork 'FullWindowArtwork' 'art\mavi-ay-arkaplan.png'
Set-KareArtwork 'BrandMoonEmblem' 'art\mavi-ay-amblem.png'
Set-KareArtwork 'RecordingMoonArtwork' 'art\kayit-ay-motifi.png'

# Also give the window / taskbar the same moon icon.
try {
    $iconPath = Join-Path $PSScriptRoot 'art\mavi-ay-amblem.ico'
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        $script:window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($iconPath))
    }
} catch {
    [Console]::Error.WriteLine('Caelocord window icon skipped: ' + $_.Exception.Message)
}

$script:dragBar = $window.FindName('DragBar')
$script:minButton = $window.FindName('MinButton')
$script:maxButton = $window.FindName('MaxButton')
$script:closeButton = $window.FindName('CloseButton')
$script:recordingMoon = $window.FindName('RecordingMoonArtwork')
# WPF luminance glow, without timer-stepped hard flashes or blinking the whole panel.
$script:moonGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:moonGlow.Color = [System.Windows.Media.Color]::FromRgb(35, 198, 255)
$script:moonGlow.BlurRadius = 25
$script:moonGlow.ShadowDepth = 0
$script:moonGlow.Opacity = 0.23
$script:recordingMoon.Effect = $script:moonGlow
$script:statusDot = $window.FindName('StatusDot')
$script:statusText = $window.FindName('StatusText')
$script:statusDetail = $window.FindName('StatusDetail')
$script:timerText = $window.FindName('TimerText')
$script:screenBox = $window.FindName('ScreenBox')
$script:fpsBox = $window.FindName('FpsBox')
$script:qualityBox = $window.FindName('QualityBox')
$script:micBox = $window.FindName('MicBox')
$script:micButton = $window.FindName('MicButton')
$script:folderBox = $window.FindName('FolderBox')
$script:browseButton = $window.FindName('BrowseButton')
$script:recordButton = $window.FindName('RecordButton')
$script:stopButton = $window.FindName('StopButton')
$script:installButton = $window.FindName('InstallButton')
$script:openButton = $window.FindName('OpenButton')
$script:engineText = $window.FindName('EngineText')
$script:lastFileText = $window.FindName('LastFileText')

function Set-Status([string]$message, [string]$detail, [string]$color) {
    $script:statusText.Text = $message
    $script:statusDetail.Text = $detail
    $script:statusDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

$script:screenBounds = New-Object 'System.Collections.Generic.List[object]'
[void]$script:screenBox.Items.Add('All displays (combined)')
$script:screenBounds.Add($null)
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $suffix = if ($screen.Primary) { ' [Primary]' } else { '' }
    [void]$script:screenBox.Items.Add(('{0} ({1}x{2}){3}' -f $screen.DeviceName, $screen.Bounds.Width, $screen.Bounds.Height, $suffix))
    $script:screenBounds.Add($screen.Bounds)
}
$script:screenBox.SelectedIndex = 0
foreach ($item in @('15 FPS', '30 FPS', '60 FPS')) { [void]$script:fpsBox.Items.Add($item) }
$script:fpsBox.SelectedIndex = 1
foreach ($item in @('High quality', 'Balanced', 'Smaller file')) { [void]$script:qualityBox.Items.Add($item) }
$script:qualityBox.SelectedIndex = 1
[void]$script:micBox.Items.Add('(Microphone off)')
$script:micBox.SelectedIndex = 0
$script:ffmpeg = Find-Ffmpeg

$videosDir = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyVideos)
if ([string]::IsNullOrWhiteSpace($videosDir)) { $videosDir = Join-Path $env:USERPROFILE 'Videos' }
$script:folderBox.Text = $videosDir

function Update-EngineUi {
    $script:ffmpeg = Find-Ffmpeg
    if ($script:ffmpeg) {
        $script:engineText.Text = 'Recording engine ready (FFmpeg).'
        $script:installButton.Visibility = 'Collapsed'
        $script:micButton.IsEnabled = $true
    } elseif ($script:downloadJob) {
        $script:engineText.Text = 'Downloading FFmpeg... An internet connection is required.'
        $script:installButton.Visibility = 'Visible'
        $script:installButton.Content = 'Downloading...'
        $script:installButton.IsEnabled = $false
        $script:micButton.IsEnabled = $false
    } else {
        $script:engineText.Text = 'FFmpeg is required for the first recording. Choose Download FFmpeg.'
        $script:installButton.Visibility = 'Visible'
        $script:installButton.Content = 'Download FFmpeg'
        $script:installButton.IsEnabled = $true
        $script:micButton.IsEnabled = $false
    }
}

function Begin-FfmpegDownload {
    if ($script:downloadJob -or $script:ffmpeg) { return }
    $reply = [System.Windows.MessageBox]::Show(
        'FFmpeg is needed for screen recording. Download the ZIP archive (approximately 109 MB) from gyan.dev to your local app folder?',
        'FFmpeg download permission',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($reply -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        $script:downloadJob = Start-Job -ArgumentList $script:rootDir, $script:localFfmpeg -ScriptBlock {
            param([string]$installDir, [string]$binaryPath)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if (-not (Test-Path -LiteralPath $installDir)) {
                [void](New-Item -ItemType Directory -Path $installDir -Force)
            }
            $tempZip = Join-Path $env:TEMP ('Caelocord_ffmpeg_' + [guid]::NewGuid().ToString('N') + '.zip')
            $tempExe = "$binaryPath.part"
            $tempHash = "$tempZip.sha256"
            try {
                $client = New-Object System.Net.WebClient
                try {
                    $client.DownloadFile('https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip', $tempZip)
                    $client.DownloadFile('https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256', $tempHash)
                } finally { $client.Dispose() }
                $rawHash = [System.IO.File]::ReadAllText($tempHash)
                $hashMatch = [regex]::Match($rawHash, '[A-Fa-f0-9]{64}')
                if (-not $hashMatch.Success) { throw 'The FFmpeg SHA256 verification file is invalid.' }
                $actualHash = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash
                if ($actualHash -ine $hashMatch.Value) { throw 'FFmpeg archive failed SHA256 verification.' }
                Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
                try {
                    $ffmpegEntry = $zip.Entries | Where-Object { $_.Name -ieq 'ffmpeg.exe' -and $_.FullName -match '(^|/)bin/ffmpeg\.exe$' } | Select-Object -First 1
                    if (-not $ffmpegEntry) { throw 'Could not find ffmpeg.exe in the downloaded archive.' }
                    $sourceStream = $ffmpegEntry.Open()
                    $targetStream = [System.IO.File]::Create($tempExe)
                    try { $sourceStream.CopyTo($targetStream) }
                    finally { $targetStream.Dispose(); $sourceStream.Dispose() }
                } finally { $zip.Dispose() }
                Move-Item -LiteralPath $tempExe -Destination $binaryPath -Force
                Write-Output 'OK'
            } finally {
                if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $tempHash) { Remove-Item -LiteralPath $tempHash -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $tempExe) { Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue }
            }
        }
        Set-Status 'Installing FFmpeg' 'You can start recording after the download completes.' '#FFBF69'
        Update-EngineUi
    } catch {
        [System.Windows.MessageBox]::Show("Unable to begin downloading: $($_.Exception.Message)", 'Caelocord') | Out-Null
    }
}

function Refresh-Microphones {
    if (-not $script:ffmpeg -or $script:recordProcess) { return }

    $previousMic = if ($script:micBox.SelectedIndex -gt 0) { [string]$script:micBox.SelectedItem } else { '' }
    $script:micButton.IsEnabled = $false
    $script:micBox.Items.Clear()
    [void]$script:micBox.Items.Add('(Microphone off)')
    $script:micBox.SelectedIndex = 0
    $process = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:ffmpeg
        $psi.Arguments = '-hide_banner -list_devices true -f dshow -i dummy'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $output = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(12000)) {
            try { $process.Kill() } catch {}
            throw 'Microphone scan timed out.'
        }

        # FFmpeg lists audio device names beneath the DirectShow audio devices header.
        # Device names need not have an '(audio)' suffix.
        $inAudioSection = $false
        $seen = @{}
        foreach ($line in ($output -split '\r?\n')) {
            if ($line -match 'DirectShow audio devices') {
                $inAudioSection = $true
                continue
            }
            if ($line -match 'DirectShow video devices') {
                $inAudioSection = $false
                continue
            }
            if (-not $inAudioSection) { continue }
            $nameMatch = [regex]::Match($line, '^\[dshow[^\]]*\]\s+"(?<device>[^\"]+)"(?:\s+\(audio\))?\s*$')
            if (-not $nameMatch.Success) { continue }
            $name = $nameMatch.Groups['device'].Value
            if (-not $seen.ContainsKey($name)) {
                [void]$script:micBox.Items.Add($name)
                $seen[$name] = $true
            }
        }

        # Some FFmpeg versions append the device type at the end of the line.
        if ($script:micBox.Items.Count -eq 1) {
            foreach ($deviceMatch in [regex]::Matches($output, '(?m)^\[dshow[^\]]*\]\s+"(?<device>[^\"]+)"\s+\(audio\)\s*$')) {
                $name = $deviceMatch.Groups['device'].Value
                if (-not $seen.ContainsKey($name)) {
                    [void]$script:micBox.Items.Add($name)
                    $seen[$name] = $true
                }
            }
        }

        if ($script:micBox.Items.Count -gt 1) {
            # Preserve the selected microphone after refreshing the list.
            for ($i = 1; $i -lt $script:micBox.Items.Count; $i++) {
                if ([string]$script:micBox.Items[$i] -eq $previousMic) {
                    $script:micBox.SelectedIndex = $i
                    break
                }
            }
            Set-Status 'Ready to record' 'Microphone found. Select one from the list if needed.' '#2AD3AA'
        } else {
            # Keep diagnostic FFmpeg output locally for troubleshooting.
            try {
                if (-not (Test-Path -LiteralPath $script:rootDir)) {
                    [void](New-Item -ItemType Directory -Path $script:rootDir -Force)
                }
                [System.IO.File]::WriteAllText((Join-Path $script:rootDir 'mikrofon-tarama.log'), $output)
            } catch {}
            Set-Status 'No microphone found' 'Check Windows microphone permissions or click Refresh.' '#FFBF69'
        }
    } catch {
        Set-Status 'Microphone scan failed' 'Could not list microphones. Try Refresh again.' '#FFBF69'
        try {
            if (-not (Test-Path -LiteralPath $script:rootDir)) {
                [void](New-Item -ItemType Directory -Path $script:rootDir -Force)
            }
            [System.IO.File]::WriteAllText((Join-Path $script:rootDir 'mikrofon-tarama.log'), $_.Exception.ToString())
        } catch {}
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch {} }
        $script:micButton.IsEnabled = [bool]$script:ffmpeg -and (-not $script:recordProcess)
    }
}

function Set-RecordingMoonPulse([bool]$isRecording) {
    # Clear the previous animation first, including after FFmpeg ends unexpectedly.
    $script:recordingMoon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $script:moonGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)

    if (-not $isRecording) {
        $script:recordingMoon.Opacity = 1.0
        $script:moonGlow.Opacity = 0.23
        return
    }

    # Smooth, infinite breathing animation: dim to bright, then ease back again.
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1700))
    $ease = New-Object System.Windows.Media.Animation.SineEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

    $brightness = New-Object System.Windows.Media.Animation.DoubleAnimation
    $brightness.From = 0.68
    $brightness.To = 1.0
    $brightness.Duration = $duration
    $brightness.AutoReverse = $true
    $brightness.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $brightness.EasingFunction = $ease
    $script:recordingMoon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $brightness)

    $glowAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $glowAnimation.From = 0.15
    $glowAnimation.To = 0.78
    $glowAnimation.Duration = $duration
    $glowAnimation.AutoReverse = $true
    $glowAnimation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $glowAnimation.EasingFunction = $ease
    $script:moonGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowAnimation)
}

function Set-RecordingControls([bool]$isRecording) {
    $script:recordButton.IsEnabled = -not $isRecording
    Set-RecordingMoonPulse $isRecording
    $script:stopButton.IsEnabled = $isRecording
    $script:screenBox.IsEnabled = -not $isRecording
    $script:fpsBox.IsEnabled = -not $isRecording
    $script:qualityBox.IsEnabled = -not $isRecording
    $script:micBox.IsEnabled = -not $isRecording
    $script:micButton.IsEnabled = -not $isRecording -and [bool]$script:ffmpeg
    $script:folderBox.IsEnabled = -not $isRecording
    $script:browseButton.IsEnabled = -not $isRecording
}

function Get-WindowsBuild {
    # Registry version is accurate even for processes without a Windows 10 manifest.
    try {
        $version = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        return [int]$version.CurrentBuildNumber
    } catch {
        return [int][Environment]::OSVersion.Version.Build
    }
}

function Disable-CaptureExclusion {
    if (-not $script:captureExclusionActive) { return }
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:window)).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][CaeloCaptureWindow]::SetWindowDisplayAffinity($hwnd, [uint32]0)
        }
    } catch {
        # The window might be closing. Never interrupt MP4 finalization here.
    } finally {
        $script:captureExclusionActive = $false
    }
}

function Enable-CaptureExclusion {
    if ((Get-WindowsBuild) -lt 19041) {
        throw 'Excluding the control panel from video requires Windows 10 version 2004 (build 19041) or Windows 11. Recording was not started without this protection.'
    }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:window)).Handle
    if ($hwnd -eq [IntPtr]::Zero) {
        throw 'Could not access the window handle. Recording was not started because the control panel could not be excluded.'
    }
    # WDA_EXCLUDEFROMCAPTURE (0x11), not WDA_MONITOR (which can leave a black box).
    [uint32]$exclusionFlag = 0x00000011
    if (-not [CaeloCaptureWindow]::SetWindowDisplayAffinity($hwnd, $exclusionFlag)) {
        $nativeError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows could not exclude the control panel from screen capture (Win32 $nativeError). Recording was not started."
    }
    $script:captureExclusionActive = $true
    [uint32]$currentFlag = 0
    if ((-not [CaeloCaptureWindow]::GetWindowDisplayAffinity($hwnd, [ref]$currentFlag)) -or ($currentFlag -ne $exclusionFlag)) {
        Disable-CaptureExclusion
        throw 'Windows could not verify the capture exclusion setting. Recording was not started.'
    }
    # Make the new capture affinity visible to DWM before FFmpeg starts reading frames.
    try { [void][CaeloCaptureWindow]::DwmFlush() } catch {}
}

function Begin-Record {
    if ($script:recordProcess) { return }
    $script:ffmpeg = Find-Ffmpeg
    if (-not $script:ffmpeg) {
        Begin-FfmpegDownload
        return
    }
    $dir = $script:folderBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) {
        [System.Windows.MessageBox]::Show('Please select a folder for your recording.', 'Caelocord') | Out-Null
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $dir -Force)
        }
        $path = Join-Path $dir ('Caelocord_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.mp4')
        if (Test-Path -LiteralPath $path) { $path = Join-Path $dir ('Caelocord_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.mp4') }
        $fps = @('15','30','60')[$script:fpsBox.SelectedIndex]
        $crf = @('18','23','28')[$script:qualityBox.SelectedIndex]
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($part in @('-hide_banner', '-loglevel', 'error', '-nostats', '-y', '-thread_queue_size', '512', '-f', 'gdigrab', '-framerate', $fps, '-draw_mouse', '1')) {
            $parts.Add($part)
        }
        $bounds = $script:screenBounds[$script:screenBox.SelectedIndex]
        if ($null -ne $bounds) {
            foreach ($part in @('-offset_x', [string]$bounds.X, '-offset_y', [string]$bounds.Y, '-video_size', ('{0}x{1}' -f $bounds.Width, $bounds.Height))) {
                $parts.Add($part)
            }
        }
        foreach ($part in @('-i', 'desktop')) { $parts.Add($part) }
        $withMic = $script:micBox.SelectedIndex -gt 0
        if ($withMic) {
            $micName = ([string]$script:micBox.SelectedItem).Replace('"','')
            foreach ($part in @('-thread_queue_size', '512', '-f', 'dshow', '-i', ('"audio={0}"' -f $micName))) { $parts.Add($part) }
        }
        foreach ($part in @('-map', '0:v:0')) { $parts.Add($part) }
        if ($withMic) {
            foreach ($part in @('-map', '1:a:0')) { $parts.Add($part) }
        }
        foreach ($part in @('-vf', '"pad=ceil(iw/2)*2:ceil(ih/2)*2"', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', $crf, '-pix_fmt', 'yuv420p')) {
            $parts.Add($part)
        }
        if ($withMic) {
            foreach ($part in @('-c:a', 'aac', '-b:a', '160k')) { $parts.Add($part) }
        }
        foreach ($part in @(('"{0}"' -f $path.Replace('"', '')))) { $parts.Add($part) }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:ffmpeg
        $psi.Arguments = ($parts -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        # Only begin desktop capture after successful verified exclusion.
        Enable-CaptureExclusion
        [void]$proc.Start()
        $script:recordProcess = $proc
        $script:recordPath = $path
        $script:stopRequested = $false
        $script:elapsed.Restart()
        Set-RecordingControls $true
        Set-Status 'Recording' 'This control panel stays visible to you, but is excluded from supported screen captures.' '#FFB36D'
        $script:recordButton.Content = 'Recording...'
    } catch {
        Disable-CaptureExclusion
        $script:recordProcess = $null
        $script:elapsed.Reset()
        Set-RecordingControls $false
        [System.Windows.MessageBox]::Show("Unable to start recording: $($_.Exception.Message)", 'Caelocord') | Out-Null
    }
}

function End-Record {
    if (-not $script:recordProcess -or $script:stopRequested) { return }
    $script:stopRequested = $true
    $script:stopDeadline = [DateTime]::UtcNow.AddSeconds(90)
    $script:stopButton.IsEnabled = $false
    Set-Status 'Saving video' 'Do not close the window while finalizing the MP4 file.' '#FFBF69'
    try {
        if (-not $script:recordProcess.HasExited) {
            $script:recordProcess.StandardInput.WriteLine('q')
            $script:recordProcess.StandardInput.Flush()
        }
    } catch {
        Set-Status 'Stopping recording' 'The app will report an error if finalization fails.' '#FFBF69'
    }
}

function Finish-Record {
    if (-not $script:recordProcess) { return }
    $proc = $script:recordProcess
    $script:recordProcess = $null
    $script:elapsed.Stop()
    $errorOutput = ''
    try { $errorOutput = $proc.StandardError.ReadToEnd() } catch {}
    $exitCode = -1
    try { $exitCode = $proc.ExitCode } catch {}
    try { $proc.Dispose() } catch {}
    # Restore normal screenshots only after FFmpeg is completely stopped.
    Disable-CaptureExclusion
    Set-RecordingControls $false
    $script:recordButton.Content = 'START RECORDING'
    $script:stopRequested = $false
    $good = ($exitCode -eq 0) -and (Test-Path -LiteralPath $script:recordPath -PathType Leaf) -and ((Get-Item -LiteralPath $script:recordPath).Length -gt 0)
    if ($good) {
        $script:lastSaved = $script:recordPath
        $script:lastFileText.Text = ('Last recording: ' + $script:lastSaved)
        Set-Status 'Recording saved' 'Your MP4 file was saved in the selected folder.' '#2AD3AA'
    } else {
        $brief = $errorOutput.Trim()
        if ($brief.Length -gt 750) { $brief = $brief.Substring($brief.Length - 750) }
        if ([string]::IsNullOrWhiteSpace($brief)) { $brief = 'Recording could not be completed. Check folder permissions and available disk space.' }
        Set-Status 'Recording failed' 'See the error dialog for details.' '#FFB36D'
        [System.Windows.MessageBox]::Show("FFmpeg error code: $exitCode`n`n$brief", 'Caelocord recording error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
}

$script:stateTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:stateTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:stateTimer.Add_Tick({
    if ($script:downloadJob) {
        if ($script:downloadJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $job = $script:downloadJob
            $script:downloadJob = $null
            $jobErr = @($job.ChildJobs | ForEach-Object { $_.Error } | ForEach-Object { $_.ToString() }) -join "`n"
            $result = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) -join "`n"
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            Update-EngineUi
            if ($script:ffmpeg) {
                Set-Status 'Setup complete' 'FFmpeg is ready. You can start recording.' '#2AD3AA'
                Refresh-Microphones
            } else {
                Set-Status 'Download failed' 'Check your connection and try again.' '#FFB36D'
                [System.Windows.MessageBox]::Show("Could not download FFmpeg.`n`n$jobErr`n$result", 'Caelocord') | Out-Null
            }
        }
    }
    if ($script:recordProcess) {
        $script:timerText.Text = $script:elapsed.Elapsed.ToString('hh\:mm\:ss')
        if ($script:recordProcess.HasExited) {
            Finish-Record
        } elseif ($script:stopRequested -and [DateTime]::UtcNow -gt $script:stopDeadline) {
            try { $script:recordProcess.Kill() } catch {}
            Set-Status 'Recording interrupted' 'FFmpeg did not exit in time. Your video may be incomplete.' '#FFB36D'
        }
    }
})

$script:dragBar.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -ge 2) {
        if ($script:window.WindowState -eq [Windows.WindowState]::Maximized) {
            $script:window.WindowState = [Windows.WindowState]::Normal
        } else {
            $script:window.WindowState = [Windows.WindowState]::Maximized
        }
    } else {
        try { $script:window.DragMove() } catch {}
    }
})
$script:minButton.Add_Click({ $script:window.WindowState = [Windows.WindowState]::Minimized })
$script:maxButton.Add_Click({
    if ($script:window.WindowState -eq [Windows.WindowState]::Maximized) {
        $script:window.WindowState = [Windows.WindowState]::Normal
    } else {
        $script:window.WindowState = [Windows.WindowState]::Maximized
    }
})
$script:closeButton.Add_Click({ $script:window.Close() })
$script:recordButton.Add_Click({ Begin-Record })
$script:stopButton.Add_Click({ End-Record })
$script:micButton.Add_Click({ Refresh-Microphones })
$script:installButton.Add_Click({ Begin-FfmpegDownload })
$script:browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the folder where screen recordings will be saved'
    if (Test-Path -LiteralPath $script:folderBox.Text -PathType Container) {
        $dialog.SelectedPath = $script:folderBox.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:folderBox.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
})
$script:openButton.Add_Click({
    $folder = $script:folderBox.Text.Trim()
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
        Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $folder) | Out-Null
    } else {
        [System.Windows.MessageBox]::Show('Recording folder not found.', 'Caelocord') | Out-Null
    }
})
$script:window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:recordProcess) {
        $eventArgs.Cancel = $true
        [System.Windows.MessageBox]::Show('Please use Stop and save to finish the MP4 recording before closing.', 'Caelocord', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})
$script:window.Add_Closed({
    Disable-CaptureExclusion
    $script:stateTimer.Stop()
    if ($script:downloadJob) {
        Stop-Job $script:downloadJob -ErrorAction SilentlyContinue
        Remove-Job $script:downloadJob -Force -ErrorAction SilentlyContinue
    }
})

Update-EngineUi
Set-Status 'Ready to record' 'Your videos are saved locally on your computer.' '#2AD3AA'
# Populate the microphone list when the application opens.
if ($script:ffmpeg) { Refresh-Microphones }
$script:stateTimer.Start()
[void]$script:window.ShowDialog()
