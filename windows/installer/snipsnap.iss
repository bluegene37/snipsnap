; Inno Setup script for SnipSnap.
;
; Do not run this by hand - build_installer.ps1 compiles it and passes in the
; version and paths. See docs/release.md.

#define MyAppName      "SnipSnap"
#define MyAppPublisher "Genexis"
#define MyAppExeName   "snipsnap.exe"
#define MyAppUserModelId "dev.genexis.snipsnap"

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
; Never change AppId. Windows matches upgrades and the uninstall entry on it,
; so a new value here turns every future release into a second app installed
; side by side instead of an upgrade.
AppId={{ABFCA52B-CFD5-4FC0-8F3B-584EB49D60E1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}

; PrivilegesRequired=lowest installs per-user, which is what makes this run
; with no UAC prompt - the whole point of an installer you can hand to a
; friend. {autopf} resolves to {localappdata}\Programs under that setting.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=yes

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir={#OutputDir}
OutputBaseFilename=SnipSnap-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Release directory, not just the exe - snipsnap.exe will not start
; without flutter_windows.dll, the plugin DLLs and data\.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; AppUserModelID must match the string main.cpp passes to
; SetCurrentProcessExplicitAppUserModelID, or taskbar pinning and notifications
; bind to a different identity than the running process claims.
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "{#MyAppUserModelId}"
Name: "{autodesktop}\{#MyAppName}";  Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "{#MyAppUserModelId}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
