#define MyAppName "OT Laundry"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "OT"
#define MyAppExeName "OT-Laundry.exe"

[Setup]
AppId={{B89A59D7-3F0A-4C88-8A93-0A7A0D1A0100}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\OT Laundry
DefaultGroupName=OT Laundry
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\release
OutputBaseFilename=OT-Laundry-Setup-1.0.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#MyAppExeName}

[Files]
Source: "..\dist\OT-Laundry\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README_AR.md"; DestDir: "{app}\docs"; DestName: "README_AR.txt"; Flags: ignoreversion
Source: "..\docs\USER_GUIDE_AR.md"; DestDir: "{app}\docs"; DestName: "USER_GUIDE_AR.txt"; Flags: ignoreversion
Source: "..\.env.example"; DestDir: "{localappdata}\OT-Laundry"; DestName: ".env"; Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{userdesktop}\OT Laundry"; Filename: "{app}\{#MyAppExeName}"
Name: "{userprograms}\OT Laundry"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "تشغيل OT Laundry"; Flags: postinstall nowait skipifsilent
