; MockMate — Inno Setup script
; Packages the Flutter Windows build into a one-click installer.
; Does NOT bundle Ollama, models, or language runtimes — handled by first-run wizard.
;
; Build prerequisites:
;   1. flutter build windows --release
;   2. Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
;   3. Run: iscc installer\windows\mockmate.iss

#define AppName      "MockMate"
#define AppVersion   "1.0.0"
#define AppPublisher "MockMate Contributors"
#define AppURL       "https://github.com/akauthale/MockMate"
#define AppExeName   "mockmate.exe"
#define BuildDir     "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{7A3F2E1D-8B4C-4E6A-9F2B-3D5C8A1E7F2B}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=MockMateSetup-{#AppVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Require Windows 10 or later
MinVersion=10.0.17763
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter app bundle (entire Release folder)
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";        Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Registry]
; Add to "Add or Remove Programs"
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppName}"; ValueType: string; ValueName: "DisplayName";    ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppName}"; ValueType: string; ValueName: "DisplayVersion"; ValueData: "{#AppVersion}"
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppName}"; ValueType: string; ValueName: "Publisher";      ValueData: "{#AppPublisher}"
