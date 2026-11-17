# Pip Dictée — builds the two OpenVINO downloads that make large-v3-turbo about 2.5× faster on PCs with Intel
# graphics (measured on a Core Ultra 7 155H: about 12 s per dictation instead of 31 s, same text):
#   whisper-openvino-x64.zip                     whisper.cpp built with OpenVINO, plus the OpenVINO runtime (CPU and
#                                                GPU plugins only) and the Visual C++ runtime it needs
#   ggml-large-v3-turbo-encoder-openvino.xml/.bin  large-v3-turbo's encoder converted for OpenVINO, in FP16
# Upload them to the Hugging Face repository named in windows/src/win/setup.rs (OPENVINO_BASE), then paste the
# sizes and SHA-256 this script prints into that file.
#
# Needs: Visual Studio 2022 Build Tools (C++ workload), git, Python 3.10–3.12 on PATH, about 12 GB free.
#   powershell -ExecutionPolicy Bypass -File scripts\build-openvino-windows.ps1 [-Work C:\pipov]
# The work folder must have a short path without accents: the build hits Windows' 260-character limit otherwise.
param([string]$Work = 'C:\pipov')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WhisperVersion = 'v1.8.4'
$Pins = @('openvino==2025.4.1', 'openai-whisper==20250625', 'onnx==1.23.2')
$TorchPin = 'torch==2.15.0'

$VS = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
if (-not (Test-Path "$VS\VC\Auxiliary\Build\vcvars64.bat")) { $VS = 'C:\Program Files\Microsoft Visual Studio\2022\Community' }
if (-not (Test-Path "$VS\VC\Auxiliary\Build\vcvars64.bat")) { throw 'Visual Studio 2022 (C++ build tools) not found.' }
if ($Work -match '[^\x00-\x7F]') { throw "The work folder must not contain accents: $Work" }

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Src = Join-Path $Work 'whisper.cpp'
$Venv = Join-Path $Work 'venv'
$Out = Join-Path $Work 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# 1. Sources and Python tools (pinned).
if (-not (Test-Path $Src)) { git clone --depth 1 --branch $WhisperVersion https://github.com/ggml-org/whisper.cpp $Src; if ($LASTEXITCODE) { throw 'git clone failed' } }
if (-not (Test-Path "$Venv\Scripts\python.exe")) { python -m venv $Venv; if ($LASTEXITCODE) { throw 'python -m venv failed' } }
$Py = "$Venv\Scripts\python.exe"
& $Py -m pip install -q --upgrade pip
& $Py -m pip install -q $TorchPin --index-url https://download.pytorch.org/whl/cpu; if ($LASTEXITCODE) { throw 'pip install torch failed' }
& $Py -m pip install -q @Pins; if ($LASTEXITCODE) { throw 'pip install failed' }
$OvDir = & $Py -I -c "import openvino, os; print(os.path.dirname(openvino.__file__))"

# 2. whisper.cpp with OpenVINO, against the runtime in the Python package.
$Cmd = Join-Path $Work 'build.cmd'
@"
@echo off
call "$VS\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set PATH=$VS\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;$VS\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%
cd /d "$Src" || exit /b 1
if exist build-ov rmdir /s /q build-ov
cmake -S . -B build-ov -G Ninja -DCMAKE_BUILD_TYPE=Release -DWHISPER_OPENVINO=ON -DOpenVINO_DIR="$OvDir\cmake" -DWHISPER_BUILD_TESTS=OFF -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl || exit /b 1
cmake --build build-ov -j --target whisper-cli whisper-server || exit /b 1
"@ | Set-Content -Encoding ascii $Cmd
cmd /c $Cmd; if ($LASTEXITCODE) { throw 'build failed' }

# 3. The engine archive. Only what Pip runs: no NPU plugin (its output was wrong in tests), no model frontends
#    besides OpenVINO's own format.
$Stage = Join-Path $Work 'engine'
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Path $Stage | Out-Null
Copy-Item "$Src\build-ov\bin\whisper-server.exe", "$Src\build-ov\bin\whisper-cli.exe", "$Src\build-ov\bin\*.dll" $Stage
$OvLibs = 'openvino.dll', 'openvino_intel_cpu_plugin.dll', 'openvino_intel_gpu_plugin.dll', 'openvino_ir_frontend.dll', 'tbb12.dll', 'tbbmalloc.dll', 'tbbbind_2_5.dll'
foreach ($f in $OvLibs) { Copy-Item "$OvDir\libs\$f" $Stage }
$Redist = Get-ChildItem "$VS\VC\Redist\MSVC" -Directory | Where-Object { $_.Name -match '^\d' } | Sort-Object Name | Select-Object -Last 1
Copy-Item "$($Redist.FullName)\x64\Microsoft.VC143.CRT\msvcp140.dll", "$($Redist.FullName)\x64\Microsoft.VC143.CRT\vcruntime140.dll",
          "$($Redist.FullName)\x64\Microsoft.VC143.CRT\vcruntime140_1.dll", "$($Redist.FullName)\x64\Microsoft.VC143.OpenMP\vcomp140.dll" $Stage
Copy-Item "$Src\LICENSE" "$Stage\LICENSE-whisper.cpp.txt"
$OvLicense = Get-ChildItem (Split-Path $OvDir) -Directory -Filter 'openvino-*.dist-info' | Select-Object -First 1
Get-ChildItem $OvLicense.FullName -Recurse -File | Where-Object { $_.Name -match 'LICENSE|third-party' } |
  ForEach-Object { Copy-Item $_.FullName "$Stage\OpenVINO-$($_.BaseName).txt" }
$Zip = Join-Path $Out 'whisper-openvino-x64.zip'
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path "$Stage\*" -DestinationPath $Zip

# 4. The encoder: PyTorch → ONNX → OpenVINO, saved in FP16 (half the size; the GPU computes in FP16 anyway).
$Conv = Join-Path $Work 'convert.py'
@'
import os, sys, tempfile, torch, whisper, openvino as ov
out = sys.argv[1]
model = whisper.load_model("large-v3-turbo").cpu()
enc = model.encoder.eval()
with tempfile.TemporaryDirectory() as tmp:
    onnx = os.path.join(tmp, "encoder.onnx")
    torch.onnx.export(enc, torch.zeros((1, model.dims.n_mels, 3000)), onnx,
                      input_names=["mel"], output_names=["output_features"], dynamo=False)
    ov.save_model(ov.convert_model(onnx), os.path.join(out, "ggml-large-v3-turbo-encoder-openvino.xml"), compress_to_fp16=True)
'@ | Set-Content -Encoding ascii $Conv
& $Py -I $Conv $Out; if ($LASTEXITCODE) { throw 'conversion failed' }

# 5. What to paste into setup.rs.
Write-Host "`nUpload these files from ${Out}:"
Get-ChildItem $Out -File | ForEach-Object {
  '{0}  {1} bytes  sha256 {2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
