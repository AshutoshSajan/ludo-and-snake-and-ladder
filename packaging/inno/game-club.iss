; Game Club Windows installer (built by release.yaml via Inno Setup 6).
; AppVersion is injected with /DAppVersion=X.Y.Z. The AppId below is a
; permanent install identity: never change it or upgrades break.
#ifndef AppVersion
#define AppVersion "0.0.0"
#endif

[Setup]
AppId={{3A7F1C9E-4B2D-48F5-A6E1-9C0D5B7F2E48}
AppName=Game Club
AppVersion={#AppVersion}
AppPublisher=Ashutosh Sajan
AppPublisherURL=https://github.com/AshutoshSajan/ludo-and-snake-and-ladder
AppSupportURL=https://github.com/AshutoshSajan/ludo-and-snake-and-ladder/issues
DefaultDirName={autopf}\GameClub
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
OutputBaseFilename=game-club-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\game_club.exe
VersionInfoVersion={#AppVersion}

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Game Club"; Filename: "{app}\game_club.exe"
Name: "{autodesktop}\Game Club"; Filename: "{app}\game_club.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; Flags: unchecked

[Run]
Filename: "{app}\game_club.exe"; Description: "Launch Game Club"; Flags: nowait postinstall skipifsilent
