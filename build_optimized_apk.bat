@echo off
chcp 65001 > nul
echo ========================================================
echo  Cloud Media Player - 최적화 릴리스 APK 빌드 시작
echo  (ABI 아키텍처 분할 + R8 코드 축소 + 디버그 심볼 분리)
echo ========================================================
echo.

cd /d "%~dp0"

echo [1/2] 최적화 APK 빌드 중... (몇 분 정도 소요될 수 있습니다)
call flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/app/outputs/symbols

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [오류] 빌드에 실패했습니다.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo ========================================================
echo  [빌드 완료] 생성된 APK 파일 목록 및 용량:
echo ========================================================
powershell -Command "Get-ChildItem -Path 'build\app\outputs\flutter-apk' -Filter 'app-*-release.apk' | Select-Object Name, @{Name='크기(MB)';Expression={[math]::Round($_.Length/1MB, 2)}} | Format-Table -AutoSize"

echo.
echo 일반적인 최신 스마트폰(Galaxy, Pixel, Xiaomi 등)에는:
echo 👉 app-arm64-v8a-release.apk 파일을 설치하시면 됩니다!
echo.
pause
