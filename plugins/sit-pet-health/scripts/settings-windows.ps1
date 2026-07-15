param(
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT,
    [string]$PluginData = $env:CLAUDE_PLUGIN_DATA,
    [string]$CodexHome,
    [switch]$FirstRun,
    [switch]$TestMode,
    [int]$AutoCloseSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if ([string]::IsNullOrWhiteSpace($PluginData)) { throw 'PluginData is required.' }
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
$PluginData = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginData))
$CodexHome = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
[System.IO.Directory]::CreateDirectory($PluginData) | Out-Null

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Merge-Config {
    param([psobject]$Base, [psobject]$Override)
    if ($null -eq $Override) { return $Base }
    foreach ($property in $Override.PSObject.Properties) {
        if ($null -ne $Base.PSObject.Properties[$property.Name]) { $Base.($property.Name) = $property.Value }
    }
    return $Base
}

function Test-ContainedPath {
    param([string]$Parent, [string]$Child)
    try {
        $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        return [System.IO.Path]::GetFullPath($Child).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-PetCandidates {
    $results = @()
    $roots = @(
        [pscustomobject]@{ Path = (Join-Path $CodexHome 'pets'); Type = 'official' },
        [pscustomobject]@{ Path = (Join-Path $PluginData 'custom-sources'); Type = 'custom' }
    )
    foreach ($root in $roots) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue)) {
            $manifestPath = Join-Path $directory.FullName 'pet.json'
            $manifest = Read-JsonSafe -Path $manifestPath
            if ($null -eq $manifest -or $null -ne $manifest.PSObject.Properties['sitPetHealthClone']) { continue }
            $relativeSprite = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.spritesheetPath)) { [string]$manifest.spritesheetPath } else { 'spritesheet.webp' }
            $spritePath = Join-Path $directory.FullName $relativeSprite
            if (-not (Test-ContainedPath -Parent $directory.FullName -Child $spritePath) -or -not (Test-Path -LiteralPath $spritePath -PathType Leaf)) { continue }
            if ([System.IO.Path]::GetExtension($spritePath).ToLowerInvariant() -notin @('.webp', '.png')) { continue }
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.displayName)) { [string]$manifest.displayName } elseif (-not [string]::IsNullOrWhiteSpace([string]$manifest.name)) { [string]$manifest.name } else { $directory.Name }
            $results += [pscustomobject]@{
                Slug = $directory.Name
                DisplayName = $displayName
                SourceType = $root.Type
                Directory = $directory.FullName
                Label = "$displayName  $([char]0x00B7)  $(if ($root.Type -eq 'official') { 'Codex 官方宠物' } else { '自定义宠物' })"
            }
        }
    }
    return @($results | Sort-Object DisplayName, Slug)
}

function Set-Status {
    param([string]$Text, [string]$Color = '#7B7069')
    $statusText.Text = $Text
    $statusText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

$configPath = Join-Path $PluginData 'config.json'
$defaultConfig = Get-Content -LiteralPath (Join-Path $PluginRoot 'assets\default-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config = Merge-Config -Base $defaultConfig -Override (Read-JsonSafe -Path $configPath)
$selection = Read-JsonSafe -Path (Join-Path $PluginData 'selected-source.json')
$selectionSlug = if ($null -ne $selection -and $null -ne $selection.PSObject.Properties['slug']) { [string]$selection.slug } else { '' }
$selectionType = if ($null -ne $selection -and $null -ne $selection.PSObject.Properties['sourceType'] -and -not [string]::IsNullOrWhiteSpace([string]$selection.sourceType)) { [string]$selection.sourceType } else { 'official' }
$pets = @(Get-PetCandidates)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="520" Height="650"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="True" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,0"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="ButtonChrome" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.86"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.70"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="12,9"/><Setter Property="Foreground" Value="#554C46"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="ItemChrome" Margin="4,2" CornerRadius="7" Background="{TemplateBinding Background}"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#F7EAE2"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#F2DDD5"/><Setter Property="FontWeight" Value="SemiBold"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#514943"/><Setter Property="Background" Value="#FFFFFF"/><Setter Property="BorderBrush" Value="#DDCFC4"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton x:Name="DropDownToggle" Focusable="False" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press" Background="Transparent" BorderThickness="0">
            <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
              <Border x:Name="ComboChrome" CornerRadius="9" Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}" BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}" BorderThickness="1">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/></Grid.ColumnDefinitions>
                  <ContentPresenter Margin="12,0,4,0" VerticalAlignment="Center" Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
                  <TextBlock Grid.Column="1" Text="⌄" FontFamily="Segoe UI Symbol" FontSize="16" Foreground="#8F8178" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </Border>
              <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ComboChrome" Property="BorderBrush" Value="#D8A995"/></Trigger></ControlTemplate.Triggers>
            </ControlTemplate></ToggleButton.Template>
          </ToggleButton>
          <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Margin="0,5,0,0" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ComboBox}}" MaxHeight="260" Padding="3" CornerRadius="10" Background="#FFFDF9" BorderBrush="#DDCFC4" BorderThickness="1">
              <Border.Effect><DropShadowEffect Color="#49372C" BlurRadius="16" ShadowDepth="4" Opacity="0.18"/></Border.Effect>
              <ScrollViewer><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#514943"/><Setter Property="Background" Value="#FFFFFF"/><Setter Property="BorderBrush" Value="#DDCFC4"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ScrollViewer x:Name="PART_ContentHost"/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
        <Grid Height="30" VerticalAlignment="Center">
          <Track x:Name="PART_Track" Height="22" Margin="11,0" VerticalAlignment="Center">
            <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static Slider.DecreaseLarge}"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="6" CornerRadius="3" Background="#E98779" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
            <Track.Thumb><Thumb Width="19" Height="19"><Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#FFFDF9" Stroke="#D9796D" StrokeThickness="2"><Ellipse.Effect><DropShadowEffect Color="#6A4D43" BlurRadius="5" ShadowDepth="1" Opacity="0.18"/></Ellipse.Effect></Ellipse></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
            <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static Slider.IncreaseLarge}"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="6" CornerRadius="3" Background="#DCE9E2" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
          </Track>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Margin="18" CornerRadius="18" Background="#FFFDF9" BorderBrush="#EADFD5" BorderThickness="1">
    <Border.Effect><DropShadowEffect Color="#49372C" BlurRadius="26" ShadowDepth="7" Opacity="0.20"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="68"/><RowDefinition Height="*"/><RowDefinition Height="72"/></Grid.RowDefinitions>
      <Border x:Name="TitleBar" Padding="22,0" Background="#FFF7EF" CornerRadius="18,18,0,0">
        <Grid>
          <StackPanel VerticalAlignment="Center"><TextBlock Text="桌宠设置" FontSize="19" FontWeight="SemiBold" Foreground="#443C37"/><TextBlock x:Name="HeaderHint" Margin="0,3,0,0" FontSize="10.5" Foreground="#9B8D83"/></StackPanel>
          <Button x:Name="CloseButton" AutomationProperties.Name="关闭设置" ToolTip="关闭" HorizontalAlignment="Right" Width="34" Height="34" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#756A63" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
        </Grid>
      </Border>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="22,16,22,8">
        <StackPanel>
          <StackPanel x:Name="PetSelectionPanel">
            <TextBlock Text="使用哪只宠物" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/>
            <ComboBox x:Name="PetPicker" AutomationProperties.Name="选择宠物" Height="40" Margin="0,7,0,4" Padding="10,0" FontSize="12.5" Background="#FFFFFF" BorderBrush="#DDCFC4"/>
            <TextBlock Text="只读取官方图集；健康动作生成在插件自己的目录。" FontSize="10" Foreground="#9B8D83"/>
          </StackPanel>

          <Border x:Name="NoPetPanel" Visibility="Collapsed" Padding="16" CornerRadius="12" Background="#FFF3EC" BorderBrush="#EBCFC1" BorderThickness="1">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <TextBlock Text="还没有宠物" FontSize="14" FontWeight="SemiBold" Foreground="#4F453F"/>
              <TextBlock Grid.Row="1" Margin="0,7,0,0" Text="回到 Codex，发一句宠物描述或一张参考图。我会生成完整动作图集，并只保存在这个 Skill 的私有目录。" FontSize="10.5" LineHeight="17" Foreground="#81746B" TextWrapping="Wrap"/>
              <Button x:Name="CopyPetPromptButton" Grid.Row="2" Width="126" Height="34" Margin="0,12,0,0" HorizontalAlignment="Left" Content="复制创建指令" Background="#E98779" BorderBrush="#E98779" Foreground="White" FontWeight="SemiBold"/>
            </Grid>
          </Border>

          <Border Margin="0,18,0,0" Padding="15" CornerRadius="12" Background="#FAF3EC" BorderBrush="#EADFD5" BorderThickness="1">
            <StackPanel>
              <TextBlock Text="离开电脑判定" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/>
              <ComboBox x:Name="SensitivityPicker" AutomationProperties.Name="离开电脑判定灵敏度" Height="38" Margin="0,8,0,0" Padding="9,0" SelectedIndex="1">
                <ComboBoxItem Content="灵敏 · 3 分钟空闲算完整休息" Tag="sensitive"/>
                <ComboBoxItem Content="标准 · 5 分钟空闲算完整休息" Tag="balanced"/>
                <ComboBoxItem Content="稳健 · 7 分钟空闲算完整休息" Tag="conservative"/>
              </ComboBox>
              <TextBlock Margin="0,7,0,0" Text="这是键鼠空闲推断，不会声称识别了真实站立动作。" FontSize="10" Foreground="#9B8D83" TextWrapping="Wrap"/>
              <TextBlock Margin="0,14,0,0" Text="久坐阶段节奏" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/>
              <ComboBox x:Name="SedentaryPicker" AutomationProperties.Name="久坐阶段节奏" Height="38" Margin="0,8,0,0" Padding="9,0">
                <ComboBoxItem Content="早提醒 · 20 分钟开始发懒" Tag="early"/>
                <ComboBoxItem Content="标准 · 30 分钟开始发懒" Tag="balanced"/>
                <ComboBoxItem Content="宽松 · 45 分钟开始发懒" Tag="relaxed"/>
              </ComboBox>
            </StackPanel>
          </Border>

          <Border Margin="0,12,0,0" Padding="15" CornerRadius="12" Background="#F2F8F5" BorderBrush="#D9E8E0" BorderThickness="1">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="88"/></Grid.ColumnDefinitions>
              <TextBlock Text="宠物大小" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/>
              <TextBlock x:Name="ScaleValue" Grid.Column="1" HorizontalAlignment="Right" FontSize="11" Foreground="#668C7B"/>
              <Slider x:Name="ScaleSlider" AutomationProperties.Name="宠物大小" Grid.Row="1" Grid.ColumnSpan="2" Margin="0,10,0,0" Minimum="0.3" Maximum="2.5" TickFrequency="0.1" IsSnapToTickEnabled="False"/>
            </Grid>
          </Border>

          <Border Margin="0,12,0,0" Padding="15" CornerRadius="12" Background="#F8F3FA" BorderBrush="#E5DAE8" BorderThickness="1">
            <StackPanel>
              <TextBlock Text="提醒语气" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/>
              <ComboBox x:Name="TonePicker" AutomationProperties.Name="提醒语气" Height="38" Margin="0,8,0,0" Padding="9,0">
                <ComboBoxItem Content="损友 · 戏谑但不说教" Tag="playful"/>
                <ComboBoxItem Content="温柔 · 陪伴和鼓励" Tag="gentle"/>
                <ComboBoxItem Content="冷幽默 · 简短克制" Tag="dry"/>
              </ComboBox>
              <TextBlock Margin="0,7,0,0" Text="台词由本地模板结合宠物名和当前记录生成，不调用 LLM。" FontSize="10" Foreground="#9B8D83"/>
            </StackPanel>
          </Border>

          <Border Margin="0,12,0,0" Padding="15" CornerRadius="12" Background="#FFF8F0" BorderBrush="#EEE0D1" BorderThickness="1">
            <StackPanel>
              <CheckBox x:Name="QuietEnabled" Content="开启安静时段（宠物继续计时，但不冒提醒）" FontSize="11.5" Foreground="#5A514B"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <TextBox x:Name="QuietStart" Width="72" Height="32" Padding="8,5" TextAlignment="Center"/>
                <TextBlock Margin="10,0" Text="到" VerticalAlignment="Center" Foreground="#8E8279"/>
                <TextBox x:Name="QuietEnd" Width="72" Height="32" Padding="8,5" TextAlignment="Center"/>
                <TextBlock Margin="14,0,0,0" Text="24 小时制" VerticalAlignment="Center" FontSize="10" Foreground="#A1948B"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Margin="0,12,0,0" Padding="15" CornerRadius="12" Background="#F8F6F3" BorderBrush="#E5DED8" BorderThickness="1">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="运行诊断" FontSize="12" FontWeight="SemiBold" Foreground="#5A514B"/><TextBlock x:Name="DiagnosticText" Margin="0,5,8,0" FontSize="10" Foreground="#91857C" Text="检查官方源文件、私有副本和运行进程。" TextWrapping="Wrap"/></StackPanel>
              <Button x:Name="DiagnoseButton" Grid.Column="1" Width="82" Height="34" Content="立即检查" Background="#FFFFFF" BorderBrush="#D9CCC2" Foreground="#625850" Cursor="Hand"/>
            </Grid>
          </Border>
          <TextBlock x:Name="StatusText" Margin="2,12,2,0" MinHeight="18" FontSize="10.5" Foreground="#7B7069" TextWrapping="Wrap"/>
        </StackPanel>
      </ScrollViewer>
      <Border Grid.Row="2" Padding="22,13" Background="#FFF9F4" CornerRadius="0,0,18,18">
        <Grid><Button x:Name="CancelButton" Width="86" Height="40" HorizontalAlignment="Left" Content="取消" Background="Transparent" BorderBrush="#D9CCC2" Foreground="#6D625B" Cursor="Hand"/>
          <Button x:Name="SaveButton" Width="126" Height="40" HorizontalAlignment="Right" Content="保存并应用" Background="#E98779" BorderBrush="#E98779" Foreground="White" FontWeight="SemiBold" Cursor="Hand"/>
        </Grid>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in @('TitleBar','HeaderHint','CloseButton','PetSelectionPanel','NoPetPanel','CopyPetPromptButton','PetPicker','SensitivityPicker','SedentaryPicker','ScaleValue','ScaleSlider','TonePicker','QuietEnabled','QuietStart','QuietEnd','DiagnoseButton','DiagnosticText','StatusText','CancelButton','SaveButton')) {
    Set-Variable -Name ($name.Substring(0,1).ToLowerInvariant() + $name.Substring(1)) -Value $window.FindName($name)
}
$headerHint.Text = if ($FirstRun) { '先选一只宠物，稍后随时能换。' } else { '宠物、提醒和隐私状态都在这里。' }
foreach ($pet in $pets) { [void]$petPicker.Items.Add($pet.Label) }
$selectedIndex = -1
for ($index = 0; $index -lt $pets.Count; $index++) {
    if ($selectionSlug -eq $pets[$index].Slug -and $selectionType -eq $pets[$index].SourceType) { $selectedIndex = $index; break }
}
if ($selectedIndex -lt 0 -and $pets.Count -gt 0) { $selectedIndex = 0 }
$petPicker.SelectedIndex = $selectedIndex
$petPicker.IsEnabled = $pets.Count -gt 0
$scaleSlider.Value = [math]::Max(0.3, [math]::Min(2.5, [double]$config.petScale))
$scaleValue.Text = "$([math]::Round($scaleSlider.Value * 100))%"
$scaleSlider.Add_ValueChanged({ $scaleValue.Text = "$([math]::Round($scaleSlider.Value * 100))%" })
$quietEnabled.IsChecked = [bool]$config.quietHoursEnabled
$quietStart.Text = [string]$config.quietHoursStart
$quietEnd.Text = [string]$config.quietHoursEnd
$sensitivityIndex = switch ([string]$config.breakSensitivity) { 'sensitive' { 0 } 'conservative' { 2 } default { 1 } }
$sensitivityPicker.SelectedIndex = $sensitivityIndex
$sedentaryPicker.SelectedIndex = switch ([string]$config.sedentaryPreset) { 'early' { 0 } 'relaxed' { 2 } default { 1 } }
$tonePicker.SelectedIndex = switch ([string]$config.dialogueTone) { 'gentle' { 1 } 'dry' { 2 } default { 0 } }
if ($pets.Count -eq 0) {
    $petSelectionPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $noPetPanel.Visibility = [System.Windows.Visibility]::Visible
    $headerHint.Text = '描述一句或发张图，我会帮你创建。'
    $saveButton.IsEnabled = $false
    $saveButton.Opacity = 0.45
    Set-Status -Text '创建完成后，宠物会自动出现在这里。'
}

$copyPetPromptButton.Add_Click({
    try {
        [System.Windows.Clipboard]::SetText('请帮我创建一只自定义 Codex 健康桌宠。我会用一句描述或上传一张参考图片。创建后立即显示，并且不要修改任何已有官方宠物。')
        Set-Status -Text '创建指令已复制。回到 Codex 粘贴发送即可。' -Color '#668C7B'
    }
    catch { Set-Status -Text '复制失败，请回到 Codex 直接描述想要的宠物。' -Color '#B35F55' }
})

$titleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close(); $eventArgs.Handled = $true }
    elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::S -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $saveButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
        $eventArgs.Handled = $true
    }
})
$closeButton.Add_Click({ $window.Close() })
$cancelButton.Add_Click({ $window.Close() })

$diagnoseButton.Add_Click({
    try {
        $result = (& (Join-Path $PluginRoot 'scripts\diagnose-windows.ps1') -PluginData $PluginData -CodexHome $CodexHome) | ConvertFrom-Json
        if ([bool]$result.ok) {
            $diagnosticText.Text = "运行正常 · 官方源文件未改 · 私有副本完整"
            $diagnosticText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#4F8A72'))
        } else {
            $diagnosticText.Text = "发现问题：" + (@($result.warnings) -join '；')
            $diagnosticText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#B26955'))
        }
    } catch { $diagnosticText.Text = "诊断失败：$($_.Exception.Message)" }
})

$saveButton.Add_Click({
    try {
        if ($petPicker.SelectedIndex -lt 0) { throw '请先选择一只宠物。' }
        if ($quietStart.Text -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' -or $quietEnd.Text -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') { throw '安静时段请用 HH:mm 格式，例如 22:00。' }
        $selectedSensitivity = [string](($sensitivityPicker.SelectedItem).Tag)
        $config.breakSensitivity = $selectedSensitivity
        switch ($selectedSensitivity) {
            'sensitive' { $config.partialBreakStartSeconds = 30; $config.fullBreakSeconds = 180 }
            'conservative' { $config.partialBreakStartSeconds = 120; $config.fullBreakSeconds = 420 }
            default { $config.partialBreakStartSeconds = 60; $config.fullBreakSeconds = 300 }
        }
        $selectedSedentary = [string](($sedentaryPicker.SelectedItem).Tag)
        $config.sedentaryPreset = $selectedSedentary
        switch ($selectedSedentary) {
            'early' { $config.graceSeconds = 1200; $config.lazySeconds = 2400; $config.wiltedSeconds = 3600; $config.sickSeconds = 5400; $config.codexOpportunitySeconds = 1200 }
            'relaxed' { $config.graceSeconds = 2700; $config.lazySeconds = 4500; $config.wiltedSeconds = 6300; $config.sickSeconds = 8100; $config.codexOpportunitySeconds = 2700 }
            default { $config.graceSeconds = 1800; $config.lazySeconds = 3600; $config.wiltedSeconds = 5400; $config.sickSeconds = 7200; $config.codexOpportunitySeconds = 1800 }
        }
        $config.petScale = [math]::Round([double]$scaleSlider.Value, 3)
        $config.dialogueTone = [string](($tonePicker.SelectedItem).Tag)
        $config.quietHoursEnabled = [bool]$quietEnabled.IsChecked
        $config.quietHoursStart = $quietStart.Text
        $config.quietHoursEnd = $quietEnd.Text
        Write-JsonAtomic -Path $configPath -Value $config

        $pet = $pets[$petPicker.SelectedIndex]
        $petChanged = [string]::IsNullOrWhiteSpace($selectionSlug) -or $selectionSlug -ne $pet.Slug -or $selectionType -ne $pet.SourceType
        if ($petChanged) {
            Set-Status -Text '正在建立私有健康副本…'
            if ($pet.SourceType -eq 'custom') {
                $null = & (Join-Path $PluginRoot 'scripts\prepare-pet-windows.ps1') -PluginData $PluginData -CodexHome $CodexHome -SourceDirectory $pet.Directory
            } else {
                $null = & (Join-Path $PluginRoot 'scripts\prepare-pet-windows.ps1') -PluginData $PluginData -CodexHome $CodexHome -SourcePet $pet.Slug
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $PluginData 'picker-completed.flag'), [DateTime]::UtcNow.ToString('o'))
        Write-JsonAtomic -Path (Join-Path $PluginData 'restart.request.json') -Value ([ordered]@{ version = 1; requestedAtUtc = [DateTime]::UtcNow.ToString('o'); reason = 'settings' })
        $window.DialogResult = $true
        $window.Close()
    } catch {
        Write-JsonAtomic -Path (Join-Path $PluginData 'last-error.json') -Value ([ordered]@{ occurredAtUtc = [DateTime]::UtcNow.ToString('o'); component = 'settings'; message = $_.Exception.Message })
        Set-Status -Text $_.Exception.Message -Color '#B35F55'
    }
})

if ($FirstRun) { [System.IO.File]::WriteAllText((Join-Path $PluginData 'picker-completed.flag'), [DateTime]::UtcNow.ToString('o')) }
if ($TestMode -and $AutoCloseSeconds -gt 0) {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($AutoCloseSeconds)
    $timer.Add_Tick({ $timer.Stop(); $window.Close() })
    $timer.Start()
}
$null = $window.ShowDialog()
