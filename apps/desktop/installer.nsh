!macro customInstall
  DetailPrint "Provisioning the dedicated local PostgreSQL database..."
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\installer\Install-LocalPos.ps1" -InstallDirectory "$INSTDIR"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Local PostgreSQL setup failed. Existing database files were preserved. Review the installer log and contact support before retrying."
    Abort
  ${EndIf}
!macroend

!macro customUnInstall
  DetailPrint "Preserving local business data while removing the POS service..."
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\installer\Uninstall-LocalPos.ps1" -InstallDirectory "$INSTDIR"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "The dedicated service could not be safely removed. The application and all ProgramData files were preserved."
    Abort
  ${EndIf}
!macroend
