#!/usr/bin/env bash
# install-dxo-photolab.sh — Installe DxO PhotoLab 9 sous Wine (Ubuntu) à partir de zéro.
#
# Testé avec : Ubuntu 26.04, NVIDIA RTX 5070 Ti, Wine Staging 11.19, PhotoLab 9.13.1.
# Les raisons de chaque étape sont détaillées dans README.md.
#
# Le script reprend là où il s'est arrêté : chaque étape terminée est marquée dans
# <préfixe>/.dxo-install/. Utiliser --redo pour en refaire certaines.
set -euo pipefail

# ---------------------------------------------------------------- versions
WINE_VERSION="${WINE_VERSION:-11.19}"
VKD3D_VERSION="${VKD3D_VERSION:-3.0.1}"
DXVK_VERSION="${DXVK_VERSION:-3.1.1}"
WINETRICKS_VERSION="${WINETRICKS_VERSION:-20250102}"
FONTTOOLS_VERSION="4.55.3"
CECIL_VERSION="0.11.6"
DXO_LANG="${DXO_LANG:-fr-FR}"

# ---------------------------------------------------------------- options
PREFIX="$HOME/.wine-dxo"
SETUP=""
DO_SYSTEM=1
DO_LAUNCHER=1
REDO=""
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/dxo-photolab-install"
LIBDIR="$HOME/.local/share/dxo-photolab"

STEPS=(prefix dotnet48 vcrun2022 winetricks-misc photolab webview2 dxvk-vkd3d gpu-dxcore winml ui
       patch-bootstrap patch-codepack user-settings launcher)

usage() {
    cat <<EOF
Usage : $0 [options]

  --setup FICHIER   installeur DxO_PhotoLab9_Setup.exe (par défaut : cherché dans le
                    dossier courant, ~/Téléchargements et ~/Downloads)
  --prefix DOSSIER  préfixe Wine à créer (défaut : $PREFIX)
  --skip-system     ne pas toucher au système (pas de sudo : Wine, winbind… déjà installés)
  --no-launcher     ne pas créer le lanceur ~/.local/bin/dxo-photolab ni l'entrée de menu
  --redo ÉTAPES     refaire des étapes déjà faites, séparées par des virgules
                    (${STEPS[*]})
  -h, --help        cette aide

Variables : WINE_VERSION ($WINE_VERSION), VKD3D_VERSION ($VKD3D_VERSION),
            DXVK_VERSION ($DXVK_VERSION), DXO_LANG ($DXO_LANG)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup) SETUP="$(realpath "$2")"; shift 2 ;;
        --prefix) PREFIX="$(realpath -m "$2")"; shift 2 ;;
        --skip-system) DO_SYSTEM=0; shift ;;
        --no-launcher) DO_LAUNCHER=0; shift ;;
        --redo) REDO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------- helpers
mkdir -p "$WORK" "$LIBDIR"
LOG="$WORK/install.log"
exec > >(tee -a "$LOG") 2>&1

# messages sur stderr : stdout sert à renvoyer des valeurs via $(...)
log()  { printf '\033[1;34m[dxo]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dxo] ERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

export WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all
MARK="$PREFIX/.dxo-install"

winpath() { winepath -w "$1" 2>/dev/null; }
wreg()    { wine reg add "$@" /f >/dev/null 2>&1; }
# attend la fin des processus Wine ; au-delà de 20 min (service resté en mémoire), on les arrête
wwait()   { timeout 1200 wineserver -w || { log "processus Wine encore actifs : arrêt"; wineserver -k || true; }; }

fetch() {  # fetch URL FICHIER — télécharge une seule fois (cache dans $WORK)
    local url=$1 out=$2
    [[ -s "$out" ]] && return 0
    log "  téléchargement de $(basename "$out")"
    mkdir -p "$(dirname "$out")"
    curl -fL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
}

run_step() {
    local name=$1; shift
    if [[ -f "$MARK/$name.done" ]]; then
        log "✓ $name (déjà fait)"
        return 0
    fi
    log "▶ $name"
    "$@"
    mkdir -p "$MARK"
    touch "$MARK/$name.done"
}

appdir() {
    local d
    d=$(ls -d "$PREFIX/drive_c/Program Files/DxO/DxO PhotoLab "* 2>/dev/null | head -1)
    [[ -n "$d" ]] || die "PhotoLab n'est pas installé dans $PREFIX"
    printf '%s\n' "$d"
}

# ---------------------------------------------------------------- étapes

step_system() {
    # shellcheck disable=SC1091
    . /etc/os-release
    local codename=$VERSION_CODENAME v
    v="${WINE_VERSION}~${codename}-1"
    log "▶ system (sudo) : Wine Staging $v, winbind et outils"
    sudo -v
    for p in wine wine64; do
        if dpkg -l "$p" 2>/dev/null | grep -q '^ii'; then
            log "  suppression du paquet Ubuntu '$p' (remplacé par WineHQ)"
            sudo apt remove -y "$p"
        fi
    done
    sudo mkdir -pm755 /etc/apt/keyrings
    sudo curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
    sudo curl -fsSL -o "/etc/apt/sources.list.d/winehq-$codename.sources" \
        "https://dl.winehq.org/wine-builds/ubuntu/dists/$codename/winehq-$codename.sources"
    sudo dpkg --add-architecture i386
    sudo apt update
    sudo apt install -y --install-recommends "winehq-staging=$v" "wine-staging=$v"
    # winbind : ntlm_auth, indispensable à la communication PhotoLab <-> moteur d'export (WCF)
    sudo apt install -y winbind cabextract 7zip zstd unzip curl binutils python3-venv
}

check_tools() {
    local missing=()
    for t in wine wineserver winepath 7z cabextract zstd unzip curl strings python3 ntlm_auth; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "outils manquants : ${missing[*]} (relancer sans --skip-system)"
    python3 -c 'import venv' 2>/dev/null || die "python3-venv manquant"
    log "Wine : $(wine --version)"
}

step_prefix() {
    wineboot -u
    wwait
}

winetricks_bin() {
    fetch "https://raw.githubusercontent.com/Winetricks/winetricks/$WINETRICKS_VERSION/src/winetricks" \
        "$WORK/winetricks-$WINETRICKS_VERSION"
    chmod +x "$WORK/winetricks-$WINETRICKS_VERSION"
    printf '%s\n' "$WORK/winetricks-$WINETRICKS_VERSION"
}

step_dotnet48() {
    "$(winetricks_bin)" -q dotnet48
    wwait
    [[ -d "$PREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319" ]] || die ".NET 4.8 absent après installation"
}

step_vcrun2022() {
    # le verbe winetricks vcrun2022 échoue (téléchargement via archive.org) : installation directe
    local d="$WORK/vcrun2022"
    fetch https://aka.ms/vs/17/release/vc_redist.x86.exe "$d/vc_redist.x86.exe"
    fetch https://aka.ms/vs/17/release/vc_redist.x64.exe "$d/vc_redist.x64.exe"
    wine "$d/vc_redist.x86.exe" /install /quiet /norestart || true
    wine "$d/vc_redist.x64.exe" /install /quiet /norestart || true
    wwait
    [[ -f "$PREFIX/drive_c/windows/system32/msvcp140.dll" ]] || die "Visual C++ 2022 non installé"
}

step_winetricks_misc() {
    "$(winetricks_bin)" -q d3dcompiler_47 corefonts win11
    wwait
    # PhotoLab 9 refuse les builds Windows < 24H2
    local k='HKLM\Software\Microsoft\Windows NT\CurrentVersion'
    wreg "$k" /v CurrentBuild /t REG_SZ /d 26100
    wreg "$k" /v CurrentBuildNumber /t REG_SZ /d 26100
    wreg "$k" /v DisplayVersion /t REG_SZ /d 24H2
    wreg "$k" /v ProductName /t REG_SZ /d "Windows 11 Pro"
    wineserver -k || true
}

step_photolab() {
    [[ -n "$SETUP" && -f "$SETUP" ]] || die "installeur introuvable (option --setup)"
    local x="$WORK/setup-extract"
    rm -rf "$x"; mkdir -p "$x/idt"
    log "  extraction de $(basename "$SETUP")"
    7z x -y -o"$x" "$SETUP" >/dev/null
    local msi
    msi=$(ls "$x"/*.msi | head -1)
    [[ -f "$msi" ]] || die "pas de .msi dans l'installeur"
    cp "$msi" "$x/patched.msi"

    # Désactive les actions qui vérifient/installent le Windows App SDK (impossible sous Wine)
    # et WebView2 (installé séparément, étape webview2).
    log "  modification du MSI (CheckWindowsAppSDKRuntime, SetIsWebView2RuntimeRequired)"
    wine msidb -d "$(winpath "$x/patched.msi")" -f "$(winpath "$x/idt")" -e InstallExecuteSequence
    local idt="$x/idt/InstallExecuteSequence.idt"
    sed -i -E 's/^(SetIsWebView2RuntimeRequired|CheckWindowsAppSDKRuntime)\t[^\t]*\t/\1\t0\t/' "$idt"
    grep -q $'^CheckWindowsAppSDKRuntime\t0\t' "$idt" || die "modification du MSI impossible"
    wine msidb -d "$(winpath "$x/patched.msi")" -f "$(winpath "$x/idt")" -i InstallExecuteSequence.idt

    log "  installation (fenêtre de progression, aucun clic nécessaire)"
    (cd "$x" && wine msiexec /i patched.msi /qb /l*v "$(winpath "$x/msi.log")") || true
    wwait
    [[ -f "$(appdir)/DxO.PhotoLab.exe" ]] || die "installation échouée, voir $x/msi.log"
}

step_webview2() {
    local f="$WORK/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
    fetch "https://go.microsoft.com/fwlink/?linkid=2124701" "$f"
    wine "$f" /silent /install || true
    # MicrosoftEdgeUpdate.exe reste en mémoire après l'installation : wineserver -w ne rendrait jamais la main
    wineserver -k || true
    ls "$PREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/"*/msedgewebview2.exe >/dev/null 2>&1 \
        || die "WebView2 non installé"
}

step_dxvk_vkd3d() {
    local v="$WORK/vkd3d-proton-$VKD3D_VERSION" d="$WORK/dxvk-$DXVK_VERSION"
    local sys32="$PREFIX/drive_c/windows/system32" wow64="$PREFIX/drive_c/windows/syswow64"
    fetch "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v$VKD3D_VERSION/vkd3d-proton-$VKD3D_VERSION.tar.zst" "$v.tar.zst"
    fetch "https://github.com/doitsujin/dxvk/releases/download/v$DXVK_VERSION/dxvk-$DXVK_VERSION.tar.gz" "$d.tar.gz"
    tar -C "$WORK" --zstd -xf "$v.tar.zst"
    tar -C "$WORK" -xzf "$d.tar.gz"
    cp "$v"/x64/*.dll "$sys32/"; cp "$v"/x86/*.dll "$wow64/"
    cp "$d"/x64/*.dll "$sys32/"; cp "$d"/x32/*.dll "$wow64/"
    local dll
    for dll in d3d12 d3d12core d3d11 d3d10core d3d9 d3d8 dxgi; do
        wreg 'HKCU\Software\Wine\DllOverrides' /v "$dll" /t REG_SZ /d native
    done
    # WebView2 : DXVK n'implémente pas CreateSwapChainForComposition -> DirectX intégré de Wine
    for dll in dxgi d3d11 d3d10core d3d12 d3d12core d3d9; do
        wreg 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides' /v "$dll" /t REG_SZ /d builtin
    done
}

install_dxcore_patcher() {
    cat > "$LIBDIR/patch_dxcore.py" <<'PY'
"""Patch Wine's builtin dxcore.dll (x86_64) so DxO PhotoLab accepts the GPU.

Wine's DXCore stubs make PhotoLab reject the GPU (no AI acceleration, no OpenCL):
  IsAttributeSupported      -> always TRUE (PhotoLab checks D3D12_GRAPHICS)
  GetProperty (unknown id)  -> 0 / S_OK instead of DXGI_ERROR_INVALID_CALL (IsIntegrated, IsDetachable)
  IsQueryStateSupported     -> TRUE for AdapterMemoryBudget
  QueryState(MemoryBudget)  -> budget = adapter video memory
  IsSetStateSupported       -> TRUE for AdapterMemoryReservation
  SetState(Reservation)     -> S_OK (ignored)
The "Wine builtin DLL" marker is cleared so Wine loads the file as a native DLL.

Function addresses come from the DLL's own COFF symbol table, and every patch checks the
original bytes, so a different Wine build fails loudly instead of being corrupted.
Usage: python3 -I patch_dxcore.py <wine dxcore.dll> <out.dll>
"""
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, "rb").read())
size0 = len(d)

pe = struct.unpack_from("<I", d, 0x3C)[0]
assert d[pe:pe + 4] == b"PE\0\0"
nsect, _, symptr, nsyms = struct.unpack_from("<HIII", d, pe + 6)
optsize = struct.unpack_from("<H", d, pe + 20)[0]
sect_tab = pe + 24 + optsize
sections = []
for i in range(nsect):
    vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", d, sect_tab + 40 * i + 8)
    sections.append((vaddr, rawptr))

strtab = symptr + 18 * nsyms
syms = {}
i = 0
while i < nsyms:
    off = symptr + 18 * i
    raw = d[off:off + 8]
    if raw[:4] == b"\0\0\0\0":
        so = strtab + struct.unpack_from("<I", raw, 4)[0]
        name = bytes(d[so:d.index(b"\0", so)]).decode()
    else:
        name = raw.rstrip(b"\0").decode(errors="replace")
    value, secnum = struct.unpack_from("<Ih", d, off + 8)
    if secnum > 0:
        syms.setdefault(name, sections[secnum - 1][1] + value)
    i += 1 + d[off + 17]


def patch(func, code, expect_prefix, at=0):
    off = syms[func] + at
    assert d[off:off + len(expect_prefix)] == expect_prefix, \
        f"{func}+{at:#x}: unexpected bytes {d[off:off + 8].hex()} (different Wine build?)"
    d[off:off + len(code)] = code          # same length: never shifts the file
    print(f"  {func}+{at:#x}: {len(code)} bytes")


SUB_RSP = bytes.fromhex("4883ec")
RET_STATE_IS_1 = bytes.fromhex("31c0 83fa01 0f94c0 c3")            # return state == 1

patch("dxcore_adapter_IsAttributeSupported", bytes.fromhex("b801000000 c3"), bytes.fromhex("53"))

# GetProperty: branch for unimplemented properties (testb dbch; jne log; mov eax,DXGI_ERROR_INVALID_CALL)
gp = syms["dxcore_adapter_GetProperty"]
branch = d.index(bytes.fromhex("b801007a88"), gp, gp + 0x200) - 0x0d
patch("dxcore_adapter_GetProperty", bytes.fromhex(
    "c60600"            # movb $0,(rsi)          rsi = buffer
    "4883fd08"          # cmp rbp,8              rbp = buffer_size
    "7207"              # jb +7
    "48c70600000000"    # movq $0,(rsi)
    "31c0"              # xor eax,eax  -> falls through into the existing epilogue
), bytes.fromhex("f605"), at=branch - gp)
assert d[branch + 0x12:branch + 0x16] == bytes.fromhex("4883c440"), "epilogue not where expected"

patch("dxcore_adapter_IsQueryStateSupported", RET_STATE_IS_1, SUB_RSP)
patch("dxcore_adapter_IsSetStateSupported", RET_STATE_IS_1, SUB_RSP)

# QueryState(AdapterMemoryBudget): video_memory read like GetProperty(DedicatedAdapterMemory)
vram_off = 0x88
assert bytes.fromhex("488b8788000000") in d[gp:gp + 0x220], "video_memory offset changed"
body = bytearray.fromhex(
    "488b442430"        # mov rax,[rsp+0x30]     buffer
    "4885c0" "7400"     # test rax,rax ; je fail (offset set below)
    "4c8b91") + struct.pack("<I", vram_off) + bytes.fromhex(  # mov r10,[rcx+vram]
    "4c8910"            # Budget
    "48c7400800000000"  # CurrentUsage
    "49d1ea" "4c895010" # AvailableForReservation = vram/2
    "48c7401800000000"  # CurrentReservation
    "31c0c3")           # S_OK
body[9] = len(body) - 10
qs = bytes.fromhex("83fa01") + bytes([0x75, len(body)]) + body + bytes.fromhex("b801400080 c3")
patch("dxcore_adapter_QueryState", qs, SUB_RSP)

patch("dxcore_adapter_SetState", bytes.fromhex("83fa01 7503 31c0c3 b801400080 c3"), SUB_RSP)

assert d[0x40:0x50] == b"Wine builtin DLL"
d[0x40:0x50] = b"\0" * 16
assert len(d) == size0
open(dst, "wb").write(d)
print("dxcore.dll patched")
PY
}

wine_dxcore() {
    local root
    root=$(dirname "$(dirname "$(readlink -f "$(command -v wine)")")")
    printf '%s\n' "$root/lib/wine/x86_64-windows/dxcore.dll"
}

step_gpu_dxcore() {
    # Sans ça, PhotoLab ne voit pas la carte graphique (« CPU » seulement, OpenCL indisponible) :
    # la DXCore de Wine est un ensemble de stubs. Copie corrigée chargée comme DLL native.
    local src app vram
    src=$(wine_dxcore)
    app=$(appdir)
    [[ -f "$src" ]] || die "dxcore.dll de Wine introuvable ($src)"
    install_dxcore_patcher
    python3 -I "$LIBDIR/patch_dxcore.py" "$src" "$app/dxcore.dll"
    sha256sum < "$src" > "$LIBDIR/dxcore.src.sha256"
    wreg 'HKCU\Software\Wine\DllOverrides' /v dxcore /t REG_SZ /d native,builtin
    # Mémoire vidéo annoncée par wined3d/DXCore (Wine annonce sinon ~165 Mo)
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    [[ "$vram" =~ ^[0-9]+$ ]] || vram=8192
    log "  mémoire vidéo annoncée : $vram Mo"
    wreg 'HKCU\Software\Wine\Direct3D' /v VideoMemorySize /t REG_SZ /d "$vram"
}

step_winml() {
    # Classes WinRT de WinML : normalement trouvées via le Windows App SDK, ici déclarées au registre.
    local app reg="$WORK/winml.reg" dll c
    app=$(appdir)
    local winapp
    winapp=$(winpath "$app")
    winapp=${winapp//\\/\\\\}
    printf 'Windows Registry Editor Version 5.00\r\n\r\n' > "$reg"
    for dll in Microsoft.AI.MachineLearning Microsoft.Windows.AI.MachineLearning; do
        { strings -e l "$app/$dll.dll"; strings "$app/$dll.dll"; } \
            | grep -E "^${dll//./\\.}\.[A-Za-z0-9]+$" | grep -v -E '\.dll$|\.I[A-Z]' | sort -u \
            | while read -r c; do
                printf '[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\WindowsRuntime\\ActivatableClassId\\%s]\r\n"DllPath"="%s\\\\%s.dll"\r\n"ActivationType"=dword:00000000\r\n"Threading"=dword:00000000\r\n\r\n' \
                    "$c" "$winapp" "$dll"
            done >> "$reg"
    done
    log "  $(grep -c ActivatableClassId "$reg") classes WinML déclarées"
    wine regedit /S "$(winpath "$reg")"
    wwait
}

step_ui() {
    # Menus noirs : rendu logiciel pour l'interface WPF (le traitement d'image reste sur GPU)
    wreg 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1
    # Lissage des polices (ClearType RGB)
    local k='HKCU\Control Panel\Desktop'
    wreg "$k" /v FontSmoothing /t REG_SZ /d 2
    wreg "$k" /v FontSmoothingType /t REG_DWORD /d 2
    wreg "$k" /v FontSmoothingGamma /t REG_DWORD /d 1400
    wreg "$k" /v FontSmoothingOrientation /t REG_DWORD /d 1

    # Segoe UI absente sous Wine : Selawik (police libre Microsoft, mêmes métriques) renommée
    local s="$WORK/selawik" venv="$WORK/venv"
    fetch https://github.com/microsoft/Selawik/releases/download/1.01/Selawik_Release.zip "$s/Selawik_Release.zip"
    unzip -o -q "$s/Selawik_Release.zip" -d "$s/x"
    [[ -x "$venv/bin/python" ]] || python3 -m venv "$venv"
    "$venv/bin/pip" -q install "fonttools==$FONTTOOLS_VERSION"
    cat > "$WORK/selawik_as_segoe.py" <<'PY'
import os, sys
from fontTools.ttLib import TTFont
src_dir, out_dir = sys.argv[1], sys.argv[2]
MAP = {
    "selawk.ttf": ("segoeui.ttf", "Segoe UI", "Regular", "Regular"),
    "selawkb.ttf": ("segoeuib.ttf", "Segoe UI", "Bold", "Bold"),
    "selawksb.ttf": ("seguisb.ttf", "Segoe UI Semibold", "Regular", "Semibold"),
    "selawkl.ttf": ("segoeuil.ttf", "Segoe UI Light", "Regular", "Light"),
    "selawksl.ttf": ("segoeuisl.ttf", "Segoe UI Semilight", "Regular", "Semilight"),
}
for src, (out, fam, sub, tsub) in MAP.items():
    font = TTFont(os.path.join(src_dir, src))
    full = fam if sub == "Regular" else f"{fam} {sub}"
    for nid, val in {1: fam, 2: sub, 3: full, 4: full, 6: full.replace(" ", ""),
                     16: "Segoe UI", 17: tsub}.items():
        font["name"].removeNames(nameID=nid)
        font["name"].setName(val, nid, 3, 1, 0x409)
        font["name"].setName(val, nid, 1, 0, 0)
    font.save(os.path.join(out_dir, out))
PY
    "$venv/bin/python" -I "$WORK/selawik_as_segoe.py" "$s/x" "$PREFIX/drive_c/windows/Fonts"
    local fk='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    wreg "$fk" /v "Segoe UI (TrueType)" /d segoeui.ttf
    wreg "$fk" /v "Segoe UI Bold (TrueType)" /d segoeuib.ttf
    wreg "$fk" /v "Segoe UI Semibold (TrueType)" /d seguisb.ttf
    wreg "$fk" /v "Segoe UI Light (TrueType)" /d segoeuil.ttf
    wreg "$fk" /v "Segoe UI Semilight (TrueType)" /d segoeuisl.ttf
}

step_patch_bootstrap() {
    # Le Windows App SDK ne peut pas s'initialiser sous Wine. On fait répondre « succès » au
    # bootstrapper : PhotoLab peut alors activer le moteur IA ONNX (cf. étape user-settings).
    local b
    b="$(appdir)/Microsoft.WindowsAppRuntime.Bootstrap.dll"
    [[ -f "$b.orig" ]] || cp "$b" "$b.orig"
    cat > "$WORK/patch_bootstrap.py" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe:pe + 4] == b"PE\0\0"
nsect = struct.unpack_from("<H", data, pe + 6)[0]
optsize = struct.unpack_from("<H", data, pe + 20)[0]
opt = pe + 24
assert struct.unpack_from("<H", data, opt)[0] == 0x20B, "PE32+ attendu"
sections = []
for i in range(nsect):
    vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, opt + optsize + 40 * i + 8)
    sections.append((vaddr, max(vsize, rawsize), rawptr))
def off(rva):
    for vaddr, size, rawptr in sections:
        if vaddr <= rva < vaddr + size:
            return rawptr + rva - vaddr
    raise ValueError(hex(rva))
e = off(struct.unpack_from("<I", data, opt + 112)[0])
_, nnames, funcs, names, ords = struct.unpack_from("<IIIII", data, e + 20)
done = 0
for i in range(nnames):
    n = off(struct.unpack_from("<I", data, off(names) + 4 * i)[0])
    name = bytes(data[n:data.index(b"\0", n)]).decode()
    if not name.startswith("MddBootstrap"):
        continue
    o = struct.unpack_from("<H", data, off(ords) + 2 * i)[0]
    fo = off(struct.unpack_from("<I", data, off(funcs) + 4 * o)[0])
    patch = b"\xC3" if name == "MddBootstrapShutdown" else b"\x31\xC0\xC3"  # ret / xor eax,eax; ret
    data[fo:fo + len(patch)] = patch
    done += 1
    print(f"  {name} patché")
assert done >= 3, "exports MddBootstrap* introuvables"
open(dst, "wb").write(data)
PY
    python3 -I "$WORK/patch_bootstrap.py" "$b.orig" "$b"
}

step_patch_codepack() {
    # À la fermeture, PhotoLab appelle kernel32!UnregisterApplicationRecoveryCallback, absente de
    # Wine -> plantage. On neutralise l'appel dans Microsoft.WindowsAPICodePack.dll (Mono.Cecil).
    local l
    l="$(appdir)/Microsoft.WindowsAPICodePack.dll"
    [[ -f "$l.orig" ]] || cp "$l" "$l.orig"
    local dn="$WORK/dotnet" p="$WORK/cecil-patcher"
    export DOTNET_ROOT="$dn" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
           DOTNET_CLI_HOME="$WORK/dotnet-home" NUGET_PACKAGES="$WORK/nuget"
    if [[ ! -x "$dn/dotnet" ]]; then
        fetch https://dot.net/v1/dotnet-install.sh "$WORK/dotnet-install.sh"
        bash "$WORK/dotnet-install.sh" --channel 8.0 --install-dir "$dn" >/dev/null
    fi
    if [[ ! -f "$p/cecil-patcher.csproj" ]]; then
        rm -rf "$p"; mkdir -p "$p"
        (cd "$p" && "$dn/dotnet" new console --force -n cecil-patcher -o . >/dev/null \
            && "$dn/dotnet" add package Mono.Cecil --version "$CECIL_VERSION" >/dev/null)
    fi
    cat > "$p/Program.cs" <<'CS'
// Usage: cecil-patcher <in.dll> <out.dll> <Type.Complet> <Méthode> : rend une méthode void vide.
using Mono.Cecil;
using Mono.Cecil.Cil;
var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(args[0])));
using var asm = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters { AssemblyResolver = resolver });
var type = asm.MainModule.GetType(args[2]) ?? throw new Exception("type introuvable");
var method = type.Methods.Single(m => m.Name == args[3]);
if (method.ReturnType.FullName != "System.Void") throw new Exception("méthode non void");
method.Body.Instructions.Clear();
method.Body.ExceptionHandlers.Clear();
method.Body.Variables.Clear();
method.Body.GetILProcessor().Emit(OpCodes.Ret);
asm.Write(args[1]);
Console.WriteLine($"  {method.FullName} neutralisée");
CS
    (cd "$p" && "$dn/dotnet" run -- "$l.orig" "$WORK/Microsoft.WindowsAPICodePack.dll" \
        Microsoft.WindowsAPICodePack.ApplicationServices.ApplicationRestartRecoveryManager \
        UnregisterApplicationRecovery)
    cp "$WORK/Microsoft.WindowsAPICodePack.dll" "$l"
}

install_user_config_fixer() {
    cat > "$LIBDIR/fix-user-config.py" <<'PY'
"""Impose les réglages utilisateur de PhotoLab nécessaires sous Wine (lancé à chaque démarrage).

- UseWindowsMLAccelerationWhenAvailable=False : PhotoLab utilise alors ONNX Runtime pour l'IA.
  L'autre moteur (WinML) charge ses modèles via une API WinRT que Wine n'implémente pas
  (RandomAccessStreamReference.CreateFromStream) et les RAW ne s'affichent plus (0x80004001).
- PrefsLanguage : seulement à la création du fichier (le choix fait ensuite dans PhotoLab est gardé).

Usage : fix-user-config.py <WINEPREFIX> [langue]
"""
import glob, os, re, sys

prefix = sys.argv[1]
lang = sys.argv[2] if len(sys.argv) > 2 else "fr-FR"
user = os.environ.get("USER") or os.getlogin()
exes = glob.glob(os.path.join(prefix, "drive_c/Program Files/DxO/DxO PhotoLab */DxO.PhotoLab.exe"))
if not exes:
    sys.exit(0)
data = open(exes[0], "rb").read()
m = re.search("ProductVersion\0".encode("utf-16-le") + rb"(?:\0\0)*((?:[^\0]\0)+)", data)
version = m.group(1).decode("utf-16-le").split("+")[0]

TYPE = ("System.Configuration.ClientSettingsSection, System, Version=4.0.0.0, Culture=neutral, "
        "PublicKeyToken=b77a5c561934e089")
EMPTY = ('<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <configSections>\n'
         '    <sectionGroup name="userSettings">\n    </sectionGroup>\n  </configSections>\n'
         '  <userSettings>\n  </userSettings>\n</configuration>\n')

def setting(name, value):
    return (f'      <setting name="{name}" serializeAs="String">\n'
            f'        <value>{value}</value>\n      </setting>\n')

def ensure(text, section, name, value, override):
    if f'<section name="{section}"' not in text:
        decl = (f'      <section name="{section}" type="{TYPE}" '
                f'allowExeDefinition="MachineToLocalUser" requirePermission="false" />\n')
        text = text.replace("    </sectionGroup>", decl + "    </sectionGroup>", 1)
    sec = re.search(rf"<{re.escape(section)}>(.*?)</{re.escape(section)}>", text, re.S)
    if not sec:
        block = f"    <{section}>\n{setting(name, value)}    </{section}>\n"
        return text.replace("  </userSettings>", block + "  </userSettings>", 1)
    body = sec.group(1)
    cur = re.search(rf'<setting name="{name}" serializeAs="String">\s*<value>(.*?)</value>', body, re.S)
    if cur is None:
        body += setting(name, value)
    elif override and cur.group(1) != value:
        body = body[:cur.start(1)] + value + body[cur.end(1):]
    return text[:sec.start(1)] + body + text[sec.end(1):]

local = os.path.join(prefix, "drive_c/users", user, "AppData/Local/DxO")
dirs = glob.glob(os.path.join(local, "DxO.PhotoLab.exe_StrongName_*")) or \
    [os.path.join(local, "DxO.PhotoLab.exe_StrongName_addo3jomrfkt2faiwwfxxb444r1xfvlh")]
for d in dirs:
    path = os.path.join(d, version, "user.config")
    new = not os.path.exists(path)
    text = EMPTY if new else open(path, encoding="utf-8-sig").read()
    out = ensure(text, "DxO.PhotoLab.Common.Properties.Settings",
                 "UseWindowsMLAccelerationWhenAvailable", "False", override=True)
    if new:
        out = ensure(out, "DxO.PhotoLab.Settings.Properties.Settings", "PrefsLanguage", lang, override=False)
    if out != text:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", encoding="utf-8").write(out)
PY
}

step_user_settings() {
    install_user_config_fixer
    python3 -I "$LIBDIR/fix-user-config.py" "$PREFIX" "$DXO_LANG"
}

step_launcher() {
    install_user_config_fixer
    install_dxcore_patcher
    local vk=""
    if [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
        # sinon llvmpipe (GPU logiciel) est vu en premier et sert de carte « WARP » au moteur IA
        vk='export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json'
    fi
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    cat > "$HOME/.local/bin/dxo-photolab" <<EOF
#!/bin/bash
# Lanceur DxO PhotoLab (généré par install-dxo-photolab.sh)
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all DXVK_LOG_LEVEL=none VKD3D_DEBUG=none
$vk
# WebView2 : pas de sandbox Chromium sous Wine, et rendu logiciel (DirectComposition non supporté)
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu --disable-gpu-compositing"
python3 -I "$LIBDIR/fix-user-config.py" "\$WINEPREFIX" "$DXO_LANG" || true
APP="\$(ls -d "\$WINEPREFIX/drive_c/Program Files/DxO/DxO PhotoLab "* | head -1)"
# Wine mis à jour ? Refaire la copie corrigée de dxcore.dll (sinon la retirer : PhotoLab
# repasse sur le processeur au lieu d'utiliser une DLL d'une autre version de Wine).
SRC="\$(dirname "\$(dirname "\$(readlink -f "\$(command -v wine)")")")/lib/wine/x86_64-windows/dxcore.dll"
if [ -f "\$SRC" ] && [ "\$(sha256sum < "\$SRC")" != "\$(cat "$LIBDIR/dxcore.src.sha256" 2>/dev/null)" ]; then
    if python3 -I "$LIBDIR/patch_dxcore.py" "\$SRC" "\$APP/dxcore.dll.new" >/dev/null 2>&1; then
        mv -f "\$APP/dxcore.dll.new" "\$APP/dxcore.dll"
        sha256sum < "\$SRC" > "$LIBDIR/dxcore.src.sha256"
    else
        rm -f "\$APP/dxcore.dll" "\$APP/dxcore.dll.new"
        notify-send "DxO PhotoLab" "Wine a changé : accélération GPU désactivée (relancer install-dxo-photolab.sh --redo gpu-dxcore)" 2>/dev/null || true
    fi
fi
cd "\$APP" && exec wine DxO.PhotoLab.exe "\$@"
EOF
    chmod +x "$HOME/.local/bin/dxo-photolab"
    cat > "$HOME/.local/share/applications/dxo-photolab.desktop" <<EOF
[Desktop Entry]
Name=DxO PhotoLab 9
Comment=Développement photo RAW (Wine)
Exec=$HOME/.local/bin/dxo-photolab
Type=Application
Categories=Graphics;Photography;
Icon=wine
EOF
}

# ---------------------------------------------------------------- main
if [[ -z "$SETUP" ]]; then
    SETUP=$(ls "$PWD"/DxO_PhotoLab*Setup*.exe "$HOME"/Téléchargements/DxO_PhotoLab*Setup*.exe \
               "$HOME"/Downloads/DxO_PhotoLab*Setup*.exe 2>/dev/null | head -1 || true)
fi

log "Journal : $LOG"
log "Préfixe : $PREFIX"
log "Installeur : ${SETUP:-(non trouvé)}"

if [[ -d "$PREFIX" && ! -d "$MARK" ]]; then
    die "$PREFIX existe déjà et n'a pas été créé par ce script : supprimez-le ou utilisez --prefix"
fi

IFS=',' read -r -a redo_list <<< "$REDO"
for s in "${redo_list[@]}"; do
    [[ -n "$s" ]] && rm -f "$MARK/$s.done"
done

[[ $DO_SYSTEM -eq 1 ]] && step_system
check_tools

run_step prefix          step_prefix
run_step dotnet48        step_dotnet48
run_step vcrun2022       step_vcrun2022
run_step winetricks-misc step_winetricks_misc
run_step photolab        step_photolab
run_step webview2        step_webview2
run_step dxvk-vkd3d      step_dxvk_vkd3d
run_step gpu-dxcore      step_gpu_dxcore
run_step winml           step_winml
run_step ui              step_ui
run_step patch-bootstrap step_patch_bootstrap
run_step patch-codepack  step_patch_codepack
run_step user-settings   step_user_settings
if [[ $DO_LAUNCHER -eq 1 ]]; then
    run_step launcher    step_launcher
fi

wineserver -k || true
log "Installation terminée."
[[ $DO_LAUNCHER -eq 1 ]] && log "Lancer : menu « DxO PhotoLab 9 » ou ~/.local/bin/dxo-photolab"
exit 0
