@echo off
rem Copy the SketchUp extension from this repo into the SketchUp 2025 Plugins folder.
set "PLUGINS=%AppData%\SketchUp\SketchUp 2025\SketchUp\Plugins"
set "SRC=%~dp0..\sketchup"

if not exist "%PLUGINS%" (
  echo Plugins folder not found: %PLUGINS%
  exit /b 1
)

copy /Y "%SRC%\su_blender_sync.rb" "%PLUGINS%\" >nul
if not exist "%PLUGINS%\su_blender_sync" mkdir "%PLUGINS%\su_blender_sync"
copy /Y "%SRC%\su_blender_sync\core.rb" "%PLUGINS%\su_blender_sync\" >nul

echo Deployed to %PLUGINS%
echo Restart SketchUp to reload the extension.
