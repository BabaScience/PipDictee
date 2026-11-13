; Pip Dictée — Windows installer (Inno Setup 6). Built by CI (.github/workflows/ci.yml and release.yml):
;   iscc /DAppVersion=2.1.0 windows\installer\PipDictee.iss    → windows\target\installer\PipDictee-Setup-2.1.0.exe
; Per-user install, no administrator rights: the app goes to %LOCALAPPDATA%\Programs\Pip Dictée, next to the data
; it already keeps in %APPDATA% and %LOCALAPPDATA%. Six languages, the same as the app.
; This file is UTF-8 with a byte-order mark (Inno Setup needs it for the "é").

#ifndef AppVersion
  #define AppVersion "2.1.0"
#endif
#define AppName "Pip Dictée"
#define AppExe "PipDictee.exe"
#define AppUrl "https://github.com/BabaScience/PipDictee"

[Setup]
; Never change AppId: Windows uses it to recognise upgrades and the uninstaller.
AppId={{561FD19B-3DCA-46BD-8F58-F871F56D9708}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Pip Dictée contributors
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} installer
; Per user, no UAC prompt.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DisableDirPage=auto
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
; 64-bit Windows 10 1809 or later (WebView2's minimum).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
; Look
WizardStyle=modern
SetupIconFile=..\assets\pip-dictee.ico
WizardImageFile=..\assets\wizard.bmp,..\assets\wizard-2x.bmp
WizardSmallImageFile=..\assets\wizard-small.bmp,..\assets\wizard-small-2x.bmp
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
; If Pip Dictée is running during an update or uninstall, close it first (it restarts after an update).
CloseApplications=force
RestartApplications=yes
; Output
OutputDir=..\target\installer
OutputBaseFilename=PipDictee-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
; Uses the Windows display language when it's one of ours; asks otherwise.
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[CustomMessages]
english.StartupGroup=When Windows starts:
english.AutostartTask=Open Pip Dictée when I sign in
english.WebView2Missing=Pip Dictée needs Microsoft Edge WebView2, which isn't installed on this PC.%n%nOpen the download page now? Install it, then run this setup again.
english.DeleteDataQuestion=Also delete your Pip Dictée data?%n%nThis removes your dictionary, your dictation history and the downloaded voice model (about 1.6 GB).%n%nChoose No to keep them for a later reinstall.
french.StartupGroup=Au démarrage de Windows :
french.AutostartTask=Ouvrir Pip Dictée à la connexion
french.WebView2Missing=Pip Dictée a besoin de Microsoft Edge WebView2, qui n'est pas installé sur ce PC.%n%nOuvrir la page de téléchargement maintenant ? Installe-le, puis relance cette installation.
french.DeleteDataQuestion=Supprimer aussi tes données Pip Dictée ?%n%nCela efface ton dictionnaire, ton historique de dictées et le modèle vocal téléchargé (environ 1,6 Go).%n%nChoisis Non pour les garder en vue d'une réinstallation.
german.StartupGroup=Beim Start von Windows:
german.AutostartTask=Pip Dictée beim Anmelden öffnen
german.WebView2Missing=Pip Dictée braucht Microsoft Edge WebView2, das auf diesem PC nicht installiert ist.%n%nDie Download-Seite jetzt öffnen? Installiere es und starte dann diese Installation erneut.
german.DeleteDataQuestion=Auch deine Pip-Dictée-Daten löschen?%n%nDas entfernt dein Wörterbuch, deinen Diktatverlauf und das geladene Sprachmodell (etwa 1,6 GB).%n%nWähle Nein, um sie für eine spätere Neuinstallation zu behalten.
italian.StartupGroup=All'avvio di Windows:
italian.AutostartTask=Apri Pip Dictée all'accesso
italian.WebView2Missing=Pip Dictée ha bisogno di Microsoft Edge WebView2, che non è installato su questo PC.%n%nAprire ora la pagina di download? Installalo, poi riavvia questa installazione.
italian.DeleteDataQuestion=Eliminare anche i tuoi dati di Pip Dictée?%n%nVerranno rimossi il dizionario, la cronologia delle dettature e il modello vocale scaricato (circa 1,6 GB).%n%nScegli No per conservarli per una futura reinstallazione.
spanish.StartupGroup=Al iniciar Windows:
spanish.AutostartTask=Abrir Pip Dictée al iniciar sesión
spanish.WebView2Missing=Pip Dictée necesita Microsoft Edge WebView2, que no está instalado en este PC.%n%n¿Abrir ahora la página de descarga? Instálalo y vuelve a ejecutar esta instalación.
spanish.DeleteDataQuestion=¿Borrar también tus datos de Pip Dictée?%n%nSe eliminarán tu diccionario, tu historial de dictados y el modelo de voz descargado (unos 1,6 GB).%n%nElige No para conservarlos para una futura reinstalación.
brazilianportuguese.StartupGroup=Quando o Windows iniciar:
brazilianportuguese.AutostartTask=Abrir o Pip Dictée ao entrar
brazilianportuguese.WebView2Missing=O Pip Dictée precisa do Microsoft Edge WebView2, que não está instalado neste PC.%n%nAbrir a página de download agora? Instale-o e execute esta instalação de novo.
brazilianportuguese.DeleteDataQuestion=Apagar também seus dados do Pip Dictée?%n%nIsso remove seu dicionário, seu histórico de ditados e o modelo de voz baixado (cerca de 1,6 GB).%n%nEscolha Não para mantê-los para uma futura reinstalação.

[Tasks]
Name: "autostart"; Description: "{cm:AutostartTask}"; GroupDescription: "{cm:StartupGroup}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\target\release\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; The same value the app's "Open at sign-in" setting reads and writes (windows/src/win/autostart.rs), quoted so a
; path with spaces can't be misread.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PipDictee"; ValueData: """{app}\{#AppExe}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
const
  WebView2Client = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  WebView2Download = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

function HasVersion(RootKey: Integer; const Key: String): Boolean;
var
  V: String;
begin
  Result := RegQueryStringValue(RootKey, Key, 'pv', V) and (V <> '') and (V <> '0.0.0.0');
end;

// WebView2 draws Pip Dictée's windows. It's part of Windows 11 and current Windows 10, but can be missing on older
// or trimmed-down installs: say so before installing rather than after.
function WebView2Installed: Boolean;
begin
  Result := HasVersion(HKLM32, WebView2Client) or HasVersion(HKLM64, WebView2Client) or HasVersion(HKCU, WebView2Client);
end;

function InitializeSetup: Boolean;
var
  ErrorCode: Integer;
begin
  Result := True;
  if not WebView2Installed then
  begin
    if SuppressibleMsgBox(CustomMessage('WebView2Missing'), mbConfirmation, MB_YESNO, IDNO) = IDYES then
      ShellExec('open', WebView2Download, '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
    Result := False;
  end;
end;

// Uninstall: stop the app, remove its sign-in entry, and only delete the user's data if they say so (default: keep).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'PipDictee');
    if not UninstallSilent then
      if MsgBox(CustomMessage('DeleteDataQuestion'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(ExpandConstant('{userappdata}\{#AppName}'), True, True, True);
        DelTree(ExpandConstant('{localappdata}\{#AppName}'), True, True, True);
      end;
  end;
end;
