; Squirrel's Windows installer (Inno Setup 6). .github/workflows/windows.yml builds it from
; desktop\windows after `gradlew createDistributable`:
;   ISCC /DAppVersion=1.2.3 packaging\squirrel.iss   ->  build\installer\Squirrel-Setup.exe
; It installs just for the current user, so there's no admin prompt and the download engine can
; update itself. The artwork comes from branding/render_icons.py.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
; Keep constant: it's how a new version finds the installed one and upgrades it
AppId={{7E58396B-29A7-4B35-87AF-2756BCB67A6B}
AppName=Squirrel
AppVersion={#AppVersion}
AppVerName=Squirrel {#AppVersion}
AppPublisher=Squirrel
AppPublisherURL=https://github.com/NatanRA/squirrel
AppSupportURL=https://github.com/NatanRA/squirrel/issues
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\Squirrel
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=Squirrel-Setup
SetupIconFile=..\icon.ico
UninstallDisplayIcon={app}\Squirrel.exe
UninstallDisplayName=Squirrel
WizardStyle=modern
WizardImageFile=wizard.bmp,wizard-2x.bmp
WizardSmallImageFile=wizard-small.bmp,wizard-small-2x.bmp
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
; An update runs while Squirrel may still be closing, or its engine is open in a browser
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; What the previous version installed, so none of its files linger (e.g. old engine packages)
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\runtime"

[Files]
Source: "..\build\compose\binaries\main\app\Squirrel\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Squirrel"; Filename: "{app}\Squirrel.exe"
Name: "{autodesktop}\Squirrel"; Filename: "{app}\Squirrel.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Squirrel.exe"; Description: "{cm:LaunchProgram,Squirrel}"; Flags: nowait postinstall skipifsilent
; Squirrel runs its own updates silently (AppUpdater.kt), then this reopens it
Filename: "{app}\Squirrel.exe"; Flags: nowait skipifnotsilent

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\';

// Squirrel 1.6.5 came as an MSI, installed elsewhere: remove it so there aren't two copies
procedure RemoveMsiVersion;
var
  Keys: TArrayOfString;
  I, ResultCode: Integer;
  Name: String;
  IsMsi: Cardinal;
begin
  if not RegGetSubkeyNames(HKCU, UninstallKey, Keys) then
    Exit;
  for I := 0 to GetArrayLength(Keys) - 1 do
    if RegQueryStringValue(HKCU, UninstallKey + Keys[I], 'DisplayName', Name) and (Name = 'Squirrel')
       and RegQueryDWordValue(HKCU, UninstallKey + Keys[I], 'WindowsInstaller', IsMsi) and (IsMsi = 1) then
      Exec('msiexec.exe', '/x ' + Keys[I] + ' /qn', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    RemoveMsiVersion;
end;
